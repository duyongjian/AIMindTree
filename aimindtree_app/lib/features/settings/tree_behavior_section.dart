/// 设置页「知识树行为」分区：两个开关（自动知识点查重 / 自动连线）。
///
/// 对应 E 模块的需求：让用户在设置页自行决定「提取 / 加树时是否查重、
/// 是否自动连线」。读写经 [TreeBehaviorSettings]（SharedPreferences 落地）。
library;

import 'package:flutter/material.dart';

import 'tree_behavior_settings.dart';

/// 知识树行为分区（E 模块）：查重 / 连线双开关。
class TreeBehaviorSection extends StatefulWidget {
  const TreeBehaviorSection({super.key});

  @override
  State<TreeBehaviorSection> createState() => _TreeBehaviorSectionState();
}

class _TreeBehaviorSectionState extends State<TreeBehaviorSection> {
  final TreeBehaviorSettings _settings = TreeBehaviorSettings.instance;

  @override
  void initState() {
    super.initState();
    // 若尚未从 SharedPreferences 载入（理论上 main 已 load 过），这里补一次，
    // 幂等，不影响后续。
    if (!_settings.isLoaded) {
      _settings.load();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 监听单例变化（开关切换 / 首次载入）即时刷新 UI。
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        final settings = _settings;
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Row(
                  children: <Widget>[
                    Icon(Icons.account_tree_outlined),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '知识树行为',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('自动知识点查重'),
                  subtitle: const Text('加入知识点时自动检查并提示重复（默认开）'),
                  value: settings.dedupEnabled,
                  onChanged: (v) => settings.setDedupEnabled(v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('自动连线'),
                  subtitle: const Text(
                      '加入 / 补前置知识点时自动建立前置关系边（默认关）'),
                  value: settings.autoLinkEnabled,
                  onChanged: (v) => settings.setAutoLinkEnabled(v),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
