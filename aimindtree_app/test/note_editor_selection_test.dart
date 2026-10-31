/// 笔记编辑器「划词提取（T15）」+「提取模式勾选」UI 测试。
///
/// 覆盖：
/// - AppBar 有第三个按钮「划词提取」（`Icons.auto_fix_high`）；
/// - 没选文字就点它 → SnackBar 提示「请先在正文中选中要提取的文字」，
///   不调 AI、不崩；
/// - 点「提取知识点」不再直接提取，先弹模式选择（三选一，默认仅知识点）；
/// - 三态映射到 **prompt variant**（走 body 穿透，任务码始终是 T1）：
///   仅知识点 = 不传（null）/ 仅要点重点 = 'keypoints' / 两者都要 = 'both'；
/// - 源码守卫：模式弹窗与划词入口的痕迹留在页面里（防回归被摘掉）。
///
/// **T4 迁移说明**：正文改造为所见即所得后，全局不再有「第 2 个常驻 TextField」
/// （`find.byType(TextField).at(1)` 必然失效）—— 正文按块渲染，点哪块哪块才变成
/// 输入框。所以先把输入动作用 [_enterBody] 收敛成一条「点正文首块 → 写入」的路径，
/// 断言本身一条不少。
library;

import 'dart:io';

import 'package:aimindtree_app/ai/ai_job_service.dart';
import 'package:aimindtree_app/ai/ai_provider.dart';
import 'package:aimindtree_app/ai/ai_service.dart';
import 'package:aimindtree_app/ai/ai_task.dart';
import 'package:aimindtree_app/ai/ai_task_router.dart';
import 'package:aimindtree_app/ai/extraction_service.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/repositories/group_repository.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:aimindtree_app/data/repositories/note_asset_repository.dart';
import 'package:aimindtree_app/data/repositories/tree_repository.dart';
import 'package:aimindtree_app/features/notes/note_editor_page.dart';
import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假平台实现：一律返回 null（= 用户取消）。
///
/// `FilePicker.platform` 是 `late` 单例，正常由生成的插件 registrant 赋值；
/// widget 测试不跑 registrant → 直接访问会抛 LateInitializationError。
class _CancelFilePicker extends FilePicker {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    @Deprecated(
        'allowCompression is deprecated and has no effect. Use compressionQuality instead.')
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      null;
}

/// 假 Provider：返回一条知识点（T1/T15 通用），并记录收到的任务码与 variant。
class _StubProvider extends AiProvider {
  final List<AiTask> tasks = <AiTask>[];
  final List<String?> variants = <String?>[];

  @override
  String get id => 'stub';

  @override
  String get protocol => 'stub';

  @override
  Future<AiTaskResult> runTask(
    AiTask task,
    Map<String, dynamic> inputs, {
    String? user,
    Duration timeout = const Duration(seconds: 120),
    String? variant,
  }) async {
    tasks.add(task);
    variants.add(variant);
    return const AiTaskResult(
      content: '{}',
      parsed: <String, dynamic>{
        'knowledge_points': <dynamic>[
          <String, dynamic>{
            'name': '导数',
            'type': 'concept',
            'definition': '描述变化率',
            'source_quote': '导数',
          },
        ],
      },
    );
  }

  @override
  Stream<AiChunk> streamChat(
    String query, {
    String? conversationId,
    String? user,
    Duration timeout = const Duration(seconds: 120),
    AiTask? task,
    String? variant,
    String? jobId,
  }) =>
      const Stream<AiChunk>.empty();

  @override
  void dispose() {}
}

/// 在正文首块里写入 [text]（改造后的「进入编辑态」路径）。
///
/// 定位方式（替代旧的 `find.byType(TextField).at(1)`）：
/// 1. 正文容器有稳定 Key `note-body`（页面里给的 `ValueKey('note-body')`）；
/// 2. 点它的左上角（内边距 12/8 之后的第一块）→ 该块就地变成 TextField；
/// 3. 再用容器**内部**唯一的那一个 TextField 写入，避免误命中标题框。
Future<void> _enterBody(WidgetTester tester, String text) async {
  final body = find.byKey(const ValueKey<String>('note-body'));
  expect(body, findsOneWidget);
  await tester.tapAt(tester.getRect(body).topLeft + const Offset(24, 12));
  await tester.pumpAndSettle();

  final field = find.descendant(of: body, matching: find.byType(TextField));
  expect(field, findsOneWidget, reason: '点正文后应当只有被点中的那一块变成输入框');
  await tester.enterText(field, text);
  await tester.pumpAndSettle();
}

