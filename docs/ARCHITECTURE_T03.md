# AIMindTree T03 同步架构

> 范围：从本地 Drift 数据库 → Supabase 隔离层中转 → 其他端点，让数据可跨端。
> 替代 §ARCHITECTURE.md §11 原"占位"段落。

---

## 1. 设计目标

- **跨端一致**：笔记 / KP / 掌握记录 / Canvas 在多端最终一致（eventual consistency）
- **离线优先**：本地数据库是唯一可信源（source of truth），网络只是分发通道
- **简单冲突处理**：LWW（Last-Write-Wins）按 `version` 排序，平局看 `updated_at`
- **可恢复**：断网 / 推送失败 → 重试，Outbox 持久化保证不丢
- **威胁模型**：设备级隔离 + Supabase 隔离层中转，客户端不持长期凭证

## 2. 不做什么（P0 简化）

- ❌ 不做 CRDT（按 KP / 按 Canvas 节点的细粒度合并留给 T09+）
- ❌ 不做服务端冲突判定（push 简单接受；冲突由下一次 pull 收敛）
- ❌ 不做字段级权限 / 加密传输（依赖 https + supabase 隔离层）
- ❌ 不做实时推送（WebSocket / SSE 增量留给 T10+）

## 3. 数据流总览

```
┌─────────────────────────┐                ┌─────────────────────────┐
│   本地 Drift（每端）    │                │   Supabase ai-proxy     │
│                         │   push / pull   │   (隔离层中转)           │
│   Write ──→ Outbox      │ ──────────────→ │   /sync/push            │
│                         │                 │   /sync/pull            │
│   Pull ──→ merge ──→ DB │ ←────────────── │   /sync/manifest        │
│                         │                 │                         │
└─────────────────────────┘                └─────────────────────────┘
        ↑                                           ↑
        │ watch                                     │ service-role
        │                                           │ 写 users/<uid>/<table>
   Drift Stream                                (Postgres RLS)
```

## 4. 表清单（同步范围）

所有带 `SyncMeta` mixin 的表都参与同步：

| 表 | 备注 |
|---|---|
| `notebooks` | 顶层容器 |
| `notes` | 笔记正文 |
| `knowledge_points` | KP（含 anchor 4 元组） |
| `prerequisite_edges` | KP 前置关系 |
| `mastery_records` | 掌握状态（append-only） |
| `cards` | 卡片（append-only） |
| `canvases` / `canvas_nodes` / `canvas_edges` | 画布 |
| `ai_sessions` / `ai_messages` | AI 对话 |
| `ai_providers` / `ai_task_routes` | 配置（密钥不入 DB） |

**不参与同步**：`sync_outbox`（本地队列）、`secret_store`（密钥本地）。

## 5. SyncEnvelope（同步传输单位）

```dart
class SyncEnvelope {
  final String deviceId;       // 产生此变更的设备
  final String entityTable;    // 表名
  final String entityId;       // 行 id
  final SyncOp op;             // upsert / delete
  final Map<String, dynamic> payload;  // 行最终态
  final int baseVersion;       // 该行 push 前的本地 version
  final DateTime updatedAt;    // 行的 updated_at
  final DateTime? deletedAt;   // 软删除 tombstone
}

enum SyncOp { upsert, delete }
```

**payload 序列化**：用 Drift 的 row → `Map<String, dynamic>`，`Map → row` 反序列化；JsonEncode/Decode 用 `json` 标准库。

## 6. Push 流程

```
local Outbox pending rows
       │
       ▼ ① 读取 status='pending' 的前 N 条（限流）
   SyncEnvelope[] batch
       │
       ▼ ② 标记为 status='sending'（防重复推）
       │
       ▼ ③ POST /sync/push { device_id, envelopes }
       │
   ┌───┴────┐
   │ 2xx    │ 其他
   ▼        ▼
   成功    失败：retryCount++ + status='failed'
   markPushed(env.id)
   （10s 后重试）
```

- **重试**：指数退避（10s → 30s → 60s），超过 5 次告警
- **限流**：单次 push 最多 100 条
- **顺序**：同表同 id 按 `baseVersion` 升序推；不保证跨表顺序

