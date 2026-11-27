/// iOS ImportOrganizer 对等实现：自然排序、书名推断、章节标题清洗、https 门禁。

int naturalCompare(String a, String b) {
  final ai = a.codeUnits;
  final bi = b.codeUnits;
  var i = 0;
  var j = 0;
  while (i < ai.length && j < bi.length) {
    final ac = ai[i];
    final bc = bi[j];
    if (_isDigit(ac) && _isDigit(bc)) {
      var p = i;
      var q = j;
      while (p < ai.length && _isDigit(ai[p])) p++;
      while (q < bi.length && _isDigit(bi[q])) q++;
      final an = int.tryParse(a.substring(i, p)) ?? 0;
      final bn = int.tryParse(b.substring(j, q)) ?? 0;
      if (an != bn) return an.compareTo(bn);
      i = p;
      j = q;
      continue;
    }
    if (ac != bc) return ac.compareTo(bc);
    i++;
    j++;
  }
  return ai.length.compareTo(bi.length);
}

bool _isDigit(int c) => c >= 48 && c <= 57;

String chapterTitle(String name) {
  var s = name;
  final dot = s.lastIndexOf('.');
  if (dot > 0) s = s.substring(0, dot);
  s = s.replaceFirst(RegExp(r'^第\s*\d+\s*[集章节]\s*'), '');
  s = s.replaceFirst(RegExp(r'^\s*\d+\s*[\.、_\- ]\s*'), '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.isEmpty ? name : s;
}

String suggestBookTitle(List<String> names) {
  if (names.isEmpty) return '导入书籍';
  final first = chapterTitle(names.first);
  if (names.length == 1) return first;
  // 公共前缀（按字符），至少 2 个字才采用；否则用第一章标题。
  var prefix = first;
  for (final name in names.skip(1)) {
    final t = chapterTitle(name);
    var i = 0;
    while (i < prefix.length && i < t.length && prefix[i] == t[i]) i++;
    prefix = prefix.substring(0, i);
    if (prefix.isEmpty) break;
  }
  prefix = prefix.replaceAll(RegExp(r'[\s\-_第0-9]+$'), '').trim();
  if (prefix.length >= 2) return prefix;
  return first;
}

class ParseDirectLinksResult {
  final List<({String url, String? title})> links;
  final List<String> badLines;

  const ParseDirectLinksResult({
    required this.links,
    required this.badLines,
  });
}

ParseDirectLinksResult parseDirectLinks(String text) {
  final links = <({String url, String? title})>[];
  final bad = <String>[];
  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    // 支持「标题, url」「标题 url」与裸链接三种写法。
    var title = <String?>[null];
    var candidate = line;
    final comma = line.lastIndexOf(',');
    if (comma > 0) {
      title = [line.substring(0, comma).trim()];
      candidate = line.substring(comma + 1).trim();
    } else {
      final match = RegExp(r'^(.*?)\s+(https?://\S+)$').firstMatch(line);
      if (match != null) {
        title = [match.group(1)!.trim()];
        candidate = match.group(2)!;
      }
    }
    final uri = Uri.tryParse(candidate);
    if (uri == null || uri.scheme != 'https') {
      bad.add(line);
      continue;
    }
    links.add((url: candidate, title: title.first));
  }
  return ParseDirectLinksResult(links: links, badLines: bad);
}
