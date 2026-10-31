/// 作业历史页（作业的「找回来」入口）。
///
/// 数据来源全部是 `homeworks` 表（经 [HomeworkRepository]，已过滤软删墓碑）：
/// - [HomeworkHistoryPage.kpId] 非空 → [HomeworkRepository.listByKp]（某知识点的作业）
/// - 否则 [HomeworkHistoryPage.canvasId] 非空 → [HomeworkRepository.listByCanvas]（某棵树的作业）
/// - 否则 [HomeworkRepository.listAll]（全局历史）
///
/// 能力（作业的完整增删改查，草稿同样适用）：
/// - **增**：AppBar「＋」/ [HomeworkPage] 新建；从知识点入口进来会自动带上该点，
///   从树入口进来会带该树 `canvasId`，全局入口 `canvasId` 为空串（落「未关联」）。
/// - **查**：搜索（标题 / 题目所属知识点名 / 题干子串，`toLowerCase`，中文不受影响）
///   ＋ 状态筛选（全部 / 待完成`assigned` / 已完成`done` / **草稿`draft`**，均带计数）
///   ＋ 两种分组（默认按「知识点」用题目里冗余的 `kpName`，可切按「时间」今天/昨天/更早）。
/// - **改**：标记已完成 / 转为待完成 / **转为草稿** / 编辑（回作业页 `existingId`）。
/// - **删**：软删墓碑，删除后 SnackBar 给 5 秒「撤销」（[HomeworkRepository.restore]，
///   清 `deleted_at` + bump version + 上行，不是再 create 一条复制品）。
///
/// 草稿也算正式记录：`status='draft'` 的行照常出现在列表里（橙色徽标），
/// 可编辑、可删、可再存草稿，也可以一键「转为待完成」正式布置。
/// 点条目 → 打开作业页继续编辑，返回后自动重载列表。
///
/// 设计要点：本页**不写表**，状态与删除一律走仓储层（§11 禁 UI 直写表）；
/// 作业关联的知识点按 `kpId`（主外键）→ `kpIds`（快照）的顺序解析，
/// 解析不到就给空列表（作业页允许空 points，出题时提示手动添加）。
library;

import 'package:flutter/material.dart';

import '../../ai/ai_job_service.dart';
import '../../ai/ai_service.dart';
import '../../core/id.dart';
import '../../core/result.dart';
import '../../data/db/drift_database.dart';
import '../../data/models/homework.dart';
import '../../data/models/knowledge_point.dart';
import '../../data/repositories/homework_repository.dart';
import '../../data/repositories/knowledge_repository.dart';
import 'homework_page.dart';

/// 作业历史页。
class HomeworkHistoryPage extends StatefulWidget {
  const HomeworkHistoryPage({
    super.key,
    required this.ai,
    required this.db,
    required this.jobs,
    this.canvasId,
    this.kpId,
    this.title = '作业历史',
  });

  /// AI 服务（点条目进作业页出题时透传）。
  final AiService ai;

  final AppDatabase db;

  /// AI 任务队列（作业页持 `homework:{id}` 锁 + 托盘计时）。
  final AiJobService jobs;

  /// 非空 = 只看这棵树的作业。
  final String? canvasId;

  /// 非空 = 只看这个知识点的作业（**优先级高于** [canvasId]）。
  final String? kpId;

  /// AppBar 标题（知识点入口会带上知识点名）。
  final String title;

  @override
  State<HomeworkHistoryPage> createState() => _HomeworkHistoryPageState();
}

class _HomeworkHistoryPageState extends State<HomeworkHistoryPage> {
  late final HomeworkRepository _repo =
      HomeworkRepository(widget.db, deviceId: DeviceId.orEmpty);

  /// 知识点解析专用仓储（只读 `pointsByIds`）。
  late final KnowledgeRepository _kpRepo =
      KnowledgeRepository(widget.db, deviceId: DeviceId.orEmpty);

  /// 全量（已按 updatedAt desc 由仓储排好序）。
  List<Homework> _all = <Homework>[];

  bool _loading = true;

  /// 搜索关键词（小写化后比较）。
  final TextEditingController _queryCtrl = TextEditingController();
  String _query = '';

  /// 状态筛选：`all` / `assigned` / `done` / `draft`。
  String _statusFilter = 'all';

  /// 分组方式：false = 按知识点（默认），true = 按时间平铺。
  bool _byTime = false;

  /// 「无法归属知识点」那一组的组名（永远排最后）。
  static const String _unlinkedLabel = '未关联知识点';