void main() {
  late AppDatabase db;
  late _StubProvider stub;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    FilePicker.platform = _CancelFilePicker();
    stub = _StubProvider();
  });

  tearDown(() async {
    await db.close();
  });

  ExtractionService makeService() => ExtractionService(
        repo: KnowledgeRepository(db, deviceId: 'd'),
        trees: TreeRepository(db, deviceId: 'd'),
        groups: GroupRepository(db, deviceId: 'd'),
        jobs: AiJobService(baseUrl: 'http://127.0.0.1:1'),
        ai: AiService(router: AiTaskRouter(providers: const {}, fallback: stub)),
        assets: NoteAssetRepository(db, deviceId: 'd'),
      );

  testWidgets('AppBar 有「划词提取」按钮；未选文字时只提示不提取',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: NoteEditorPage(service: makeService(), db: db),
    ));
    await tester.pumpAndSettle();

    final btn = find.byTooltip('划词提取');
    expect(btn, findsOneWidget);
    expect(find.byIcon(Icons.auto_fix_high), findsOneWidget);

    // 没选文字 → SnackBar 提示，且不调 AI。
    await tester.tap(btn);
    await tester.pumpAndSettle();
    expect(find.text('请先在正文中选中要提取的文字'), findsOneWidget);
    expect(stub.tasks, isEmpty);
    expect(find.byType(NoteEditorPage), findsOneWidget);
  });

  testWidgets('点「提取知识点」先弹模式选择（默认仅知识点）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: NoteEditorPage(service: makeService(), db: db),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('提取知识点 (T1)'));
    await tester.pumpAndSettle();

    // 弹窗出现，三个模式都在。
    expect(find.text('选择提取模式'), findsOneWidget);
    expect(find.text('仅知识点'), findsOneWidget);
    expect(find.text('仅要点重点'), findsOneWidget);
    expect(find.text('知识点 + 要点'), findsOneWidget);
    // 还没开始提取。
    expect(stub.tasks, isEmpty);

    // 取消 → 不提取。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('选择提取模式'), findsNothing);
    expect(stub.tasks, isEmpty);
  });

  testWidgets('选「仅要点重点」→ 开始提取 → variant=keypoints 透传',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: NoteEditorPage(service: makeService(), db: db),
    ));
    await tester.pumpAndSettle();

    // 先写点正文（否则 _save 出来的笔记是空的，锚点校验会剔除）。
    await _enterBody(tester, '导数');

    await tester.tap(find.byTooltip('提取知识点 (T1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅要点重点'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始提取'));
    await tester.pumpAndSettle();

    // 任务码仍是 T1（variant 不是新任务码），variant='keypoints' 走 body。
    expect(stub.tasks, <AiTask>[AiTask.t1Extract]);
    expect(stub.variants, <String>['keypoints']);
    // 提取成功：状态栏给回执。
    expect(find.textContaining('已入库'), findsOneWidget);
  });

  testWidgets('选「知识点 + 要点」→ 开始提取 → variant=both 透传',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: NoteEditorPage(service: makeService(), db: db),
    ));
    await tester.pumpAndSettle();

    await _enterBody(tester, '导数');

    await tester.tap(find.byTooltip('提取知识点 (T1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('知识点 + 要点'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始提取'));
    await tester.pumpAndSettle();

    expect(stub.tasks, <AiTask>[AiTask.t1Extract]);
    expect(stub.variants, <String>['both']);
  });

  testWidgets('默认「仅知识点」→ 不带变体（保旧行为）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: NoteEditorPage(service: makeService(), db: db),
    ));
    await tester.pumpAndSettle();

    await _enterBody(tester, '导数');

    await tester.tap(find.byTooltip('提取知识点 (T1)'));
    await tester.pumpAndSettle();
    // 不动任何单选，直接开始。
    await tester.tap(find.text('开始提取'));
    await tester.pumpAndSettle();

    expect(stub.tasks, <AiTask>[AiTask.t1Extract]);
    expect(stub.variants.single, '');
  });

  test('源码守卫：划词入口 + 模式弹窗 + variant 痕迹留在编辑器里', () {
    final src = File('lib/features/notes/note_editor_page.dart')
        .readAsStringSync();
    expect(src, contains('Icons.auto_fix_high'));
    expect(src, contains("tooltip: '划词提取'"));
    expect(src, contains('extractFromSelection'));
    expect(src, contains('_selectionText'));
    expect(src, contains('选择提取模式'));
    // 三态勾选映射到 variant（不再是新任务码）。
    expect(src, contains("value: 'keypoints'"));
    expect(src, contains("value: 'both'"));
    expect(src, contains('variant: variant'));
    expect(src, contains('_variantLabel'));
    expect(src, contains('kSelectionMaxLength'));
  });
}
