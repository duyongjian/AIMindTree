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
/// - **节点可拖动**：**左键直接拖卡片**即可移动节点，松手吸附到 20px 网格并写入
///   `canvas_nodes` 持久化（Figma/Miro 直觉：拖东西就移动东西，无需修饰键）。
///   拖动逻辑并入 [_onScaleStart]：按下时用 [_nodeAt] 判断指针下有没有节点 ——
///   命中节点且没按 Space → 拖节点；否则 → 平移画布。**没有独立的热区层**，
///   卡片本体（`Material`，opaque 命中）与外层 `ScaleGestureRecognizer` 同在
///   竞技场：静止点击 → 卡片 InkWell 的 Tap 胜出（onKpTap / 连接按钮）；移动 →
///   Scale 胜出 → 拖节点。
/// - **平移画布**：左键拖**空白**，或 **Space + 左键拖**（即使指针压在卡片上也平移）。
///   Space 是「我要平移，别误抓卡片」的明确信号，光标会切到 `grab` 反馈。
/// - **重叠卡片靠 hover 置顶保证「所见即所抓」**：`_raiseHovered` 在画布层按**实际
///   绘制顺序**（`_paintOrder`）把指针下的卡置顶，[_nodeAt] 按同一顺序取最上层 ⇒
///   所见即所抓。绘制顺序、命中测试**必须同源**（build 里算一次 `ordered`，
///   `_paintOrder` 与卡片渲染共用），否则置顶等于无效。
/// - **连线可编辑**：卡片「连接」按钮 → 点目标卡片建前置边；删除入口是**鼠标
///   悬停到某条线上**才在该线中点浮现的 `×`（以前是每条线常驻一个，线一多
///   整张图全是小叉）。取消连线：提示条「取消」按钮 / Esc / 点击画布空白处。
/// - **互相交叉的连线颜色不同**：按「交叉图」贪心着色（见 edge_router.dart），
///   保证有真实穿越的两条边颜色一定不同，没交叉的保持默认灰。着色结果按几何
///   签名缓存，hover 频繁 rebuild 也不会每帧重算 O(E² × 段数²)。
///
/// 位置来源优先级：拖动中的临时位置 → 库里保存的位置 → 布局引擎算出的位置。
/// 首次渲染会把布局结果**固化写库**，之后连线/删线都不会再重排。
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/canvas_content.dart';
import '../../data/models/knowledge_point.dart';
import 'canvas_text_card.dart';
import 'edge_router.dart';
import 'knowledge_node_card.dart';
import 'layout_engine.dart';

/// 画布上保存下来的节点位置（kpId → x/y），由仓储层从 `canvas_nodes` 读出。
typedef NodePositions = Map<String, ({double x, double y})>;

/// 未与任何连线交叉时用的默认灰色（保持改造前的基调）。
const Color _defaultEdgeColor = Color(0xFFBDBDBD); // Colors.grey.shade400

/// 画布底纹网格的线色（浅色主题）。要足够可见——用户看得见格子才会觉得
/// 「对齐到格了」；太淡（<10% α）等于没有，反而被当成「没对齐」。
const Color _gridMinorColor = Color(0x33283593); // indigo，约 20% α —— 细线
const Color _gridMajorColor = Color(0x66283593); // indigo，约 40% α —— 每 5 格主线