  /// 时间分组的固定顺序。
  static const List<String> _timeGroups = <String>['今天', '昨天', '更早'];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  /// 按入口优先级载入作业列表。
  Future<void> _reload() async {
    final String? kpId = widget.kpId;
    final String? canvasId = widget.canvasId;
    final List<Homework> list;
    if (kpId != null) {
      list = await _repo.listByKp(kpId);
    } else if (canvasId != null) {
      list = await _repo.listByCanvas(canvasId);
    } else {
      list = await _repo.listAll();
    }
    if (!mounted) return;
    setState(() {
      _all = list;
      _loading = false;
    });
  }

  /// 取某条作业的更新时间（模型带 `updatedAt`，仓储层已按它降序排好）。
  DateTime? _timeOf(Homework hw) => hw.updatedAt;

  // ============ 过滤 ============

  /// 状态 + 关键词双重过滤后的结果（顺序沿用仓储的 updatedAt desc）。
  List<Homework> get _filtered {
    final q = _query.trim().toLowerCase();
    return _all.where((hw) {
      if (_statusFilter != 'all' && hw.status != _statusFilter) return false;
      return _matches(hw, q);
    }).toList();
  }

  /// 关键词匹配：标题 / 题目知识点名 / 题干任一命中即算命中。
  bool _matches(Homework hw, String q) {
    if (q.isEmpty) return true;
    if (hw.title.toLowerCase().contains(q)) return true;
    for (final item in hw.items) {
      if (item.kpName.toLowerCase().contains(q)) return true;
      if (item.question.toLowerCase().contains(q)) return true;
    }
    return false;
  }

  // ============ 展示辅助 ============

  /// 某状态（或全部）的份数。分母是 `_all`（未筛选的全量），
  /// 这样搜索/筛选时计数不会跟着跳变。
  int _countOf(String key) => key == 'all'
      ? _all.length
      : _all.where((Homework h) => h.status == key).length;

  /// 状态 → 中文标签。
  String _statusLabel(String status) => switch (status) {
        'done' => '已完成',
        'draft' => '草稿',
        'assigned' => '待完成',
        _ => status,
      };

  /// 状态 → 颜色（与状态标签同源，避免两处不一致）。
  Color _statusColor(String status) => switch (status) {
        'done' => Colors.green,
        'draft' => Colors.orange,
        'assigned' => Colors.indigo,
        _ => Colors.grey,
      };

  /// 更新时间 `MM-dd HH:mm`（本地时区）。
  String _formatTime(DateTime updatedAt) {
    final t = updatedAt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  /// 批量徽标文案：取 batchId 尾 4 位（短 id 就整段显示）。
  String _batchLabel(String batchId) {
    final tail =
        batchId.length <= 4 ? batchId : batchId.substring(batchId.length - 4);
    return '批量 #$tail';
  }

  /// 按知识点分组：组名取第一条题目的 `kpName`，没有题目就回退作业标题。
  String _kpGroupLabel(Homework hw) {
    for (final item in hw.items) {
      if (item.kpName.trim().isNotEmpty) return item.kpName.trim();
    }
    if (hw.title.trim().isNotEmpty) return hw.title.trim();
    return _unlinkedLabel;
  }

  /// 按时间分组：今天 / 昨天 / 更早（时间缺失按「更早」处理）。
  String _timeGroupLabel(DateTime? updatedAt) {
    if (updatedAt == null) return '更早';
    final t = updatedAt.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    if (diff <= 0) return '今天';
    if (diff == 1) return '昨天';
    return '更早';
  }

  // ============ 分组渲染 ============

  /// 把过滤结果切成「组头 + 条目」的一维 widget 列表。
  List<Widget> _buildGroupedWidgets(List<Homework> items) {
    final List<Widget> out = <Widget>[];
    if (_byTime) {
      // 按固定顺序输出三个时间组，保证「今天」永远在最上。
      final Map<String, List<Homework>> buckets = <String, List<Homework>>{
        for (final label in _timeGroups) label: <Homework>[],
      };
      for (final hw in items) {
        buckets[_timeGroupLabel(_timeOf(hw))]!.add(hw);
      }
      for (final label in _timeGroups) {
        final group = buckets[label]!;
        if (group.isEmpty) continue;
        out.add(_groupHeader(label, group.length));
        for (final hw in group) {
          out.add(_tile(hw));
        }
      }
      return out;
    }

    // 按知识点：保持「首次出现顺序」（列表已按 updatedAt desc，等于最近用到的在上），
    // 「未关联知识点」单独拎出来压到最后。
    final Map<String, List<Homework>> groups = <String, List<Homework>>{};
    for (final hw in items) {
      final label = _kpGroupLabel(hw);
      groups.putIfAbsent(label, () => <Homework>[]).add(hw);
    }
    final List<Homework> unlinked =
        groups.remove(_unlinkedLabel) ?? <Homework>[];
    groups.forEach((label, group) {
      out.add(_groupHeader(label, group.length));
      for (final hw in group) {
        out.add(_tile(hw));
      }
    });
    if (unlinked.isNotEmpty) {
      out.add(_groupHeader(_unlinkedLabel, unlinked.length));
      for (final hw in unlinked) {
        out.add(_tile(hw));
      }
    }
    return out;
  }

  /// 分组小标题（知识点名 / 今天 / 昨天 …）。
  Widget _groupHeader(String label, int count) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ),
            Text(
              '$count',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      );

