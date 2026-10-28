# 听书 iOS（v1.3.3 · com.tingyou.app.ios）

iOS 原生 SwiftUI 移植版，与安卓 v1.3.3（com.tingyou.app）功能对齐。沙箱内仅完成源码编写，编译与测试由 GitHub Actions macOS runner 执行。

## 1. 关键信息

- **Bundle ID**：`com.tingyou.app.ios`
- **CFBundleShortVersionString**：`1.3.3`
- **CFBundleVersion**：`27`（与安卓 versionCode 对齐）
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
└── TingYouTests/                   # XCTest（212 条测试函数（23 个测试文件、31 个测试类），见 §8）
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
4. `xcodebuild test` 跑 XCTest（212 条）
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
| b | 发现页 | ✅ | `DiscoverScreen`；build 22：浏览固定主源听友FM（对齐安卓 LibraryScreen，移除音源切换菜单与 `discover_selected_source` 持久化），二级分类折叠默认收起（仅听友FM 分类）保留自 build 21；搜索框历史记忆（去重置顶上限 20）保留；复用容器内 `APIClient`（`DiscoverViewModel.attach` 幂等注入）；build 24：loadMore 失败置轻量反馈态（列表尾部「加载更多失败 + 重试」入口，不弹窗打断、不清空已加载列表，成功后自动清除）；磁盘缓存 init 一次性清理多源时代孤儿键文件（仅保留 `tingyou|` 前缀，防缓存目录膨胀）；build 27：搜索历史展示 + 提交即记录——空关键词显示「最近搜索」区块（条目点填即搜、单条删除、一键清空；SearchScreen 为不可达死代码，历史此前只写不读），提交搜索即记（非空即记，不依赖结果成败——被反爬拦截/全源失败的词同样落库）；搜索状态更新全路径 @MainActor |
| c | 我的页 | ✅ | `MineScreen`，含音源管理入口、听书时长统计、设置 |
| d | 播放器 | ✅ | `AVPlayer` + `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`，后台/锁屏控制/倍速/进度/睡眠定时/片头片尾跳过；播放直链经 `AVAssetResourceLoaderDelegate` 接管 `tingyou-chapter://` 占位 URI 惰性解析（`PlaybackRepository` 按源路由真实地址），不再把占位 URI 直接喂给 `AVPlayerItem`；build 21：定时/设置弹窗补挂（`.sheet` 复用 applySleepTimer 三模式 + 播放模式三档顺序/单曲循环/列表循环，chapterFinishedAction 纯函数决策）、分享改 SwiftUI 原生 `ShareLink`；build 22：倍速弹层 `SpeedSheet.select` 先写 Binding 再回调，修复选择后 `pm.speed` 不生效的死控件问题；build 23：弹窗呈现机制重构——同一视图链四个 `.sheet(isPresented:)` 合并为单枚举驱动的 `.sheet(item:)`（SwiftUI 已知限制：同视图多 sheet 只有最后挂载的可靠生效，build 22 真机表现为倍速/章节弹窗点不出），四个按钮 action 改 `activeSheet = .speed/.chapters/.sleepTimer/.settings`；build 25（对齐安卓 v1.3.0 item 8）：片头/片尾跳过——设置面板新增两行时长选择器（Slider 0–300 每 5 秒一档、0 显示「关闭」），按书（src+albumId）持久化；片头在起播位置应用（恢复播放保留上次进度不被覆盖）、片尾由 1s 进度观察检测剩余时长切下一章（与自动连播同入口，末章不越界）；速度按钮补 `.pressable` 按压反馈；build 26（倍速真机隔离设计）：弹窗内容闭包改为呈现时非可选捕获 pm（原 `pm?.xxx` 可选链在 pm 为 nil 时静默无操作，与真机「面板正常但选择无效」现象吻合，静态审查无法区分），pm 为 nil 时弹窗显示诊断视图直接定位；SpeedSheet 选择后延迟 0.6s 关闭并常驻显示「当前：Xx」——面板值变而主界面不变 = 视图刷新断裂，面板值也不变 = 写入未执行；build 27（倍速间歇性失效加固）：统一 applyRate() 速率重放入口——speed setter / play / 条目 readyToPlay / 音频会话中断结束（shouldResumeAfterInterruption 纯函数决策）全部重放当前 speed（暂停态 guard 不起播）；设置面板删除播放模式分区（仅保留片头/片尾跳过） |
| e | 多音源 | ✅ | 搜索/详情/章节/播放四链路全部真实路由：tingyou（JSON API）、ting15 / ting08（`MsrcAdapter`：HTML 解析 + 两步 token，付费 -1 打标、频控 -2 退避 [3s, 8s]）、悦听（`YtysxsAdapter`：WordPress + AudioIgniter，直链白名单自检）、书音FM（`MekuiAdapter`：ecmsapi + wapseries MD5 签名，黄金值测试锁定）；`AlbumScreen` 章节列表按 `album.source` 路由加载并支持点击播放；build 22：搜索改为全部启用音源聚合（`AggregateSearcher` 固定序、失败源名透出，`SearchScreen` 移除单源切换菜单，对齐安卓 SearchViewModel）；build 24：聚合搜索 `withTaskGroup` 并行请求全部启用源（结果仍按固定序拼接、失败收名/allFailed/悦听 antibot 语义不变，最坏耗时 ≈ 最慢单源而非各源求和） |
| f | 悦听反爬 | ✅ | `YtysxsVerifyWebView`（WKWebView 容器）人工验证流程完整落地：命中反爬特征抛 `AntibotException` → 弹验证页 → `httpCookieStore` 捕获 `be_captcha_token` → `KeychainTokenStore`（kSecClassGenericPassword，SecItemAdd/CopyMatching/Delete）持久化 24h → 验证完成自动重试原搜索；后续请求自动携带 Cookie。不自动破解验证码 |
| g | 502/503/504 重试 | ✅ | `APIClient.execute` 统一重试入口：Msrc 1 次 / 1.5s（与安卓 MsrcHttp 一致）、Mekui 2 次 / [2.5s, 8s]（与安卓 MekuiHttp 一致）；非 200 且不可重试直接失败。端到端行为由 stub URLProtocol 测试锁定；build 22 r2：新增连接级错误自动重试——URLError 的 -1005/-1001/-1004/-1009 四类连接错误固定最多 2 次重试（共 3 次尝试）、退避 0.5s/1s，其余错误不重试；耗尽后报「网络连接中断（已自动重试仍失败），请检查网络后重试」（真机「The network connection was lost.」路径被断的对策）；build 24：连接错误集补入 -1003 cannotFindHost / -1006 dnsLookupFailed（DNS 瞬时错误同样自动重试，共六类，退避与上限不变） |
| h | 导入功能 | ✅ | m3u / 直链 / 本地文件路径，https-only 校验，自然排序，书名建议 |
| i | 音源开关持久化 | ✅ | `SourceManageScreen` 开关写入 `SourceEnabledStore`（UserDefaults `source_enabled_` 前缀），重启后保持；build 22：开关真正控制搜索聚合范围（`AggregateSearcher` 读 `enabledSearchSources()`，搜索页/发现页共用），关最后一个启用搜索源时拒绝并提示「至少保留一个音源」（对齐安卓 toggleSource），「导入」不参与搜索聚合、行内标注 |
| j | 启动自动恢复上次播放 | ✅ | build 21：启动读最新 `HistoryModel`，`HistoryResumePlanner` 重建队列后 `prepareQueue` 载入迷你播放条（上次进度），**不自动出声**，用户点播放才播；无历史则维持首启现状 |

