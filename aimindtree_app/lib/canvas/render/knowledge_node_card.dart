/// 知识树节点卡片（画布上的一个 KP 节点）。
///
/// - 顶部灰条是**拖拽手柄**：只有拖它才移动节点，拖卡片其它区域仍然是
///   「平移画布」，避免与画布的 pan/zoom 手势抢 GestureArena。
/// - 手柄的**判定区远大于可见区**：卡片外框总高被布局写死（`nodeHeight`，默认
///   136），主体内容实测需要 114px —— 历史上给 90px 时直接报
///   `BOTTOM OVERFLOWED BY 24 PIXELS`。所以单纯把灰条加高会挤压主体
///   （14→24px 时主体只剩 112px，必然溢出），这里改成：可见灰条
///   [handleVisibleHeight]（主体还剩 118px，留 4px 余量）+ 一层**透明命中层**
///   向下多覆盖 [handleExtraHitHeight]，得到 [handleTotalHitHeight] 的实际抓取
///   高度（原始实现只有 14px），却完全不占主体的布局空间。
///   ⚠️ 命中层不能向上溢出卡片：Flutter 的 RenderBox.hitTest 先判
///   `size.contains(position)`，超出 Stack/Material 自身尺寸的区域**画得出来但
///   点不到**（这是 RenderBox 的通用限制，不是 Stack 的 bug）。所以横向 / 向上
///   都不做溢出，只在卡片内部扩大。
/// - 桌面端鼠标：命中层套了 [MouseRegion] + `SystemMouseCursors.move`，鼠标移
///   上去立刻变四向箭头，让「这里可以拖」这件事有明确反馈。
/// - 右上角「连接」按钮：进入连线模式，再点目标节点建立前置关系。
///   ⚠️ 命中层压在它上方，所以命中层必须 `HitTestBehavior.translucent`
///   （外加 `MouseRegion(opaque: false)`）：`defaultHitTestChildren` 是
///   **命中第一个 child 就 `return true`**，opaque 会让底下的 InkWell /
///   连接按钮完全进不了 hit path，顶部这一带的点击会被静默吞掉。
///   改成 translucent 之后：pan 与下层 Tap 同时进竞技场，静止点击时 pan 会在
///   pointer up 认输、Tap 胜出；拖动时 pan 越过 slop 照常 accept。
///   另外命中层向下只延伸到 [handleExtraHitHeight]，不是整张卡片，
///   给标题行和下半部分留出完整的点击面积。
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
  });

  /// 拖拽手柄的**可见**高度。
  ///
  /// 取 18 而不是上限 20：nodeHeight(136) - 20 = 116，只比主体实测所需的
  /// 114px 多 2px，真机上字体 / 字号一变就容易 `BOTTOM OVERFLOWED`；
  /// 18 时主体有 118px（4px 余量），而抓取区靠下面的命中层补齐，肉眼几乎
  /// 看不出 18 与 20 的差别。
  static const double handleVisibleHeight = 18.0;

  /// 拖拽命中层向下多覆盖的高度（压在主体顶部那一部分）。
  ///
  /// 这是**纯透明**延伸，不占布局空间，所以加大它不会挤压主体（主体高度只由
  /// [handleVisibleHeight] 决定）。加到 20（总抓取区 38px）是为了「一抓就中」，
  /// 而不必担心吃掉主体点击 —— 拖拽手势自带启动阈值（见 `TreeCanvas` 的
  /// `_dragStartThreshold`）：位移没攒够就抬手时，pan 会在 pointer up 认输，
  /// 下层的 Tap 照常触发「打开详情 / 连线目标」。
  static const double handleExtraHitHeight = 20.0;

  /// 可抓取区域的总高度（可见条 + 向下的透明延伸）。
  static const double handleTotalHitHeight =
      handleVisibleHeight + handleExtraHitHeight;

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
      child: Stack(
        // fit: expand 是关键：让下层 Column 拿到**紧约束**（等于卡片尺寸），
        // 与改造前 Positioned 直接给卡片施加的约束完全一致 —— 否则 Stack 默认
        // loose 会把约束松成 min=0，Expanded 分到的高度就不再是 116px 了。
        fit: StackFit.expand,
        children: <Widget>[
          ClipRRect(
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
                  // ── 拖拽手柄（只是外观，手势在下面的透明命中层里）──
                  Container(
                    height: handleVisibleHeight,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      // 底部分隔线：让这条 [handleVisibleHeight] 高的灰条读起来
                      // 像一根「把手」，而不是卡片内容的一部分。
                      // （刻意不写死数字：常量一改注释就得跟着改，容易漏。）
                      border: Border(
                        bottom: BorderSide(color: Colors.grey.shade300),
                      ),
                    ),
                    child: Center(
                      child: Icon(
                        Icons.drag_indicator,
                        size: 18,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
                  // ── 卡片主体 ──
                  Expanded(
                    child: InkWell(
                      onTap: onTap,
                      child: Container(
                        decoration: BoxDecoration(
                          border:
                              Border.all(color: borderColor, width: borderWidth),
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
                                        isLinkSource
                                            ? Icons.link_off
                                            : Icons.link,
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
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey),
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
                              style:
                                  TextStyle(fontSize: 10, color: _masteryColor),
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
          // ── 拖拽手势**不在这里**（曾经在这里，是个真 bug）──
          // 抓取条原本是本卡片内部的透明命中层，但卡片都放在同一个 Stack 里，
          // 后绘制的卡片压在上面时，命中测试会先命中上面那张、直接 return
          // （RenderStack.defaultHitTestChildren 首命中即止），底下这张的
          // 抓取条就**永远抓不到** —— 表现是「把 A 拖到 B 上之后，B 再也拖不动」。
          // 现在拖动命中靠外层 ScaleRecognizer 的起点分流（见 TreeCanvas 的
          // _onScaleStart：_nodeAt 命中节点→拖节点，否则→平移），这里只保留
          // 手柄的**外观**（灰条 + 图标），不参与手势。
        ],
      ),
    );
  }
}
