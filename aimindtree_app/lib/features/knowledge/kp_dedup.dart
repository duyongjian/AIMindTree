/// 知识点「查重去重」全功能（T14）。
///
/// 用户诉求：让 AI 分析所有知识点，两个其实重复的知识点让用户选择只保留一个，
/// 被删点的所有关联信息挂到保留点上（知识树连线等），与连线规则冲突就不硬挂；
/// 且所有涉及知识点创建的环节都要在后台异步跑一轮查重，出结果弹给用户选。
///
/// 组成：
/// 1. **本地预筛**（[findDedupCandidates]）：名称规范化后按「完全相等 /
///    包含 / 字符二元组 Jaccard」打分，控制喂给 LLM 的量（纯函数，可单测）。
/// 2. **聚类**（[clusterDuplicateIds] / [buildKpDedupClusters]）：把 T14 返回的
///    重复对用并查集合成簇（纯函数）。
/// 3. **触发**（[kpDedupSchedule]）：各创建路径成功后 fire-and-forget；
///    进程内单例式合并（在飞就跳过），提交 T14 job（`kp:dedup` 资源锁，
///    silent 不进托盘打扰），完成后走全局导航键弹对话窗。
/// 4. **对话窗**（[showKpDedupDialog]）：每簇一个分区，Radio 选保留者
///    （默认 createdAt 最老者），确认后重新加载成员再逐簇合并。
/// 5. **合并核心**（[mergeDuplicateCluster]）：被删点的来源笔记 / 树成员 +
///    位置 / 连线 / 掌握度按序迁移到保留点，最后软删（墓碑）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../ai/ai_job_service.dart';
import '../../ai/ai_task.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../../data/db/drift_database.dart';
import '../../data/models/knowledge_point.dart';
import '../../data/repositories/knowledge_repository.dart';
import '../../data/repositories/tree_repository.dart';
import '../settings/tree_behavior_settings.dart';

/// 全局导航键：后台任务（T14 查重完成）没有页面上下文时，靠它弹对话窗。
///
/// 接在 `main.dart` 的 `MaterialApp.navigatorKey` 上；拿不到 context
/// （应用尚未挂载 / 已销毁）时调用方静默跳过并记日志。
final GlobalKey<NavigatorState> kGlobalNavigatorKey = GlobalKey<NavigatorState>();

final AppLog _log = AppLog('kp_dedup');

/// 本地预筛出的候选重复对（喂 LLM 之前的一道量控闸）。
class DedupCandidatePair {
  const DedupCandidatePair({
    required this.aId,
    required this.bId,
    required this.score,
  });

  final String aId;
  final String bId;

  /// 相似度：1.0 = 规范化后同名；0.8 = 包含关系；其余 = 二元组 Jaccard。
  final double score;
}

/// 规范化：转小写 + 去空白 / 标点 / 符号（保留字母、数字、CJK 等实字符）。
final RegExp _kNameNoise = RegExp(r'[\s\p{P}\p{S}]+', unicode: true);

String _normalizeName(String raw) =>
    raw.toLowerCase().replaceAll(_kNameNoise, '');

/// 字符二元组集合（长度 < 2 时无二元组）。
Set<String> _bigrams(String s) {
  if (s.length < 2) return const <String>{};
  final out = <String>{};
  for (var i = 0; i < s.length - 1; i++) {
    out.add(s.substring(i, i + 2));
  }
  return out;
}

/// 截断到 [max] 字符（超出补省略号，供 LLM 输入 / 对话窗展示控量）。
String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

/// 本地预筛候选重复对（纯函数）。
///
/// 规则（名称规范化后）：
/// - 完全相等 → 1.0；
/// - 互相包含且较短者长度 ≥ 4 → 0.8；
/// - 字符二元组 Jaccard ≥ 0.6 → 分数 = Jaccard。
///
/// 每个无序对只出一次；按分数降序（并列按 id 字典序，保证确定性）；
/// 截断到 [maxPairs]（默认 40，控制喂给 LLM 的量）。
/// 本地预筛候选重复对（纯函数，同步版）。
///
/// 大数据量 / 自动扫描请走 [findDedupCandidatesAsync]：把 O(n²) 两两比较丢到
/// 独立 isolate，避免阻塞 UI 主线程（A 优化）。两者语义完全一致，仅运行位置不同。
List<DedupCandidatePair> findDedupCandidates(
  List<KnowledgePoint> points, {
  int maxPairs = 40,
}) {
  return _computeCandidatesOnSeeds(_toSeeds(points), maxPairs: maxPairs);
}

