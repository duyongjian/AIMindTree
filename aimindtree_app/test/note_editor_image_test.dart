/// 笔记编辑器「插入图片」入口测试（T05）。
///
/// 只测 UI 接线与取消路径的鲁棒性：
/// - 工具栏出现「插入图片」按钮（`onInsertImage` 已注入）；
/// - 点它 → file_picker 走平台 channel（测试环境无人应答 = 用户取消）
///   → 静默返回：不弹错、不改状态、编辑器照常可用。
///
/// 入库 / 去重 / 上限 / 孤儿清理 / LRU 的数据面在
/// `note_asset_repository_test.dart` 覆盖；选文件的正常路径依赖真实
/// 系统对话框，属真机 E2E（见 docs 真机清单）。
library;

import 'package:aimindtree_app/ai/ai_job_service.dart';
import 'package:aimindtree_app/ai/ai_provider.dart';
import 'package:aimindtree_app/ai/ai_service.dart';
import 'package:aimindtree_app/ai/ai_task_router.dart';
import 'package:aimindtree_app/ai/extraction_service.dart';
import 'package:aimindtree_app/data/db/drift_database.dart';
import 'package:aimindtree_app/data/repositories/group_repository.dart';
import 'package:aimindtree_app/data/repositories/knowledge_repository.dart';
import 'package:aimindtree_app/data/repositories/note_asset_repository.dart';
import 'package:aimindtree_app/data/repositories/notebook_repository.dart';
import 'package:aimindtree_app/data/repositories/tree_repository.dart';
import 'package:aimindtree_app/features/notes/note_editor_page.dart';
import 'package:file_picker/file_picker.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假平台实现：一律返回 null（= 用户取消）。
///
/// `FilePicker.platform` 是 `late` 单例，正常由生成的插件 registrant 赋值；
/// widget 测试不跑 registrant → 直接访问会抛 LateInitializationError。
/// 子类构造函数走 file_picker 内部的私有 token，`platform` setter 的
/// 校验能通过（PlatformInterface 的标准测试手法）。
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

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    FilePicker.platform = _CancelFilePicker();
  });

  tearDown(() async => db.close());

  ExtractionService makeService() => ExtractionService(
        repo: KnowledgeRepository(db, deviceId: 'd'),
        notebooks: NotebookRepository(db, deviceId: 't'),
        trees: TreeRepository(db, deviceId: 'd'),
        groups: GroupRepository(db, deviceId: 'd'),
        jobs: AiJobService(baseUrl: 'http://127.0.0.1:8787'),
        ai: AiService(router: AiTaskRouter(providers: <String, AiProvider>{})),
        assets: NoteAssetRepository(db, deviceId: 'd'),
      );

  testWidgets('工具栏有「插入图片」按钮；取消选图时静默无异常', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: NoteEditorPage(service: makeService(), db: db),
    ));
    await tester.pumpAndSettle();

    // 按钮存在（链接按钮右边那一组）。
    final btn = find.byTooltip('插入图片（选本地图片，存入笔记附件）');
    expect(btn, findsOneWidget);

    // 点击 → 平台 channel 无人应答 = 取消 → 静默返回。
    await tester.tap(btn);
    await tester.pumpAndSettle();

    // 编辑器照常：没有报错状态文字、没有 SnackBar、页面还在。
    expect(find.byType(NoteEditorPage), findsOneWidget);
    expect(find.textContaining('选图失败'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });
}