## 8. 测试对账

- **安卓基线**：276 条 `@Test`（43 个测试类）
- **iOS 现有**：**208 条测试函数（22 个测试文件、30 个 XCTestCase 类）**（三口径可 grep 实数核对：文件数 `ls TingYouTests/*.swift | wc -l`、类数 grep `final class.*XCTestCase`、函数数 grep `func test`；136 条为 build 20 基线，build 21 新增 42，build 22 新增 16，build 23 新增 3，build 24 新增 4，build 25 新增 7，build 27 新增 4；build 26 为弹窗写入路径运行时隔离改造，无新增测试函数——SpeedSheet 写入语义仍由既有 `SpeedSheetBindingTests` 2 条锁定）：
  - `Build21FeedbackTests`：20 条（build 21 · 反馈 1：播放模式决策纯函数 6 + 持久化 1 + 展示名唯一 1；反馈 2：HTML 实体解码 6 含 parseSearch 出口黄金样本 + charset 解码 6 含 GBK 黄金字节流）
  - `Build22AlignmentTests`：13 条（build 22 · 倍速：SpeedSheet select 写 Binding 后 speed 实际变化 2；聚合搜索：启用集过滤+固定序 1 / 关一个源少一个源结果 1 / 失败源名透出 1 / 悦听 antibot 关键词透传 1 / 仅剩单源全败 allFailed 1 / searchSources 不含导入 1；音源开关守卫：最后一个源不可关 1 / 重开后可关 1 / 导入不受保护 1 / toggleSource 翻转 1；build 24 并行化：并行执行下结果仍固定序且总耗时 < 0.55s·串行需 1.0s 1）
  - `CoverImageCacheTests`：9 条（build 19：封面会话挂 PinningURLSessionDelegate 断言 / 封面图源域名白名单互检 / 非白名单 host fail-closed·取图拒 nil / 防盗链 Referer 设置与省略 / 请求 URL 保全；build 20 必修 1：同一 guoguo URL 按 ting15/ting08 源各带准确 referer）
  - `DiscoverCacheTests`：8 条（build 18：发现页预加载缓存命中 / 磁盘缓存失效 / 预取调度；build 20 必修 6：中间态等待改 expectation；build 24：loadMore 失败置反馈态且不清列表 1 / 失败后重试页码回退·成功恢复 1 / 磁盘缓存孤儿键 init 清理 1）
  - `DiscoverAndHistoryTests`：22 条（build 21 · 反馈 7：搜索历史保存/去重置顶/上限 20/单删/清空 6；反馈 4/6：发现页目录 7 含各源分类清单与 URL 注入拒绝 + 分类页解析黄金样本 3 + 多源路由/不支持源/翻页/失败回退 5；反馈 3：启动恢复不出声 1）
  - `DtoMappingTests`：8 条（snake_case JSON → DTO → 领域模型）
  - `HistoryAndFavoriteTests`：6 条（build 18：历史 upsert / 收藏增删查幂等；build 19：P1-1 同源收藏两本书均落库 / P1-2 乱序写历史最终为新章节且写入串行）
  - `HistoryResumeTests`：6 条（build 20 必修 2：恢复播放重建完整队列·定位 index/chapterId/标题/夹取 / 拉取失败与空列表降级单章 / locate 纯函数匹配优先级）
  - `ImportOrganizerTests`：14 条（自然排序 / 章节标题 / 书名建议 / 直链 / m3u 解析）
  - `ImportServiceTests`：3 条（build 20 必修 3：两本导入书均落库且 id 递增互异 / 章节挂正确 bookId / 空链接建书 0 章）
  - `KeychainTokenStoreTests`：9 条（token 过期边界纯函数 / Keychain 存取闭环 / 过期自清理 / Cookie 头格式 / 24h 默认 Max-Age）
  - `MekuiAdapterTests`：8 条（wapseries MD5 签名黄金值 ×2 / 详情解析黄金样本 / 付费打标 / 缺章节降级）
  - `MsrcHtmlTests`：17 条（ting15 / ting08 搜索解析黄金样本 / 详情解析 / 两步 token 播放页 meta / 播放响应 BOM·status 双形态·-1 付费·-2 频控 / encodeUriComponent %20 语义与 ASCII 白名单）
  - `PlayUriTests`：5 条（占位 URI 构建 / 解析 / 旧 URI 兼容 / 非 ASCII URL 归一化）
  - `PlayerSheetPresentationTests`：3 条（build 23 · 弹窗机制重构：PlayerSheet 四 case 的 id 返回自身 / 四 id 互异且 switch 槽位唯一不新增不遗漏 / Equatable 同 case 等不同 case 不等——sheet(item:) 呈现触发依赖这两项契约；运行时呈现行为以真机/CI 为准，不硬凑 UI 测试）
  - `RetryAndPinningTests`：22 条（可重试状态码判定 / 安卓基线重试参数 / stub URLProtocol 端到端重试 3 条 / 域名白名单后缀·精确·大小写·fail-closed 5 条；build 20 必修 5：传输层错误重试退避阶梯 / 重试前必须等待 / 首发成功零延迟；build 22 r2：连接级错误集合恰为六类（build 24 补入 -1003/-1006）且非 URLError 不重试 / 连接被断重试后成功 / 连续 3 次连接失败报升级文案 / 非连接级错误（取消）不重试）
  - `ShelfMappingTests`：3 条（build 18：书架领域模型 → SwiftData 实体映射）
  - `SkipSettingsTests`：7 条（build 25 · 对齐安卓 v1.3.0 item 8：起播位置决策纯函数 2 含恢复进度优先 / prepareQueue 集成断言起播历史位置含片头秒 1 / 片尾判定边界 1 含恰好等于与末尾不触发 / 末章切章不越界 1 / 按书持久化隔离与写入 clamp 600 1 / 设置入口写当前书与换书刷新 1）
  - `Build27Tests`：4 条（build 27 · 倍速加固：音频会话中断恢复决策纯函数 3——结束+建议恢复/开始/结束无建议；搜索历史提交即记录语义 1——三种成败的词一视同仁）
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

