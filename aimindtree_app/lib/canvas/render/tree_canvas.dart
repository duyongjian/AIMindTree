/// 知识树画布（ARCHITECTURE T05 画布 + 知识树）。
///
/// - **pan/zoom 自己实现，不用 [InteractiveViewer]**：
///   InteractiveViewer 在外部写入 `transformationController.value` 之后，会按
///   `boundaryMargin` / `constrained` 再做一次边界 clamp 校正，把内容推到视口
///   之外 —— 表现为「一缩放，画面内容就消失」。这里改成自己维护
///   `_scale` + `_translation`，用 [Transform] 直接应用，行为完全可控。
///   变换约定：**screen = scale * scene + translation**
///   （scene 是以内容左上角为原点的坐标，screen 是画布可视区坐标）。
/// - **手势**：[GestureDetector] 的 onScaleStart/Update/End 负责
///   指针拖拽平移 + 双指捏合缩放。
/// - **桌面端滚轮**：[Listener] 自己接管 —— 普通滚轮 = 平移，
///   Ctrl/⌘ + 滚轮 = 以光标为锚点缩放；右下角缩放控件兜底。
/// - **节点可拖动**：拖顶部手柄移动，松手写入 `canvas_nodes` 持久化
///   （拖动手柄而非卡片主体，避免与「拖画布平移」手势抢 GestureArena）。
/// - **连线可编辑**：卡片「连接」按钮 → 点目标卡片建前置边；
///   已有连线在折线中点显示删除按钮。取消连线：提示条「取消」按钮 / Esc /
///   点击画布空白处。
///
/// 位置来源优先级：拖动中的临时位置 → 库里保存的位置 → 布局引擎算出的位置。
/// 首次渲染会把布局结果**固化写库**，之后连线/删线都不会再重排。
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/knowledge_point.dart';
import 'edge_router.dart';
import 'knowledge_node_card.dart';
import 'layout_engine.dart';

/// 画布上保存下来的节点位置（kpId → x/y），由仓储层从 `canvas_nodes` 读出。
typedef NodePositions = Map<String, ({double x, double y})>;

class TreeCanvas extends StatefulWidget {
  const TreeCanvas({
    super.key,
    required this.points,
    required this.edges,
    required this.currentMastery,
    this.onKpTap,
    this.selectedKpId,
    this.savedPositions = const <String, ({double x, double y})>{},
    this.onMoveNode,
    this.onCreateEdge,
    this.onDeleteEdge,
    this.onRelayout,
    this.config = const LayoutConfig(),
  });

  final List<KnowledgePoint> points;
  final List<PrerequisiteEdge> edges;
  final MasteryStatus Function(String kpId) currentMastery;
  final void Function(KnowledgePoint kp)? onKpTap;

  /// 当前被画布点选的节点 id（用于卡片高亮）。
  final String? selectedKpId;

  /// 库里已保存的节点位置（拖动持久化用）。
  final NodePositions savedPositions;

  /// 拖动结束回调：(kpId, x, y)。
  final void Function(String kpId, double x, double y)? onMoveNode;

  /// 建立前置关系：(fromKpId 前置, toKpId 后继)。
  final void Function(String fromKpId, String toKpId)? onCreateEdge;

  /// 删除前置关系：(edgeId)。
  final void Function(String edgeId)? onDeleteEdge;

  /// 「重新布局」：清空已固化的节点位置，让布局引擎重排一次。
  ///
  /// 位置一旦固化就永久有效，用户把图拖乱之后需要一个一键恢复的入口。
  final VoidCallback? onRelayout;

  final LayoutConfig config;

  @override
  State<TreeCanvas> createState() => TreeCanvasState();
}

class TreeCanvasState extends State<TreeCanvas> {
  // ================= 视口变换（自维护，不再经过 InteractiveViewer） =================

  /// 缩放比例，范围 [_minScale, _maxScale]。
  double _scale = 1.0;

  /// 平移量（屏幕像素）。screen = _scale * scene + _translation。
  Offset _translation = Offset.zero;

