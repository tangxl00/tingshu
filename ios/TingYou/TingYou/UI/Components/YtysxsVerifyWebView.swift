import SwiftUI
import WebKit

/// 悦听有声书人工验证 WebView（P0-4，安卓 YtysxsVerifyWebView 对等）。
///
/// 完整反爬闭环：
/// 1. 搜索/详情命中 AntibotException（搜索驗證 / cf-turnstile / be_captcha_token 页特征）；
/// 2. UI 弹出本 sheet，加载悦听搜索页，用户人工完成验证（不自动破解验证码）；
/// 3. 每次导航结束经 WKWebsiteDataStore.httpCookieStore 捕获 be_captcha_token；
/// 4. token 写入 KeychainTokenStore（Keychain 主体 + 24h Max-Age 元数据）；
/// 5. 有效期内原生请求（YtysxsAdapter.fetchHtml）自动携带 Cookie 放行。
///
/// build 38 · 反馈 2（用户第二次反馈「验证页加载不出来」深修）：
/// ① makeUIView 初始 frame 不再用 .zero——部分 iOS 版本下零尺寸 WKWebView 可能
///    不触发 provisional navigation（表现为永久转圈），给屏幕尺寸的防御性初始帧；
/// ② 接入 estimatedProgress KVO → sheet 状态机，加载中显示可见进度条；
///    25 秒超时兜底经状态机收敛（仅 loading 态可触发，迟到超时不覆盖已回包结果）；
/// ③ didFinish 后把悦听域全部 cookie 同步进 HTTPCookieStorage.shared
///    （YtysxsCookieSync），验证 WebView 的会话随 URLSession 请求复用——
///    此前只传 be_captcha_token 单值，其它会话 cookie 丢失会导致验证通过后
///    搜索再次触发验证；
/// ④ webViewWebContentProcessDidTerminate 第一次自动 reload 一次（此前只报错，
///    需用户手动重试）；同一 WebView 实例只自动恢复一次，再终止走人工重试。
struct YtysxsVerifyWebView: UIViewRepresentable {
    let keyword: String
    let cookieStore: KeychainTokenStore
    let onResult: (Bool) -> Void
    /// build 27：加载状态回调（true = 加载中）——驱动 sheet 层进度与错误 UI
    let onLoadingChange: (Bool) -> Void
    /// build 27：加载失败回调（错误描述 + 重试闭包由 sheet 层组装）
    let onLoadError: (String) -> Void
    /// build 38 · 反馈 2 ②：estimatedProgress 进度回包（0.0~1.0，仅加载中回调）
    let onProgress: (Double) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // build 41 · 反馈 ②（UA 指纹对齐）：验证会话与后续 URLSession 请求必须同 UA——
        // 此前 WebView 用 applicationNameForUserAgent 追加（完整 UA 运行时随系统版本
        // 变化），适配器请求走 APIClient.browserUA，两端不一致，站点若把放行绑定 UA
        // 指纹则验证形同虚设。改为 webView 创建后 customUserAgent 固定为同一常量
        //（完整覆盖、两端完全相同）。build 37 的动态版本拼接（TingYou/<version>）退役。
        // build 38 · 反馈 2 ①：防御性非零初始帧——SwiftUI 布局接管前 provisional
        // navigation 已可开始；autoresizingMask 保证布局生效后贴合容器。
        let initialFrame = UIScreen.main.bounds
        let webView = WKWebView(frame: initialFrame, configuration: config)
        webView.customUserAgent = APIClient.browserUA
        webView.navigationDelegate = context.coordinator
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // build 38 · 反馈 2 ②：进度可见性——estimatedProgress KVO（dismantle 时移除）
        webView.addObserver(context.coordinator, forKeyPath: "estimatedProgress",
                            options: [.new], context: nil)
        context.coordinator.isObservingProgress = true
        return webView
    }

    /// build 38 · 反馈 2 ②：视图移除（含 .id 重试重建）时移除 KVO 观察者，
    /// 避免悬垂观察者崩溃。
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        if coordinator.isObservingProgress {
            uiView.removeObserver(coordinator, forKeyPath: "estimatedProgress")
            coordinator.isObservingProgress = false
        }
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = kw.isEmpty
            ? "https://www.ytysxs.com"
            : "https://www.ytysxs.com/?s=\(MsrcHtml.encodeUriComponent(kw))"
        guard let url = URL(string: urlString), context.coordinator.loadedURL != urlString else { return }
        context.coordinator.loadedURL = urlString
        load(webView: uiView, url: url)
    }

    /// build 27：统一加载入口——置加载态后加载（重试由 sheet 层 .id 重建触发，不直接复用本方法）。
    private func load(webView: WKWebView, url: URL) {
        DispatchQueue.main.async { [onLoadingChange] in
            onLoadingChange(true)
        }
        webView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(cookieStore: cookieStore, onResult: onResult,
                   onLoadingChange: onLoadingChange, onLoadError: onLoadError,
                   onProgress: onProgress)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let cookieStore: KeychainTokenStore
        let onResult: (Bool) -> Void
        let onLoadingChange: (Bool) -> Void
        let onLoadError: (String) -> Void
        let onProgress: (Double) -> Void
        var loadedURL: String?
        /// build 38 · 反馈 2 ②：KVO 观察者注册标记（dismantleUIView 恰好移除一次）
        var isObservingProgress = false
        /// build 38 · 反馈 2 ④：进程终止自动恢复只做一次（防 reload 循环）
        private var didAutoReloadContentProcess = false
        /// build 44 · 反馈 2（「已验证仍拦截」二轮）：滑块通过是页面内 AJAX/fetch，
        /// 不产生新导航——didFinish 后才 Set 的会话 cookie 永不进捕获窗口。
        /// 补救：didFinish 后 15 秒内每 2 秒轮询一次 httpCookieStore，新 cookie
        /// 立即同步 + 发现 token 即回包。轮询代次标记使旧轮询在新导航后失效。
        private var cookiePollGeneration = 0
        /// build 44 · 反馈 2：onResult(true) 只回包一次——didFinish 与轮询两条
        /// 路径都可能发现 token，重复回包会导致 sheet 关闭后搜索被重放多次。
        private var didReportSuccess = false

        init(cookieStore: KeychainTokenStore, onResult: @escaping (Bool) -> Void,
             onLoadingChange: @escaping (Bool) -> Void, onLoadError: @escaping (String) -> Void,
             onProgress: @escaping (Double) -> Void) {
            self.cookieStore = cookieStore
            self.onResult = onResult
            self.onLoadingChange = onLoadingChange
            self.onLoadError = onLoadError
            self.onProgress = onProgress
        }

        // build 38 · 反馈 2 ②：estimatedProgress KVO → 进度回包（仅加载中转发；
        /// 导航完成后的迟到回包由 sheet 状态机丢弃，不复活加载态）
        override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                   change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            guard keyPath == "estimatedProgress",
                  let progress = change?[.newKey] as? Double else { return }
            DispatchQueue.main.async { [onProgress] in
                onProgress(progress)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // build 27：主线程回包（WKNavigationDelegate 本就在主线程，防御性统一）
            DispatchQueue.main.async { [onLoadingChange] in onLoadingChange(false) }
            // 验证完成后从 httpCookieStore 捕获 be_captcha_token（24h 有效）
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self else { return }
                // build 38 · 反馈 2 ③：悦听域全部 cookie 同步进 URLSession 侧
                // （HTTPCookieStorage.shared）——验证会话随后续原生请求复用，
                // 修复「验证通过后搜索仍再触发验证」的形态。
                YtysxsCookieSync.sync(cookies)
                if let token = YtysxsCookieSync.captchaToken(from: cookies) {
                    self.reportSuccess(token: token)
                }
            }
            // build 44 · 反馈 2（「已验证仍拦截」二轮）：滑块 AJAX 后补捕获——
            // 见 cookiePollGeneration 声明处注释。didFinish 时滑块大概率未过，
            // 放行 cookie 要等用户拖完滑块才 Set，必须靠轮询兜住。
            startCookiePolling(webView: webView)
        }

        /// build 44 · 反馈 2：didFinish 后 15 秒轮询（2 秒间隔共 8 轮）——
        /// 每轮全量同步悦听域 cookie；新出现 captchaToken 即保存并回包。
        /// 代次失效：新一轮 didFinish（重试/重新加载）使旧轮询闭包作废；
        /// dismantle 后 Coordinator 释放（[weak self]），轮询自然终止。
        private func startCookiePolling(webView: WKWebView) {
            cookiePollGeneration += 1
            let generation = cookiePollGeneration
            for tick in 1...8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(tick) * 2.0) { [weak self] in
                    guard let self = self, generation == self.cookiePollGeneration else { return }
                    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                        YtysxsCookieSync.sync(cookies)
                        if let token = YtysxsCookieSync.captchaToken(from: cookies) {
                            self.reportSuccess(token: token)
                        }
                    }
                }
            }
        }

        /// build 44 · 反馈 2：成功回包幂等收敛（见 didReportSuccess 声明处注释）。
        /// token 始终重新保存——轮询发现的「迟到 token」可能是滑块后刷新的新值。
        private func reportSuccess(token: String) {
            cookieStore.save(token: token)
            guard !didReportSuccess else { return }
            didReportSuccess = true
            DispatchQueue.main.async { self.onResult(true) }
        }

        /// build 27（空白页修复）：加载失败此前无任何 UI 反馈，静默成空白页——
        /// 现回调错误描述到 sheet 层展示（含重试按钮），用户可恢复。
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { [onLoadingChange, onLoadError] in
                onLoadingChange(false)
                onLoadError((error as NSError).localizedDescription)
            }
        }

        /// build 37 · 反馈 5：预加载阶段失败（DNS/TLS/连接被拒/超时）此前不产生任何
        /// 回调 UI——loading 转圈卡死、无错误提示（「验证页面加载不出来」的直接根因）。
        /// 补齐与 didFail 一致的失败路径（错误提示 + 重试，复用 sheet 层 .id(retryToken)
        /// 重建机制）；重试重建引发的 NSURLErrorCancelled 静默清态、不误报。
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let ns = error as NSError
            guard ns.code != NSURLErrorCancelled else {
                DispatchQueue.main.async { [onLoadingChange] in onLoadingChange(false) }
                return
            }
            DispatchQueue.main.async { [onLoadingChange, onLoadError] in
                onLoadingChange(false)
                onLoadError(ns.localizedDescription)
            }
        }

        /// build 27：导航被取消（系统侧 w/ NSURLErrorCancelled）不算失败也不算成功——
        /// 清加载态静默返回（重试场景常见，不能误报错误）。
        /// build 38 · 反馈 2 ④：进程终止自动恢复一次（Apple 推荐的 webView.reload()），
        /// 恢复期间回到加载态（进度/超时兜底照常接线）；同一实例只自动恢复一次，
        /// 再次终止按原路径报错走人工重试，避免 reload 循环。
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if !didAutoReloadContentProcess, loadedURL != nil {
                didAutoReloadContentProcess = true
                DispatchQueue.main.async { [onLoadingChange] in
                    onLoadingChange(true)
                }
                webView.reload()
                return
            }
            DispatchQueue.main.async { [onLoadingChange, onLoadError] in
                onLoadingChange(false)
                onLoadError("网页进程已终止，请重试加载")
            }
        }
    }
}