  /// 单条作业。
  Widget _tile(Homework hw) {
    final String batchId = hw.batchId ?? '';
    final DateTime? updatedAt = _timeOf(hw);
    return ListTile(
      title: Text(
        hw.title.trim().isEmpty ? '(未命名作业)' : hw.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Wrap(
        spacing: 8,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Text(
            '共 ${hw.itemCount} 题',
            style: const TextStyle(fontSize: 12),
          ),
          _badge(
            _statusLabel(hw.status),
            _statusColor(hw.status),
          ),
          Text(
            updatedAt == null ? '—' : _formatTime(updatedAt),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          if (batchId.isNotEmpty) _badge(_batchLabel(batchId), Colors.blueGrey),
        ],
      ),
      trailing: PopupMenuButton<String>(
        tooltip: '更多',
        onSelected: (String v) => _onMenuSelected(hw, v),
        // 状态项按当前状态裁剪：已经是「已完成」就不再显示「标记已完成」，
        // 免得菜单里一半是点了没反应的同义项。
        itemBuilder: (_) => <PopupMenuEntry<String>>[
          if (hw.status != 'done')
            const PopupMenuItem<String>(
              value: 'done',
              child: Text('标记已完成'),
            ),
          if (hw.status != 'assigned')
            const PopupMenuItem<String>(
              value: 'assigned',
              child: Text('转为待完成'),
            ),
          if (hw.status != 'draft')
            const PopupMenuItem<String>(
              value: 'draft',
              child: Text('转为草稿'),
            ),
          const PopupMenuItem<String>(
            value: 'edit',
            child: Text('编辑'),
          ),
          const PopupMenuItem<String>(
            value: 'delete',
            child: Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
      onTap: () => _openHomework(hw),
    );
  }

  /// 状态 / 批量小徽标。
  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 11, color: color),
        ),
      );

  // ============ 交互 ============

  Future<void> _onMenuSelected(Homework hw, String value) async {
    switch (value) {
      case 'done':
        await _setStatus(hw, 'done');
      case 'assigned':
        await _setStatus(hw, 'assigned');
      case 'draft':
        await _setStatus(hw, 'draft');
      case 'edit':
        await _openHomework(hw);
      case 'delete':
        await _confirmDelete(hw);
    }
  }

  /// 更新作业状态后重载（列表按 updatedAt 排序，状态变更会改变顺序）。
  Future<void> _setStatus(Homework hw, String status) async {
    await _repo.updateStatus(hw.id, status);
    if (!mounted) return;
    _toast(switch (status) {
      'done' => '已标记完成',
      'draft' => '已转为草稿',
      _ => '已标记待完成',
    });
    await _reload();
  }

  /// 新建作业（「增」的入口）。
  ///
  /// - 从「某知识点」入口进来 → 自动带上该知识点（出题/归属都直接可用）；
  /// - 从「某棵树」入口进来 → 带该树的 canvasId；
  /// - 从全局入口进来 → canvasId 为空串（作业会落在「未关联」里，仍可查）。
  Future<void> _createNew() async {
    List<KnowledgePoint> points = const <KnowledgePoint>[];
    String canvasId = widget.canvasId ?? '';
    final String? kpId = widget.kpId;
    if (kpId != null) {
      points = await _kpRepo.pointsByIds(<String>[kpId]);
      canvasId = await _kpRepo.canvasIdForKp(kpId) ?? canvasId;
    }
    if (!mounted) return;
    final lockKey = 'homework:new:$canvasId';
    if (widget.jobs.isLocked(lockKey)) {
      _toast('这棵树已经有一个「布置作业」页开着，完成后再试');
      widget.jobs.requestExpandTray();
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => HomeworkPage(
          ai: widget.ai,
          db: widget.db,
          canvasId: canvasId,
          points: points,
          jobs: widget.jobs,
        ),
      ),
    );
    if (!mounted) return;
    await _reload();
  }