  /// 一次缩放手势开始时的快照，用于「锚点不动」的换算。
  double _scaleAtStart = 1.0;
  Offset _sceneFocalAtStart = Offset.zero;

  /// 缩放范围：10% ~ 400%。
  static const double _minScale = 0.1;
  static const double _maxScale = 4.0;

  /// 连线画布四周预留的绘制余量：绕行路径可能走到节点包围盒之外（往左 / 往上绕），
  /// 不留余量就会被 CustomPaint 的尺寸裁掉。
  static const double _paintMargin = 64.0;

  /// 用户拖动过的位置（kpId → Offset）。未拖动的走布局引擎结果。
  final Map<String, Offset> _pos = <String, Offset>{};

  /// 连线模式的起点 kpId；非空表示「已选中起点，等待点目标」。
  String? _linkingFrom;

  /// 用于接收 Esc（只在进入连线态时主动抢焦点，平时不抢下拉框的焦点）。
  final FocusNode _canvasFocus = FocusNode();

  /// 初始布局是否已经固化写库（只对每批新数据跑一次，绝不在 build 里反复写）。
  bool _layoutPersisted = false;

  /// 已经固化过位置的 kpId。库里的 [TreeCanvas.savedPositions] 是异步回来的，
  /// 直接用它判断会重复覆盖，所以本地再记一份。
  final Set<String> _persistedIds = <String>{};

  /// 首次拿到视口尺寸后是否自动 fit 过（只在库里没有已保存位置时做一次）。
  bool _autoFitDone = false;

  Size _viewport = Size.zero;

  @override
  void initState() {
    super.initState();
    _syncSavedPositions();
    _schedulePersistLayout();
  }

