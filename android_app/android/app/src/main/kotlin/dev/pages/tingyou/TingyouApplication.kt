package dev.pages.tingyou

import io.flutter.app.FlutterApplication

/**
 * App Application：听书版为纯本地应用，无第三方统计 SDK 预初始化。
 * 保留 FlutterApplication 子类以维持 AndroidManifest 中的 android:name 引用。
 */
class TingyouApplication : FlutterApplication() {

    override fun onCreate() {
        super.onCreate()
    }
}