## 11. build 48 变更说明（v1.4.4 · CFBundleVersion 48）

本 build 合并四项需求：三条 UI 改造（需求 1/2/3）+ 一条 B 站取流超时修复（需求 4）。

### 11.1 需求 1 · 历史搜索「全部显示 + 聚焦才显示」

**改造前**：历史搜索区在 `keyword.isEmpty` 时常驻可见，且条目超过 8 条时被截断（自然高度上限 8 条 / `ScrollView` 固定 160pt）。

**改造后**：

- 历史区改为**聚焦门卫**：只有「搜索框处于聚焦态 **且** 关键字为空」时才渲染；一旦失焦或开始输入即整体隐藏。
- 移除全部截断逻辑：条目数量不再设上限，列表改为 `LazyVGrid` 换行自然铺开，长词整体换行、不省略。

**交互完整描述**：进入发现页 → 历史区默认隐藏 → 点击顶部搜索框（键盘弹起）→ 历史记录以换行网格全部展开显示，条数不限 → 点击任意一条历史词 → 立刻发起搜索并显示结果 → 点击搜索框外任意区域失焦 → 历史区收起隐藏；已输入关键字时历史区始终不显示。

**焦点隔离（build 41 回归防线）**：`@FocusState` 的**读写全部收敛到两个叶子视图**——`DiscoverSearchField`（持有焦点绑定）与 `DiscoverHistoryGate`（持有显隐判定）。`DiscoverScreen.body` 自身**只写不读**焦点态，焦点翻转的重渲染范围止于叶子，不会波及书库 `List` 的行激活，从根上避免 build 41 真机回归「聚焦后点书无反应」。回归守卫：UI 测试用例 A/B/H（`DiscoverNavigationUITests`）真实点击验证。

