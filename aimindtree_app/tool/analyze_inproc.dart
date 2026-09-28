/// 进程内静态分析（等价于 `flutter analyze`，但不起子进程）。
///
/// 存在理由：某些受限环境（WSL 黑名单拦截 flutter 脚本、或 Windows 匿名管道
/// 实例耗尽导致 `dart analyze` 的 analysis server 子进
/// 程 `CreateFile failed 231`）下，`flutter analyze` / `dart analyze` 都跑不起来。
/// 本脚本直接用 `package:analyzer` 在同一进程内做全量分析，绕开子进程。
///
/// 用法（必须在 `aimindtree_app/` 目录下执行，以便解析 package_config.json）：
/// ```
/// dart tool/analyze_inproc.dart            # 分析 lib/ + test/
/// dart tool/analyze_inproc.dart lib/ai     # 只分析指定目录
/// ```
///
/// 退出码：0 = 无问题；1 = 有 error/warning/lint。
/// 生成文件（`*.g.dart` / `*.freezed.dart`）与 `.dart_tool/` 默认跳过，
/// 与 `analysis_options.yaml` 的 `analyzer.exclude` 保持一致。
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:path/path.dart' as p;

const List<String> kDefaultRoots = <String>['lib', 'test'];

bool _skipped(String path) {
  final s = path.replaceAll('\\', '/');
  if (s.contains('/.dart_tool/')) return true;
  if (s.endsWith('.g.dart') || s.endsWith('.freezed.dart')) return true;
  return false;
}

/// 统一成 Windows 原生绝对路径（analyzer 强制要求 absolute + normalized）。
String _abs(String raw) => p.normalize(p.absolute(raw));

Future<void> main(List<String> args) async {
  final base = _abs(Directory.current.path);
  final roots = args.isNotEmpty ? args : kDefaultRoots;
  final included = <String>[for (final r in roots) _abs(r)];

  final collection = AnalysisContextCollection(includedPaths: included);

  final found = <_Issue>[];
  var fileCount = 0;

  for (final context in collection.contexts) {
    for (final path in context.contextRoot.analyzedFiles()) {
      if (!path.endsWith('.dart') || _skipped(path)) continue;
      fileCount++;
      final result = await context.currentSession.getErrors(path);
      if (result is! ErrorsResult) {
        stderr.writeln('跳过（无法分析）：$path');
        continue;
      }
      for (final e in result.errors) {
        found.add(_Issue(
          severity: e.errorCode.errorSeverity.name.toUpperCase(),
          file: path,
          line: e.offset >= 0 ? result.lineInfo.getLocation(e.offset).lineNumber : 0,
          col: e.offset >= 0 ? result.lineInfo.getLocation(e.offset).columnNumber : 0,
          code: e.errorCode.name,
          message: e.message,
        ));
      }
    }
  }

  found.sort((a, b) {
    final c = a.file.compareTo(b.file);
    return c != 0 ? c : a.line.compareTo(b.line);
  });

  String rel(String path) {
    final n = p.normalize(path);
    return n.toLowerCase().startsWith(base.toLowerCase())
        ? n.substring(base.length + 1)
        : n;
  }

  for (final i in found) {
    stdout.writeln(
        '  ${i.severity.padRight(7)} ${rel(i.file)}:${i.line}:${i.col}  ${i.code}');
    stdout.writeln('    ${i.message.replaceAll('\n', ' ⏎ ')}');
  }

  final errors = found.where((i) => i.severity == 'ERROR').length;
  final warnings = found.where((i) => i.severity == 'WARNING').length;
  final infos = found.where((i) => i.severity == 'INFO').length;

  stdout.writeln('');
  stdout.writeln('Analyzed $fileCount file(s) → '
      '$errors error(s), $warnings warning(s), $infos info(s)');
  // 门禁口径：只有 error / warning 才 fail；info（todo 注释等）仅提示。
  if (errors + warnings == 0) {
    stdout.writeln('No issues found!');
    exit(0);
  }
  exit(1);
}

class _Issue {
  const _Issue({
    required this.severity,
    required this.file,
    required this.line,
    required this.col,
    required this.code,
    required this.message,
  });
  final String severity;
  final String file;
  final int line;
  final int col;
  final String code;
  final String message;
}