/// 把知识点投影成可跨 isolate 传输的轻量种子 `[id, name]`。
/// `KnowledgePoint` 实例不可直接跨 isolate 发送，且预筛只用 name。
List<List<String>> _toSeeds(List<KnowledgePoint> points) =>
    <List<String>>[for (final p in points) <String>[p.id, p.name]];

/// 异步预筛：把 O(n²) 两两比较丢到独立 isolate（[compute]），不卡 UI 主线程（A 优化）。
///
/// 小数据 / 单测可继续用同步版 [findDedupCandidates]。点数 < 2 或非正 cap
/// 直接短路返回，不启动 isolate（省开销）。
Future<List<DedupCandidatePair>> findDedupCandidatesAsync(
  List<KnowledgePoint> points, {
  int maxPairs = 40,
}) {
  if (points.length < 2 || maxPairs <= 0) {
    return Future.value(const <DedupCandidatePair>[]);
  }
  final seeds = _toSeeds(points);
  return compute(_runFindDedup, (seeds, maxPairs));
}

/// isolate 入口（顶层函数，无捕获，保证可序列化发送）。
List<DedupCandidatePair> _runFindDedup((List<List<String>>, int) arg) =>
    _computeCandidatesOnSeeds(arg.$1, maxPairs: arg.$2);

/// 预筛核心（纯函数）：输入 `[id, name]` 种子，输出候选重复对。
/// 与 [findDedupCandidates] 行为一致，只是数据来源换成可序列化的种子，
/// 方便在 isolate 内运行。
List<DedupCandidatePair> _computeCandidatesOnSeeds(
  List<List<String>> seeds, {
  int maxPairs = 40,
}) {
  if (seeds.length < 2) return const <DedupCandidatePair>[];
  // 预计算：每个点的规范化名 + 二元组集合只算一次（配对是 O(n²) 的）。
  final names = <String>[];
  final grams = <Set<String>>[];
  for (final s in seeds) {
    final n = _normalizeName(s[1]);
    names.add(n);
    grams.add(_bigrams(n));
  }

  final out = <DedupCandidatePair>[];
  for (var i = 0; i < seeds.length; i++) {
    final a = names[i];
    if (a.isEmpty) continue;
    for (var j = i + 1; j < seeds.length; j++) {
      final b = names[j];
      if (b.isEmpty) continue;
      if (a == b) {
        out.add(DedupCandidatePair(aId: seeds[i][0], bId: seeds[j][0], score: 1.0));
        continue;
      }
      final shorter = a.length <= b.length ? a : b;
      final longer = a.length <= b.length ? b : a;
      if (shorter.length >= 4 && longer.contains(shorter)) {
        out.add(DedupCandidatePair(aId: seeds[i][0], bId: seeds[j][0], score: 0.8));
        continue;
      }
      final ga = grams[i];
      final gb = grams[j];
      if (ga.isEmpty || gb.isEmpty) continue;
      // 长度比预筛：J ≤ min/max，min/max < 0.6 时 J 必不达标，省掉集合交。
      final mn = ga.length <= gb.length ? ga.length : gb.length;
      final mx = ga.length <= gb.length ? gb.length : ga.length;
      if (mn * 10 < mx * 6) continue;
      var inter = 0;
      for (final g in ga) {
        if (gb.contains(g)) inter++;
      }
      if (inter == 0) continue;
      final union = ga.length + gb.length - inter;
      final jaccard = inter / union;
      if (jaccard >= 0.6) {
        out.add(DedupCandidatePair(
          aId: seeds[i][0],
          bId: seeds[j][0],
          score: jaccard,
        ));
      }
    }
  }

  out.sort((x, y) {
    final byScore = y.score.compareTo(x.score);
    if (byScore != 0) return byScore;
    final byA = x.aId.compareTo(y.aId);
    if (byA != 0) return byA;
    return x.bId.compareTo(y.bId);
  });
  return out.length <= maxPairs ? out : out.sublist(0, maxPairs);
}

/// T14 判定的一对重复（服务端 `duplicates` 数组元素）。
class DedupDuplicatePair {
  const DedupDuplicatePair({required this.aId, required this.bId, this.reason = ''});

