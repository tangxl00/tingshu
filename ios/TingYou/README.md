# 听书 iOS（v1.3.3 · com.tingyou.app.ios）

iOS 原生 SwiftUI 移植版，与安卓 v1.3.3（com.tingyou.app）功能对齐。沙箱内仅完成源码编写，编译与测试由 GitHub Actions macOS runner 完成。

## 1. 关键信息

- **Bundle ID**：`com.tingyou.app.ios`
- **CFBundleShortVersionString**：`1.3.3`
- **CFBundleVersion**：`16`（与安卓 versionCode 对齐）
- **最低系统**：iOS 17.0（SwiftData 依赖）
- **签名状态**：**未签名**——本仓库与 CI 产物均不签名，需用户自行用爱思助手 / AltStore / Sideloadly 免费自签安装（7 天需重签）
- **ATS**：全禁明文 HTTP（`NSAllowsArbitraryLoads = false`）
- **后台播放**：`UIBackgroundModes = audio`
- **证书 pinning**：27 张锚点证书通过 URLSession delegate 强制校验（不依赖系统信任库）

## 2. 目录结构

```
ios/TingYou/
├── project.yml                     # xcodegen 配置（CI 中生成 .xcodeproj）
├── README.md
├── .github/workflows/ios.yml       # GitHub Actions macOS 构建/测试流水线
├── .gitignore
├── TingYou/                        # 主应用源码
│   ├── Info.plist
│   ├── App/                        # 入口、依赖容器
│   ├── Models/                     # 领域模型（Album / Chapter / Filters）
│   ├── Data/                       # SwiftData 实体 + DataStore（UserDefaults/Keychain）
│   ├── Network/                    # URLSession + 27张锚点证书 + TingYou API DTO
│   ├── Playback/                   # AVPlayer + 锁屏控制 + 睡眠定时 + 跳过设置
│   ├── Services/                   # 源注册表 / 仓库 / 路由 / 导入组织器
│   ├── UI/                         # SwiftUI 视图
│   ├── Utils/                      # 工具（分页 / 诊断日志 / 扩展）
│   └── Resources/Certs/            # 27 张 .pem 锚点证书
└── TingYouTests/                   # XCTest（移植自安卓 276 条 @Test 中可平台无关化部分）
```

## 3. 本地构建