  @override
  void didUpdateWidget(TreeCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.savedPositions, widget.savedPositions)) {
      _syncSavedPositions();
    }
    if (!identical(oldWidget.points, widget.points)) {
      // 换了一批知识点（切笔记 / 重新提取）：新节点需要重新固化一次。
      _layoutPersisted = false;
      _schedulePersistLayout();
    }
  }

  void _syncSavedPositions() {
    _pos
      ..clear()
      ..addEntries(widget.savedPositions.entries
          .map((e) => MapEntry(e.key, Offset(e.value.x, e.value.y))));
  }

  /// 在首帧之后把布局位置写库，避免在 build 里触发父组件 setState。
  void _schedulePersistLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _persistLayoutOnce();
    });
  }

  /// 把布局引擎算出的初始位置一次性写库。
  ///
  /// 目的：连/删一条边会改变图的层级，如果每次 build 都用纯函数重算位置，
  /// 所有节点都会跳位。固化之后位置只由库里的值决定，不再重排。
  void _persistLayoutOnce() {
    if (_layoutPersisted) return;
    final onMove = widget.onMoveNode;
    if (onMove == null || widget.points.isEmpty) return;
    _layoutPersisted = true;

    final layout =
        layoutForest(widget.points, widget.edges, config: widget.config);
    for (final n in layout.nodes) {
      // 用户拖过 / 之前固化过的节点不覆盖，尊重已有位置。
      if (widget.savedPositions.containsKey(n.kpId)) continue;
      if (!_persistedIds.add(n.kpId)) continue;
      onMove(n.kpId, n.x, n.y);
    }
  }

  @override
  void dispose() {
    _canvasFocus.dispose();
    super.dispose();
  }

  // ================= 缩放 / 平移 =================

  /// 当前的变换矩阵：先平移再缩放（等价于 screen = scale * scene + t）。
  ///
  /// ⚠️ `translateByDouble(tx, ty, tz, tw)` 的第 4 个参数是 **w 分量**：
  /// 仿射平移必须传 1（`translateByVector3` 内部也是这么调的）。传 0 会把
  /// m[15] 置 0，矩阵退化成奇异矩阵，`MatrixUtils.perspectiveTransform`
  /// 除以 w=0 得到 Infinity —— 表现就是「一缩放内容就不见 / 点不中」。
  Matrix4 get _matrix => Matrix4.identity()
    ..translateByDouble(_translation.dx, _translation.dy, 0, 1)
    ..scaleByDouble(_scale, _scale, 1, 1);

  /// 屏幕（视口）坐标 → 场景坐标。
  Offset _toScene(Offset screen) => (screen - _translation) / _scale;

  /// 当前视口中心对应的场景坐标。
  Offset _sceneCenter() => _toScene(_viewport.center(Offset.zero));

  /// 缩放到 [nextScale]，并保持场景点 [sceneAnchor] 的屏幕位置不变。
  ///
  /// 推导：screen = scale * scene + t
  /// 要求 scale_old * P + t_old == scale_new * P + t_new
  ///   ⇒ **t_new = t_old + (scale_old - scale_new) * P**
  void _applyScale(double nextScale, Offset sceneAnchor) {
    final target = nextScale.clamp(_minScale, _maxScale);
    if ((target - _scale).abs() < 1e-9) return;
    _translation += sceneAnchor * (_scale - target);
    _scale = target;
  }

  void _zoomBy(double factor) =>
      setState(() => _applyScale(_scale * factor, _sceneCenter()));

  void _reset() => setState(() {
        _scale = 1.0;
        _translation = Offset.zero;
      });

  /// 首次拿到视口尺寸时自动适应窗口一次。
  ///
  /// 只在库里**没有**已保存位置时做：有保存位置说明用户自己调过视图，
  /// 一进来就 fit 会把他辛苦摆的位置又缩放一遍，反而添乱。
  void _autoFitOnce(Offset Function(String) posOf, List<LaidOutNode> nodes) {
    if (_autoFitDone || _viewport.isEmpty || nodes.isEmpty) return;
    _autoFitDone = true;
    if (widget.savedPositions.isNotEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _fitToContent(posOf, nodes));
    });
  }

  /// 缩放并平移到刚好框住全部节点。
  void _fitToContent(Offset Function(String) posOf, List<LaidOutNode> nodes) {
    if (nodes.isEmpty || _viewport.isEmpty) return;
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final n in nodes) {
      final p = posOf(n.kpId);
      minX = math.min(minX, p.dx);
      minY = math.min(minY, p.dy);
      maxX = math.max(maxX, p.dx);
      maxY = math.max(maxY, p.dy);
    }
    final cw = maxX - minX + widget.config.nodeWidth;
    final ch = maxY - minY + widget.config.nodeHeight;
    if (cw <= 0 || ch <= 0) return;
    final s = math.min(_viewport.width / (cw + 80), _viewport.height / (ch + 80))
        .clamp(_minScale, _maxScale);
    _scale = s;
    // 让内容中心落在视口中心：t = (视口 - 内容 * s) / 2 - min * s
    _translation = Offset(
      (_viewport.width - cw * s) / 2 - minX * s,
      (_viewport.height - ch * s) / 2 - minY * s,
    );
  }

  // ---- 指针 / 滚轮手势 ----

  void _onScaleStart(ScaleStartDetails details) {
    _scaleAtStart = _scale;
    // 记下「按下时焦点下面的场景点」，整个手势期间都让它跟着焦点走。
    _sceneFocalAtStart = _toScene(details.localFocalPoint);
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final nextScale = (_scaleAtStart * details.scale).clamp(_minScale, _maxScale);
    setState(() {
      _scale = nextScale;
      // focal_now = scale_new * sceneFocus + t_new ⇒ t_new = focal - scale * scene
      // 单指时 details.scale 恒为 1，focal 的位移就是平移量；双指捏合时
      // focal 是两指中点，平移与缩放一次算完，不会互相打架。
      _translation = details.localFocalPoint - _sceneFocalAtStart * nextScale;
    });
  }

  /// 接管鼠标滚轮：Ctrl/⌘ + 滚轮缩放，普通滚轮平移。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      final anchor = _toScene(event.localPosition);
      final factor = event.scrollDelta.dy > 0 ? 1 / 1.15 : 1.15;
      setState(() => _applyScale(_scale * factor, anchor));
    } else {
      setState(() => _translation = _translation - event.scrollDelta);
    }
  }

  // ================= 连线 =================

  void _onLinkTap(String kpId) {
    setState(() {
      final from = _linkingFrom;
      if (from == null) {
        _linkingFrom = kpId;
      } else if (from == kpId) {
        _linkingFrom = null; // 再点一次自己 = 取消
      } else {
        _linkingFrom = null;
        widget.onCreateEdge?.call(from, kpId);
      }
    });
    if (_linkingFrom != null) {
      // 进入连线态才抢焦点，这样 Esc 一定落在画布上。
      _canvasFocus.requestFocus();
    }
  }

  /// 取消连线态（提示条按钮 / Esc / 点空白处，三条路都走这里）。
  void _cancelLinking() {
    if (_linkingFrom == null) return;
    setState(() => _linkingFrom = null);
  }

  // ================= 构建 =================

  @override
  Widget build(BuildContext context) {
    if (widget.points.isEmpty) {
      return const Center(
        child: Text(
          '该笔记还没有提取出知识点。\n先去「提取」页跑一次 T1。',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    final layout = layoutForest(widget.points, widget.edges, config: widget.config);
    final byId = <String, KnowledgePoint>{for (final p in widget.points) p.id: p};
    final basePos = <String, Offset>{
      for (final n in layout.nodes) n.kpId: Offset(n.x, n.y),
    };
    Offset posOf(String id) => _pos[id] ?? basePos[id] ?? Offset.zero;

    var maxX = 0.0;
    var maxY = 0.0;
    for (final n in layout.nodes) {
      final p = posOf(n.kpId);
      maxX = math.max(maxX, p.dx);
      maxY = math.max(maxY, p.dy);
    }
    final w = maxX + widget.config.nodeWidth + 80;
    final h = maxY + widget.config.nodeHeight + 80;

    final linking = _linkingFrom != null;

    // ── 连线路由：在 build 里对每条边算一次，painter 和删除按钮共用 ──
    // 以前是「源底边中点 → 拐点(x 对齐) → 目标顶边中点」的写死三段线：横段正好
    // 压在目标卡片上边缘，跨层连线的竖直段还会从中间层卡片身上穿过去。现在改成
    // 正交避障路由（见 edge_router.dart），并只算一次给两处复用。
    final nodeSize = Size(widget.config.nodeWidth, widget.config.nodeHeight);
    final nodeRects = <String, Rect>{
      for (final n in layout.nodes)
        n.kpId: posOf(n.kpId) & nodeSize, // Offset & Size → Rect
    };
    final routed = <_RoutedEdge>[
      for (final e in widget.edges)
        if (nodeRects.containsKey(e.fromKpId) && nodeRects.containsKey(e.toKpId))
          _RoutedEdge(
            edge: e,
            points: routeEdge(
              from: nodeRects[e.fromKpId]!.topLeft,
              to: nodeRects[e.toKpId]!.topLeft,
              nodeSize: nodeSize,
              // 只避让「其它」节点：两端卡片允许接触（起终点本就贴在卡片边上）。
              obstacles: <Rect>[
                for (final entry in nodeRects.entries)
                  if (entry.key != e.fromKpId && entry.key != e.toKpId)
                    entry.value,
              ],
              gap: widget.config.vGap,
            ),
          ),
    ];

    final content = SizedBox(
      width: w,
      height: h,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 绕行的连线可能走到内容包围盒之外（往左绕 / 往上绕），所以给
          // CustomPaint 四周各留 _paintMargin 的余量，并把这份偏移补偿回
          // 场景坐标，否则绕出去的那一段会被裁掉。
          Positioned(
            left: -_paintMargin,
            top: -_paintMargin,
            right: -_paintMargin,
            bottom: -_paintMargin,
            child: CustomPaint(
              painter: _EdgesPainter(
                edges: routed,
                origin: const Offset(_paintMargin, _paintMargin),
                linkingFrom: _linkingFrom,
              ),
            ),
          ),
          for (final n in layout.nodes)
            Positioned(
              left: posOf(n.kpId).dx,
              top: posOf(n.kpId).dy,
              width: widget.config.nodeWidth,
              height: widget.config.nodeHeight,
              child: KnowledgeNodeCard(
                kp: byId[n.kpId]!,
                mastery: widget.currentMastery(n.kpId),
                isLinkSource: _linkingFrom == n.kpId,
                isLinkTargetCandidate: linking && _linkingFrom != n.kpId,
                isSelected: widget.selectedKpId == n.kpId,
                onLinkTap: () => _onLinkTap(n.kpId),
                onTap: () {
                  if (linking) {
                    _onLinkTap(n.kpId);
                  } else {
                    widget.onKpTap?.call(byId[n.kpId]!);
                  }
                },
                onDragUpdate: (delta) => setState(() {
                  _pos[n.kpId] = posOf(n.kpId) + delta;
                }),
                onDragEnd: () {
                  final p = posOf(n.kpId);
                  widget.onMoveNode?.call(n.kpId, p.dx, p.dy);
                },
              ),
            ),
          // 连线上的删除按钮：定位在**路由后折线的长度中点**，和画出来的线一致
          // （edges 已由入口过滤，两端必然在画布内）。
          for (final r in routed)
            Builder(builder: (context) {
              final mid = polylineMidpoint(r.points);
              return Positioned(
                left: mid.dx - 11,
                top: mid.dy - 11,
                width: 22,
                height: 22,
                // 反向缩放：抵消画布缩放，保证任何缩放级别下按钮都是 22px 可点
                // （否则缩到 10% 时它只有 2px，根本点不中）。
                child: Transform.scale(
                  scale: 1 / _scale,
                  alignment: Alignment.center,
                  child: _EdgeDeleteButton(
                    onTap: () => widget.onDeleteEdge?.call(r.edge.id),
                  ),
                ),
              );
            }),
        ],
      ),
    );

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): _CancelLinkIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _CancelLinkIntent: CallbackAction<_CancelLinkIntent>(
            onInvoke: (_CancelLinkIntent intent) {
              _cancelLinking();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _canvasFocus,
          child: LayoutBuilder(builder: (context, constraints) {
            _viewport = Size(constraints.maxWidth, constraints.maxHeight);
            _autoFitOnce(posOf, layout.nodes);
            return Stack(
              children: [
                // ── 手势层：既是 pan/zoom 的接收面，也是「空白处点击」的接收面 ──
                // HitTestBehavior.opaque 让它在没有命中任何子节点时也能收到事件；
                // 它同时是内容的**祖先**，所以命中节点卡片时它也在 hit path 里，
                // 拖卡片主体依然可以平移画布。
                Positioned.fill(
                  child: Listener(
                    onPointerSignal: _onPointerSignal,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onScaleStart: _onScaleStart,
                      onScaleUpdate: _onScaleUpdate,
                      // 只在连线态挂 onTap，避免平时和缩放手势抢 arena。
                      onTap: linking ? _cancelLinking : null,
                      child: OverflowBox(
                        alignment: Alignment.topLeft,
                        minWidth: 0,
                        minHeight: 0,
                        maxWidth: double.infinity,
                        maxHeight: double.infinity,
                        child: Transform(
                          alignment: Alignment.topLeft,
                          transform: _matrix,
                          child: content,
                        ),
                      ),
                    ),
                  ),
                ),
                if (linking)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: _LinkHint(onCancel: _cancelLinking),
                  ),
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: _ZoomControls(
                    onZoomIn: () => setState(() => _zoomBy(1.2)),
                    onZoomOut: () => setState(() => _zoomBy(1 / 1.2)),
                    onFit: () => setState(() => _fitToContent(posOf, layout.nodes)),
                    onReset: _reset,
                    scale: _scale,
                    onRelayout: widget.onRelayout,
                  ),
                ),
              ],
            );
          }),
        ),
      ),
    );
  }
}

