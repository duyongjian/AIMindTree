import 'package:aimindtree_app/data/models/knowledge_tree.dart';
import 'package:aimindtree_app/features/notes/delete_note_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final impacts = <TreeImpact>[
    const TreeImpact(treeId: 't1', treeName: '物理笔记树', pointCount: 3),
    const TreeImpact(treeId: 't2', treeName: '我的考研树', pointCount: 1),
  ];

  Future<DeleteNotePlan?> open(WidgetTester tester, {int pointCount = 3}) {
    return showDeleteNoteDialog(
      context: tester.element(find.byType(Scaffold)),
      noteTitle: '牛顿定律',
      pointCount: pointCount,
      impacts: impacts,
    );
  }

  testWidgets('无知识点时走简单确认，不展示知识树列表', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          return TextButton(
            onPressed: () => showDeleteNoteDialog(
              context: context,
              noteTitle: '流水账',
              pointCount: 0,
              impacts: const <TreeImpact>[],
            ),
            child: const Text('删'),
          );
        }),
      ),
    ));

    await tester.tap(find.text('删'));
    await tester.pumpAndSettle();

    expect(find.text('删除笔记'), findsOneWidget);
    expect(find.text('我的考研树'), findsNothing);
    expect(find.textContaining('这篇笔记没有知识点'), findsOneWidget);
  });

  testWidgets('展示影响面；勾选/彻底删除会切换提示文案', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));

    final future = open(tester);
    await tester.pumpAndSettle();

    expect(find.text('物理笔记树'), findsOneWidget);
    expect(find.text('3 个知识点来自这篇笔记'), findsOneWidget);
    // 默认不勾任何树 → 知识点保留在原树
    expect(find.textContaining('知识点保留在原知识树中'), findsOneWidget);

    // 勾第一棵树
    await tester.tap(find.text('物理笔记树'));
    await tester.pumpAndSettle();
    expect(find.textContaining('将从 1 棵知识树中移除'), findsOneWidget);

    // 勾「彻底删除」→ 树选择被禁用，文案变化
    await tester.tap(find.text('彻底删除这些知识点'));
    await tester.pumpAndSettle();
    expect(find.textContaining('将删除 3 个知识点及其所有关系'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    final plan = await future;
    expect(plan, isNotNull);
    expect(plan!.deletePoints, isTrue);
  });

  testWidgets('取消返回 null', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));

    final future = open(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(await future, isNull);
  });
}
