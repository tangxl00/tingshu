/// B 站接口端点常量
class BiliEndpoints {
  BiliEndpoints._();

  static const String home = 'https://www.bilibili.com';
  static const String base = 'https://api.bilibili.com';
  static const String sSearch = 'https://s.search.bilibili.com';

  /// 网页搜索首页（搜索请求的合法来源 Referer/Origin）
  static const String searchHome = 'https://search.bilibili.com';

  /// 预热：拿 buvid 等基础 Cookie
  static const String warmup = '$home/';

  /// 获取 WBI img_key / sub_key 及登录态
  static const String nav = '$base/x/web-interface/nav';

  /// 通用搜索
  static const String searchType = '$base/x/web-interface/wbi/search/type';

  /// UP 主空间投稿列表（按 mid 拉取该 UP 的视频）
  static const String spaceArcSearch = '$base/x/space/wbi/arc/search';

  /// UP 主合集/系列列表（匿名可用的主要来源）
  static const String upCollections =
      '$base/x/polymer/web-space/seasons_series_list';

  /// 单个合集下的全部视频（分页）
  static const String upCollectionArchives =
      '$base/x/polymer/web-space/seasons_archives_list';

  /// 视频基本信息（含分P列表）
  static const String view = '$base/x/web-interface/view';

  /// 分P列表
  static const String pageList = '$base/x/player/pagelist';

  /// 取流
  static const String playUrl = '$base/x/player/wbi/playurl';

  /// buvid 激活（gaia 风控闭环：ExClimbWuzhi）
  static const String activateBuvid = '$base/x/internal/gaia-gateway/ExClimbWuzhi';

  /// 二维码登录：获取生成参数（登录相关接口在 passport 域，api 域会 404）
  static const String qrGenerate =
      'https://passport.bilibili.com/x/passport-login/web/qrcode/generate';

  /// 二维码登录：轮询结果
  static const String qrPoll =
      'https://passport.bilibili.com/x/passport-login/web/qrcode/poll';

  /// 原作品网页链接
  static String video(String bvid) => '$home/video/$bvid';

  /// UP 主主页链接
  static String space(int mid) => '$home/space/$mid';

  /// UP 主空间页（部分 polyer 接口要求这个 referer 才返回数据）
  static String spaceHome(int mid) => 'https://space.bilibili.com/$mid';

  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
}