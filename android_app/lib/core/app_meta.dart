/// 应用元信息（版本号与 pubspec.yaml 保持一致）
///
/// ⚠️ 每次发版必须和 pubspec.yaml 的 version 一起改，否则「检查更新」会误判：
/// 这里是拿本地版本去和 GitHub Release 的 tag 比大小。
class AppMeta {
  AppMeta._();

  static const String name = '听书';
  static const String version = '2.0.2';

  /// 副标题 / 一句话介绍
  static const String tagline = '免登录、无广告、专注收听的 B 站有声小说播放器';

  /// 开源仓库
  static const String repoUrl = 'https://github.com/tangxl00/tingshu';

  /// 官网
  static const String siteUrl = 'https://github.com/tangxl00/tingshu';

  /// 开源协议
  static const String licenseUrl = '$repoUrl/blob/main/LICENSE';

  /// 问题反馈
  static const String issuesUrl = '$repoUrl/issues';
}