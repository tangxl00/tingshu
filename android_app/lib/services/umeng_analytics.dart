/// 本地版：无云端统计上报。
///
/// 听书 Android 版移除一切云端数据上报（友盟等）——所有事件/页面打点不注册
/// 任何第三方 SDK、不发起网络请求。公开 API 保持不变，避免改动各调用点。
class AppAnalytics {
  AppAnalytics._();

  static Future<void> init() async {}

  static void onEvent(String name, [Map<String, dynamic>? params]) {}

  static void onPageStart(String name) {}

  static void onPageEnd(String name) {}
}
