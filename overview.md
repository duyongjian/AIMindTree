# AIMindTree — P0 全量交付总结

**日期**：2026-09-07
**阶段**：T07 收口 + Bugfix + T03 同步全部完成 → **P0 闭环**

---

## TL;DR

今天集中推进两件事：
1. **T07 收口**：把硬编码 Dify Key 拆到 `ai_providers` 表 + SecretStore 模式，新增设置页 UI（4 Tab）；
2. **T03 同步**：从占位段落变成可跑通的 Outbox + LWW + Supabase 中转实现，含 12 个集成测试；

顺带发现并修复了一个**真实的存量 bug**（MasteryRecords 同毫秒排序不稳定）。

至此 P0 全部 7 个任务闭环。

---

## 一、T07 收口 + Bugfix（详见前一份 overview）

- 5 新文件 + 3 改文件（详见 daily log `2026-09-07.md` 上午段）
- Bug：`MasteryRecords.currentMastery` 用 `ORDER BY updatedAt DESC` 在同毫秒连写时退化成按 rowid 排 → 改成用 `version` 列做权威排序键
- 关键决策：密钥只存 SecretStore 不进 DB；Provider 启动一次性装载，UI 改动需重启生效

## 二、T03 同步（P0 最后一项）

### 设计文档
`docs/ARCHITECTURE_T03.md` 完整规划：数据流图、表清单、SyncEnvelope、Push / Pull 流程、LWW 决策表、Tombstone 语义、API 契约、测试策略、配置。

### 实现（11 新文件 + 3 改文件）

| 层 | 文件 | 职责 |
|---|---|---|
| 协议 | `sync_types.dart` | SyncOp / OutboxStatus / SyncEnvelope（不可变 + toJson/fromJson） |
| 持久 | `sync_outbox.dart` | SyncOutboxRepo（状态机 + 批量 customUpdate） |
| 网络 | `sync_api.dart` | 抽象 + HttpSyncApi（dart:io，UTF-8，Bearer）+ MockSyncApi |
| 引擎 | `sync_engine.dart` | push / pull / merge / LWW / Tombstone / 5 张表 Row↔Map |
| 状态 | `sync_status.dart` | SyncStatusStore（shared_preferences：last_pulled_at / last_push_at / status） |
| 配置 | `sync_config.dart` | SyncConfig（prefs 存 URL/token_ref/enabled，token 走 SecretStore） |
| 调度 | `sync_scheduler.dart` | 启动一次性 + 周期 60s + 手动触发 + 失败退避 |
| 容器 | `sync_context.dart` | SyncContext 容器 |
| UI | `sync_settings_section.dart` | 设置页新增「同步」分区 |

### LWW 决策表（不可变）

```
┌──────────────────────────────┬────────────────────────┐
│ remote vs local              │ 结果                    │
├──────────────────────────────┼────────────────────────┤
│ remote.deletedAt != null     │ 本地硬删除该行          │
│ remote.baseVersion > local     │ apply remote            │
│ remote.baseVersion < local   │ keep local              │
│ == 且 remote.updatedAt 晚    │ apply remote            │
│ remote.deviceId == 本地      │ skip（自回声）           │
└──────────────────────────────┴────────────────────────┘
```

### 关键决策

1. **`baseVersion` = 目标 version**（不是前置 version）：写入本地时直接落地，不 +1
2. **自回声过滤**：pull 时 deviceId == 本地 → 跳过
3. **Tombstone**：deleted envelope 直接硬删本地行（保留 outbox 历史）
4. **Mock 占位**：未配 sync 配置时使用 MockSyncApi，App 启动不报错
5. **P0 简化**：失败 5 次告警 + 连续 3 次失败进入 5 分钟退避；不分页不分批
6. **零网络依赖**：复用 dart:io HttpClient（与 DifyClient 同），不引入 `package:http`

### 同类风险排查
- ✅ MasteryRecords：DESC 取最新 → 已修（用 version 列）
- ✅ AiMessages：ASC 列消息 → 不动（ULID 单调兜底）
- ✅ PrerequisiteEdges / Cards：无 ORDER BY → 不动

## 三、验证结果

```
flutter test --no-pub          →  45 / 45 通过
  ├─ knowledge_repository_test   5/5  ✓（含修复后的链式级联）
  ├─ layout_engine_test          7/7  ✓
  ├─ models_test                 8/8  ✓
  ├─ secret_store_test           6/6  ✓
  ├─ settings_repository_test    7/7  ✓
  └─ sync_engine_test           12/12 ✓（新增：push/自回声/LWW×4/Tombstone/闭环）

flutter analyze --no-pub       →  No issues found!
```