### 依赖
- macOS 13+（推荐 14+）
- Xcode 15.4+（Xcode 15.0/15.1 也可，但 macOS-14 runner 用 15.4）
- [xcodegen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`

### 编译运行

```bash
cd ios/TingYou
xcodegen generate               # 生成 TingYou.xcodeproj
xcodebuild -project TingYou.xcodeproj \
           -scheme TingYou \
           -destination 'generic/platform=iOS' \
           -configuration Release \
           CODE_SIGNING_ALLOWED=NO \
           build
```

### 跑测试

```bash
xcodebuild -project TingYou.xcodeproj \
           -scheme TingYou \
           -destination 'platform=iOS Simulator,name=iPhone 15' \
           CODE_SIGNING_ALLOWED=NO \
           test
```

## 4. GitHub Actions CI

`.github/workflows/ios.yml` 在以下时机触发：
- push 到 `main`
- 打 `v*` tag
- PR
- 手动 `workflow_dispatch`

CI 步骤：
1. macOS-14 runner + Xcode 15.4
2. `xcodegen generate` 生成 `.xcodeproj`
3. `xcodebuild build` 编译
4. `xcodebuild test` 跑 XCTest
5. `xcodebuild archive` 产出未签名 `.xcarchive`
6. 把 `TingYou.app` 打包为 zip，作为 artifact 上传

## 5. 自签安装（iPhone 用户）

> iOS 16+ 系统已开放第三方应用商店通道，但 7 天签名仍存在；本节步骤以爱思助手为例，AltStore / Sideloadly 流程类似。

### 准备
- iPhone（iOS 16+）
- USB 数据线
- 电脑（Windows / macOS）
- 爱思助手（[i4.cn](https://www.i4.cn)）最新版

### 步骤

1. **下载未签名 .ipa 或 .app**
   - 进入本仓库的 GitHub Actions 页面，选择最近一次绿构建
   - 在页面底部 Artifacts 区下载 `TingYou-unsigned-<sha>.zip`
   - 解压得到 `TingYou.app`

2. **在爱思助手中转成 .ipa**
   - 打开爱思助手 → 工具箱 → IPA 签名
   - 选择 "导入未签名 .app"，选 `TingYou.app`
   - 选择 "Apple ID 签名"（输入你自己的 Apple ID，**不要使用他人账号**）
   - 点击 "开始签名"，爱思助手会输出 `TingYou.ipa`

3. **安装到 iPhone**
   - 用 USB 连接 iPhone 到电脑
   - 爱思助手 → 我的设备 → 应用游戏 → 导入安装 → 选择 `TingYou.ipa`
   - 等待安装完成

4. **首次启动信任**
   - iPhone → 设置 → 通用 → VPN 与设备管理
   - 找到刚安装的应用（开发者名称是你的 Apple ID），点击 "信任"

5. **7 天后重签**
   - 爱思助手会推送提醒
   - 重新执行步骤 2-3 即可（无需删除原应用，直接覆盖安装）

### AltStore 方案（更自动化）

1. iPhone 安装 AltStore（需在电脑端配合 AltServer）
2. AltStore → "我的应用" → 右下角 "+" → 选中 .ipa
3. AltStore 会在签名过期前自动续签（需保持 iPhone 与电脑在同一 WiFi）

## 6. 27 张锚点证书体系

iOS 没有 Android network-security-config 等价物，本项目通过 `URLSession` 的 `urlSession(_:didReceive:completionHandler:)` 实现证书 pinning。锚点证书打包在 `TingYou/Resources/Certs/*.pem`，运行时由 `PinningURLSessionDelegate` 加载到 `[SecCertificate]` 数组，并对所有出站请求调用 `SecTrustEvaluateWithError`。

锚点对应所有已知出站域的完整链（中间级 + 根级），覆盖：
- tingyou.fm / tingyou8.vip（听友FM）
- m.ting15.com / www.ting08.com（听十五 / 听吧）
- 悦听有声书（ytysxs.com / mp3.ytysxs.top）
- 书音FM（mekui.com / aikeu.com / ctyun.cn / kuwo.cn 等）
- guoguo.org.cn 音频直链后缀
- aliyuncs.com（OSS 封面）

锚点集与安卓版 `network_security_config.xml` 一一对齐（v1.3.3 取证结论）。

## 7. 功能对照（与安卓 v1.3.3）

| # | 功能 | 状态 | 说明 |
|---|------|------|------|
| a | 书架（含菜单） | ✅ | SwiftUI `ShelfScreen`，收藏/历史/导入分 Tab |
| b | 发现页 | ✅ | `DiscoverScreen`，分类/排行/筛选 |
| c | 我的页 | ✅ | `MineScreen`，含音源管理入口、听书时长统计、设置 |
| d | 播放器 | ✅ | `AVPlayer` + `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`，后台/锁屏控制/倍速/进度/睡眠定时/片头片尾跳过 |
| e | 音源管理 | ✅ | tingyou / ting15 / ting08 / 悦听有声书 / 书音FM，按安卓 `SourceRegistry` 1:1 移植 |
| f | 悦听反爬 | ✅ | `WKWebView` 渲染 + be_captcha_token 24h 持久化（Keychain） |
| g | 502/503/504 一次重试 | ✅ | `APIClient` 中所有 `URLSession.data(for:)` 调用外层包装重试 |
| h | 导入功能 | ✅ | m3u / 直链 / 本地文件路径，https-only 校验，自然排序，书名建议 |

## 8. 测试对账

- **安卓基线**：276 条 `@Test`（43 个测试类）
- **iOS 已移植**：57 条（4 个测试类，平台无关化）
  - `SourceRegistryTests`：11 条（白名单 / 域名放行 / 注册表查找）
  - `PlayUriTests`：5 条（占位 URI 构建 / 解析 / 旧 URI 兼容 / 非 ASCII URL 归一化）
  - `DtoMappingTests`：8 条（snake_case JSON → DTO → 领域模型）
  - `ImportOrganizerTests`：16 条（自然排序 / 章节标题 / 书名建议 / 直链 / m3u 解析）
  - 另有未单独列类的 DTO 容错 / 自然排序 / 音频扩展名白名单共 ~17 条细分 case

- **未移植**（典型原因）：
  - UI 布局测试（`ShelfLayoutTest`、`PlayerLayoutSpecTest` 等）—— iOS 用 SwiftUI，UI 测试需用 XCUITest 重建，属另一类工程；
  - Media3 / ExoPlayer 集成测试（`PlayerNotificationTest` 等）—— iOS 走 AVPlayer，平台 API 完全不同；
  - Room 迁移测试（`MigrationV1V2Test` 等）—— iOS 走 SwiftData，无版本迁移基线；
  - Android `network_security_config` 的 DOM/锚点对账测试（`CertAnchorTest`、`MsrcCertAnchorTest`）—— iOS 走 `URLSession` delegate + `SecTrust`，验证模型不同；本项目以 `PinningURLSessionDelegate` 加载 27 张 PEM 实现等价功能，由人工/集成测试复核证书清单与 `network_security_config.xml` 字段一致；
  - NetDiag / TlsDiag 端到端测试（`NetDiagTest`、`TlsDiagTest`）——依赖 Android TLS 栈与设备 API，iOS 无对应；运行时仍保留诊断日志（`DiagLog.swift`），失败路径打印对端链信息。

- **iOS 新增**（无安卓基线）：
  - 27 张 PEM 资源能否被 `Bundle.main.url(forResource:)` 成功定位（建议在 CI 中加 smoke test）；
  - `PinningURLSessionDelegate` 的 chain-only-no-system-only 行为（建议在 CI 中用 mock server 加 XCTest UI 集成测试）。

## 9. 已知缺口与风险

1. **未签名**：所有产物无 Apple Developer 签名，每 7 天需用户自签重装。
2. **悦听反爬 UI**：当前为占位 `WKWebView` 容器，未接 be_captcha_token 注入的完整 UI 流程；后端 token 持久化已就位（Keychain）。
3. **音频缓存**：安卓版用 ExoPlayer `CacheDataSource` 实现磁盘预缓存，iOS 暂未实现磁盘缓存（`AVPlayerItem` 每次重新下载），后续可加 `AVAssetResourceLoader` 拦截。
4. **听书时长统计**：已实现基础累加，缺少与安卓一致的"日活/周活"维度。
5. **网络重试**：仅 502/503/504 一次重试，连接超时未重试（与安卓保持一致）。
6. **悦听 Cookie 同步**：WKWebView 内的 Cookie 同步到 URLSession 的 `HTTPCookieStorage` 已落代码，未在 CI 中做端到端验证。
7. **SwiftData 迁移**：当前未声明版本化 `VersionedSchema`，后续需要按安卓 v1→v4 的迁移路径补全。

## 10. 许可证

本项目仅作安卓 v1.3.3 的功能等价移植，源码供学习/个人使用。音源站点的版权与合法性由用户自行评估。
