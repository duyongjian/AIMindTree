/// `markdown_actions.dart` 纯函数测试（不依赖 Flutter 渲染，只算字符串 + 选区）。
///
/// 覆盖：加粗/斜体/行内代码包裹、行前缀切换（标题/列表/引用）、代码块、链接、
/// 表格、图片、分割线；以及必测边界：
/// 1. 有选区 / 无选区（占位）；
/// 2. 反向选区（extentOffset < baseOffset）；
/// 3. 文首（offset 0）/ 文末（offset == length）；
/// 4. 多行选区逐行加前缀；
/// 5. 已有前缀时再点一次 → 取消。
library;

import 'package:aimindtree_app/features/notes/markdown_actions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // -------------------------------------------------------------------------
  // wrapInline
  // -------------------------------------------------------------------------
  group('wrapInline', () {
    test('无选区：插入占位并选中占位文案', () {
      final r = wrapInline('', const TextSelection.collapsed(offset: 0), '**');
      expect(r.text, '**粗体文字**');
      expect(r.selection.start, 2);
      expect(r.selection.end, 6); // 「粗体文字」4 字
    });

    test('无选区：行内代码用「代码」占位', () {
      final r = wrapInline('正文', const TextSelection.collapsed(offset: 2), '`');
      expect(r.text, '正文`代码`');
      expect(r.selection.start, 3);
      expect(r.selection.end, 5);
    });

    test('有选区：包住选区并保持选中（含 marker）', () {
      const text = 'hello world';
      final sel = const TextSelection(baseOffset: 0, extentOffset: 5);
      final r = wrapInline(text, sel, '**');
      expect(r.text, '**hello** world');
      expect(r.selection.start, 0);
      expect(r.selection.end, 9);
    });

    test('反向选区（extent < base）：结果等同正向选区', () {
      const text = 'hello world';
      final forward = wrapInline(
          text, const TextSelection(baseOffset: 0, extentOffset: 5), '*');
      final backward = wrapInline(
          text, const TextSelection(baseOffset: 5, extentOffset: 0), '*');
      expect(backward.text, forward.text);
      expect(backward.selection.start, forward.selection.start);
      expect(backward.selection.end, forward.selection.end);
    });

    test('文首：无前导字符时也能正确包裹', () {
      const text = 'abc';
      final r = wrapInline(
          text, const TextSelection(baseOffset: 0, extentOffset: 0), '**');
      expect(r.text, '**粗体文字**abc');
      expect(r.selection.start, 2);
      expect(r.selection.end, 6);
    });

    test('文末：光标在最尾部也能正确包裹占位', () {
      const text = 'abc';
      final r = wrapInline(
          text, const TextSelection.collapsed(offset: 3), '`');
      expect(r.text, 'abc`代码`');
      expect(r.selection.start, 4);
      expect(r.selection.end, 6);
    });

    test('再点一次：选中带 marker 的文本 → 取消标记', () {
      const text = '**粗体文字**';
      final first = wrapInline(text, const TextSelection(baseOffset: 0, extentOffset: 8), '**');
      expect(first.text, '粗体文字');
      expect(first.selection.start, 0);
      expect(first.selection.end, 4);
    });

    test('再点一次：上一次 wrap 后的选区（含外部 marker）→ 取消标记', () {
      const text = 'hello';
      final wrapped = wrapInline(
          text, const TextSelection(baseOffset: 0, extentOffset: 5), '**');
      expect(wrapped.text, '**hello**');
      final unwrapped = wrapInline(wrapped.text, wrapped.selection, '**');
      expect(unwrapped.text, 'hello');
      expect(unwrapped.selection.start, 0);
      expect(unwrapped.selection.end, 5);
    });

    test('越界偏移：夹取到文末而不是抛异常', () {
      const text = 'abc';
      final r = wrapInline(
        text,
        const TextSelection(baseOffset: 99, extentOffset: 200),
        '**',
      );
      expect(r.text, 'abc**粗体文字**');
      expect(r.selection.start, 5);
    });
  });

  // -------------------------------------------------------------------------
  // toggleLinePrefix
  // -------------------------------------------------------------------------
  group('toggleLinePrefix', () {
    test('单行加前缀', () {
      const text = '标题';
      final r = toggleLinePrefix(
          text, const TextSelection.collapsed(offset: 2), '# ');
      expect(r.text, '# 标题');
      expect(r.selection.start, 0);
      expect(r.selection.end, 4);
    });

    test('已有前缀 → 取消（同前缀再点一次）', () {
      const text = '# 标题';
      final r = toggleLinePrefix(
          text, const TextSelection.collapsed(offset: 4), '# ');
      expect(r.text, '标题');
    });

    test('多行选区：逐行加前缀', () {
      const text = '第一行\n第二行\n第三行';
      final r = toggleLinePrefix(
        text,
        const TextSelection(baseOffset: 1, extentOffset: 10),
        '- ',
      );
      expect(r.text, '- 第一行\n- 第二行\n- 第三行');
      expect(r.selection.start, 0);
      expect(r.selection.end, r.text.length);
    });

    test('多行选区：全部已有前缀时一次性取消', () {
      const text = '- a\n- b';
      final r = toggleLinePrefix(
        text,
        const TextSelection(baseOffset: 0, extentOffset: 7),
        '- ',
      );
      expect(r.text, 'a\nb');
    });

    test('多行选区：只有部分行有前缀时补全缺失行', () {
      const text = '- a\nb';
      final r = toggleLinePrefix(
        text,
        const TextSelection(baseOffset: 0, extentOffset: 5),
        '- ',
      );
      expect(r.text, '- a\n- b');
    });

    test('反向选区：同样作用于整行', () {
      const text = 'abc\ndef';
      final forward = toggleLinePrefix(
          text, const TextSelection(baseOffset: 1, extentOffset: 6), '- ');
      final backward = toggleLinePrefix(
          text, const TextSelection(baseOffset: 6, extentOffset: 1), '- ');
      expect(backward.text, forward.text);
      expect(backward.text, '- abc\n- def');
    });

    test('文首 + 文末：整篇作用且不越界', () {
      const text = 'a\nb';
      final r = toggleLinePrefix(
          text, const TextSelection(baseOffset: 0, extentOffset: 3), '> ');
      expect(r.text, '> a\n> b');
    });

    test('标题家族：## 点 H1 → 替换级别，再点一次 → 取消', () {
      const text = '## 标题';
      final toH1 = toggleLinePrefix(
          text, const TextSelection.collapsed(offset: 5), '# ');
      expect(toH1.text, '# 标题');
      final off = toggleLinePrefix(
          toH1.text, const TextSelection.collapsed(offset: 4), '# ');
      expect(off.text, '标题');
    });

    test('有序列表家族：任意编号都能取消', () {
      const text = '3. 第三步';
      final r = toggleLinePrefix(
          text, const TextSelection.collapsed(offset: 7), '1. ');
      expect(r.text, '第三步');
    });

    test('无序列表家族：* / + 视为同一族（再点一次取消）', () {
      const text = '* 项';
      final r = toggleLinePrefix(
          text, const TextSelection.collapsed(offset: 3), '- ');
      expect(r.text, '项');
    });

    test('有序列表可直接换成无序列表，反之亦然', () {
      final toUl =
          toggleLinePrefix('1. 项', const TextSelection.collapsed(offset: 4), '- ');
      expect(toUl.text, '- 项');
      final toOl =
          toggleLinePrefix('- 项', const TextSelection.collapsed(offset: 3), '1. ');
      expect(toOl.text, '1. 项');
    });

    test('保留行首缩进', () {
      const text = '  - 子项';
      final r = toggleLinePrefix(
          text, const TextSelection.collapsed(offset: 6), '- ');
      expect(r.text, '  子项');
      final reAdd = toggleLinePrefix(
          r.text, const TextSelection.collapsed(offset: 4), '- ');
      expect(reAdd.text, '  - 子项');
    });

    test('引用家族：多层引用降级为单层', () {
      const text = '>> 深引文';
      final r = toggleLinePrefix(
          text, const TextSelection.collapsed(offset: 6), '> ');
      expect(r.text, '> 深引文');
      final off = toggleLinePrefix(
          r.text, const TextSelection.collapsed(offset: 5), '> ');
      expect(off.text, '深引文');
    });
  });

  // -------------------------------------------------------------------------
  // insertFence
  // -------------------------------------------------------------------------
  group('insertFence', () {
    test('无选区：插入代码块并选中占位代码', () {
      const text = '正文';
      final r = insertFence(text, const TextSelection.collapsed(offset: 2));
      expect(r.text, '正文\n\n```\n在此输入代码\n```');
      expect(r.selection.start, 8);
      expect(r.selection.end, 8 + '在此输入代码'.length);
    });

    test('有选区：把选区放进代码块', () {
      const text = 'let a = 1;';
      final r = insertFence(
          text, const TextSelection(baseOffset: 0, extentOffset: 10));
      expect(r.text, '```\nlet a = 1;\n```');
      expect(r.selection.start, 4);
      expect(r.selection.end, 14);
    });

    test('文首：不需要补前导换行', () {
      const text = 'x';
      final r = insertFence(text, const TextSelection.collapsed(offset: 0));
      expect(r.text.startsWith('```\n'), isTrue);
      expect(r.text, '```\n在此输入代码\n```\n\nx');
    });

    test('已在行首且上面有空行：不重复补空行', () {
      const text = '段落\n\n';
      final r = insertFence(text, const TextSelection.collapsed(offset: 4));
      expect(r.text, '段落\n\n```\n在此输入代码\n```');
    });
  });

  // -------------------------------------------------------------------------
  // insertLink
  // -------------------------------------------------------------------------
  group('insertLink', () {
    test('无选区：插入默认链接并选中 URL', () {
      const text = '';
      final r = insertLink(text, const TextSelection.collapsed(offset: 0));
      expect(r.text, '[链接文字](https://)');
      expect(r.selection.start, '[链接文字]('.length);
      expect(r.selection.end, '[链接文字]('.length + 'https://'.length);
    });

    test('有选区：选区作为链接文案', () {
      const text = '官网';
      final r = insertLink(
          text, const TextSelection(baseOffset: 0, extentOffset: 2));
      expect(r.text, '[官网](https://)');
      expect(r.selection.start, '[官网]('.length);
    });

    test('选区是 URL：作为 URL 插入', () {
      const text = 'https://aimindtree.dev';
      final r = insertLink(
          text, const TextSelection(baseOffset: 0, extentOffset: 22));
      expect(r.text, '[链接文字](https://aimindtree.dev)');
    });

    test('反向选区与正向选区结果一致', () {
      const text = '官网';
      final forward = insertLink(
          text, const TextSelection(baseOffset: 0, extentOffset: 2));
      final backward = insertLink(
          text, const TextSelection(baseOffset: 2, extentOffset: 0));
      expect(backward.text, forward.text);
      expect(backward.text, '[官网](https://)');
    });
  });

  // -------------------------------------------------------------------------
  // insertTable
  // -------------------------------------------------------------------------
  group('insertTable', () {
    test('无选区：插入 2×2 占位表并选中「列1」', () {
      const text = '';
      final r = insertTable(text, const TextSelection.collapsed(offset: 0));
      expect(r.text, '| 列1 | 列2 |\n| --- | --- |\n| 内容1 | 内容2 |');
      expect(r.selection.start, 2);
      expect(r.selection.end, 4);
      expect(r.text.substring(r.selection.start, r.selection.end), '列1');
    });

    test('有内容：前后补空行隔离', () {
      const text = '上文\n';
      final r = insertTable(text, const TextSelection.collapsed(offset: 3));
      expect(r.text, '上文\n\n| 列1 | 列2 |\n| --- | --- |\n| 内容1 | 内容2 |');
    });

    test('文末：表格后不带多余换行', () {
      const text = '正文';
      final r = insertTable(text, const TextSelection.collapsed(offset: 2));
      expect(r.text, '正文\n\n| 列1 | 列2 |\n| --- | --- |\n| 内容1 | 内容2 |');
      expect(r.text.endsWith('|'), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // insertImage
  // -------------------------------------------------------------------------
  group('insertImage', () {
    test('默认走 aimindtree-asset:// 协议', () {
      const text = '';
      final r = insertImage(
          text, const TextSelection.collapsed(offset: 0), 'asset-1', '架构图');
      expect(r.text, '![架构图](aimindtree-asset://asset-1)');
      expect(r.selection.isCollapsed, isTrue);
      expect(r.selection.baseOffset, r.text.length);
    });

    test('alt 为空时使用默认替代文本', () {
      final r = insertImage(
          '', const TextSelection.collapsed(offset: 0), 'asset-2', '');
      expect(r.text, '![图片](aimindtree-asset://asset-2)');
    });

    test('assetId 已带协议前缀时不重复拼接', () {
      final r = insertImage(
        '',
        const TextSelection.collapsed(offset: 0),
        'aimindtree-asset://asset-3',
        '图',
      );
      expect(r.text, '![图](aimindtree-asset://asset-3)');
    });

    test('插入位置在正文中：替换选区并保持换行隔离', () {
      const text = '前\n后';
      final r = insertImage(
          text, const TextSelection.collapsed(offset: 2), 'a1', 'x');
      expect(r.text, '前\n\n![x](aimindtree-asset://a1)\n\n后');
    });
  });

  // -------------------------------------------------------------------------
  // insertDivider
  // -------------------------------------------------------------------------
  group('insertDivider', () {
    test('分隔符独占一行，光标落到下一行行首', () {
      const text = '上\n下';
      final r = insertDivider(text, const TextSelection.collapsed(offset: 2));
      expect(r.text, '上\n\n---\n\n下');
      expect(r.selection.isCollapsed, isTrue);
      expect(r.selection.baseOffset, '上\n\n---\n'.length);
    });

    test('文首插入不产生前导空行', () {
      const text = '下';
      final r = insertDivider(text, const TextSelection.collapsed(offset: 0));
      expect(r.text, '---\n\n下');
    });

    test('文末插入后仍有一个换行方便续写', () {
      const text = '上';
      final r = insertDivider(text, const TextSelection.collapsed(offset: 1));
      expect(r.text, '上\n\n---\n');
      expect(r.selection.baseOffset, r.text.length);
    });
  });

  // -------------------------------------------------------------------------
  // wrapInline —— 删除线（~~）
  // -------------------------------------------------------------------------
  group('wrapInline（删除线 ~~）', () {
    test('无选区：插入占位并选中占位文案「删除线」', () {
      final r = wrapInline('', const TextSelection.collapsed(offset: 0), '~~');
      expect(r.text, '~~删除线~~');
      expect(r.selection.start, 2);
      expect(r.selection.end, 5); // 「删除线」3 字
    });

    test('再点一次：选中带 marker 的文本 → 取消标记', () {
      const text = '~~删除线~~';
      final r = wrapInline(text, const TextSelection(baseOffset: 0, extentOffset: 7), '~~');
      expect(r.text, '删除线');
      expect(r.selection.start, 0);
      expect(r.selection.end, 3);
    });
  });

  // -------------------------------------------------------------------------
  // toggleLinePrefix —— 任务列表（- [ ] 待办）
  // -------------------------------------------------------------------------
  group('toggleLinePrefix（任务列表 - [ ] ）', () {
    test('单行无前缀：加上任务列表', () {
      const text = '待办';
      final r = toggleLinePrefix(
          text, const TextSelection.collapsed(offset: 2), '- [ ] ');
      expect(r.text, '- [ ] 待办');
    });

    test('已是普通无序列表：点任务列表升级为 `- [ ]`', () {
      const text = '- 项';
      final r = toggleLinePrefix(
          text, const TextSelection.collapsed(offset: 3), '- [ ] ');
      expect(r.text, '- [ ] 项');
    });

    test('已是任务列表：再点一次取消', () {
      const text = '- [ ] 项';
      final r = toggleLinePrefix(
          text, const TextSelection.collapsed(offset: 7), '- [ ] ');
      expect(r.text, '项');
    });

    test('多行选区：逐行加任务列表', () {
      const text = '甲\n乙';
      final r = toggleLinePrefix(
        text,
        const TextSelection(baseOffset: 0, extentOffset: 3),
        '- [ ] ',
      );
      expect(r.text, '- [ ] 甲\n- [ ] 乙');
    });
  });

  // -------------------------------------------------------------------------
  // extractHeadings（目录 / 大纲抽取）
  // -------------------------------------------------------------------------
  group('extractHeadings', () {
    test('各级标题都识别，offset 指向行首', () {
      const text = '# 标题\n## 副标题';
      final hs = extractHeadings(text);
      expect(hs, hasLength(2));
      expect(hs[0].level, 1);
      expect(hs[0].title, '标题');
      expect(hs[0].offset, 0);
      expect(hs[1].level, 2);
      expect(hs[1].title, '副标题');
      expect(hs[1].offset, '# 标题'.length + 1); // 第一行长度 + 换行
    });

    test('H1~H6 级别正确', () {
      const text = '# a\n## b\n### c\n#### d\n##### e\n###### f';
      final hs = extractHeadings(text);
      expect(hs.map((h) => h.level).toList(), <int>[1, 2, 3, 4, 5, 6]);
      expect(hs.map((h) => h.title).toList(),
          <String>['a', 'b', 'c', 'd', 'e', 'f']);
    });

    test('围栏代码块（```）内的井号不算标题', () {
      const text = '# 真标题\n```\n# 假标题\n```\n# 又真';
      final hs = extractHeadings(text);
      expect(hs, hasLength(2));
      expect(hs[0].title, '真标题');
      expect(hs[1].title, '又真');
      // 第二个真标题在第二段 ``` 之后，offset 应跳过整段代码块。
      expect(hs[1].offset,
          '# 真标题\n'.length + '```\n# 假标题\n```\n'.length);
    });

    test('行内的井号（非行首）不识别', () {
      const text = '正文里有 # 不是标题';
      expect(extractHeadings(text), isEmpty);
    });

    test('井号后无空白（#no）不识别', () {
      const text = '#no space';
      expect(extractHeadings(text), isEmpty);
    });

    test('空正文返回空列表', () {
      expect(extractHeadings(''), isEmpty);
      expect(extractHeadings('   只有空白   '), isEmpty);
    });
  });
}