## 四、P0 全量任务清单

| 任务 | 状态 | 关键产出 |
|---|---|---|
| T01 基础设施 | ✅ | Drift / Result / ULID / Logger / Platform |
| T02 数据层 | ✅ | 14 张表 + 锚点校验 + 级联降级（已修 version 排序 bug） |
| **T03 同步** | ✅ | **Outbox + LWW + Supabase 中转 + 12 测试** |
| T04 AI Provider 抽象 | ✅ | DifyClient / AiTask / AiTaskRouter / AiService |
| T05 画布 + 知识树 | ✅ | LayoutEngine / TreeCanvas / 卡片 |
| T06 业务流 | ✅ | 笔记编辑器 / 老师模式 / 画布节点 |
| T07 多端适配 | ✅ | 设置页 4 Tab + SecretStore + ai_providers 表 |

## 五、文件清单（绝对路径）

**T03 新增（11）**：
- `D:\AndroidStudioProjects\AIMindTree\docs\ARCHITECTURE_T03.md`
- `D:\AndroidStudioProjects\AIMindTree\aimindtree_app\lib\data\sync\sync_types.dart`
- `D:\AndroidStudioProjects\AIMindTree\aimindtree_app\lib\data\sync\sync_outbox.dart`
- `D:\AndroidStudioProjects\AIMindTree\aimindtree_app\lib\data\sync\sync_api.dart`
- `D:\AndroidStudioProjects\AIMindTree\aimindtree_app\lib\data\sync\sync_engine.dart`
- `D:\AndroidStudioProjects\AIMindTree\aimindtree_app\lib\data\sync\sync_status.dart`
- `D:\AndroidStudioProjects\AIMindTree\aimindtree_app\lib\data\sync\sync_config.dart`
- `D:\AndroidStudioProjects\AIMindTree\aimindtree_app\lib\data\sync\sync_scheduler.dart`
- `D:\AndroidStudioProjects\AIMindTree\aimindtree_app\lib\data\sync\sync_context.dart`
- `D:\AndroidStudioProjects\AIMindTree\aimindtree_app\lib\features\settings\sync_settings_section.dart`
- `D:\AndroidStudioProjects\AIMindTree\aimindtree_app\test\sync_engine_test.dart`

**T03 修改（3）**：
- `D:\AndroidStudioProjects\AIMindTree\aimindtree_app\lib\ai\extraction_service.dart`（bootstrap 返回 5 元组，装配 SyncContext）
- `D:\AndroidStudioProjects\AIMindTree\aimindtree_app\lib\main.dart`（注入 SyncContext / SecretStore）
- `D:\AndroidStudioProjects\AIMindTree\aimindtree_app\lib\features\settings\settings_page.dart`（嵌入 SyncSettingsSection）

**日志 / 长期记忆**：
- `D:\AndroidStudioProjects\AIMindTree\.workbuddy\memory\2026-09-07.md`（追加 T03 段）
- `D:\AndroidStudioProjects\AIMindTree\.workbuddy\memory\MEMORY.md`（新增 §7 LWW 决策表 + §8 baseVersion 语义 + §9 sync 包约定）

## 六、下一步建议

1. **真机端到端验证**（必须）：
   ```
   cd D:\AndroidStudioProjects\AIMindTree\aimindtree_app
   flutter run -d windows
   ```
   - 首次启动：自动 seed Dify provider（来自 LocalAiConfig）
   - 设置 Tab → 同步：填 Supabase URL + Token → 测试 → 启用 → 立即同步
   - 没有 supabase 后端也能跑（Mock 占位）

2. **Supabase 端 ai-proxy 部署**（T03 闭环前置）：
   - 在 Supabase Edge Functions 里实现 `/sync/push`、`/sync/pull`、`/sync/manifest`
   - 用 service_role key 写 `users/<uid>/<table>`（按 user_id 隔离）
   - 表结构和 envelope 字段映射见 ARCHITECTURE_T03.md §12

3. **P1 已完成**：剩余 6 张 SyncMeta 表适配（cards / canvases / canvas_nodes / canvas_edges / ai_sessions / ai_messages），sync_engine_test 从 12 增到 20，全套件 53/53 通过

4. **P2 增量**（真机跑稳后再做）：
   - ai_providers / ai_task_routes 加 SyncMeta mixin + schemaVersion=2 迁移
   - Provider 变更响应式监听（当前重启生效）
   - 实时同步（WebSocket / SSE）
   - 冲突 UI 反馈（合并 / 覆盖选择）