### 11.2 需求 2 · 删除发现页「分类：热门推荐」折叠按钮，改为常驻标签栏

- 删除「分类：热门推荐」入口按钮及其展开态交互代码（`DisclosureGroup` / `categoryExpanded` / `「分类：」` 文案全部移除，无死代码残留）。
- 改为**常驻横向滚动标签栏**：沿用原展开态蓝框样式——选中项粗体 + 主色，未选中项次级色；当前书源的分类恒驻显示，无需点击展开。
- 切换音源后标签栏立即刷新为新书源的分类，并自动选中新书源的默认分类。

### 11.3 需求 3 · 删除书架页「导入」tab

- 移除书架页的「导入」tab 及其空状态页（「暂无导入书籍」）视图代码，仅保留「收藏 / 历史」两个 tab。
- **边界说明**：按字面最小范围执行——外部导入入口（`Menu` 中的本地导入 / 网页导入）与 `ImportedBookModel` 数据层**保留**；导入进来的书籍仍会出现在收藏/历史中，只是不再有独立的「导入」分类页。

### 11.4 需求 4 · B 站取流超时修复（镜像自动重试 + watchdog 二分判定）

**真机现象**：《择日飞升》（玄幻/仙侠/多人小说剧，X 1-5，总时长 49:38）进度卡在 00:05，诊断红字：

