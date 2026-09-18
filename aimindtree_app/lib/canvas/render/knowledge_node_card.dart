/// 知识树节点卡片（画布上的一个 KP 节点）。
///
/// - 顶部灰条是**拖拽手柄**：只有拖它才移动节点，拖卡片其它区域仍然是
///   「平移画布」，避免与画布的 pan/zoom 手势抢 GestureArena。
/// - 右上角「连接」按钮：进入连线模式，再点目标节点建立前置关系。
/// - 选中态（[isSelected]）：从画布点选某节点时高亮蓝色边框，用于补前置入口。
library;

import 'package:flutter/material.dart';

import '../../data/models/knowledge_point.dart';

class KnowledgeNodeCard extends StatelessWidget {
  const KnowledgeNodeCard({
    super.key,
    required this.kp,
    required this.mastery,
    this.isLinkSource = false,
    this.isLinkTargetCandidate = false,
    this.isSelected = false,
    this.onTap,
    this.onLinkTap,
    this.onDragUpdate,
    this.onDragEnd,
  });

  final KnowledgePoint kp;
  final MasteryStatus mastery;

  /// 当前正处于「连线起点」状态。
  final bool isLinkSource;

  /// 连线进行中、且可作为目标（即不是起点自己）。
  final bool isLinkTargetCandidate;

  /// 当前被画布点选的节点（高亮蓝色边框）。
  final bool isSelected;

  final VoidCallback? onTap;
  final VoidCallback? onLinkTap;

  /// 拖动增量（场景坐标）。
  final ValueChanged<Offset>? onDragUpdate;
  final VoidCallback? onDragEnd;

  Color get _masteryColor => switch (mastery) {
        MasteryStatus.mastered => Colors.green,
        MasteryStatus.learning => Colors.blue,
        MasteryStatus.notMastered => Colors.red.shade400,
        MasteryStatus.abandoned => Colors.grey,
        MasteryStatus.unknown => Colors.orange.shade200,
      };

  @override
  Widget build(BuildContext context) {
    final borderColor = isSelected
        ? Colors.blue.shade700
        : (isLinkSource
            ? Colors.amber.shade700
            : (isLinkTargetCandidate
                ? Colors.amber.shade300
                : Colors.transparent));
    final borderWidth = isSelected || isLinkSource ? 2.0 : 1.5;
    return Material(
      elevation: isSelected ? 4 : (isLinkSource ? 6 : 1.5),
      borderRadius: BorderRadius.circular(8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: _masteryColor, width: 4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── 拖拽手柄 ──
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) => onDragUpdate?.call(d.delta),
                onPanEnd: (_) => onDragEnd?.call(),
                child: Container(
                  height: 14,
                  color: Colors.grey.shade200,
                  child: Icon(Icons.drag_indicator,
                      size: 12, color: Colors.grey.shade600),
                ),
              ),
              // ── 卡片主体 ──
              Expanded(
                child: InkWell(
                  onTap: onTap,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: borderColor, width: borderWidth),
                    ),
                    padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                kp.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            // ── 连线按钮 ──
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: Tooltip(
                                message: isLinkSource
                                    ? '取消连线'
                                    : '从这里连一条前置关系到别的知识点',
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(10),
                                  onTap: onLinkTap,
                                  child: Icon(
                                    isLinkSource ? Icons.link_off : Icons.link,
                                    size: 14,
                                    color: isLinkSource
                                        ? Colors.amber.shade800
                                        : Colors.grey.shade600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${kp.type.label} · 置信度 ${kp.confidence.toStringAsFixed(2)}',
                          style:
                              const TextStyle(fontSize: 11, color: Colors.grey),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (kp.definition.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            kp.definition,
                            style: const TextStyle(fontSize: 11),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const Spacer(),
                        Text(
                          '掌握：${mastery.label}',
                          style: TextStyle(fontSize: 10, color: _masteryColor),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