  /// 删除（软删墓碑）→ 重载；SnackBar 给 5 秒「撤销」。
  Future<void> _confirmDelete(Homework hw) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除作业'),
        content: Text(
          '确定删除「${hw.title.trim().isEmpty ? '(未命名作业)' : hw.title}」吗？'
          '删除后不会出现在历史里（5 秒内可撤销）。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final res = await _repo.softDelete(hw.id);
    if (!mounted) return;
    final err = res.fold<Object?>((_) => null, (e, _) => e);
    if (err != null) {
      _toast('删除失败：$err');
      return;
    }
    await _reload();
    if (!mounted) return;
    // 撤销：走仓储 restore（清 deleted_at + bump version + 上行），
    // 不是「再 create 一条」——否则会多出一份换了 id 的复制品。
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: const Text('已删除'),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () async {
            await _repo.restore(hw.id);
            if (!mounted) return;
            await _reload();
            _toast('已恢复');
          },
        ),
      ));
  }

  /// 打开作业页（`existingId` = 本作业），返回后重载。
  Future<void> _openHomework(Homework hw) async {
    // 同一份作业的编辑会话已开着 → 挡（与画布入口同口径，不静默失败）。
    final lockKey = 'homework:${hw.id}';
    if (widget.jobs.isLocked(lockKey)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(
          content: Text('这份作业的编辑页已经打开，完成后再试'),
          duration: Duration(seconds: 2),
        ));
      widget.jobs.requestExpandTray();
      return;
    }
    final List<KnowledgePoint> points = await _pointsFor(hw);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => HomeworkPage(
          ai: widget.ai,
          db: widget.db,
          canvasId: hw.canvasId,
          points: points,
          jobs: widget.jobs,
          existingId: hw.id,
        ),
      ),
    );
    if (!mounted) return;
    await _reload();
  }

  /// 解析该作业关联的知识点：主外键 `kpId` 优先，否则用快照 `kpIds`；
  /// 都解析不到就返回空列表（作业页允许空 points，出题时提示手动加题）。
  Future<List<KnowledgePoint>> _pointsFor(Homework hw) async {
    final Set<String> ids = <String>{};
    final String primary = hw.kpId ?? '';
    if (primary.isNotEmpty) {
      ids.add(primary);
    } else {
      for (final id in hw.kpIds) {
        if (id.isNotEmpty) ids.add(id);
      }
    }
    if (ids.isEmpty) return const <KnowledgePoint>[];
    return _kpRepo.pointsByIds(ids.toList());
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ));
  }

  // ============ 视图 ============

  @override
  Widget build(BuildContext context) {
    final List<Homework> items = _filtered;
    final bool onlyKp = widget.kpId != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: <Widget>[
          IconButton(
            onPressed: _createNew,
            icon: const Icon(Icons.add),
            tooltip: '新建作业',
          ),
          IconButton(
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _queryCtrl,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: '搜索作业标题 / 知识点 / 题干',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (String v) => setState(() => _query = v),
            ),
          ),
          // 状态筛选 chips。
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                for (final entry in const <(String, String)>[
                  ('all', '全部'),
                  ('assigned', '待完成'),
                  ('done', '已完成'),
                  ('draft', '草稿'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      // 带计数：草稿也算「有记录」，0 份时也照样显示，
                      // 用户一眼能看出「我存过的东西还在不在」。
                      label: Text('${entry.$2}（${_countOf(entry.$1)}）'),
                      selected: _statusFilter == entry.$1,
                      onSelected: (_) =>
                          setState(() => _statusFilter = entry.$1),
                    ),
                  ),
              ],
            ),
          ),
          // 分组方式切换：按知识点（默认） / 按时间。
          Row(
            children: <Widget>[
              const SizedBox(width: 12),
              Text(
                '按知识点',
                style: TextStyle(
                  fontSize: 12,
                  color: _byTime ? Colors.grey : Colors.indigo,
                ),
              ),
              Switch(
                value: _byTime,
                onChanged: (bool v) => setState(() => _byTime = v),
              ),
              Text(
                '按时间',
                style: TextStyle(
                  fontSize: 12,
                  color: _byTime ? Colors.indigo : Colors.grey,
                ),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  '${items.length} 份',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : items.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _emptyText(onlyKp),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.grey),
                          ),
                        ),
                      )
                    : ListView(
                        children: _buildGroupedWidgets(items),
                      ),
          ),
        ],
      ),
    );
  }

  /// 空态文案：区分「本来就没有」与「筛掉了」。
  String _emptyText(bool onlyKp) {
    if (_all.isNotEmpty) return '没有匹配的作业，换个关键词或筛选条件试试。';
    return onlyKp ? '该知识点还没有作业' : '还没有作业记录';
  }
}