```
加载超时，请重试 [诊断]
B站取证：截图反馈此段
取流超时·20秒内条目未就绪（缓冲挂起，AVFoundation 未报 .failed）
play · HTTP 206 video/mp4 @ upos-sz-estgcos.bilivideo.com
```

**根因结论（三层定位）**：

1. **HTTP 层正常，b47 未回退**：`HTTP 206` + `Content-Type: video/mp4` 正确，该节点走的正是 b47 的「正确类型透传」路径，未退化为 `application/octet-stream`；Referer / Range 注入（`applyBiliCdnHeaders`）与 `rewrittenBiliContentType` / `sniffedBiliMp4Mime` 全部在位，本次修复未触碰。
2. **真实触发点是本地 watchdog 20s 兜底**：AVFoundation 侧**既不报 `.failed` 也不就绪**，属「慢 / 挂起」形态，与此前「秒败 Cannot Open」是不同层的问题——故障不在代理层的类型改写，而在**所选镜像节点吞吐过慢 + 本地超时判定过粗**。
3. **判定过粗**：原 watchdog 一律「20s 未就绪 ⇒ 掐断报错」，没有区分「完全没数据」与「数据在缓慢到达」，把**可恢复的缓冲**误判为失败。

**修复方案（三部分）**：

- **① 镜像候选链 + 自动换源重试**：B 站 play 接口的响应通常带多个镜像（`backup_url`）。resolve 阶段一次性取回**候选链**——`getPlayUrlCandidates` → `audioStreamUrlCandidates` → `extractPlayableUrlCandidates` → `selectStreamUrlCandidates`（`baseUrl` + `base_url` + `backupUrls`，经 `isAllowedStreamUrl` 白名单过滤并去重，**主选恒居首位**）。主选照旧入 `resolvedPlayUrls` 缓存服务，其余镜像存 `mirrorCandidates`（`mirrorLock` 保护）。watchdog 触发时 `takeNextMirrorCandidate()` 在锁内原子「出队 + 计数」，上限 `mirrorRetryLimit = 3`；换源方式为 `storeResolved(key:uri, url:next)` 把缓存重定向到新镜像 + `loadCurrentChapter(autoPlay:true, keepMirrorChain:true)` 重建 `AVPlayerItem`（**同一 `loadingRequest` 只能 `finishLoading` 一次，故不能在原请求上换 URL**）。镜像链耗尽才向用户报错。
- **② watchdog 二分判定**：`ProxyStreamSessionDelegate` 累计 `forwardedBytesTotal`（**只计偏移对齐丢弃后的净 respond 字节**）。watchdog 到点采样增量，与基线比对，增量 ≥ `streamProgressFloorBytes`（16 KB，约 fMP4 init segment 量级）判为 `.progressing` → **延长观察 20s**（更新基线、`watchdogExtensions += 1`），不掐可恢复缓冲；否则零字节判 `.stalledNoData`、已有部分数据判 `.stalledAfterData(forwardedBytes:)` → 两者**都切镜像**，仅诊断文案区分。
- **③ 诊断文案分形态**：`.progressing` → 「watchdog · 数据缓慢到达（20s 增量 N 字节，累计 M 字节），延长观察第 K 轮」；`.stalledNoData` → 「零字节到达」；`.stalledAfterData` → 「数据中途停滞（先到达 N 字节后停止）」。报错文案附观察窗时长、换镜像次数与 `B站取证：截图反馈此段`。

