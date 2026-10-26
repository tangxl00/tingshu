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
struct YtysxsVerifyWebView: UIViewRepresentable {
    let keyword: String
    let cookieStore: KeychainTokenStore
    let onResult: (Bool) -> Void
    /// build 27：加载状态回调（true = 加载中）——驱动 sheet 层进度与错误 UI
    let onLoadingChange: (Bool) -> Void
    /// build 27：加载失败回调（错误描述 + 重试闭包由 sheet 层组装）
    let onLoadError: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // build 27（空白页候选修复）：悦听站点对 WebView 默认 UA 的响应差异——
        // 显式带上 Safari/WebKit 标识（保持 iOS 真实形态，不伪装桌面 UA）。
        // build 37 · 反馈 5：原硬编码 "TingYou/1.3.3" 版本陈旧且覆写偏旧，易被站点
        // UA 风控误判——改为读取当前 CFBundleShortVersionString 动态拼接。
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.4"
        config.applicationNameForUserAgent = "TingYou/\(appVersion) Safari/605.1.15"
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        return webView
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
                   onLoadingChange: onLoadingChange, onLoadError: onLoadError)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let cookieStore: KeychainTokenStore
        let onResult: (Bool) -> Void
        let onLoadingChange: (Bool) -> Void
        let onLoadError: (String) -> Void
        var loadedURL: String?

        init(cookieStore: KeychainTokenStore, onResult: @escaping (Bool) -> Void,
             onLoadingChange: @escaping (Bool) -> Void, onLoadError: @escaping (String) -> Void) {
            self.cookieStore = cookieStore
            self.onResult = onResult
            self.onLoadingChange = onLoadingChange
            self.onLoadError = onLoadError
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // build 27：主线程回包（WKNavigationDelegate 本就在主线程，防御性统一）
            DispatchQueue.main.async { [onLoadingChange] in onLoadingChange(false) }
            // 验证完成后从 httpCookieStore 捕获 be_captcha_token（24h 有效）
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self else { return }
                if let token = cookies.first(where: { $0.name == "be_captcha_token" })?.value,
                   !token.isEmpty {
                    self.cookieStore.save(token: token)
                    DispatchQueue.main.async { self.onResult(true) }
                }
            }
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
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            DispatchQueue.main.async { [onLoadingChange, onLoadError] in
                onLoadingChange(false)
                onLoadError("网页进程已终止，请重试加载")
            }
        }
    }
}

/// 验证流程 sheet：标题 + 完成验证 / 取消按钮 + WebView 主体。
struct YtysxsVerifySheet: View {
    let keyword: String
    let cookieStore: KeychainTokenStore
    let onDone: (Bool) -> Void
    /// build 27：加载状态（WebView 不可达时不再静默空白）
    @State private var isLoading = true
    /// build 27：加载失败描述（nil = 无失败）
    @State private var loadErrorText: String?
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
            isLoading = false
            loadErrorText = "验证页加载超时（25 秒），请检查网络后重试"
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
                        isLoading = loading
                        if loading {
                            loadErrorText = nil
                            startLoadTimeout()
                        } else {
                            cancelLoadTimeout()
                        }
                    },
                    onLoadError: { text in
                        loadErrorText = text
                    }
                )
                .ignoresSafeArea(edges: .bottom)
                .id(retryToken) // build 27：重试 = 整体重建 WebView（清空陈旧导航状态）

                if isLoading && loadErrorText == nil {
                    // build 27：加载中提示（原实现无任何反馈，慢网络下像空白页）
                    ProgressView("正在加载验证页面…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if let text = loadErrorText {
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
                            loadErrorText = nil
                            isLoading = true
                            retryToken += 1 // 触发 .id 变化重建 WebView 重新加载
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