  final String aId;
  final String bId;
  final String reason;
}

/// 容错解析 T14 结果里的 `duplicates` 列表（缺键 / 类型不对一律跳过）。
List<DedupDuplicatePair> parseDedupDuplicates(Object? raw) {
  if (raw is! List) return const <DedupDuplicatePair>[];
  final out = <DedupDuplicatePair>[];
  for (final e in raw) {
    if (e is! Map) continue;
    final a = (e['a_id'] as String?)?.trim() ?? '';
    final b = (e['b_id'] as String?)?.trim() ?? '';
    if (a.isEmpty || b.isEmpty || a == b) continue;
    out.add(DedupDuplicatePair(
      aId: a,
      bId: b,
      reason: (e['reason'] as String?)?.trim() ?? '',
    ));
  }
  return out;
}

/// 并查集聚类（纯函数）：把重复对合成 `List<List<String>>`（只留 ≥2 个 id 的簇）。
///
/// 传递性：A-B、B-C 判重 → A、B、C 同簇。簇内 id 升序、簇间按首个 id 升序，
/// 保证输出确定性（便于单测与 UI 稳定展示）。
List<List<String>> clusterDuplicateIds(Iterable<DedupDuplicatePair> pairs) {
  final parent = <String, String>{};

  String find(String x) {
    parent[x] ??= x;
    var root = x;
    while (parent[root] != root) {
      root = parent[root]!;
    }
    // 路径压缩
    var cur = x;
    while (parent[cur] != root) {
      final next = parent[cur]!;
      parent[cur] = root;
      cur = next;
    }
    return root;
  }

  for (final p in pairs) {
    final ra = find(p.aId);
    final rb = find(p.bId);
    if (ra != rb) parent[rb] = ra;
  }

  final groups = <String, List<String>>{};
  for (final id in parent.keys) {
    groups.putIfAbsent(find(id), () => <String>[]).add(id);
  }
  final out = groups.values.where((g) => g.length >= 2).toList();
  for (final g in out) {
    g.sort();
  }
  out.sort((a, b) => a.first.compareTo(b.first));
  return out;
}

/// 一个查重簇：≥2 个成员知识点 + AI 给出的重复判定理由。
class KpDedupCluster {
  const KpDedupCluster({required this.members, required this.reason});

  /// 成员（≥2；按 effectiveCreatedAt 升序，并列按 id，默认保留者即首个）。
  final List<KnowledgePoint> members;

  /// AI 判定理由（簇内多对时合并展示）。
  final String reason;

  List<String> get memberIds => <String>[for (final m in members) m.id];
}