**实测证据**：

- `streamStallVerdict(previousBytes:currentBytes:)` 单元断言覆盖三形态与 **16383 / 16384 边界**（`Build48FeatureTests.testStreamStallVerdictDistinguishesTwoStallShapes`）。
- 镜像链链路与 `mirrorRetryLimit = 3` 由 `Build48FeatureTests.testBiliMirrorRetryChainGuard` 守护，同时**断言 b47 三处不得回退**（`rewrittenBiliContentType` / `sniffedBiliMp4Mime` / `applyBiliCdnHeaders`）。
- 真机复测：用户确认「B站播放复测正常了」，b47 改写在多数书上已闭环；本 build 的镜像重试与 watchdog 二分需随包真机回归验证（**沙箱无 Swift 工具链，未能本地 xcodebuild**）。

### 11.5 改动文件清单

| 文件 | 需求 | 说明 |
| --- | --- | --- |
| `TingYou/UI/Discover/DiscoverScreen.swift` | 1 / 2 | 焦点隔离叶子视图（`DiscoverSearchField` / `DiscoverHistoryGate`）；删除折叠分类按钮，改常驻横向标签栏 + 音源切换联动 |
| `TingYou/UI/Shelf/ShelfScreen.swift` | 3 | 删除「导入」tab 与「暂无导入书籍」空状态页 |
| `TingYou/Playback/PlaybackManager.swift` | 4 | 镜像候选链、`mirrorCandidates` / `mirrorLock`、`takeNextMirrorCandidate`、`forwardedBytesTotal` 计数、`streamStallVerdict` 二分判定、`handleStreamWatchdogFired` 分形态处理与切镜像 |
| `TingYou/Services/PlaybackRepository.swift` | 4 | 新增 `getPlayUrlCandidates(src:albumId:chapterIdx:detailPath:)` |
| `TingYou/Services/BiliAdapter.swift` | 4 | 新增 `audioStreamUrlCandidates` / `extractPlayableUrlCandidates` / `selectStreamUrlCandidates` / `deduplicatedUrls`（原 `selectStreamUrl` 单值改为候选链） |
| `project.yml` | 版本 | `CURRENT_PROJECT_VERSION: 48`、`CFBundleVersion: "48"` |
| `TingYou/Info.plist` | 版本 | `CFBundleVersion` = 48 |
| `TingYouTests/Build29RegressionTests.swift` | 1 | 禁④守卫改写为「焦点态必须隔离在叶子视图」；版本断言 → 48 |
| `TingYouTests/Build32RegressionTests.swift` | 1 / 3 | 历史区显隐改为焦点驱动口径；书架导入 tab 翻转为否定断言 + 收藏/历史两 tab 肯定断言；新增 `codeOnly`（剔除整行注释）避免删除说明注释误伤 |
| `TingYouTests/Build44FeedbackTests.swift` | 1 | 历史区三截断形态否定断言 + `historyList` 直挂肯定断言 |
| `TingYouTests/Build45FeedbackTests.swift` | 1 | `history.count <= 8` 否定 + `frame(height: 160)` 否定 |
| `TingYouTests/Build48FeatureTests.swift` | 1–4 | **新增**：分类标签栏常驻、镜像重试链守卫、两种停滞形态判定、书架导入 tab 移除但外部导入保留 |
| `TingYouUITests/DiscoverNavigationUITests.swift` | 1 / 2 | 用例 C 锚点改常驻标签栏「推荐」；新增用例 H（聚焦后点书仍能推入 AlbumScreen） |

### 11.6 已知边界与未验证范围

- **沙箱无 Swift 工具链**：本 build 的编译验证依赖 GitHub Actions CI 的 `xcodebuild`；本地只做了括号配平、断言 needle 回查与逻辑仿真，**未本地跑通编译与 XCTest**。
- 镜像重试与 watchdog 二分的真机效果需随包在真机回归（重点：《择日飞升》长音频、X 1-5）。
- `readme` 中的 build 48 章节随源码包附载，便于离线核对改动与证据。
