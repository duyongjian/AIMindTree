/// 画布富组件视图模型（★2.0.0：无限画布放置更多组件）。
///
/// 纯数据载体，不依赖 Flutter UI 类型，供仓储层、画布渲染层、页面层共用。
library;

/// 画布文本卡片视图模型。
///
/// 同时承载两种 UI：
/// - 「笔记卡片」（`noteId` 非空）：标题+摘要可由关联笔记自动派生；
/// - 「透明文本框」（自由文本）：标题/正文手填。
///
/// 位置（x/y/w/h）来自对应的 [CanvasNodes]（`target_type='card'`）行。
class CanvasCardVm {
  const CanvasCardVm({
    required this.id, // CanvasCards.id
    required this.nodeId, // CanvasNodes.id = '$canvasId:$cardId'
    required this.x,
    required this.y,
    this.w = 220,
    this.h = 140,
    this.noteId,
    this.title = '',
    this.body = '',
    this.kind = 'text_box', // 'note_card' | 'text_box'
  });

  final String id;
  final String nodeId;
  final double x;
  final double y;
  final double w;
  final double h;
  final String? noteId;
  final String title;
  final String body;
  final String kind;
}

/// 画布手写笔迹视图模型（圆珠笔 + 橡皮）。
///
/// [points] 为**画布坐标系**的点序列（与节点 x/y 同一套坐标系）。
class CanvasStrokeVm {
  const CanvasStrokeVm({
    required this.id,
    required this.canvasId,
    required this.points,
    this.color = '#1a1a1a',
    this.width = 3.0,
  });

  final String id;
  final String canvasId;
  final List<({double x, double y})> points;
  final String color;
  final double width;
}
