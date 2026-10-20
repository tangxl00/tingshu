# 听书 iOS（v1.3.3 · com.tingyou.app.ios）

iOS 原生 SwiftUI 移植版，与安卓 v1.3.3（com.tingyou.app）功能对齐。沙箱内仅完成源码编写，编译与测试由 GitHub Actions macOS runner 执行。

## 1. 关键信息

- **Bundle ID**：`com.tingyou.app.ios`
- **CFBundleShortVersionString**：`1.3.3`
- **CFBundleVersion**：`20`（与安卓 versionCode 对齐）
- **最低系统**：iOS 17.0（SwiftData 依赖）
- **签名状态**：**未签名**——本仓库与 CI 产物均不签名，需用户自行用爱思助手 / AltStore / Sideloadly 免费自签安装（7 天需重签）
- **ATS**：全禁明文 HTTP（`NSAllowsArbitraryLoads = false`）
- **后台播放**：`UIBackgroundModes = audio`
- **证书 pinning**：27 张锚点证书通过 URLSession delegate 强制校验（不依赖系统信任库）+ 域名后缀白名单 fail-closed（见 §6）

## 2. 目录结构

```
ios/TingYou/
├── project.yml                     # xcodegen 配置（CI 中生成 .xcodeproj；info.properties 显式声明 plist 全部关键键，防 xcodegen 重写丢键）
├── README.md
├── .github/workflows/ios.yml       # GitHub Actions macOS 构建/测试/archive/打包 + plist 关键键验证
├── .gitignore
├── TingYou/                        # 主应用源码
│   ├── Info.plist
│   ├── App/                        # 入口、依赖容器（AppContainer 统一持有 SourceRouter / KeychainTokenStore / PlaybackManager）
│   ├── Models/                     # 领域模型（Album / Chapter / Filters）
│   ├── Data/                       # SwiftData 实体 + DataStore（UserDefaults/Keychain）
│   ├── Network/                    # APIClient（502/503/504 重试）+ 27张锚点证书 pinning + 域名白名单 + TingYou API DTO
│   ├── Playback/                   # AVPlayer + 锁屏控制 + 睡眠定时 + 跳过设置 + AVAssetResourceLoaderDelegate 直链解析
│   ├── Services/                   # SourceRegistry / SourceRouter / PlaybackRepository / MsrcHtml / MsrcAdapter / YtysxsAdapter / MekuiAdapter / KeychainTokenStore / 导入组织器
│   ├── UI/                         # SwiftUI 视图（含 YtysxsVerifyWebView 反爬人工验证容器）
│   ├── Utils/                      # 工具（分页 / 诊断日志 / 扩展）
│   └── Resources/Certs/            # 27 张 .pem 锚点证书
└── TingYouTests/                   # XCTest（136 条测试函数，17 个测试类，见 §8）
```

## 3. 本地构建