/// Esc 取消连线的 Intent。
class _CancelLinkIntent extends Intent {
  const _CancelLinkIntent();
}

/// 连线进行中的提示条。
class _LinkHint extends StatelessWidget {
  const _LinkHint({required this.onCancel});
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Material(
        elevation: 2,
        borderRadius: BorderRadius.circular(6),
        color: Colors.amber.shade100,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.link, size: 16),
              const SizedBox(width: 6),
              const Text('再点一个知识点，把它设为后继（按 Esc 或点空白处也可取消）',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(width: 8),
              // 带文字的取消按钮 —— 之前只有一个 16px 的小叉，太难点。
              TextButton.icon(
                onPressed: onCancel,
                icon: const Icon(Icons.close, size: 16),
                label: const Text('取消'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.brown.shade800,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ),
      );
}

/// 连线上的删除按钮。
class _EdgeDeleteButton extends StatelessWidget {
  const _EdgeDeleteButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        elevation: 1,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: const SizedBox(
            width: 22,
            height: 22,
            child: Icon(Icons.close, size: 14, color: Colors.redAccent),
          ),
        ),
      );
}

/// 右下角缩放控件（桌面端鼠标用户的可靠入口）。
class _ZoomControls extends StatelessWidget {
  const _ZoomControls({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
    required this.onReset,
    required this.scale,
    this.onRelayout,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;
  final VoidCallback onReset;
  final double scale;
  final VoidCallback? onRelayout;

  @override
  Widget build(BuildContext context) => Card(
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${(scale * 100).round()}%',
                  style: const TextStyle(fontSize: 10, color: Colors.grey)),
              IconButton(
                icon: const Icon(Icons.add),
                iconSize: 18,
                tooltip: '放大',
                onPressed: onZoomIn,
              ),
              IconButton(
                icon: const Icon(Icons.remove),
                iconSize: 18,
                tooltip: '缩小',
                onPressed: onZoomOut,
              ),
              IconButton(
                icon: const Icon(Icons.fit_screen),
                iconSize: 18,
                tooltip: '适应窗口',
                onPressed: onFit,
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                iconSize: 18,
                tooltip: '重置视图',
                onPressed: onReset,
              ),
              if (onRelayout != null)
                IconButton(
                  icon: const Icon(Icons.auto_awesome_mosaic),
                  iconSize: 18,
                  tooltip: '重新布局（清掉手动拖动的位置，自动重排）',
                  onPressed: onRelayout,
                ),
            ],
          ),
        ),
      );
}