## 7. Pull 流程

```
last_pulled_at (本地持久化)
       │
       ▼ ① POST /sync/pull { device_id, since: last_pulled_at }
       │
   server 返回 { envelopes: [...], server_time }
       │
       ▼ ② 过滤 self 回声：deviceId == 本地 → 丢弃
       │
       ▼ ③ mergeRow(envelope) — 逐条 LWW 合并
       │
       ▼ ④ 应用到本地 DB
       │
       ▼ ⑤ last_pulled_at = server_time
```

**自回声**：本地 push 后，pull 会从服务端拿到自己的 envelope（因为服务端不知道客户端已经收到）。必须在本地过滤掉 `envelope.deviceId == 本地 deviceId`。

## 8. LWW 合并算法

```
mergeRow(local, remote):
  if local == null: insert(remote)
  elif remote.deletedAt != null: delete(local)
  elif remote.baseVersion < local.version: keep local  // 老数据
  elif remote.baseVersion > local.version: apply remote // 新数据
  else: // version 相同 → 看时间
    if remote.updatedAt > local.updatedAt: apply remote
    else: keep local
```

**冲突判定**：服务端收到 push 时如果发现同 id 已存在但 `server.version > envelope.baseVersion`，**先 reject** 让客户端 pull 后再推（P0 不做，客户端 push 覆盖服务端）。

## 9. Tombstone（删除传播）

- 本地软删除一行 → 写 Outbox `{op: delete, deleted_at: now}`
- Push → 服务端标记 `deleted_at = not null`
- Pull → 对方端 merge 时 `remote.deletedAt != null` → 本地硬删除（保留 outbox 历史记录）

## 10. SyncStatus 持久化

```
shared_preferences:
  aimindtree.last_pulled_at       : ISO8601 string
  aimindtree.last_push_at         : ISO8601 string
  aimindtree.last_sync_status     : "idle" | "syncing" | "error:..."
```

## 11. 调度策略

- **启动**：一次性全量 push pending → pull since last_pulled_at
- **周期性**：60s 一次后台同步（仅 Wi-Fi / 电量正常）
- **手动**：设置页「立即同步」按钮
- **失败退避**：指数退避，避免风暴

## 12. API 契约（Supabase ai-proxy 端点）

```
POST /sync/push
  Headers: Authorization: Bearer <user_token>
  Body:    { device_id, envelopes: SyncEnvelope[] }
  Resp:    { accepted: int, server_time: ISO8601 }

POST /sync/pull
  Headers: Authorization: Bearer <user_token>
  Body:    { device_id, since: ISO8601 | null }
  Resp:    { envelopes: SyncEnvelope[], server_time: ISO8601 }

POST /sync/manifest  （可选：列出服务端所有 envelope 总数）
  Resp:    { count: int }
```

## 13. 测试策略

- `MockSyncApi`：可配置返回 envelopes / 接受/拒绝策略
- `sync_engine_test.dart`：用 `NativeDatabase.memory()` + MockSyncApi 覆盖：
  - push 单条 / 批量 / 失败重试
  - pull + 自回声过滤
  - LWW version 大者赢
  - LWW 平局时间晚者赢
  - tombstone 删除传播
  - 完整 push → pull 闭环

## 14. 配置

设置页新增「同步」分区：
- Supabase URL（如 `https://xxx.supabase.co/functions/v1/ai-proxy`）
- User Token（Bearer；走 Supabase Auth）
- 「立即同步」按钮
- 状态显示：上次同步时间 / 待推条数 / 错误信息

## 15. 风险与边界

- **密钥同步**：`ai_providers` 行的 `api_key_ref` 不参与 push（密钥只在 SecretStore）
- **增量冲突**：pull 期间本地又写了 → outbox 会有记录，下次 push 解决
- **大表全量**：不实现"按时间分页"，一次 pull 可能上千条（待 T09+ 分页）
- **T03 不做**：实时同步（WS）、CRDT、字段权限、离线编辑合并 UI 反馈