/// 把 T14 重复对 + 当前库里的知识点合成查重簇。
///
/// 成员以 [points] 里的实时数据为准（扫描后可能被删 / 改）；不足 2 个存活
/// 成员的簇直接丢弃（没有去重意义）。
List<KpDedupCluster> buildKpDedupClusters({
  required List<DedupDuplicatePair> pairs,
  required List<KnowledgePoint> points,
}) {
  if (pairs.isEmpty) return const <KpDedupCluster>[];
  final byId = <String, KnowledgePoint>{for (final p in points) p.id: p};
  final out = <KpDedupCluster>[];
  for (final ids in clusterDuplicateIds(pairs)) {
    final members = <KnowledgePoint>[
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
    if (members.length < 2) continue;
    members.sort((a, b) {
      final byTime = a.effectiveCreatedAt.compareTo(b.effectiveCreatedAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    // 簇内所有 pair 的理由合并（去重、保序）。
    final idSet = ids.toSet();
    final reasons = <String>[];
    for (final p in pairs) {
      if (idSet.contains(p.aId) &&
          idSet.contains(p.bId) &&
          p.reason.isNotEmpty &&
          !reasons.contains(p.reason)) {
        reasons.add(p.reason);
      }
    }
    out.add(KpDedupCluster(members: members, reason: reasons.join('；')));
  }
  return out;
}

/// 默认保留者：createdAt 最老者；并列取列表中第一个（先到先得，纯函数）。
String defaultKeepId(List<KnowledgePoint> members) {
  assert(members.isNotEmpty);
  var best = members.first;
  for (final m in members) {
    if (m.effectiveCreatedAt.isBefore(best.effectiveCreatedAt)) best = m;
  }
  return best.id;
}

// ==================== 触发（各创建路径的后台异步查重） ====================

/// 进程内单例式合并标志：已有扫描 / T14 任务在飞 → 后续触发直接跳过。
bool _kpDedupInFlight = false;

/// 是否有一轮查重（扫描或 T14 任务）正在进行中（手动按钮先查它做提示）。
bool get kpDedupInFlight => _kpDedupInFlight;

/// 各知识点创建路径成功后的**后台异步**触发（fire-and-forget）。
///
/// 走防抖：批量创建（如一次导入几十个知识点）会在静默期后合并成**一次**扫描，
/// 避免每个点都跑一轮 O(n²) 预筛（E 优化）。手动按钮 [kpDedupRunNow] 不防抖，
/// 点了立即扫。
///
/// 行为：① 防抖静默期内重复触发只重置定时器；② 到点在飞就稍后重试；
/// ③ 读全部未删知识点；④ 无候选静默结束；⑤ 有候选 → 提交 T14 job
/// （`kp:dedup` 资源锁 + silent）；⑥ 完成 → [_onKpDedupResult]。
///
/// 内部全兜异常：本函数不抛错、不需要调用方等待。
void kpDedupSchedule({
  required KnowledgeRepository repo,
  required AiJobService jobs,
}) {
  _scheduleDebouncedScan(repo: repo, jobs: jobs);
}

/// 自动触发的防抖定时器（E 优化）。
///
/// 创建路径频繁触发时，只在「最后一次触发后 [_kKpDedupDebounce] 内无新触发」
/// 才真正跑一轮扫描。到点在飞则说明上一轮还没结束，稍后重试以免漏掉本次触发。
Timer? _kpDedupTimer;
const Duration _kKpDedupDebounce = Duration(milliseconds: 1500);

void _scheduleDebouncedScan({
  required KnowledgeRepository repo,
  required AiJobService jobs,
}) {
  _kpDedupTimer?.cancel();
  _kpDedupTimer = Timer(_kKpDedupDebounce, () {
    _kpDedupTimer = null;
    if (_kpDedupInFlight) {
      // 当前有扫描在飞，稍后重试，避免漏掉这次触发。
      _scheduleDebouncedScan(repo: repo, jobs: jobs);
      return;
    }
    _kpDedupScan(repo: repo, jobs: jobs);
  });
}

/// 手动「查重去重」按钮入口：与 [kpDedupSchedule] 同一管线，但把「无候选」
/// 回调给 UI 做 toast（后台路径传 null = 静默）。
///
/// 调用方应先查 [kpDedupInFlight] 自行提示「正在查重中」——在飞时这里也会
/// 直接返回，不重复开跑。
Future<void> kpDedupRunNow({
  required KnowledgeRepository repo,
  required AiJobService jobs,
  void Function()? onNoCandidates,
}) =>
    _kpDedupScan(
      repo: repo,
      jobs: jobs,
      onNoCandidates: onNoCandidates,
    );

Future<void> _kpDedupScan({
  required KnowledgeRepository repo,
  required AiJobService jobs,
  void Function()? onNoCandidates,
}) async {
  // 受「自动知识点查重」开关控制（E）：关 → 不查重（允许重复，不打扰）。
  if (!TreeBehaviorSettings.instance.dedupEnabled) {
    _log.i('知识点查重：开关「自动知识点查重」已关闭，跳过本次扫描');
    return;
  }
  if (_kpDedupInFlight) {
    _log.i('知识点查重：已有扫描 / 任务在飞，跳过本轮触发');
    return;
  }
  _kpDedupInFlight = true;
  try {
    // 软删铁律：allKnowledgePoints 已过滤 deletedAt。
    final points = await repo.allKnowledgePoints();
    // 预筛丢到独立 isolate，避免 O(n²) 两两比较卡住 UI 主线程（A 优化）。
    final candidates = await findDedupCandidatesAsync(points);
    if (candidates.isEmpty) {
      _kpDedupInFlight = false;
      onNoCandidates?.call();
      return;
    }
    final byId = <String, KnowledgePoint>{for (final p in points) p.id: p};
    final pairs = <Map<String, String>>[];
    for (final c in candidates) {
      final a = byId[c.aId];
      final b = byId[c.bId];
      if (a == null || b == null) continue;
      pairs.add(<String, String>{
        'a_id': a.id,
        'a_name': a.name,
        'a_def': _truncate(a.definition, 80),
        'b_id': b.id,
        'b_name': b.name,
        'b_def': _truncate(b.definition, 80),
      });
    }
    if (pairs.isEmpty) {
      _kpDedupInFlight = false;
      onNoCandidates?.call();
      return;
    }
    final job = await jobs.submit(
      task: AiTask.t14KpDedup.code,
      resourceKey: 'kp:dedup',
      label: '知识点查重',
      inputs: <String, dynamic>{'pairs': jsonEncode(pairs)},
      silent: true,
      onDone: (j) => _onKpDedupResult(j, repo),
      onError: (Object e) {
        _kpDedupInFlight = false;
        _log.w('知识点查重任务失败（忽略，不打扰主流程）：$e');
      },
      // 用户从托盘取消：不放标志会把这轮查重永久卡死在飞状态。
      onCancel: () {
        _kpDedupInFlight = false;
        _log.i('知识点查重任务被用户取消');
      },
    );
    if (job == null) {
      // 队列开关关 / 资源锁被占（客户端 isLocked 预检或服务端 409）→ 静默。
      _kpDedupInFlight = false;
    }
    // submit 成功：标志留到终态回调里放（onDone / onError / onCancel）。
  } on Object catch (e, s) {
    _kpDedupInFlight = false;
    _log.e('知识点查重触发异常', error: e, stackTrace: s);
  }
}

/// T14 完成：解析重复对 → 聚类 → 弹对话窗给用户选保留者。
Future<void> _onKpDedupResult(AiJob job, KnowledgeRepository repo) async {
  try {
    final parsed = job.result?['parsed'];
    final dups = parseDedupDuplicates(parsed is Map ? parsed['duplicates'] : null);
    if (dups.isEmpty) return; // 没判出重复：静默结束
    final ids = <String>{for (final d in dups) ...<String>{d.aId, d.bId}};
    // 重新读库：扫描可能过去了一会儿，用实时数据建簇。
    final points = await repo.pointsByIds(ids.toList());
    final clusters = buildKpDedupClusters(pairs: dups, points: points);
    if (clusters.isEmpty) return;
    final ctx = kGlobalNavigatorKey.currentContext;
    if (ctx == null) {
      _log.w('知识点查重：拿不到全局导航上下文，跳过结果弹窗');
      return;
    }
    // 树仓储与 KP 仓储必须共用同一个库实例（同步 outbox 身份校验）。
    final trees = TreeRepository(repo.db, deviceId: repo.deviceId);
    await showKpDedupDialog(
      ctx,
      clusters,
      repo: repo,
      trees: trees,
      db: repo.db,
    );
  } on Object catch (e, s) {
    _log.e('知识点查重结果处理异常', error: e, stackTrace: s);
  } finally {
    _kpDedupInFlight = false;
  }
}

// ==================== 合并核心 ====================

/// 一轮去重合并的执行报告。
class KpDedupMergeReport {
  const KpDedupMergeReport({
    required this.mergedCount,
    required this.skippedEdges,
    required this.failedIds,
  });

  /// 成功合并（软删）的被删点数量。
  final int mergedCount;

  /// 因连线规则冲突被跳过的边数（自环 / 单后继 / 防环，用户要求不硬挂）。
  final int skippedEdges;

  /// 合并异常的被删点 id。
  final List<String> failedIds;
}

/// 合并一个重复簇：[members] 里除 [keepId] 外的点逐个把关联迁移到保留点后软删。
///
/// 每个被删点**严格按此顺序**：
/// a. 来源笔记：KP 的 `sourceNoteId` 是单列（非集合），保留点没有来源时继承
///    被删点的；两边都有则保留保留点自己的（不硬改锚点语义）；
/// b. 树成员 + 位置：必须在软删**之前**（软删会级联硬删 canvas_nodes 行）。
///    保留点不是该树成员 → 入树；保留点无位置行且被删点有非 (0,0) 位置 →
///    继承坐标与 pinned；然后把被删点移出该树；
/// c. 连线迁移：被删点的出射边改挂 `keepId→X`、入射边改挂 `X→keepId`。
///    [KnowledgeRepository.addManualPrerequisiteEdge] 自带自环 / 单后继 /
///    防环校验，返回 Failure 就跳过该边并计数（与连线规则冲突不硬挂）；
/// d. 掌握度：保留点无掌握记录且被删点有 → 复制过去；
/// e. 软删（墓碑 + 级联清从属数据 + 同步墓碑入队）。
Future<KpDedupMergeReport> mergeDuplicateCluster({
  required KnowledgeRepository repo,
  required TreeRepository trees,
  required AppDatabase db,
  required List<KnowledgePoint> members,
  required String keepId,
}) async {
  if (members.length < 2) {
    return const KpDedupMergeReport(
      mergedCount: 0,
      skippedEdges: 0,
      failedIds: <String>[],
    );
  }
  var mergedCount = 0;
  var skippedEdges = 0;
  final failedIds = <String>[];

  // keepId 不在 members 里（调用方数据变动）→ 兜底用默认保留者。
  var keep = members.firstWhere(
    (m) => m.id == keepId,
    orElse: () => members.first,
  );

  for (final del in members) {
    if (del.id == keep.id) continue;
    try {
      // a. 来源笔记合并（走现成更新路径 updateKpMeta，不裸写 SQL）。
      if (keep.sourceNoteId.isEmpty && del.sourceNoteId.isNotEmpty) {
        final upd = await repo.updateKpMeta(
          keep.copyWith(sourceNoteId: del.sourceNoteId),
        );
        upd.fold(
          (_) => keep = keep.copyWith(sourceNoteId: del.sourceNoteId),
          (e, _) => _log.w('查重合并：来源笔记继承失败（${keep.id}）：$e'),
        );
      }

      // b. 树成员 + 位置（软删之前，否则 canvas_nodes 行被级联清掉）。
      for (final im in await trees.treesContaining(<String>[del.id])) {
        final treeId = im.treeId;
        // 先读布局再入树：addPoints 会给保留点造一条 (0,0) 位置行，
        // 读晚了就分不清「本来就没位置」还是「刚造的位置」。
        final layout = await repo.loadNodeLayout(treeId);
        final keepPos = layout[keep.id];
        final delPos = layout[del.id];
        if (!layout.containsKey(keep.id)) {
          await trees.addPoints(treeId, <String>[keep.id]);
        }
        if (keepPos == null &&
            delPos != null &&
            (delPos.x != 0 || delPos.y != 0)) {
          await repo.saveNodePosition(
            treeId,
            keep.id,
            delPos.x,
            delPos.y,
            pinned: delPos.pinned,
          );
        }
        await trees.removePoints(treeId, <String>[del.id]);
      }

      // c. 连线迁移（现成 helper：successorsOf / prerequisitesOf 即入射+出射）。
      for (final to in await repo.successorsOf(del.id)) {
        final r = await repo.addManualPrerequisiteEdge(
          keep.id,
          to,
          origin: 'manual',
          reason: '查重合并迁移',
        );
        if (r is Failure) skippedEdges++;
      }
      for (final from in await repo.prerequisitesOf(del.id)) {
        final r = await repo.addManualPrerequisiteEdge(
          from,
          keep.id,
          origin: 'manual',
          reason: '查重合并迁移',
        );
        if (r is Failure) skippedEdges++;
      }

      // d. 掌握度复制（保留点没有记录且被删点有）。
      if (await repo.currentMastery(keep.id) == MasteryStatus.unknown) {
        final inherited = await repo.currentMastery(del.id);
        if (inherited != MasteryStatus.unknown) {
          await repo.setMastery(keep.id, inherited);
        }
      }

      // e. 软删（墓碑 + 级联 + 同步入队）。
      final delRes = await repo.softDeleteKnowledgePoint(del.id);
      if (delRes is Success<int>) {
        mergedCount += delRes.value;
      } else {
        failedIds.add(del.id);
      }
    } on Object catch (e, s) {
      _log.e('查重合并失败（${del.id}）', error: e, stackTrace: s);
      failedIds.add(del.id);
    }
  }

  return KpDedupMergeReport(
    mergedCount: mergedCount,
    skippedEdges: skippedEdges,
    failedIds: failedIds,
  );
}

// ==================== 结果对话窗 ====================

/// 弹出去重对话窗：每簇一个分区，成员各一行（名称 + 截断定义 + AI 理由），
/// Radio 选保留者（默认 createdAt 最老者）；确认时先用
/// [KnowledgeRepository.pointsByIds] 重新加载成员（防扫描后数据变动），
/// 再逐簇 [mergeDuplicateCluster]，完成后 toast 汇报。
///
/// 列表刷新由调用方页面自行决定（本函数只负责合并与回执）。
Future<void> showKpDedupDialog(
  BuildContext context,
  List<KpDedupCluster> clusters, {
  required KnowledgeRepository repo,
  required TreeRepository trees,
  required AppDatabase db,
}) async {
  if (clusters.isEmpty) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _KpDedupDialog(
      clusters: clusters,
      repo: repo,
      trees: trees,
      db: db,
    ),
  );
}

class _KpDedupDialog extends StatefulWidget {
  const _KpDedupDialog({
    required this.clusters,
    required this.repo,
    required this.trees,
    required this.db,
  });

  final List<KpDedupCluster> clusters;
  final KnowledgeRepository repo;
  final TreeRepository trees;
  final AppDatabase db;

  @override
  State<_KpDedupDialog> createState() => _KpDedupDialogState();
}

class _KpDedupDialogState extends State<_KpDedupDialog> {
  /// 每簇选中的保留者 id（初始 = 默认保留者）。
  late final List<String> _keepIds =
      <String>[for (final c in widget.clusters) defaultKeepId(c.members)];

  bool _busy = false;

  Future<void> _confirm() async {
    setState(() => _busy = true);
    // ScaffoldMessenger 在 Navigator 之上，弹窗 pop 后依然有效，先取再用。
    final messenger = ScaffoldMessenger.of(context);
    // 重新加载成员：扫描到现在数据可能变了（删 / 改）。
    final allIds = <String>{for (final c in widget.clusters) ...c.memberIds};
    final fresh = await widget.repo.pointsByIds(allIds.toList());

    var clustersDone = 0;
    var mergedPoints = 0;
    var skippedEdges = 0;
    final failed = <String>[];
    for (var i = 0; i < widget.clusters.length; i++) {
      final c = widget.clusters[i];
      final members = fresh.where((p) => c.memberIds.contains(p.id)).toList();
      if (members.length < 2) continue; // 成员被删得不成簇：跳过
      var keepId = _keepIds[i];
      if (!members.any((m) => m.id == keepId)) {
        keepId = defaultKeepId(members); // 原保留者没了 → 回退默认
      }
      try {
        final report = await mergeDuplicateCluster(
          repo: widget.repo,
          trees: widget.trees,
          db: widget.db,
          members: members,
          keepId: keepId,
        );
        clustersDone++;
        mergedPoints += report.mergedCount;
        skippedEdges += report.skippedEdges;
        failed.addAll(report.failedIds);
      } on Object catch (e, s) {
        _log.e('查重合并异常', error: e, stackTrace: s);
        failed.addAll(members.where((m) => m.id != keepId).map((m) => m.id));
      }
    }

    if (!mounted) return;
    final msg = clustersDone == 0
        ? '没有可合并的重复知识点（数据已变动）'
        : '已合并 $clustersDone 簇（$mergedPoints 个重复知识点）'
            '${skippedEdges > 0 ? '，跳过 $skippedEdges 条冲突连线' : ''}'
            '${failed.isNotEmpty ? '，${failed.length} 个失败' : ''}';
    messenger.showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 3),
    ));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('发现 ${widget.clusters.length} 组重复知识点'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '每组选择要保留的知识点，其余成员的关联（来源笔记 / 树成员 / '
                '连线 / 掌握度）将迁移到保留者；与连线规则冲突的关联不会强行挂上。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < widget.clusters.length; i++) ...[
                Text(
                  '第 ${i + 1} 组（${widget.clusters[i].members.length} 个）',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                if (widget.clusters[i].reason.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2, bottom: 4),
                    child: Text(
                      'AI 理由：${widget.clusters[i].reason}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                RadioGroup<String>(
                  groupValue: _keepIds[i],
                  // RadioGroup.onChanged 非空：合并进行中在这里内部挡住。
                  onChanged: (v) {
                    if (_busy) return;
                    setState(() => _keepIds[i] = v ?? _keepIds[i]);
                  },
                  child: Column(
                    children: <Widget>[
                      for (final m in widget.clusters[i].members)
                        RadioListTile<String>(
                          value: m.id,
                          title: Text(m.name),
                          subtitle: m.definition.isEmpty
                              ? null
                              : Text(
                                  _truncate(m.definition, 40),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 16),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('暂不处理'),
        ),
        FilledButton(
          onPressed: _busy ? null : _confirm,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('去重并迁移关联'),
        ),
      ],
    );
  }
}