/// 一条已经算好折线的前置关系边（painter 与删除按钮共用同一份路由结果）。
class _RoutedEdge {
  const _RoutedEdge({required this.edge, required this.points});

  final PrerequisiteEdge edge;

  /// 正交折线顶点（场景坐标），至少 2 个；最后一个点是箭头圆点位置。
  final List<Offset> points;
}

/// 画前置关系连线（前置在上、后继在下，正交折线 + 终点圆点）。
///
/// 折线由 [routeEdge] 预先算好（避开所有其它节点卡片），这里只负责描出来。
class _EdgesPainter extends CustomPainter {
  const _EdgesPainter({
    required this.edges,
    this.origin = Offset.zero,
    this.linkingFrom,
  });

  final List<_RoutedEdge> edges;

  /// painter 局部坐标系原点对应的场景坐标（见 [_paintMargin]）。
  final Offset origin;

  final String? linkingFrom;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = Colors.grey.shade400
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    final arrow = Paint()..color = Colors.grey.shade600;

    for (final r in edges) {
      final pts = r.points;
      if (pts.length < 2) continue;
      final highlighted = linkingFrom == r.edge.fromKpId;
      final path = Path()
        ..moveTo(pts.first.dx + origin.dx, pts.first.dy + origin.dy);
      for (var i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx + origin.dx, pts[i].dy + origin.dy);
      }
      canvas.drawPath(
        path,
        highlighted
            ? (Paint()
              ..color = Colors.amber.shade700
              ..strokeWidth = 2.2
              ..style = PaintingStyle.stroke)
            : stroke,
      );
      canvas.drawCircle(
        Offset(pts.last.dx + origin.dx, pts.last.dy + origin.dy),
        3,
        arrow,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _EdgesPainter old) =>
      !identical(old.edges, edges) ||
      old.linkingFrom != linkingFrom ||
      old.origin != origin;
}
