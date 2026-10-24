/// 画布上的自由文本卡片（笔记卡片 / 透明文本框）。
///
/// 纯展示组件：填满父级 `Positioned` 给定的盒子（宽高由调用方按 card.w/card.h 传入），
/// 不参与拖拽 / 点击手势 —— 这些由外层 [TreeCanvas] 在场景坐标层统一处理。
library;

import 'package:flutter/material.dart';

/// 画布文本卡片。
///
/// - `kind == 'note_card'`：不透明白卡（圆角 + 细边框 + 浅阴影），显示标题（粗体）与正文摘要；
///   若 [linked] 为真，左上角显示「笔记」小标签。
/// - `kind == 'text_box'`：透明无底，直接把文字画在画布上（空内容时给一条极淡边框提示热区）。
class CanvasTextCard extends StatelessWidget {
  const CanvasTextCard({
    required this.title,
    required this.body,
    required this.kind,
    this.linked = false,
    this.onTap,
    super.key,
  });

  final String title;
  final String body;
  final String kind; // 'note_card' | 'text_box'
  final bool linked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isNote = kind == 'note_card';

    final textChild = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (isNote && linked)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                '笔记',
                style: TextStyle(fontSize: 10, color: Colors.blue),
              ),
            ),
          ),
        Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: isNote ? Colors.black87 : Colors.black,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        Text(
          body,
          style: TextStyle(
            fontSize: 12,
            color: isNote ? Colors.grey.shade700 : Colors.black87,
          ),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );

    return SizedBox.expand(
      child: Container(
        clipBehavior: Clip.antiAlias,
        padding: const EdgeInsets.all(10),
        decoration: isNote
            ? BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x1A000000),
                    blurRadius: 4,
                    offset: Offset(0, 1),
                  ),
                ],
              )
            : BoxDecoration(
                // 透明文本框：无底色；空内容时给一条极淡的实线边框提示热区。
                borderRadius: BorderRadius.circular(4),
                border: (title.isEmpty && body.isEmpty)
                    ? Border.all(color: Colors.grey.shade300)
                    : null,
              ),
        child: textChild,
      ),
    );
  }
}
