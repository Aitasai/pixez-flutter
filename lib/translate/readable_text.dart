// 把含 Pixiv 特殊标记的小说正文转成供导出/阅读的自然语言文本。
// 原 _export 导出 novelTextResponse.text，里面有 [newpage] [pixivimage:1] 等
// 裸标记，可读性差。译文同样使用这套转换，保证导出文本一致可读。

String toReadableText(String raw) {
  var s = raw;
  s = s.replaceAll(RegExp(r'\[newpage\]', dotAll: true), '\n\n——————\n\n');
  s = s.replaceAllMapped(
    RegExp(r'\[chapter:([^\]]*)\]', dotAll: true),
    (m) => '\n\n《${m[1]}》\n\n',
  );
  s = s.replaceAll(RegExp(r'\[pixivimage:[^\]]*\]', dotAll: true), '〔嵌入插画〕');
  s = s.replaceAll(RegExp(r'\[uploadedimage:[^\]]*\]', dotAll: true), '〔上传图片〕');
  s = s.replaceAll(RegExp(r'\[\[jumpuri:.*?\]\]', dotAll: true), '〔链接〕');
  s = s.replaceAllMapped(
    RegExp(r'\[\[rb:([^>]*)>([^\]]*)\]\]', dotAll: true),
    (m) => '${m[1]}(${m[2]})',
  );
  // 折叠过剩空行。
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return s.trim();
}