/// 验证流程 sheet：标题 + 完成验证 / 取消按钮 + WebView 主体。
/// build 38 · 反馈 2：加载/失败/超时/重试状态收敛到 VerifyLoadStateMachine（可单测），
/// UI 全部由 machine.phase 派生。
struct YtysxsVerifySheet: View {
    let keyword: String
    let cookieStore: KeychainTokenStore
    let onDone: (Bool) -> Void
    /// build 38 · 反馈 2：加载状态机（唯一事实源）
    @State private var machine = VerifyLoadStateMachine()
    /// build 27：重试触发（更新即让 WebView updateUIView 重新 load）
    @State private var retryToken = 0
    /// build 37 · 反馈 5：加载超时兜底任务——慢网络 / 连接挂起（无任何导航回包）时
    /// 25 秒后提示超时可重试，不再无限转圈。随 loading 状态启停：didFinish/didFail/
    /// didFailProvisional 任一回包即取消；重试重建 WebView 后由新一轮 loading 重新计时。
    @State private var loadTimeoutTask: Task<Void, Never>?

    /// build 37 · 反馈 5：超时兜底时长 25 秒（20~30s 建议区间取中，站点实测 3.5s/136KB）。
    private static let loadTimeoutNanos: UInt64 = 25_000_000_000