### 依赖
- macOS 13+（推荐 14+）
- Xcode 15.4+（Xcode 15.0/15.1 也可，但 macOS-14 runner 用 15.4）
- [xcodegen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`

### 编译运行

```bash
cd ios/TingYou
xcodegen generate               # 生成 TingYou.xcodeproj（会按 project.yml 的 info.properties 重写 Info.plist）
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
4. `xcodebuild test` 跑 XCTest（91 条）
5. `xcodebuild archive` 产出未签名 `.xcarchive`
6. **`plutil` 验证 archive 产物 Info.plist**：`UIBackgroundModes` 必含 `audio`、`NSAppTransportSecurity.NSAllowsArbitraryLoads` 必须为 `false`，缺失即 CI 失败（防 plist 漂移回归）
7. 把 `TingYou.app` 打包为 zip，作为 artifact 上传

## 5. 自签安装（iPhone 用户）

> iOS 16+ 系统已开放第三方应用商店通道，但 7 天签名仍存在；本节步骤以爱思助手为例，AltStore / Sideloadly 流程类似。

### 准备
- iPhone（iOS 16+）
- USB 数据线
- 电脑（Windows / macOS）
- 爱思助手（[i4.cn](https://www.i4.cn)）最新版

### 步骤

1. **下载未签名 .app**
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

## 6. 证书 pinning 与域名白名单

iOS 没有 Android network-security-config 等价物，本项目通过 `URLSession` 的 `urlSession(_:didReceive:completionHandler:)` 实现证书 pinning。锚点证书打包在 `TingYou/Resources/Certs/*.pem`，运行时由 `PinningURLSessionDelegate` 加载到 `[SecCertificate]` 数组，并对所有出站请求调用 `SecTrustEvaluateWithError`。

在此之上叠加**域名白名单 fail-closed**（对等安卓 `includeSubdomains` 语义，`PinnedDomainAllowlist`）：

- **后缀域**（匹配自身与任意子域）：`tingyou.fm`、`tingyou8.vip`、`guoguo.org.cn`、`kuwo.cn`、`ctyun.cn`
- **精确域**（仅匹配自身）：`file.hgeuz.cn`、`m.ting15.com`、`www.ting08.com`、`www.ytysxs.com`、`mp3.ytysxs.top`、`m.mekui.com`、`api.mekui.com`、`api.aikeu.com`、`mp3.aikeu.com`、`shuyinfm.oss-cn-hangzhou.aliyuncs.com`、`imge.kugou.com`

白名单之外的 host 直接取消连接（`cancelAuthenticationChallenge`），大小写不敏感；后缀匹配要求域名边界（`eviltingyou.fm` 不匹配 `.tingyou.fm`）。清单与安卓 `network_security_config.xml` 一一对齐，并由 `RetryAndPinningTests` 中 5 条白名单测试锁定。

锚点对应所有已知出站域的完整链（中间级 + 根级），覆盖：
- tingyou.fm / tingyou8.vip（听友FM）
- m.ting15.com / www.ting08.com（听十五 / 听吧）
- 悦听有声书（ytysxs.com / mp3.ytysxs.top）
- 书音FM（mekui.com / aikeu.com / ctyun.cn / kuwo.cn 等）
- guoguo.org.cn 音频直链后缀
- aliyuncs.com（OSS 封面）

## 7. 功能对照（与安卓 v1.3.3）

| # | 功能 | 状态 | 说明 |
|---|------|------|------|
| a | 书架（含菜单） | ✅ | SwiftUI `ShelfScreen`，收藏/历史/导入分 Tab |
| b | 发现页 | ✅ | `DiscoverScreen`，分类/排行/筛选；复用容器内 `APIClient`（`DiscoverViewModel.attach` 幂等注入） |
| c | 我的页 | ✅ | `MineScreen`，含音源管理入口、听书时长统计、设置 |
| d | 播放器 | ✅ | `AVPlayer` + `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`，后台/锁屏控制/倍速/进度/睡眠定时/片头片尾跳过；播放直链经 `AVAssetResourceLoaderDelegate` 接管 `tingyou-chapter://` 占位 URI 惰性解析（`PlaybackRepository` 按源路由真实地址），不再把占位 URI 直接喂给 `AVPlayerItem` |
| e | 多音源 | ✅ | 搜索/详情/章节/播放四链路全部真实路由：tingyou（JSON API）、ting15 / ting08（`MsrcAdapter`：HTML 解析 + 两步 token，付费 -1 打标、频控 -2 退避 [3s, 8s]）、悦听（`YtysxsAdapter`：WordPress + AudioIgniter，直链白名单自检）、书音FM（`MekuiAdapter`：ecmsapi + wapseries MD5 签名，黄金值测试锁定）；`AlbumScreen` 章节列表按 `album.source` 路由加载并支持点击播放 |
| f | 悦听反爬 | ✅ | `YtysxsVerifyWebView`（WKWebView 容器）人工验证流程完整落地：命中反爬特征抛 `AntibotException` → 弹验证页 → `httpCookieStore` 捕获 `be_captcha_token` → `KeychainTokenStore`（kSecClassGenericPassword，SecItemAdd/CopyMatching/Delete）持久化 24h → 验证完成自动重试原搜索；后续请求自动携带 Cookie。不自动破解验证码 |
| g | 502/503/504 重试 | ✅ | `APIClient.execute` 统一重试入口：Msrc 1 次 / 1.5s（与安卓 MsrcHttp 一致）、Mekui 2 次 / [2.5s, 8s]（与安卓 MekuiHttp 一致）；非 200 且不可重试直接失败。端到端行为由 stub URLProtocol 测试锁定 |
| h | 导入功能 | ✅ | m3u / 直链 / 本地文件路径，https-only 校验，自然排序，书名建议 |
| i | 音源开关持久化 | ✅ | `SourceManageScreen` 开关写入 `SourceEnabledStore`（UserDefaults `source_enabled_` 前缀），重启后保持 |

## 8. 测试对账

- **安卓基线**：276 条 `@Test`（43 个测试类）
- **iOS 现有**：**136 条测试函数，17 个测试类**（与 `TingYouTests/*.swift` 内 `func test` 计数一致，可 grep 核对）：
  - `CoverImageCacheTests`：9 条（build 19：封面会话挂 PinningURLSessionDelegate 断言 / 封面图源域名白名单互检 / 非白名单 host fail-closed·取图拒 nil / 防盗链 Referer 设置与省略 / 请求 URL 保全；build 20 必修 1：同一 guoguo URL 按 ting15/ting08 源各带准确 referer）
  - `DiscoverCacheTests`：5 条（build 18：发现页预加载缓存命中 / 磁盘缓存失效 / 预取调度；build 20 必修 6：中间态等待改 expectation）
  - `DtoMappingTests`：8 条（snake_case JSON → DTO → 领域模型）
  - `HistoryAndFavoriteTests`：6 条（build 18：历史 upsert / 收藏增删查幂等；build 19：P1-1 同源收藏两本书均落库 / P1-2 乱序写历史最终为新章节且写入串行）
  - `HistoryResumeTests`：6 条（build 20 必修 2：恢复播放重建完整队列·定位 index/chapterId/标题/夹取 / 拉取失败与空列表降级单章 / locate 纯函数匹配优先级）
  - `ImportOrganizerTests`：14 条（自然排序 / 章节标题 / 书名建议 / 直链 / m3u 解析）
  - `ImportServiceTests`：3 条（build 20 必修 3：两本导入书均落库且 id 递增互异 / 章节挂正确 bookId / 空链接建书 0 章）
  - `KeychainTokenStoreTests`：9 条（token 过期边界纯函数 / Keychain 存取闭环 / 过期自清理 / Cookie 头格式 / 24h 默认 Max-Age）
  - `MekuiAdapterTests`：8 条（wapseries MD5 签名黄金值 ×2 / 详情解析黄金样本 / 付费打标 / 缺章节降级）
  - `MsrcHtmlTests`：17 条（ting15 / ting08 搜索解析黄金样本 / 详情解析 / 两步 token 播放页 meta / 播放响应 BOM·status 双形态·-1 付费·-2 频控 / encodeUriComponent %20 语义与 ASCII 白名单）
  - `PlayUriTests`：5 条（占位 URI 构建 / 解析 / 旧 URI 兼容 / 非 ASCII URL 归一化）
  - `RetryAndPinningTests`：18 条（可重试状态码判定 / 安卓基线重试参数 / stub URLProtocol 端到端重试 3 条 / 域名白名单后缀·精确·大小写·fail-closed 5 条；build 20 必修 5：传输层错误重试退避阶梯 / 重试前必须等待 / 首发成功零延迟）
  - `ShelfMappingTests`：3 条（build 18：书架领域模型 → SwiftData 实体映射）
  - `SleepTimerTests`：5 条（build 20 必修 4：定点睡眠目标时刻今天/顺延明天/恰好等于/午夜边界 / applySleepTimer 接线）
  - `SourceRegistryTests`：6 条（源注册表 / fetch·img·audio 白名单互检）
  - `ThemeStoreTests`：4 条（build 18：外观主题持久化与跟随系统）
  - `YtysxsAdapterTests`：10 条（反爬特征全关键词 / 搜索·详情·曲目解析黄金样本 / 直链白名单自检）

- **未移植**（典型原因）：
  - UI 布局测试（`ShelfLayoutTest`、`PlayerLayoutSpecTest` 等）—— iOS 用 SwiftUI，UI 测试需用 XCUITest 重建，属另一类工程；
  - Media3 / ExoPlayer 集成测试（`PlayerNotificationTest` 等）—— iOS 走 AVPlayer，平台 API 完全不同；
  - Room 迁移测试（`MigrationV1V2Test` 等）—— iOS 走 SwiftData，无版本迁移基线；
  - Android `network_security_config` 的 DOM/锚点对账测试（`CertAnchorTest`、`MsrcCertAnchorTest`）—— iOS 走 `URLSession` delegate + `SecTrust`，验证模型不同；本项目以 `PinningURLSessionDelegate` 加载 27 张 PEM 实现等价功能，域名清单由 `RetryAndPinningTests` 锁定，证书清单与 `network_security_config.xml` 的一致性由人工复核；
  - NetDiag / TlsDiag 端到端测试（`NetDiagTest`、`TlsDiagTest`）——依赖 Android TLS 栈与设备 API，iOS 无对应；运行时仍保留诊断日志（`DiagLog.swift`）。

- **测试执行口径**：以上 91 条测试全部在 CI（macOS runner）的 `xcodebuild test` 步骤执行；**不包含**对真实音源站点的网络调用（全部为离线纯函数 / stub 注入），真实站点连通性与反爬时效属运行时人工验收范围，不在自动化测试承诺内。

## 9. 已知缺口与风险

1. **未签名**：所有产物无 Apple Developer 签名，每 7 天需用户自签重装。
2. **音频缓存**：安卓版用 ExoPlayer `CacheDataSource` 实现磁盘预缓存，iOS 暂未实现磁盘缓存（`AVPlayerItem` 每次重新下载）。
3. **听书时长统计**：已实现基础累加，缺少与安卓一致的"日活/周活"维度。
4. **重试范围**：仅 502/503/504 状态码重试（Msrc/Mekui 各自基线），连接超时等传输层错误不重试（与安卓一致）。
5. **悦听反爬依赖人工验证**：验证码由用户在 WKWebView 内人工完成（设计如此，不自动破解）；站点验证页结构变化时需更新 `YtysxsVerifyWebView` 的捕获逻辑。
6. **SwiftData 迁移**：当前未声明版本化 `VersionedSchema`，后续需要按安卓 v1→v4 的迁移路径补全。
7. **多源付费内容**：ting15/ting08/-1、mekui ispass/积分等付费章节一律拦截并打标（`PaidChapterRegistry`），不做任何绕过。

## 10. 许可证

本项目仅作安卓 v1.3.3 的功能等价移植，源码供学习/个人使用。音源站点的版权与合法性由用户自行评估。
