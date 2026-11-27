/// UP 主（搜索结果条目）
class UpUser {
  final int mid;
  final String name;
  final String face;
  final String sign;
  final int fans;
  final int videos;

  const UpUser({
    required this.mid,
    required this.name,
    this.face = '',
    this.sign = '',
    this.fans = 0,
    this.videos = 0,
  });

  /// 搜索结果里的昵称带 <em class="keyword"> 高亮标签，需要剥掉
  static String _clean(String s) => s
      .replaceAll('<em class="keyword">', '')
      .replaceAll('</em>', '')
      .trim();

  factory UpUser.fromSearch(Map<String, dynamic> m) => UpUser(
        mid: int.tryParse('${m['mid'] ?? 0}') ?? 0,
        name: _clean(m['uname'] as String? ?? ''),
        face: _normalize(m['upic'] as String? ?? ''),
        sign: _clean(m['usign'] as String? ?? ''),
        fans: int.tryParse('${m['fans'] ?? 0}') ?? 0,
        videos: int.tryParse('${m['videos'] ?? 0}') ?? 0,
      );

  static String _normalize(String u) {
    final s = u.trim();
    if (s.isEmpty) return s;
    if (s.startsWith('//')) return 'https:$s';
    if (s.startsWith('http://')) return 'https://${s.substring(7)}';
    return s;
  }

  Map<String, dynamic> toJson() => {
        'mid': mid,
        'name': name,
        'face': face,
        'sign': sign,
        'fans': fans,
        'videos': videos,
      };

  factory UpUser.fromJson(Map<String, dynamic> m) => UpUser(
        mid: int.tryParse('${m['mid'] ?? 0}') ?? 0,
        name: m['name'] as String? ?? '',
        face: m['face'] as String? ?? '',
        sign: m['sign'] as String? ?? '',
        fans: int.tryParse('${m['fans'] ?? 0}') ?? 0,
        videos: int.tryParse('${m['videos'] ?? 0}') ?? 0,
      );
}