    private func startLoadTimeout() {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: Self.loadTimeoutNanos)
            guard !Task.isCancelled else { return }
            // build 38：经状态机收敛——若导航已回包（phase 不再 loading），迟到超时不覆盖
            machine.timeout()
        }
    }

    private func cancelLoadTimeout() {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                YtysxsVerifyWebView(
                    keyword: keyword,
                    cookieStore: cookieStore,
                    onResult: { captured in
                        if captured { onDone(true) }
                    },
                    onLoadingChange: { loading in
                        if loading {
                            machine.start()
                            startLoadTimeout()
                        } else {
                            machine.finish()
                            cancelLoadTimeout()
                        }
                    },
                    onLoadError: { text in
                        machine.fail(text)
                    },
                    onProgress: { progress in
                        machine.updateProgress(progress)
                    }
                )
                .ignoresSafeArea(edges: .bottom)
                .id(retryToken) // build 27：重试 = 整体重建 WebView（清空陈旧导航状态）

                if case .loading(let progress) = machine.phase {
                    // build 27：加载中提示（原实现无任何反馈，慢网络下像空白页）；
                    // build 38 · 反馈 2 ②：有 estimatedProgress 回包时显示确定进度条
                    // 与百分比，无回包时保持不确定转圈——站点 2~3s 响应也有可见进展。
                    VStack(spacing: 10) {
                        if let p = progress {
                            ProgressView(value: p)
                                .frame(maxWidth: 240)
                            Text("正在加载验证页面… \(Int((p * 100).rounded()))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView("正在加载验证页面…")
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if case .failed(let text) = machine.phase {
                    // build 27：加载失败提示 + 重试（原实现静默失败成空白页）
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text("验证页加载失败")
                            .font(.headline)
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") {
                            if machine.retry() {
                                retryToken += 1 // 触发 .id 变化重建 WebView 重新加载
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                }
                if case .timedOut = machine.phase {
                    // build 38：超时从 failed 独立成态——文案明确 25 秒兜底口径
                    VStack(spacing: 12) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text("验证页加载超时")
                            .font(.headline)
                        Text("页面 25 秒内未加载完成，请检查网络后重试")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") {
                            if machine.retry() {
                                retryToken += 1
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                }
            }
            .navigationTitle("完成安全验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onDone(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("我已完成验证") { onDone(cookieStore.hasValidToken()) }
                }
            }
        }
    }
}