/// 交叉连线的调色板（需求③：交叉处靠颜色分辨走向）。
///
/// - 只用 **700/800 档的深色**：连线描边只有 1.4px，浅色在白底上几乎看不见。
/// - 前几个色相拉得最开（蓝 / 深橙 / 深紫 / 青绿 / 玫红 / 靛蓝），保证相邻
///   色号（贪心最常只用前两三个）肉眼一眼能分。
/// - **给到 8 个色号**：贪心的色号在密集图上能涨到 8（交叉图的最大度数），
///   而调用方是 `palette[(v - 1) % palette.length]` —— 只有 6 色时第 7、8 号
///   会绕回来跟第 1、2 号撞色，有交叉的两条边就可能同色（QA 实测密集图
///   60/5181 对）。8 色覆盖实测上限，撞色概率归零。
const List<Color> _edgeCrossingPalette = <Color>[
  Color(0xFF1565C0), // blue 800
  Color(0xFFE65100), // orange 900
  Color(0xFF6A1B9A), // purple 800
  Color(0xFF00695C), // teal 800
  Color(0xFFC2185B), // pink 700
  Color(0xFF4527A0), // deep purple 800
  Color(0xFF795548), // brown 700
  Color(0xFF2E7D32), // green 800
];

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
    this.selectionMode = false,
    this.selectedKpIds = const <String>{},
    this.onSelectionChanged,
    this.onMoveNodes,
    this.allowGroupDrag = false,
    this.frameMode = false,
    this.onToggleFrameMode,
    this.config = const LayoutConfig(),
    // ★2.0.0：自由文本卡片 / 手写笔迹
    this.cards = const [],
    this.strokes = const [],
    this.penMode = false,
    this.eraserMode = false,
    this.onEditCard,
    this.onMoveCard,
    this.onAddStroke,
    this.onEraseStroke,
    this.onViewportCenter,
  });

  /// 视口中心场景坐标变化时回调（父组件新建卡片时用来定位到可视区中央）。
  final void Function(Offset sceneCenter)? onViewportCenter;

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

  /// 框选模式：在画布上拖拽出选框框选多个知识点（此模式下禁用画布平移/缩放）。
  final bool selectionMode;

  /// 框选模式下已选中的知识点 id（由父组件持有，受控）。
  final Set<String> selectedKpIds;

  /// 框选模式下选择变化回调。
  final void Function(Set<String> selected)? onSelectionChanged;

  /// 框选后「整组移动」回调：松手时一次性上报「id → 新场景坐标」。
  ///
  /// 与单节点 [onMoveNode] 分开：这里是**批量**、**瞬时**（松手才回调一次），父组件
  /// 无需再重载，因为画布内部 `_pos` 已实时反映位移。
  final void Function(Map<String, Offset> positions)? onMoveNodes;

  /// 允许「框选后拖动整组移动」：仅当处于 [selectionMode] 且指针压在**已选中**
  /// 节点上时生效（否则照常开始新框选）。
  final bool allowGroupDrag;

  /// 框选模式开关状态（父组件持有；右下角悬浮栏的「框选模式」按钮反映它）。
  final bool frameMode;

  /// 悬浮栏「框选模式」开关回调（把切换动作交回父组件）。
  final VoidCallback? onToggleFrameMode;

  final LayoutConfig config;

  // ── ★2.0.0：自由文本卡片 / 手写笔迹 ──

  /// 画布上的自由文本卡片（笔记卡片 / 透明文本框）。
  final List<CanvasCardVm> cards;

  /// 已持久化的手写笔迹。
  final List<CanvasStrokeVm> strokes;

  /// 画笔模式：true = 用笔画线。
  final bool penMode;

  /// 橡皮模式：true = 擦除整笔。
  final bool eraserMode;

  /// 点击卡片 → 打开编辑器（由父组件接线对话框）。
  final ValueChanged<CanvasCardVm>? onEditCard;

  /// 卡片拖动结束：(cardNodeId, x, y)。
  final void Function(String cardNodeId, double x, double y)? onMoveCard;

  /// 画笔抬笔 → 持久化一笔：(stroke)。
  final void Function(CanvasStrokeVm stroke)? onAddStroke;

  /// 橡皮命中 → 删除整笔：(strokeId)。
  final void Function(String strokeId)? onEraseStroke;

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

  /// 底纹网格往内容包围盒外再多铺的余量（场景单位）：卡片被拖到包围盒外时，
  /// 脚下仍有格子可参照，不会一拖出去就「没有格子了」。
  static const double _gridMargin = 480.0;

  /// 连线的 hover 判定阈值（**屏幕像素**）：鼠标到折线的最短距离在这个范围内
  /// 才算「指到了这条线」。
  ///
  /// 7px ≈ 一个正常手抖的余量。太小 → 得贴着线瞄准；太大 → 隔着老远就误判。
  static const double _edgeHoverThreshold = 10.0;

  /// 已经 hover 的那条线的**粘滞倍数**（threshold 乘以它）。
  ///
  /// ⚠️ 根因：删除「×」画在折线中点上，但按钮是颗 r=11 的圆 —— 鼠标从线上移向
  /// 按钮**边缘**的过程中，到线的距离会一路涨到 11px，超过 7px 的阈值 ⇒
  /// hover 态中途丢失 ⇒ 按钮跟着消失，永远点不着（hover-reveal 交互最典型的坑）。
  /// 取 3 倍（21px）后，整颗按钮及其外圈都仍在一份加宽的阈值里，路径不会断。
  static const double _hoverStickyFactor = 3.0;

  /// 拖动节点的**启动阈值**，单位是**屏幕像素**（手感单位，跟缩放无关）。
  ///
  /// ⚠️ 必须自己设：Flutter 对鼠标用的是精确指针 slop（约 1px），手指/光标
  /// 抖 1px 就会被 `PanGestureRecognizer` 判成「开始拖动」，于是想点一下却把
  /// 卡片拖跑了（误拖）。攒够这个距离才真正开始移动，之后 1:1 跟手。
  /// ⚠️ 判定必须换算到屏幕像素（`场景位移 * _scale`）：手势给的增量是场景
  /// 单位，不换算的话缩小视图时阈值形同虚设、放大视图时又大到拖不动。
  static const double _dragStartThreshold = 4.0;

  /// 网格线在屏幕上小于这个像素数时，视觉上就糊成一片灰雾了 ⇒ 线距按 2 的幂
  /// 逐级放大（20 → 40 → 80 …）。因为放大后仍是基础格距的整数倍，**吸附目标
  /// 永远落在基础网格上**，缩回原比例也不会「格子对不上」。
  static const double _minGridScreenPx = 10.0;

  /// 当前生效的网格线距（场景单位）；[LayoutConfig.gridSize] ≤ 0 时返回 0 = 关闭。
  ///
  /// 既用于画底纹，也用于拖动吸附 —— 两者共用同一个值，用户看到的格子就是吸附的格子。
  double get _gridStep {
    final base = widget.config.gridSize;
    if (base <= 0) return 0;
    var step = base;
    // 防御：极端缩放下最多放大 64 倍，避免死循环 / 线数爆炸。
    var guard = 0;
    while (step * _scale < _minGridScreenPx && guard < 6) {
      step *= 2;
      guard++;
    }
    return step;
  }

  /// 把场景坐标吸附到当前网格（网格关闭时原样返回）。
  Offset _snap(Offset p) {
    final step = _gridStep;
    if (step <= 0) return p;
    return Offset(snapToGrid(p.dx, step), snapToGrid(p.dy, step));
  }

  /// 用户拖动过的位置（kpId → Offset）。未拖动的走布局引擎结果。
  final Map<String, Offset> _pos = <String, Offset>{};

  /// 连线模式的起点 kpId；非空表示「已选中起点，等待点目标」。
  String? _linkingFrom;

  /// 鼠标正在悬停的连线 id（需求②：只有它才显示删除叉）。
  String? _hoveredEdgeId;
  /// 当前「点选」选中的连线：点击连线即可选中（显示持久删除叉，可按 Delete/Backspace 删除，
  /// 或点连线上的 ×）；再点空白处清除。与 [_hoveredEdgeId] 区分：hover 是瞬态（鼠标移动），
  /// selected 是点击后固化的态。
  String? _selectedEdgeId;

  /// 当前「置顶」的卡片（最后一次被拖动 / 悬停的那张）。
  ///
  /// Stack 里后绘制 = 在上层。把它排到最后，用户把某张卡片拖到别人身上时，
  /// 那张卡片才不会钻到底下卡片的后面（看着像「拖不动 / 没动」）。
  /// 悬停抓取区也会置顶 —— 这样被压住的卡片一 hover 就露出它的灰色外观条，
  /// 否则用户根本看不见抓取条在哪。
  String? _frontKpId;

  // ── 拖动状态（配合 _dragStartThreshold 防误拖）──
  String? _dragId;
  bool _dragStarted = false;

  /// 拖动起点：按下瞬间**指针的场景坐标** + 卡片当时的场景坐标。
  ///
  /// ⚠️ 位置用**绝对位移**算：`起点卡片位置 + (当前指针 - 起点指针)`，
  /// 而不是逐帧 `+= d.delta` 累加。用户报「动多了之后仍然有识别偏移」——
  /// 逐帧累加会把每一次的微小取整/换算误差都攒起来，拖得越久、拖的次数越多，
  /// 卡片与光标偏离越大。绝对式每一帧都从**同一起点**重算，误差无法累积。
  Offset _dragSceneAtStart = Offset.zero;
  Offset _dragPosAtStart = Offset.zero;

  /// 当前拖动的是否为「卡片」（true 走卡片位置表 _cardPos / onMoveCard，
  /// false 走 KP 节点位置表 _pos / onMoveNode）。
  bool _draggingCard = false;

  // ── ★2.0.0：自由文本卡片 / 手写笔迹的状态 ──

  /// 卡片实时位置（nodeId → 场景坐标），拖动时写入；未拖动则回退到 vm 的 x/y。
  final Map<String, Offset> _cardPos = <String, Offset>{};

  /// 卡片场景矩形缓存，供命中测试用（build 里写入）。
  Map<String, Rect> _cardRects = const <String, Rect>{};

  /// 卡片实际绘制顺序（底 → 顶），与渲染共用，保证「所见即所抓」。
  List<String> _cardPaintOrder = const <String>[];

  /// 被拖到最上层的卡片 nodeId（绘制/命中顺序置顶）。
  String? _frontCardNodeId;

  /// 当前正在画的笔迹点（屏幕坐标 → 场景坐标后累积）；空 = 没在画。
  List<Offset> _currentStroke = const <Offset>[];

  /// 是否处于绘制中（仅在 penMode 下为 true）。
  bool _drawing = false;

  /// 本次擦除手势中已经删掉的笔迹 id，避免同一笔被重复回调。
  final Set<String> _erasedThisGesture = <String>{};

  /// 最近一次指针按下点的场景坐标，供 _onCanvasTap 命中卡片（onTap 拿不到位置）。
  Offset _lastTapScene = Offset.zero;

  /// 是否按住 Space：**强制平移画布**（即使指针在卡片上也平移，不拖卡片）。
  ///
  /// 去 Ctrl 改造后的新交互（Figma/Miro 惯例）：
  /// - 左键拖**卡片** = 移动卡片（无需任何修饰键）
  /// - 左键拖**空白** = 平移画布
  /// - **Space + 左键拖** = 平移画布（即使指针压在卡片上）
  ///
  /// Space 是「我要平移，别误抓卡片」的明确信号。判定靠 [_onScaleStart] 里
  /// `_nodeAt(focal)` 命中：命中节点且没按 Space → 拖节点；否则 → 平移。
  ///
  /// ⚠️ 这是**按键事件驱动的缓存**，不是真值。读它的地方一律走 [_spaceHeld]。
  bool _spaceDown = false;
  bool Function(KeyEvent)? _spaceKeyHandler;

  /// Space 当前是否**真的**按着：每次 build 用键盘真实状态校正缓存。
  ///
  /// ⚠️ 按键事件（`addHandler`）会漏（窗口焦点切换 / 组合键被外层 Shortcuts 吃掉），
  /// 缓存可能卡在旧值。所以取值必须以 `HardwareKeyboard` 真值为准，缓存只当优化。
  bool get _spaceHeld {
    final down = HardwareKeyboard.instance.isLogicalKeyPressed(
        LogicalKeyboardKey.space);
    if (down != _spaceDown) _spaceDown = down;
    return down;
  }

  /// 在**指针事件**里校正 Space 缓存（鼠标移动 / 按下时顺带做，代价可忽略）。
  ///
  /// ⚠️ [_spaceHeld] 只在 build 期间生效，可 build 不一定赶得上下一次按下：
  /// 丢一次 KeyUp 后若恰好没有别的重建，光标反馈会停留在旧值。鼠标移动是高频
  /// 事件且必然先于按下，所以在 hover / pointerDown 里各校正一次。
  void _syncSpaceState() {
    if (!mounted) return;
    final down = HardwareKeyboard.instance.isLogicalKeyPressed(
        LogicalKeyboardKey.space);
    if (down != _spaceDown) setState(() => _spaceDown = down);
  }

  /// 鼠标当前悬停的节点 kpId（用于切换光标为 move；非节点且非 Space → basic）。
  /// 由 [_onCanvasHover] 实时更新。
  String? _hoveredKpId;

  /// 上一次 build 算好的连线路由结果。
  ///
  /// hover 是在手势回调里算的，那里拿不到 layout / build context，和 `_nodeRects`
  /// 一样得在 build 里留一份快照。
  List<_RoutedEdge> _routedEdges = const <_RoutedEdge>[];

  /// 交叉着色的缓存 key（见 [polylinesSignature]）：只要几何没变就不需要重算。
  String? _edgeColorsKey;

  /// 交叉着色的缓存值；几何不变时复用**同一个 List 实例**，
  /// 好让 [_EdgesPainter.shouldRepaint] 的 `identical` 能短路掉重绘。
  List<Color> _edgeColorsCache = const <Color>[];

  /// 用于接收 Esc（只在进入连线态时主动抢焦点，平时不抢下拉框的焦点）。
  final FocusNode _canvasFocus = FocusNode();

  /// 初始布局是否已经固化写库（只对每批新数据跑一次，绝不在 build 里反复写）。
  bool _layoutPersisted = false;

  /// 已经固化过位置的 kpId。库里的 [TreeCanvas.savedPositions] 是异步回来的，
  /// 直接用它判断会重复覆盖，所以本地再记一份。
  final Set<String> _persistedIds = <String>{};

  // ===== 框选选择状态 =====

  /// 本次 build 的**实际绘制顺序**（底 → 顶），即 `_orderedNodes(layout.nodes)`
  /// 的 kpId 序列。由 build 写入，供手势回调里的 [_nodeAt] 使用。
  ///
  /// 为什么不能直接遍历 `_nodeRects`：那是**布局顺序**，与置顶无关。置顶后视觉
  /// 最上面的是 `_frontKpId`，而 `_nodeRects` 的迭代顺序没变 ⇒ 命中测试算出的
  /// 「最上面那张」和用户看到的不是同一张，置顶机制等于失效。
  List<String> _paintOrder = const <String>[];

  /// 框选矩形（场景坐标）；两者都非空表示正在进行框选。
  Offset? _marqueeStart;
  Offset? _marqueeEnd;

  /// 拖拽开始时的基线选中集（框选结果 = 基线 ∪ 框内节点）。
  Set<String> _baseSelection = <String>{};

  /// 框选过程中的实时选中集；null = 未在框选（用 widget.selectedKpIds）。
  Set<String>? _liveSelection;

  /// 本次 build 缓存的节点场景矩形，供框选命中测试用。
  Map<String, Rect> _nodeRects = const <String, Rect>{};

  // ===== 框选「整组移动」状态（见 widget.allowGroupDrag）=====

  /// 正在整组拖动的节点 id 集合；空 = 未在进行整组拖动。
  Set<String> _groupDragIds = <String>{};

  /// 整组拖动起始的场景焦点（与 [_groupDragStartPos] 一起算整组位移）。
  Offset _groupDragSceneStart = Offset.zero;

  /// 整组拖动开始时各成员的位置快照（id → 场景坐标）。
  Map<String, Offset> _groupDragStartPos = <String, Offset>{};

  /// 是否已越过启动阈值、真正开始整组位移（防误拖，用屏幕像素判定）。
  bool _groupDragStarted = false;

  /// 首次拿到视口尺寸后是否自动 fit 过（只在库里没有已保存位置时做一次）。
  bool _autoFitDone = false;

  Size _viewport = Size.zero;

  @override
  void initState() {
    super.initState();
    _syncSavedPositions();
    _schedulePersistLayout();
    _spaceDown = HardwareKeyboard.instance.isLogicalKeyPressed(
        LogicalKeyboardKey.space);
    _spaceKeyHandler = (KeyEvent _) {
      // 只在状态变化时 setState，避免每次按键都重建。
      // ⚠️ addHandler 回调本身也可能漏（失焦 / 组合键被外层吃掉），漏一次缓存
      // 就卡住。真正的兜底在 _spaceHeld：每次 build 都会再校一次。
      final down = HardwareKeyboard.instance.isLogicalKeyPressed(
          LogicalKeyboardKey.space);
      if (down != _spaceDown) {
        _spaceDown = down;
        if (mounted) setState(() {});
      }
      return false; // 不消费事件，照常下发
    };
    HardwareKeyboard.instance.addHandler(_spaceKeyHandler!);
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

  /// 把父组件回传的位置合并进 [_pos]。
  ///
  /// ⚠️ **不能 `_pos.clear()` 再整体重建**（这是「组里的节点第二次拖不动」的
  /// 第二个根因）：拖动刚松手时 [_pos] 里是**刚落库的新坐标**，而父组件的
  /// `savedPositions` 要等它自己下一次 `_loadForTree` 才会更新。只要这中间夹着
  /// 一次重建（连边 / 切树 / 改掌握度都会触发），`clear()` 就会用**旧坐标**
  /// 覆盖刚落库的位置 ⇒ 卡片视觉上跳回原处，而用户紧接着的第二次拖动是从
  /// 「以为已经在那儿」的位置伸手的，怎么拖都不对。
  ///
  /// 改成**就地合并**：只在父组件确实给了某个节点的新坐标时才覆盖它，本地
  /// 独有的（还没落库的实时位置）一律保留。落库后的值与 [_pos] 本来就一致，
  /// 所以合并等价于「以本地为准 + 吸收外部更新」，不存在漂移。
  void _syncSavedPositions() {
    for (final e in widget.savedPositions.entries) {
      // (0,0) 视为「还没布局」而非「放在原点」：addPoints 写出的新成员默认
      // x/y=0，若当成已摆放会全挤在原点且拖不动。跳过它们，让布局引擎铺开。
      if (e.value.x == 0 && e.value.y == 0) continue;
      _pos[e.key] = Offset(e.value.x, e.value.y);
    }
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
      // 已手动摆放（库里有真实坐标，非 (0,0)）/ 之前固化过的节点不覆盖。
      // addPoints 写出的新成员默认 x/y=0，被当成「放在原点」会全挤在一起，
      // 所以 (0,0) 视为「还没布局」，交由布局引擎铺开并固化。
      final sp = widget.savedPositions[n.kpId];
      if (sp != null && (sp.x != 0 || sp.y != 0)) continue;
      // 库里本就是 (0,0) 且引擎算出来还是同一个点：写回一遍完全相同的值是
      // **无意义落库**（白跑一次 DB 往返，还会污染「手势不该落库」的观测），
      // 直接跳过。引擎给出不同坐标时（真正的新点）照常固化。
      if (sp != null && sp.x == n.x && sp.y == n.y) continue;
      if (!_persistedIds.add(n.kpId)) continue;
      onMove(n.kpId, n.x, n.y);
    }
  }

  @override
  void dispose() {
    if (_spaceKeyHandler != null) {
      HardwareKeyboard.instance.removeHandler(_spaceKeyHandler!);
    }
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
  ///
  /// ⚠️ 这里**必须**与 [_matrix] 严格互逆：`screen = scale * scene + _translation`
  /// ⇒ `scene = (screen - t) / scale`。曾经为了容纳外扩的组框而给内容盒加过一层
  /// `Transform.translate(offset: -origin)`，把式子改成 `scale * (scene - origin)`，
  /// 于是**所有**反解平移量的地方（平移锚点 / 缩放锚点 / 自动 fit）都得跟着减 origin，
  /// 漏一处就「鼠标一动画布平移一段」。该内移已随分组功能一起移除，此处回到最简形式。
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
    // 记录按下点的场景坐标，供 _onCanvasTap 命中卡片用（onTap 拿不到位置）。
    _lastTapScene = _toScene(details.localFocalPoint);

    // ── 画笔 / 橡皮模式：直接接管手势，禁止平移/拖节点 ──
    if (widget.penMode || widget.eraserMode) {
      final scene = _lastTapScene;
      if (widget.penMode) {
        _drawing = true;
        _currentStroke = <Offset>[scene];
        setState(() {});
      } else {
        _erasedThisGesture.clear();
        _eraseAt(scene);
      }
      return;
    }

    if (widget.selectionMode) {
      // ── 框选整组移动：指针压在**已选中**节点上 → 开始整组拖动，而非开新框选 ──
      if (widget.allowGroupDrag) {
        final sceneStart = _toScene(details.localFocalPoint);
        final hit = _nodeAt(sceneStart);
        if (hit != null && widget.selectedKpIds.contains(hit)) {
          setState(() {
            _marqueeStart = null;
            _marqueeEnd = null;
          });
          _groupDragIds = Set<String>.of(widget.selectedKpIds);
          _groupDragSceneStart = sceneStart;
          _groupDragStartPos = <String, Offset>{
            for (final id in _groupDragIds)
              id: _nodeRects[id]?.topLeft ?? _pos[id] ?? Offset.zero,
          };
          _groupDragStarted = false;
          return;
        }
      }
      // 防御：走「开新框选」这条路时，先清干净上一次可能残留的整组拖动状态
      //（例如手势进行中 allowGroupDrag 被切走），避免框选继承脏状态。
      _groupDragIds = <String>{};
      _groupDragStartPos = <String, Offset>{};
      _groupDragStarted = false;
      final p = _toScene(details.localFocalPoint);
      _baseSelection = Set<String>.of(widget.selectedKpIds);
      setState(() {
        _marqueeStart = p;
        _marqueeEnd = p;
        _liveSelection = _baseSelection;
      });
      return;
    }
    _scaleAtStart = _scale;
    // 记下「按下时焦点下面的场景点」，整个手势期间都让它跟着焦点走。
    _sceneFocalAtStart = _toScene(details.localFocalPoint);

    // ── 去 Ctrl 后的命中分流（核心）──
    // 单指、未按 Space、指针下有节点 → 拖节点；否则 → 平移画布。
    // 这是 Figma/Miro 的直觉：拖东西就移动东西，拖空白 / Space 就平移。
    // 双指一律走平移/缩放（不拖节点，避免捏合与拖动打架）。
    if (details.pointerCount == 1 && !_spaceHeld &&
        !widget.penMode && !widget.eraserMode) {
      final hit = _nodeAt(_sceneFocalAtStart);
      if (hit != null) {
        _dragId = hit;
        _draggingCard = false;
        // ⚠️ 坐标空间：外层 onScale 的 GestureDetector 在 Transform **之外**，
        // `details.localFocalPoint` 是**屏幕坐标**；而 `_nodeRects` / `_pos` 是
        // **场景坐标**。两者不能直接相加 —— 必须把 focal 转成场景坐标再算位移。
        // 用已算好的 _sceneFocalAtStart（= _toScene(localFocalPoint)）当起点。
        _dragSceneAtStart = _sceneFocalAtStart;
        _dragPosAtStart = _nodeRects[hit]?.topLeft ?? Offset.zero;
        _dragStarted = false;
        if (_frontKpId != hit) setState(() => _frontKpId = hit);
        return;
      }
      // 命中卡片（非 KP 节点）→ 拖卡片（复用同一套阈值/绝对位移逻辑）。
      final cardHit = _cardAt(_sceneFocalAtStart);
      if (cardHit != null) {
        _dragId = cardHit;
        _draggingCard = true;
        _dragSceneAtStart = _sceneFocalAtStart;
        _dragPosAtStart = _cardRects[cardHit]?.topLeft ?? Offset.zero;
        _dragStarted = false;
        if (_frontCardNodeId != cardHit) {
          setState(() => _frontCardNodeId = cardHit);
        }
        return;
      }
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // ── 画笔：把当前点追加进正在画的笔迹 ──
    if (widget.penMode && _drawing) {
      _currentStroke = <Offset>[
        ..._currentStroke,
        _toScene(details.localFocalPoint),
      ];
      setState(() {});
      return;
    }
    // ── 橡皮：沿移动轨迹逐段擦除整笔 ──
    if (widget.eraserMode) {
      _eraseAt(_toScene(details.localFocalPoint));
      return;
    }

    if (widget.selectionMode) {
      // ── 框选整组移动：按整组位移实时更新各成员位置（不吸附，松手再吸附）──
      if (_groupDragIds.isNotEmpty) {
        final sceneFocal = _toScene(details.localFocalPoint);
        final delta = sceneFocal - _groupDragSceneStart;
        if (!_groupDragStarted) {
          if (delta.distance * _scale < _dragStartThreshold) return;
          _groupDragStarted = true;
        }
        setState(() {
          for (final id in _groupDragIds) {
            final s = _groupDragStartPos[id];
            if (s != null) _pos[id] = s + delta;
          }
        });
        return;
      }
      final p = _toScene(details.localFocalPoint);
      final rect = Rect.fromPoints(_marqueeStart ?? p, p);
      final hit = <String>{
        for (final entry in _nodeRects.entries)
          if (entry.value.overlaps(rect)) entry.key,
      };
      setState(() {
        _marqueeEnd = p;
        _liveSelection = <String>{..._baseSelection, ...hit};
      });
      return;
    }
    // 节点拖动分支：绝对位移 + 跟手（不吸附），吸附放到 _onScaleEnd 松手时做。
    if (_dragId != null) {
      // focal 转场景坐标（外层 GestureDetector 在 Transform 外，localFocalPoint
      // 是屏幕坐标；_dragPosAtStart / _pos 是场景坐标，必须同空间才能相加）。
      final sceneFocal = _toScene(details.localFocalPoint);
      final raw = _dragPosAtStart + (sceneFocal - _dragSceneAtStart);
      if (!_dragStarted) {
        if ((raw - _dragPosAtStart).distance * _scale <
            _dragStartThreshold) {
          return;
        }
        _dragStarted = true;
      }
      setState(() {
        if (_draggingCard) {
          _cardPos[_dragId!] = raw;
        } else {
          _pos[_dragId!] = raw;
        }
      });
      return;
    }
    if (!widget.penMode && !widget.eraserMode) {
      final nextScale = (_scaleAtStart * details.scale).clamp(_minScale, _maxScale);
      setState(() {
        _scale = nextScale;
        // focal_now = scale_new * sceneFocus + t_new ⇒ t_new = focal - scale * scene
        // 单指时 details.scale 恒为 1，focal 的位移就是平移量；双指捏合时
        // focal 是两指中点，平移与缩放一次算完，不会互相打架。
        _translation = details.localFocalPoint - _sceneFocalAtStart * nextScale;
      });
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    // ── 画笔收笔：点足够多则上报持久化 ──
    if (widget.penMode && _drawing) {
      if (_currentStroke.length >= 2) {
        widget.onAddStroke?.call(CanvasStrokeVm(
          id: '',
          canvasId: '',
          points: <({double x, double y})>[
            for (final o in _currentStroke) (x: o.dx, y: o.dy),
          ],
          color: '#1a1a1a',
          width: 3.0,
        ));
      }
      _drawing = false;
      _currentStroke = const <Offset>[];
      setState(() {});
      return;
    }
    // ── 橡皮收笔：清空本次手势已擦集合 ──
    if (widget.eraserMode) {
      _erasedThisGesture.clear();
      return;
    }

    if (widget.selectionMode) {
      // ── 框选整组移动收尾 ──
      if (_groupDragIds.isNotEmpty) {
        if (_groupDragStarted) {
          // 真正移动过：松手吸附到网格 + 批量上报（不改变选中集）。
          final moved = <String, Offset>{};
          setState(() {
            for (final id in _groupDragIds) {
              final snapped = _snap(_pos[id] ?? Offset.zero);
              _pos[id] = snapped;
              moved[id] = snapped;
            }
          });
          widget.onMoveNodes?.call(moved);
        } else {
          // 未越过阈值 = 点按：在已选中集合上切换命中节点的选中态。
          final hit = _nodeAt(_groupDragSceneStart);
          if (hit != null) {
            final next = Set<String>.of(widget.selectedKpIds);
            if (!next.add(hit)) next.remove(hit);
            widget.onSelectionChanged?.call(next);
          }
        }
        _groupDragIds = <String>{};
        _groupDragStartPos = <String, Offset>{};
        _groupDragStarted = false;
        return;
      }
      final start = _marqueeStart;
      final end = _marqueeEnd;
      var result = _liveSelection ?? widget.selectedKpIds;
      // 位移极小 = 点按：切换命中那个节点的选中态。
      if (start != null && end != null && (end - start).distance < 6) {
        final hit = _nodeAt(end);
        final next = Set<String>.of(_baseSelection);
        if (hit != null) {
          if (!next.add(hit)) next.remove(hit);
        }
        result = next;
      }
      widget.onSelectionChanged?.call(result);
      if (!mounted) return;
      setState(() {
        _marqueeStart = null;
        _marqueeEnd = null;
        _liveSelection = null;
        _baseSelection = <String>{};
      });
      return;
    }
    // 节点/卡片拖动收尾：松手才吸附到网格 + 写库。没真正拖动过（< 阈值）不写库。
    if (_dragId != null) {
      if (_dragStarted) {
        if (_draggingCard) {
          final snapped = _snap(_cardPos[_dragId] ?? Offset.zero);
          setState(() => _cardPos[_dragId!] = snapped);
          widget.onMoveCard?.call(_dragId!, snapped.dx, snapped.dy);
        } else {
          final snapped = _snap(_pos[_dragId] ?? Offset.zero);
          setState(() => _pos[_dragId!] = snapped);
          widget.onMoveNode?.call(_dragId!, snapped.dx, snapped.dy);
        }
      }
      _dragId = null;
      _dragStarted = false;
      _draggingCard = false;
    }
  }

  /// 命中测试：场景点 [p] 落在哪个节点矩形里。
  ///
  /// ⚠️ 必须按**实际绘制顺序**（[_paintOrder]，= `_orderedNodes` 的结果）从底往上
  /// 取最后一个命中的，而不是直接遍历 `_nodeRects` —— 后者是布局顺序，和
  /// 「谁被置顶」无关。两者不一致时，置顶机制就形同虚设：画面上最上面的是
  /// `_frontKpId`，而这里算出来的却是布局顺序里的另一张，于是 hover 置顶会
  /// 置顶一张用户根本没指的卡，「所见即所抓」直接失效。
  String? _nodeAt(Offset p) {
    String? found;
    for (final id in _paintOrder) {
      final r = _nodeRects[id];
      if (r != null && r.contains(p)) found = id;
    }
    return found;
  }

  /// 命中测试：场景点 [p] 落在哪个卡片矩形里（返回卡片 nodeId）。
  ///
  /// 与 [_nodeAt] 同理，必须按**实际绘制顺序**（[_cardPaintOrder]）从底往上取最
  /// 后一个命中的，保证「所见即所抓」。
  String? _cardAt(Offset p) {
    String? found;
    for (final id in _cardPaintOrder) {
      final r = _cardRects[id];
      if (r != null && r.contains(p)) found = id;
    }
    return found;
  }

  /// 卡片的实时场景坐标：拖动中优先用 [_cardPos]，否则回退到 vm 自带的 x/y。
  Offset posOfCard(CanvasCardVm card) =>
      _cardPos[card.nodeId] ?? Offset(card.x, card.y);

  /// 卡片绘制顺序：被拖到最上层的卡片排到最后（在上层），保证「所见即所抓」。
  List<CanvasCardVm> _orderedCards(List<CanvasCardVm> cards) {
    final front = _frontCardNodeId;
    if (front == null) return cards;
    final idx = cards.indexWhere((c) => c.nodeId == front);
    if (idx < 0 || idx == cards.length - 1) return cards;
    final out = <CanvasCardVm>[...cards];
    out.add(out.removeAt(idx));
    return out;
  }

  /// 橡皮擦：场景点 [scene] 落到某条笔迹附近 → 删除整笔（回调一次）。
  void _eraseAt(Offset scene) {
    for (final s in widget.strokes) {
      if (_erasedThisGesture.contains(s.id)) continue;
      if (_strokeHit(s, scene)) {
        _erasedThisGesture.add(s.id);
        widget.onEraseStroke?.call(s.id);
      }
    }
  }

  /// [scene] 是否命中笔迹 [s]（距任一线段 ≤ 阈值 `8 + 线宽/2`）。
  bool _strokeHit(CanvasStrokeVm s, Offset scene) {
    final pts = <Offset>[for (final p in s.points) Offset(p.x, p.y)];
    if (pts.isEmpty) return false;
    if (pts.length == 1) {
      return (pts.first - scene).distance <= 8.0 + s.width / 2;
    }
    final limit = 8.0 + s.width / 2;
    for (var i = 0; i < pts.length - 1; i++) {
      if (_distanceToSegment(scene, pts[i], pts[i + 1]) <= limit) return true;
    }
    return false;
  }

  /// 点 [p] 到线段 [a]–[b] 的最短距离。
  double _distanceToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.distanceSquared;
    if (len2 == 0) return (p - a).distance;
    var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2;
    t = t.clamp(0.0, 1.0);
    final proj = a + ab * t;
    return (p - proj).distance;
  }

  /// 悬停置顶：鼠标挪到哪张卡，哪张卡就排到最上层。
  ///
  /// ⚠️ 这条不是锦上添花，而是「有时能动有时不能动」的正解（见类注释的
  /// 「重叠卡片与手势竞技」）。热区是 translucent ⇒ 它的 `hitTest` 返回 **false**
  /// 却仍进 hit path（`proxy_box.dart:183-191`：只有 `opaque` 才 `hitTestSelf`，
  /// translucent 靠 `result.add` 混进 path），Stack 于是**继续向下命中** ⇒ 卡片
  /// 重叠时**所有**重叠热区的 `PanGestureRecognizer` 同时进竞技场互相抢。
  /// 谁抢赢谁被置顶，于是「拖到的是哪张」取决于当帧的竞技结果 = **不确定**：
  /// 同一张卡这次能拖、下次拖不动。
  ///
  /// hover 置顶把这件事变确定：指针下的卡立刻成为最上层，既是视觉最上层、
  /// 也是 hit path 里第一个被命中的那个 ⇒ 所见即所抓，竞技场里只剩它一个候选。
  ///
  /// 为什么放在 `_onCanvasHover` 而不给每条热区挂 `onEnter`：重叠的 translucent
  /// 区域会收到**多个** enter/exit，且 enter 是**自上而下**派发 ⇒ 挂在热区上
  /// 反而会把最**下面**那张翻上来（与「所见即所抓」相反，见 `2026-10-10.md`）。
  /// 在画布层用 `_nodeRects` 自己判断指针下最上面那张，是唯一可靠的做法。
  void _raiseHovered(Offset scene) {
    final hit = _nodeAt(scene);
    if (hit == null || hit == _frontKpId) return;
    // 置顶只影响绘制/命中顺序，不影响几何，无需重建路由与边色缓存。
    setState(() => _frontKpId = hit);
  }

  /// 当前用于渲染高亮的选中集（框选进行时用实时集，否则用父组件传入的）。
  Set<String> get _highlighted => widget.selectionMode
      ? (_liveSelection ?? widget.selectedKpIds)
      : <String>{if (widget.selectedKpId != null) widget.selectedKpId!};

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

  // ================= 连线 hover（需求②）=================

  /// 鼠标在画布上移动：找出最近的那条连线，把它标记成 hover 态。
  ///
  /// ⚠️ 这个 [MouseRegion] 挂在**整个画布的外层**（见 build），所以鼠标在画布
  /// 任意位置都能进来；挂在单条连线的 Positioned 上的话，只有 1.4px 宽的那条
  /// 线本身能命中，实际几乎不可能触发。
  void _onCanvasHover(PointerHoverEvent event) {
    // 画笔/橡皮模式不处理节点 hover / 置顶，避免干扰绘制。
    if (widget.penMode || widget.eraserMode) return;
    // 校正 Space 缓存：保证「按下那一刻」平移门控已是真值（见 _syncSpaceState）。
    _syncSpaceState();
    final scene = _toScene(event.localPosition);

    // 悬停置顶 + 光标反馈：指针下的卡立刻成为最上层，让「看到的」=「能抓的」。
    // 框选模式下不置顶：那一层要的是稳定选中，别让层级随鼠标乱跳。
    // 例外：框选整组移动模式下仍要算出 hoveredKp，好把光标切到 move（但不置顶）。
    final wantHover = !widget.selectionMode || widget.allowGroupDrag;
    final hoveredKp = (wantHover && _dragId == null) ? _nodeAt(scene) : null;
    if (!widget.selectionMode && _dragId == null) _raiseHovered(scene);

    // 鼠标压在某张卡片上时不考虑连线 hover：此时用户是要抓卡片 / 拖画布，
    // 在中点上冒出来的 × 只会碍事（也能避免卡片上沿的那条入线被误判）。
    final hitNode =
        _nodeRects.values.any((r) => r.inflate(2.0).contains(scene));
    // 框选模式下鼠标主要服务于框选手势，也不显示删除叉。
    final nextId = (widget.selectionMode || hitNode) ? null : _edgeIdAt(scene);
    // 合并三态变化一次性 setState，避免每帧多次重建。
    if (nextId == _hoveredEdgeId && hoveredKp == _hoveredKpId) return;
    setState(() {
      _hoveredEdgeId = nextId;
      _hoveredKpId = hoveredKp;
    });
  }

  /// 鼠标移出整个画布：清掉 hover 态，别让删除叉残留在外面。
  void _onCanvasHoverExit(PointerExitEvent event) {
    if (_hoveredEdgeId == null) return;
    setState(() => _hoveredEdgeId = null);
  }

  /// 画布点击（非连线态）：若鼠标正悬停在某条连线上 → 选中它（显示持久删除叉，
  /// 之后可按 Delete/Backspace 删除，或点连线上的 ×）；否则清空已选中的连线。
  /// 悬停在节点上时 [_hoveredEdgeId] 恒为 null（hover 跳过节点），故点击节点会自动
  /// 清掉连线选中态，不会和节点点选冲突。
  void _onCanvasTap() {
    if (widget.selectionMode) return;
    // 画笔/橡皮模式下点击用于落笔/擦除，不触发卡片编辑。
    if (widget.penMode || widget.eraserMode) return;
    // 先判断是不是点到了卡片 → 打开编辑器。
    final cardHit = _cardAt(_lastTapScene);
    if (cardHit != null) {
      CanvasCardVm? vm;
      for (final c in widget.cards) {
        if (c.nodeId == cardHit) {
          vm = c;
          break;
        }
      }
      if (vm != null) widget.onEditCard?.call(vm);
      return;
    }
    setState(() => _selectedEdgeId = _hoveredEdgeId);
  }

  /// Delete/Backspace 键盘删除：优先删 hover 的线，否则删选中的线。
  void _deleteHoveredOrSelectedEdge() {
    if (widget.selectionMode) return;
    final id = _hoveredEdgeId ?? _selectedEdgeId;
    if (id == null) return;
    widget.onDeleteEdge?.call(id);
    if (mounted) {
      setState(() {
        _hoveredEdgeId = null;
        _selectedEdgeId = null;
      });
    }
  }

  /// 距场景点 [scene] 最近、且在阈值内的那条连线的 id；没有就返回 null。
  ///
  /// ⚠️ 阈值必须换算到场景单位：距离是用场景坐标算的，而人是按**屏幕像素**
  /// 瞄准的（`sceneThreshold = 阈值 / _scale`）。不换算的话缩到 50% 时要贴着
  /// 线走才认、放大到 400% 又会隔着很远就误命中。
  /// 当前 hover 的那条线用 [_hoverStickyFactor] 放大阈值，保证鼠标从线移到
  /// 删除按钮的途中不会掉线。
  String? _edgeIdAt(Offset scene) {
    if (_routedEdges.isEmpty) return null;
    final baseLimit = _edgeHoverThreshold / _scale;
    String? bestId;
    var bestDistance = double.infinity;
    for (final r in _routedEdges) {
      final limit = r.edge.id == _hoveredEdgeId
          ? baseLimit * _hoverStickyFactor
          : baseLimit;
      final d = distanceToPolyline(r.points, scene);
      if (d <= limit && d < bestDistance) {
        bestDistance = d;
        bestId = r.edge.id;
      }
    }
    return bestId;
  }

  /// 把「置顶」的那张卡片排到最后（Stack 里后绘制 = 在上层）。
  List<LaidOutNode> _orderedNodes(List<LaidOutNode> nodes) {
    final front = _frontKpId;
    if (front == null) return nodes;
    final idx = nodes.indexWhere((n) => n.kpId == front);
    if (idx < 0 || idx == nodes.length - 1) return nodes;
    final out = <LaidOutNode>[...nodes];
    out.add(out.removeAt(idx));
    return out;
  }

  /// ⚠️ 坐标系铁律（踩过一次，别再踩）：`DragUpdateDetails.delta` /
  /// `localPosition` 都是**接收者局部坐标**下的量，不是屏幕像素。
  ///
  /// 依据：`monodrag.dart` 里 `delta: _getDeltaForDetails(resolvedDelta)`，
  /// resolvedDelta 来自 `event.localDelta`；而 `localDelta` 的定义就是
  /// "the delta transformed into the event receiver's local coordinate system
  /// according to transform"。
  /// 抓取带画在画布的 [Transform] **里面**，局部坐标 = 场景坐标 ⇒
  /// **`d.localPosition` / `d.delta` 都是场景量，可直接用于 `_pos`**。
  ///
  /// 曾经在这里多除了一次 `_scale`（以为是屏幕像素）：缩放 0.3 时卡片以 3 倍速
  /// 飞走、根本抓不住。要做屏幕像素换算只有一处 —— [_dragStartThreshold] 的判定，
  /// 因为那是按**人的手感**（屏幕像素）定的。


  /// 交叉着色（需求③），带几何缓存。
  ///
  /// hover / 拖动会让 build 跑得非常勤，但着色结果只取决于折线几何 —— 所以按
  /// [polylinesSignature] 缓存，避免每帧重跑 O(E² × 段数²) 的交叉判定。
  /// 返回的颜色列表与 [routed] 顺序一一对应。
  List<Color> _resolveEdgeColors(List<_RoutedEdge> routed) {
    final polylines = <List<Offset>>[for (final r in routed) r.points];
    final signature = polylinesSignature(polylines);
    if (signature == _edgeColorsKey && _edgeColorsCache.length == routed.length) {
      return _edgeColorsCache;
    }
    final indices = assignCrossingColors(polylines);
    final colors = <Color>[
      for (var i = 0; i < routed.length; i++)
        indices[i] == 0
            ? _defaultEdgeColor
            : _edgeCrossingPalette[(indices[i] - 1) % _edgeCrossingPalette.length],
    ];
    _edgeColorsKey = signature;
    _edgeColorsCache = colors;
    return colors;
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
    // 缓存给框选命中测试用（手势回调里拿不到 layout）。
    _nodeRects = nodeRects;
    // 缓存**实际绘制顺序**（含置顶）：_nodeAt 靠它判断「指针下最上面那张」。
    // 必须在 _nodeRects 之后、任何 return 之前赋值，且与下面两处渲染卡片/
    // 热区的 _orderedNodes(...) 用同一个表达式，否则二者会漂移。
    final ordered = _orderedNodes(layout.nodes);
    _paintOrder = <String>[for (final n in ordered) n.kpId];

    // ── ★2.0.0：卡片（自由文本 / 笔记卡片）命中测试缓存 ──
    final orderedCards = _orderedCards(widget.cards);
    final cardRects = <String, Rect>{
      for (final c in orderedCards) c.nodeId: posOfCard(c) & Size(c.w, c.h),
    };
    _cardRects = cardRects;
    _cardPaintOrder = <String>[for (final c in orderedCards) c.nodeId];

    // ── 内容包围盒：只按节点算，从 0 起 ──
    // 分组功能已整体下线（框/标签/拖组都移除了），内容不再有任何超出节点矩形
    // 的部件，因此不需要再为「外扩的组框 + 上探的标签条」预留空间，也**不需要**
    // 给内容盒加 `Transform.translate` 内移 —— 那层内移会把换算式改成
    // `scale * (scene - origin)`，所有反解平移量的地方都得跟着改，漏一处就
    // 「鼠标一动画布平移一段」，实测整片画布都会拖不动。详见 [_toScene] 的注释。
    var maxX = 0.0;
    var maxY = 0.0;
    for (final n in layout.nodes) {
      final p = posOf(n.kpId);
      maxX = math.max(maxX, p.dx);
      maxY = math.max(maxY, p.dy);
    }
    final w = maxX + widget.config.nodeWidth + 80;
    final h = maxY + widget.config.nodeHeight + 80;
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
    // 快照给 hover 命中测试用（同 _nodeRects：手势回调里拿不到 layout）。
    _routedEdges = routed;

    // ── 需求③：互相交叉的连线用不同颜色 ──
    // 几何不变时直接复用上一次的结果（含同一个 List 实例，方便 painter 短路重绘）。
    final edgeColors = _resolveEdgeColors(routed);

    // ── 需求②：只有鼠标悬停的那条线才渲染删除叉 ──
    // edges 列表在 hover 期间不会变，所以这里按 id 查一次即可；已经不存在的
    // id（刚被删掉的线）自然查不到，不会渲染出孤儿叉。
    final canDeleteEdge = widget.onDeleteEdge != null && !widget.selectionMode;
    // 删除叉显示给「hover 的线」优先；若没有 hover 但有「选中」的线，也显示（点选后持久可见）。
    final String? activeDeleteEdgeId =
        canDeleteEdge ? (_hoveredEdgeId ?? _selectedEdgeId) : null;
    _RoutedEdge? hoveredRoute;
    if (activeDeleteEdgeId != null) {
      for (final r in routed) {
        if (r.edge.id == activeDeleteEdgeId) {
          hoveredRoute = r;
          break;
        }
      }
    }
    final Offset? hoveredMid =
        hoveredRoute == null ? null : polylineMidpoint(hoveredRoute.points);

    // ── 底纹网格（场景坐标系，随画布一起缩放 / 平移；由 config.showGrid 控制是否绘制）──
    // 可见线与吸附共用同一个 _gridStep；showGrid=false 时不画线，但仍保留松手吸附。
    final gridStep = _gridStep;
    final content = SizedBox(
      width: w,
      height: h,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (widget.config.showGrid && gridStep > 0)
            Positioned(
              left: -_gridMargin,
              top: -_gridMargin,
              right: -_gridMargin,
              bottom: -_gridMargin,
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _GridPainter(
                    step: gridStep,
                    originShift: _gridMargin,
                    // 线宽用场景单位表达「1 屏幕像素」：缩放后线不会变粗 / 变细。
                    strokeWidth: 1 / _scale,
                  ),
                ),
              ),
            ),
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
                edgeColors: edgeColors,
                origin: const Offset(_paintMargin, _paintMargin),
                linkingFrom: _linkingFrom,
                hoveredEdgeId: hoveredRoute?.edge.id,
              ),
            ),
          ),
          // ── ★2.0.0：手写笔迹（已持久化 + 当前正在画的那一笔）──
          // 与连线同一套场景坐标系，跟随画布一起缩放/平移；不手动套矩阵。
          Positioned(
            left: -_paintMargin,
            top: -_paintMargin,
            right: -_paintMargin,
            bottom: -_paintMargin,
            child: CustomPaint(
              painter: _StrokesPainter(
                strokes: widget.strokes,
                current: _drawing ? _currentStroke : const <Offset>[],
                origin: const Offset(_paintMargin, _paintMargin),
              ),
            ),
          ),
          // 置顶的那张排到最后（后绘制 = 在上层），避免被别的卡片盖住。
          for (final n in ordered)
            Positioned(
              // 同上：置顶重排时靠 key 保住元素身份（卡片里有 InkWell 的 State）。
              key: ValueKey<String>('node-card:${n.kpId}'),
              left: posOf(n.kpId).dx,
              top: posOf(n.kpId).dy,
              width: widget.config.nodeWidth,
              height: widget.config.nodeHeight,
              child: KnowledgeNodeCard(
                kp: byId[n.kpId]!,
                mastery: widget.currentMastery(n.kpId),
                isLinkSource: _linkingFrom == n.kpId,
                isLinkTargetCandidate: linking && _linkingFrom != n.kpId,
                isSelected: _highlighted.contains(n.kpId),
                onLinkTap: () => _onLinkTap(n.kpId),
                onTap: () {
                  // 点击即置顶：兜住「抓取带被另一张卡片的抓取带完全重合盖住」的
                  // 极端情况 —— 那张卡片的抓取带一点都露不出来，hover 也进
                  // 不去，只能靠点卡片主体把它翻上来（设计工具的标准行为）。
                  if (_frontKpId != n.kpId) {
                    setState(() => _frontKpId = n.kpId);
                  }
                  if (linking) {
                    _onLinkTap(n.kpId);
                  } else {
                    widget.onKpTap?.call(byId[n.kpId]!);
                  }
                },
              ),
            ),
          // ── ★2.0.0：自由文本卡片 / 笔记卡片 ──
          for (final c in orderedCards)
            Positioned(
              key: ValueKey<String>('canvas-card:${c.nodeId}'),
              left: posOfCard(c).dx,
              top: posOfCard(c).dy,
              width: c.w,
              height: c.h,
              child: CanvasTextCard(
                title: c.title,
                body: c.body,
                kind: c.kind,
                linked: c.noteId != null,
                // 问题7：点击由卡片自身命中（命中区 = 卡片盒），不再依赖外层
                // 画布坐标换算，杜绝「点不中 / 有偏移」。框选/画笔/橡皮/连线
                // 模式下不接管，交回外层手势。
                onTap: (linking ||
                        widget.selectionMode ||
                        widget.penMode ||
                        widget.eraserMode)
                    ? null
                    : () {
                        if (_frontCardNodeId != c.nodeId) {
                          setState(() => _frontCardNodeId = c.nodeId);
                        }
                        widget.onEditCard?.call(c);
                      },
              ),
            ),
          // 连线上的删除按钮：**只有鼠标悬停的那条线才会渲染**（以前是每条线
          // 常驻一个 ×，线一多整张图全是小叉）。位置仍在**路由后折线的长度
          // 中点**，和画出来的线保持一致。
          if (hoveredMid != null)
            Positioned(
              left: hoveredMid.dx - 14,
              top: hoveredMid.dy - 14,
              width: 28,
              height: 28,
              // 反向缩放：抵消画布缩放，保证任何缩放级别下按钮都是 28px 可点
              // （否则缩到 10% 时它只有 2px，根本点不中）。
              child: Transform.scale(
                scale: 1 / _scale,
                alignment: Alignment.center,
                child: _EdgeDeleteButton(
                  onTap: () {
                    widget.onDeleteEdge?.call(hoveredRoute!.edge.id);
                    // 线都没了，hover / 选中态必须立刻撤掉，否则会在原地残留孤立的叉
                    // （父组件回传的新 edges 里已经没有这条 id）。
                    if (mounted) {
                      setState(() {
                        _hoveredEdgeId = null;
                        _selectedEdgeId = null;
                      });
                    }
                  },
                ),
              ),
            ),
          // ── 节点拖动已并入外层 _onScaleStart 的命中分流，不再有独立热区层 ──
          // （去 Ctrl 改造：左键拖卡片 = 移动，左键拖空白 = 平移，Space+左键 = 平移）。
          // 框选矩形（场景坐标，跟随画布变换一起缩放/平移）。
          if (widget.selectionMode && _marqueeStart != null && _marqueeEnd != null)
            Positioned.fromRect(
              rect: Rect.fromPoints(_marqueeStart!, _marqueeEnd!),
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.12),
                    border: Border.all(color: Colors.blue, width: 1),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): _CancelLinkIntent(),
        SingleActivator(LogicalKeyboardKey.delete): _DeleteEdgeIntent(),
        SingleActivator(LogicalKeyboardKey.backspace): _DeleteEdgeIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _CancelLinkIntent: CallbackAction<_CancelLinkIntent>(
            onInvoke: (_CancelLinkIntent intent) {
              _cancelLinking();
              return null;
            },
          ),
          _DeleteEdgeIntent: CallbackAction<_DeleteEdgeIntent>(
            onInvoke: (_DeleteEdgeIntent intent) {
              _deleteHoveredOrSelectedEdge();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _canvasFocus,
          autofocus: true,
          child: LayoutBuilder(builder: (context, constraints) {
            _viewport = Size(constraints.maxWidth, constraints.maxHeight);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) widget.onViewportCenter?.call(_sceneCenter());
            });
            _autoFitOnce(posOf, layout.nodes);
            // ── 连线 hover 层 ──
            // 挂在**整个 Stack 的外面**（而不是某条线的 Positioned 上）：
            // ① 鼠标在画布任意位置都能进来 —— 包括空白区域和节点卡片之上；
            // ② MouseRegion 只做回调、不参与手势竞技，不会吞掉下面的 pan/缩放；
            // ③ 它的祖先角色还让 hover 事件在 hover → 删除按钮的迁移过程中不断线。
            // 光标反馈当前模式：Space=grab（要平移）；悬停节点=move（可拖卡片）；
            // 否则=basic（空白处平移 / 点击）。让用户一眼看出「现在拖会发生什么」。
            // 框选整组移动模式下，只有悬停在**已选中**节点上才给 move（此时拖=移动整组），
            // 悬停未选中节点 / 空白则是 basic（拖=开新框选）。
            final groupHover = widget.selectionMode &&
                widget.allowGroupDrag &&
                _hoveredKpId != null &&
                widget.selectedKpIds.contains(_hoveredKpId);
            final cursor = widget.penMode
                ? SystemMouseCursors.cell
                : widget.eraserMode
                    ? SystemMouseCursors.click
                    : (_spaceHeld
                        ? SystemMouseCursors.grab
                        : (groupHover ||
                                (!widget.selectionMode && _hoveredKpId != null))
                            ? SystemMouseCursors.move
                            : SystemMouseCursors.basic);
            return MouseRegion(
              cursor: cursor,
              onHover: _onCanvasHover,
              onExit: _onCanvasHoverExit,
              child: Stack(
                children: [
                  // ── 手势层：既是 pan/zoom 的接收面，也是「空白处点击」的接收面 ──
                  // HitTestBehavior.opaque 让它在没有命中任何子节点时也能收到事件；
                  // 它同时是内容的**祖先**，所以命中节点卡片时它也在 hit path 里，
                  // 按下时 _onScaleStart 用 _nodeAt 分流：命中节点→拖节点，否则→平移。
                  Positioned.fill(
                    child: Listener(
                      onPointerSignal: _onPointerSignal,
                      // 按下瞬间再校正一次 Space 态：hover 已覆盖绝大多数情况，
                      // 这里兜住「鼠标一直停着不动、直接按住 Space 点下去」——
                      // 那种情况下没有 hover 事件，平移门控必须是最新的。
                      // 只是改一个 bool，不会误触发缩放/平移。
                      onPointerDown: (_) => _syncSpaceState(),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onScaleStart: _onScaleStart,
                        onScaleUpdate: _onScaleUpdate,
                        onScaleEnd: _onScaleEnd,
                        // 点击命中必须用「本次点按」的场景坐标：tap 抢赢竞技场时
                        // _onScaleStart 不会触发，沿用上次留下的 _lastTapScene
                        // 会让命中判定偏移（问题7）。onTapDown 总能拿到真实位置。
                        onTapDown: (d) =>
                            _lastTapScene = _toScene(d.localPosition),
                        // 只在连线态挂 onTap，避免平时和缩放手势抢 arena。
                        onTap: linking ? _cancelLinking : _onCanvasTap,
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
                // 框选覆盖层：此模式下接管指针 —— 拖拽框选、点按切换节点选中；
                // 放内容之上，故框选时不会误拖卡片 / 平移画布。
                if (widget.selectionMode)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onScaleStart: _onScaleStart,
                      onScaleUpdate: _onScaleUpdate,
                      onScaleEnd: _onScaleEnd,
                    child: const SizedBox.expand(),
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
                      onFit: () =>
                          setState(() => _fitToContent(posOf, layout.nodes)),
                      onReset: _reset,
                      scale: _scale,
                      frameMode: widget.frameMode,
                      onToggleFrameMode: widget.onToggleFrameMode,
                    ),
                  ),
                ],
              ),
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

/// Delete/Backspace 触发：删除当前 hover 或选中的连线。
class _DeleteEdgeIntent extends Intent {
  const _DeleteEdgeIntent();
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
            width: 28,
            height: 28,
            child: Icon(Icons.close, size: 18, color: Colors.redAccent),
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
    required this.frameMode,
    this.onToggleFrameMode,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;
  final VoidCallback onReset;
  final double scale;

  /// 框选模式开关状态（按钮图标 / 高亮反映它）。
  final bool frameMode;

  /// 「框选模式」开关回调。
  final VoidCallback? onToggleFrameMode;

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
              // 框选模式（常驻开关）：开启后画布可拖拽框选知识点，选好后可
              // 局部重排 / 局部连线，拖动选中组内任意一个即整组一起移动。
              IconButton(
                icon: Icon(frameMode ? Icons.deselect : Icons.crop_free),
                iconSize: 18,
                tooltip: frameMode
                    ? '退出框选模式'
                    : '框选模式：拖拽框选知识点；选好后可局部重排 / 局部连线，拖动其中一个整组移动',
                onPressed: onToggleFrameMode,
                style: frameMode
                    ? IconButton.styleFrom(
                        backgroundColor:
                            Theme.of(context).colorScheme.primaryContainer)
                    : null,
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

/// 画布底纹网格（细格子 + 每 5 格一根略深的主线）。
///
/// 在**场景坐标系**里绘制（调用方把它放在画布的 `Transform` 之内），所以格子会
/// 跟着画布一起缩放 / 平移 —— 用户看到的格子就是拖动时吸附的格子，所见即所得。
///
/// [step] 由 `TreeCanvasState._gridStep` 按当前缩放算好（缩小时逐级加倍），
/// 保证屏幕上任何时刻都不会密成一片灰雾；因为加倍后仍是基础格距的整数倍，
/// 吸附目标始终落在同一套格点上。
class _GridPainter extends CustomPainter {
  const _GridPainter({
    required this.step,
    required this.originShift,
    required this.strokeWidth,
  });

  /// 网格线距（场景单位）。≤ 0 时不画。
  final double step;

  /// painter 局部原点相对场景 (0,0) 的偏移（= 调用方给的 `_gridMargin`）。
  final double originShift;

  /// 线宽（场景单位）：调用方传 `1 / _scale`，让屏幕上线宽恒为 1px。
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (step <= 0 || size.isEmpty) return;
    final minor = Paint()
      ..color = _gridMinorColor
      ..strokeWidth = strokeWidth;
    final major = Paint()
      ..color = _gridMajorColor
      ..strokeWidth = strokeWidth * 1.5;

    // 按**场景格号** k 遍历：格号能被 5 整除的画主线，这样主线的位置与缩放无关。
    final firstCol = (-originShift / step).floor();
    final lastCol = ((size.width - originShift) / step).ceil();
    for (var k = firstCol; k <= lastCol; k++) {
      final x = originShift + k * step;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        k % 5 == 0 ? major : minor,
      );
    }
    final firstRow = (-originShift / step).floor();
    final lastRow = ((size.height - originShift) / step).ceil();
    for (var k = firstRow; k <= lastRow; k++) {
      final y = originShift + k * step;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        k % 5 == 0 ? major : minor,
      );
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.step != step ||
      old.originShift != originShift ||
      old.strokeWidth != strokeWidth;
}

/// 画前置关系连线（前置在上、后继在下，正交折线 + 终点圆点）。
///
/// 折线由 [routeEdge] 预先算好（避开所有其它节点卡片），这里只负责描出来。
/// [edgeColors] 是提前算好的「交叉着色」结果（带几何缓存），见 [TreeCanvasState._resolveEdgeColors]。

class _EdgesPainter extends CustomPainter {
  const _EdgesPainter({
    required this.edges,
    required this.edgeColors,
    this.origin = Offset.zero,
    this.linkingFrom,
    this.hoveredEdgeId,
  });

  final List<_RoutedEdge> edges;

  /// 每条边的描边颜色，与 [edges] 一一对应（无交叉的是默认灰）。
  final List<Color> edgeColors;

  /// painter 局部坐标系原点对应的场景坐标（见 [_paintMargin]）。
  final Offset origin;

  final String? linkingFrom;

  /// 鼠标悬停的连线 id；它的线会加粗 + 描一圈半透明光晕。
  final String? hoveredEdgeId;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < edges.length; i++) {
      final pts = edges[i].points;
      if (pts.length < 2) continue;
      final path = Path()
        ..moveTo(pts.first.dx + origin.dx, pts.first.dy + origin.dy);
      for (var k = 1; k < pts.length; k++) {
        path.lineTo(pts[k].dx + origin.dx, pts[k].dy + origin.dy);
      }

      // ── 颜色优先级：连线态起点高亮（琥珀） > 鼠标悬停 > 交叉着色 > 默认灰 ──
      //   琥珀必须压在最上层：它表达的是「这条边的起点正在连线」这个**临时状态**，
      //   是本帧最重要的语义；而着色只是静态区分度。
      final isLinkHighlighted = linkingFrom == edges[i].edge.fromKpId;
      final isHovered = hoveredEdgeId == edges[i].edge.id;
      final base = i < edgeColors.length ? edgeColors[i] : _defaultEdgeColor;
      final color = isLinkHighlighted ? Colors.amber.shade700 : base;
      final strokeWidth = isLinkHighlighted ? 2.2 : (isHovered ? 2.4 : 1.4);

      if (isHovered || isLinkHighlighted) {
        // 光晕：先用半透明粗笔画描一遍，让「被选中的是哪条」在密集的交叉路段
        // 也能一眼看出来（只看 2.4px 的细线不够）。
        canvas.drawPath(
          path,
          Paint()
            ..color = color.withValues(alpha: 0.22)
            ..strokeWidth = strokeWidth + 5
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..style = PaintingStyle.stroke,
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = strokeWidth
          ..style = PaintingStyle.stroke,
      );
      canvas.drawCircle(
        Offset(pts.last.dx + origin.dx, pts.last.dy + origin.dy),
        isHovered ? 4.0 : 3.0,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _EdgesPainter old) =>
      !identical(old.edges, edges) ||
      !identical(old.edgeColors, edgeColors) ||
      old.linkingFrom != linkingFrom ||
      old.hoveredEdgeId != hoveredEdgeId ||
      old.origin != origin;
}

/// 把 `#rrggbb`（或 `#RRGGBB`）十六进制颜色解析成 Flutter [Color]。
///
/// 只取低 24 位 RGB，alpha 固定不透明（笔迹不需要透明度）。
Color _parseHex(String hex) {
  final h = hex.replaceFirst('#', '').trim();
  final v = int.parse(h, radix: 16);
  return Color(0xFF000000 | v);
}

/// 画布手写笔迹绘制（已持久化笔迹 + 当前正在画的那一笔）。
///
/// 在**场景坐标系**里绘制（调用方把它放在画布的 `Transform` 之内），所以笔迹会
/// 跟着画布一起缩放 / 平移。与 [_EdgesPainter] 一样用 [origin] 补偿掉外层
/// `Positioned` 的 `-_paintMargin` 偏移，避免被裁掉。
class _StrokesPainter extends CustomPainter {
  const _StrokesPainter({
    required this.strokes,
    this.current = const <Offset>[],
    this.origin = Offset.zero,
  });

  /// 已持久化的笔迹。
  final List<CanvasStrokeVm> strokes;

  /// 当前正在画的笔迹（跟随手指的实时点）；空 = 没在画。
  final List<Offset> current;

  /// painter 局部坐标系原点对应的场景坐标（见 [_paintMargin]）。
  final Offset origin;

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      _drawStroke(
        canvas,
        <Offset>[for (final p in s.points) Offset(p.x, p.y)],
        _parseHex(s.color),
        s.width,
      );
    }
    if (current.length >= 2) {
      _drawStroke(canvas, current, _parseHex('#1a1a1a'), 3.0);
    } else if (current.length == 1) {
      // 单点也画一个圆点，避免「点一下没反应」。
      canvas.drawCircle(
        current.first + origin,
        1.5,
        Paint()..color = _parseHex('#1a1a1a'),
      );
    }
  }

  void _drawStroke(
      Canvas canvas, List<Offset> pts, Color color, double width) {
    if (pts.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    if (pts.length == 1) {
      canvas.drawCircle(pts.first + origin, width / 2, paint);
      return;
    }
    final path = Path()
      ..moveTo(pts.first.dx + origin.dx, pts.first.dy + origin.dy);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx + origin.dx, pts[i].dy + origin.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _StrokesPainter old) =>
      !identical(old.strokes, strokes) || !identical(old.current, current);
}
