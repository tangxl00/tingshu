/// 音源注册表：与 iOS SourceRegistry / DiscoverCatalog / BiliCategories 对齐。

class SourceRegistry {
  static const String tingyou = 'tingyou';
  static const String bili = 'bili';
  static const String importSource = 'import';
  /// v2.0.2：悦听有声书（ytysxs.com）重新接入——独立适配器 + 本地索引。
  static const String ytysxs = 'ytysxs';

  static const List<String> searchSources = [tingyou, bili, ytysxs];

  static String displayName(String src) {
    switch (src) {
      case tingyou:
        return '听友FM';
      case bili:
        return 'B站';
      case ytysxs:
        return '悦听';
      case importSource:
        return '导入';
      default:
        return src;
    }
  }
}

class DiscoverCategory {
  final String id;
  final String name;
  final String? keyword;
  final String? order;

  const DiscoverCategory(this.id, this.name, {this.keyword, this.order});
}

class DiscoverCatalog {
  static const Map<String, List<DiscoverCategory>> _categories = {
    SourceRegistry.tingyou: [
      DiscoverCategory('recommend', '推荐'),
      DiscoverCategory('new', '最新'),
      DiscoverCategory('hot', '热门'),
      DiscoverCategory('serial', '连载'),
      DiscoverCategory('story', '评书'),
    ],
    SourceRegistry.bili: [
      DiscoverCategory('hot', '热门推荐', keyword: '有声小说', order: 'click'),
      DiscoverCategory('radio', '广播剧', keyword: '广播剧', order: 'totalrank'),
      DiscoverCategory('pingshu', '评书相声', keyword: '评书', order: 'totalrank'),
      DiscoverCategory('mystery', '悬疑推理', keyword: '悬疑推理有声小说', order: 'totalrank'),
      DiscoverCategory('xuanhuan', '玄幻仙侠', keyword: '玄幻仙侠有声小说', order: 'totalrank'),
      DiscoverCategory('classic', '名著悦读', keyword: '名著有声书', order: 'totalrank'),
    ],
    // v2.0.2 · 悦听站点原始分类（数据走本地索引，零网络）
    SourceRegistry.ytysxs: [
      DiscoverCategory('yanqing', '言情'),
      DiscoverCategory('xianxia', '仙侠'),
      DiscoverCategory('xuanhuan', '玄幻'),
      DiscoverCategory('lishi', '历史'),
      DiscoverCategory('dushi', '都市'),
      DiscoverCategory('qihuan', '奇幻'),
      DiscoverCategory('wuxia', '武侠'),
      DiscoverCategory('kehuan', '科幻'),
      DiscoverCategory('junshi', '军事'),
      DiscoverCategory('kbly', '恐怖灵异'),
    ],
  };

  static List<DiscoverCategory> categories(String source) {
    return _categories[source] ?? const [];
  }

  static DiscoverCategory? find(String source, String id) {
    for (final c in categories(source)) {
      if (c.id == id) return c;
    }
    return null;
  }
}

/// iOS ChapterTitleFormatting.hasOwnIndex 的对等实现。
bool chapterTitleHasOwnIndex(String title) {
  final t = title.trim();
  if (t.isEmpty) return false;
  final patterns = <RegExp>[
    RegExp(r'^第\s*[0-9０-９一二三四五六七八九十百千零两]+\s*[集章节回部篇]'),
    RegExp(r'^\s*[Pp]\s*\d+\b'),
    RegExp(r'^\s*\d+\s*[\.、：:)]'),
    RegExp(r'^Episode\s*\d+', caseSensitive: false),
    RegExp(r'^Vol\.?\s*\d+', caseSensitive: false),
  ];
  return patterns.any((r) => r.hasMatch(t));
}
