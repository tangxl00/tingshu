import XCTest
@testable import TingYou

/// build 50 · 两项迭代守卫。
///
/// 任务 1 · 云同步接入：tingshu-sync 云函数（契约 v1.0.0）九端点客户端
///   （auth/v1/config·code·login·refresh·logout + account/v1/me +
///   sync/v1/pull·push + export/v1/daily），设置页「账号与同步」区块
///   （邮箱+验证码登录），收藏/播放进度 LWW 双向同步，断网本地 outbox
///   排队、联网自动补传；40003 自动续期重试、40002 清凭据回未登录；
///   免费版云函数单次 3 秒限制的友好重试提示。
/// 任务 2 · 音源对齐 PC（v1.1.8 三源基准）：补齐易听书（yitingshu）——
///   注册/四链路路由/播放/发现页 9 分类/本地标题索引搜索/证书白名单。
///
/// 沙箱无 Swift 工具链，运行时行为（真云登录、验证码邮件、镜像合并、
/// 断网补传）由真机复测与 CI 兜底；此处锁定可静态/纯函数验证的接线面。
final class Build50FeatureTests: XCTestCase {

    // MARK: - 任务 2 · 易听书补齐（对齐 PC 三源基准）

    /// 三源基准守卫：发现页可选音源必须与 PC v1.1.8 完全一致
    /// （tingyou / bili / yitingshu），易听书 9 个分类同 PC YTS_CATS 清单。
    func testDiscoverCatalogMatchesPcThreeSourceBaseline() {
        XCTAssertEqual(DiscoverCatalog.sourceOptions.map(\.id),
                       [SourceRegistry.TINGYOU, SourceRegistry.BILI, SourceRegistry.YITINGSHU],
                       "发现页音源清单必须与 PC v1.1.8 三源基准一致（build 50 补齐易听书）")
        let yts = DiscoverCatalog.categories(for: SourceRegistry.YITINGSHU)
        XCTAssertEqual(yts.count, 9, "易听书分类必须为 9 个（PC YTS_CATS 同清单）")
        XCTAssertEqual(yts.first?.name, "言情", "易听书首个分类应为言情（PC 同顺序）")
        XCTAssertEqual(yts.last?.name, "商业财经", "易听书末个分类应为商业财经（PC 同顺序）")
        // 搜索源三处注册一致性由 Build22AlignmentTests 守卫，此处不重复
    }

    /// 证书白名单守卫：build 50 新增的 4 个主机必须放行——易听书站点页 /
    /// 封面 CDN / 音频直链 CDN（aod.cos.tx.xmcdn.com，精确主机口径，
    /// 不放行 *.xmcdn.com 整域）/ tingshu-sync 云函数网关。
    func testPinnedAllowlistAdmitsBuild50Hosts() {
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("www.yitingshu.com"),
                      "易听书站点页主机必须放行（build 50）")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("imagev2.xmcdn.com"),
                      "易听书封面 CDN 必须放行（build 50）")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("aod.cos.tx.xmcdn.com"),
                      "易听书音频直链 CDN 必须放行（build 50）")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("tingshu-d2gjera4688800c8e.service.tcloudbase.com"),
                      "tingshu-sync 云函数网关必须放行（build 50 云同步）")
        // fail-closed 结构性保证：白名单整域通配不得回归
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("evil.xmcdn.com"),
                       "xmcdn.com 不得整域放行——只允许 imagev2 / aod.cos.tx 两个精确子域")
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("evil.yitingshu.com"),
                       "yitingshu.com 不得整域放行（fail-closed 铁律）")
    }

    /// 音频代理域守卫（精确主机口径，与 PC v1.1.8 返修 P2-1 同口径）：
    /// audioExact 只认 aod.cos.tx.xmcdn.com，audioSuffixes 必须为空
    /// ——后缀 .xmcdn.com 会放行其他子域。
    func testYitingshuAudioDomainsAreExactHostOnly() {
        let cfg = SourceRegistry.configOf(src: SourceRegistry.YITINGSHU)
        XCTAssertNotNil(cfg, "易听书必须注册在 msrcSources（build 50）")
        XCTAssertEqual(cfg?.audioExact, ["aod.cos.tx.xmcdn.com"],
                       "音频直链只认精确主机 aod.cos.tx.xmcdn.com")
        XCTAssertEqual(cfg?.audioSuffixes ?? ["非空"], [],
                       "音频后缀白名单必须为空（不得整域放行 .xmcdn.com）")
        XCTAssertEqual(cfg?.fetchHosts, ["www.yitingshu.com"],
                       "站点页主机必须精确为 www.yitingshu.com")
    }

    /// 四链路路由守卫：搜索（含本地索引兜底）/ 详情 / 章节 / 发现页分类
    /// 都必须有 YITINGSHU case；播放链路在 PlaybackRepository 必须有
    /// YITINGSHU case。本地索引资源必须随包（Resources/yts_index.txt）。
    func testYitingshuWiredIntoAllRoutes() throws {
        let router = Self.codeOnly(try Self.loadSource("TingYou/Services/SourceRouter.swift"))
        let ytsCases = router.components(separatedBy: "case SourceRegistry.YITINGSHU:")
        XCTAssertEqual(ytsCases.count, 5,
                       "SourceRouter 必须有 4 个 YITINGSHU case（搜索/详情/章节/发现页分类），实际 \(ytsCases.count - 1) 个")
        XCTAssertTrue(router.contains("func discoverCategory(src: String, categoryId: String, page: Int)"),
                      "发现页分类路由必须存在（易听书走 /yi/{cat}-{page}.html 分类页口径）")

        let playback = Self.codeOnly(try Self.loadSource("TingYou/Services/PlaybackRepository.swift"))
        XCTAssertTrue(playback.contains("case SourceRegistry.YITINGSHU:"),
                      "PlaybackRepository 播放链路必须有 YITINGSHU case（var now 直链提取）")

        let adapter = Self.codeOnly(try Self.loadSource("TingYou/Services/YitingshuAdapter.swift"))
        XCTAssertTrue(adapter.contains("Bundle.main.url(forResource: \"yts_index\", withExtension: \"txt\")"),
                      "搜索必须加载本地标题索引 Resources/yts_index.txt（search.php 被 vdimgck 验证码拦截）")

        let project = try Self.loadSource("project.yml")
        XCTAssertTrue(project.contains("- path: TingYou/Resources"),
                      "Resources 目录必须整体入包（yts_index.txt 随包分发）")
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.projectRoot() + "/TingYou/Resources/yts_index.txt"),
                      "yts_index.txt 资源文件必须在场（16,671 条本地索引）")
    }

    // MARK: - 任务 1 · 云同步接入

    /// 云端地址守卫：SyncCloudClient.baseURL 必须指向已部署的
    /// tingshu-sync 云函数网关（与 PC 端 v1.1.14 同一服务），不得漂移。
    func testSyncCloudClientBaseURLPointsToDeployedGateway() throws {
        let client = Self.codeOnly(try Self.loadSource("TingYou/Services/SyncCloudClient.swift"))
        XCTAssertTrue(client.contains(#"static let baseURL = URL(string: "https://tingshu-d2gjera4688800c8e.service.tcloudbase.com")!"#),
                      "baseURL 必须为已部署云函数网关常量（与 PC 端同一服务）")
        // 九端点路径必须齐全（契约 v1.0.0；路径常量不带前导斜杠）
        for path in ["auth/v1/config", "auth/v1/code", "auth/v1/login",
                     "auth/v1/refresh", "auth/v1/logout", "account/v1/me",
                     "sync/v1/pull", "sync/v1/push", "export/v1/daily"] {
            XCTAssertTrue(client.contains("\"\(path)\""),
                          "九端点缺 \(path)——契约 v1.0.0 必须全覆盖")
        }
        // 会话必须复用证书固定 delegate（不得裸 URLSession 绕过 fail-closed）
        XCTAssertTrue(client.contains("PinningURLSessionDelegate"),
                      "云同步会话必须复用证书固定 delegate（新主机已入白名单）")
    }

    /// 同步节奏守卫（纯常量）：push 分片 100（契约 ops ≤500 上限内的
    /// 安全分片）、outbox 容量 900（9 个分片，覆盖首登快照回传存量）、
    /// 增量拉取轮数上限 10。（SyncEngine 为 @MainActor，静态常量随类隔离，
    /// 本用例同步标注 @MainActor 访问。）
    @MainActor
    func testSyncEngineChunkingConstants() {
        XCTAssertEqual(SyncEngine.pushChunk, 100, "push 分片必须为 100")
        XCTAssertEqual(SyncLocalStore.outboxCap, 900, "outbox 容量必须为 900（9 个分片）")
        XCTAssertEqual(SyncEngine.pullMaxRounds, 10, "增量拉取轮数上限必须为 10")
    }

    /// 错误码口径守卫（纯函数）：50001 必须带「3 秒限制 + 重试」友好文案
    /// （免费版云函数首登建表可能超时），40002/40003 必须可区分。
    func testSyncCloudErrorFriendlyMessages() {
        let internal50001 = SyncCloudError(code: 50001, message: "whatever")
        XCTAssertTrue(internal50001.errorDescription?.contains("重试") == true,
                      "50001 文案必须引导重试")
        XCTAssertTrue(internal50001.errorDescription?.contains("3 秒") == true,
                      "50001 文案必须说明 3 秒执行限制（首登建表可能超时）")
        XCTAssertEqual(SyncCloudError(code: 40002, message: "").errorDescription,
                       "登录状态已失效，请重新登录",
                       "40002 = 未登录/刷新令牌无效 → 引导重新登录")
        // build 52 · 条件 1（#140 P1）：40003 文案不得再写「正在自动续期」——
        // 原实现把续期失败重包成 40003，那句「进行中」文案就把终局失败伪装成
        // 进行中（真机红字挂 3.5h 不动）。现 40003 = 令牌过期且续期未成功，
        // 新增 40004 = 续期成功仍被拒（终局，须重新登录），两者文案必须可区分。
        XCTAssertEqual(SyncCloudError(code: 40003, message: "").errorDescription,
                       "登录状态已过期，自动续期未成功",
                       "40003 = 访问令牌过期且续期未完成 → 不得再写「正在续期」")
        XCTAssertEqual(SyncCloudError(code: SyncCloudError.renewalRejectedCode, message: "").errorDescription,
                       "登录状态异常：续期后仍被拒绝，请重新登录",
                       "40004 = 续期成功仍被拒 → 终局，必须引导重新登录")
        XCTAssertEqual(SyncCloudError.renewalRejectedCode, 40004,
                       "续期后仍被拒的内部码必须为 40004（不与 40003 复用）")
        XCTAssertEqual(SyncCloudError(code: 50002, message: "").errorDescription,
                       "云端资源不存在",
                       "50002 = 资源不存在")
        XCTAssertEqual(SyncCloudError(code: 10003, message: "").errorDescription,
                       "验证码发送太频繁，请稍后再试",
                       "10003 = 验证码 60 秒内重发")
    }

    /// 设置页入口守卫：「账号与同步」区块必须挂在听书数据之前的
    /// Mine 页，登录表单必须含邮箱 + 验证码 + 60 秒倒计时。
    func testAccountSyncScreenEntryWired() throws {
        let mine = Self.codeOnly(try Self.loadSource("TingYou/UI/Mine/MineScreen.swift"))
        XCTAssertTrue(mine.contains(#"Section("账号与同步")"#),
                      "Mine 页必须有「账号与同步」Section（build 50）")
        XCTAssertTrue(mine.contains("AccountSyncScreen()"),
                      "Section 必须以 NavigationLink 进 AccountSyncScreen")

        let screen = Self.codeOnly(try Self.loadSource("TingYou/UI/Mine/AccountSyncScreen.swift"))
        XCTAssertTrue(screen.contains("resendIn"),
                      "登录表单必须有 60 秒重发倒计时（与 PC 端交互一致）")
        XCTAssertTrue(screen.contains("TextField("),
                      "登录表单必须有邮箱/验证码输入框")
        XCTAssertTrue(screen.contains("role: .destructive"),
                      "退出登录按钮必须为 destructive 语义")
        XCTAssertTrue(screen.contains("排队") || screen.contains("补传"),
                      "footer 必须说明断网排队/联网补传行为")
    }

    /// 业务接线守卫：收藏增删与播放进度记录必须入队 outbox——
    /// AlbumRepository 三处调用点（进度/收藏 upsert/收藏删除），
    /// removeFavorite 必须带 detailPath 参数（bili 的 album_key 需要 bvid）。
    func testAlbumRepositoryEnqueuesSyncOps() throws {
        let repo = Self.codeOnly(try Self.loadSource("TingYou/Services/AlbumRepository.swift"))
        XCTAssertTrue(repo.contains("syncStore?.enqueueProgress("),
                      "recordHistory 必须入队进度 op（build 50）")
        XCTAssertTrue(repo.contains("syncStore?.enqueueFavoriteUpsert("),
                      "addFavorite 必须入队收藏 upsert op（build 50）")
        XCTAssertTrue(repo.contains("syncStore?.enqueueFavoriteDelete("),
                      "removeFavorite 必须入队收藏删除 op（build 50）")
        XCTAssertTrue(repo.contains("detailPath: String? = nil"),
                      "removeFavorite 必须带可选 detailPath（bili album_key 需要 bvid，默认 nil 保既有调用兼容）")

        let player = Self.codeOnly(try Self.loadSource("TingYou/UI/Player/PlayerScreen.swift"))
        XCTAssertTrue(player.contains("removeFavorite(src: album.source, albumId: album.albumId,"),
                      "PlayerScreen 取消收藏必须走 repo.removeFavorite")
        XCTAssertTrue(player.contains("detailPath: album.detailPath)"),
                      "取消收藏必须传 detailPath（bili 书目删除同步的 album_key 需要 bvid）")
    }

    /// outbox 压缩守卫（纯逻辑，离线可测）：同实体同书目的新 op 必须压缩
    /// 旧 op（只保留最后一条）；业务入队 helper 未登录时必须静默跳过。
    /// 用注入 defaults 隔离 UserDefaults.standard 单例副作用。
    func testOutboxCompressionAndLoginGuard() throws {
        let suite = UserDefaults(suiteName: "build50_outbox_test")!
        suite.removePersistentDomain(forName: "build50_outbox_test")
        let store = SyncLocalStore(defaults: suite)
        defer { store.resetForLogout() }

        let album = SyncOpAlbum(source: SourceRegistry.YITINGSHU, bookId: "12345", bvid: nil)
        let payload = SyncOpPayload(album: album, title: "测试书目", author: nil,
                                    coverUrl: nil, addedAt: 1_700_000_000_000,
                                    chapterIdx: nil, positionMs: nil,
                                    durationMs: nil, updatedAt: nil)
        store.enqueue(SyncPushOp(clientOpId: "op-1", entity: "favorite", op: "upsert",
                                 clientAt: 1, payload: payload))
        store.enqueue(SyncPushOp(clientOpId: "op-2", entity: "favorite", op: "delete",
                                 clientAt: 2, payload: payload))
        store.enqueue(SyncPushOp(clientOpId: "op-3", entity: "favorite", op: "upsert",
                                 clientAt: 3, payload: payload))
        let outbox = store.takeOutboxChunk(max: 100)
        XCTAssertEqual(outbox.count, 1, "同实体同书目的三条 op 必须压缩为一条")
        XCTAssertEqual(outbox.first?.op, "upsert", "压缩必须保留最后一条（clientAt=3 的 upsert）")
        XCTAssertEqual(outbox.first?.clientOpId, "op-3", "保留的必须是最后入队的 op")

        // 冲刷成功后按 client_op_id 移除（服务端 2s deadline 兜底：只移除
        // results 里返回的 op，未处理的不误删）
        store.enqueue(SyncPushOp(clientOpId: "op-4", entity: "progress", op: "upsert",
                                 clientAt: 4, payload: payload))
        store.removeOutbox(opIds: ["op-3"])
        XCTAssertEqual(store.outboxCount, 1, "只移除指定 client_op_id，其余 op 必须保留")
        XCTAssertEqual(store.takeOutboxChunk(max: 10).first?.clientOpId, "op-4")

        // 未登录守卫：业务 helper enqueue 必须静默跳过（不入队）
        store.resetForLogout()
        store.enqueueFavoriteUpsert(src: SourceRegistry.YITINGSHU, albumId: 12345,
                                    title: "测试书目", author: nil, coverUrl: nil,
                                    detailPath: nil)
        store.enqueueProgress(src: SourceRegistry.YITINGSHU, albumId: 12345,
                              title: "测试书目", coverUrl: nil, chapterIdx: 0,
                              positionMs: 1000, durationMs: 60000, detailPath: nil)
        XCTAssertEqual(store.outboxCount, 0, "未登录状态业务入队必须静默跳过（不入队）")
    }

    // MARK: - 版本

    /// 版本守卫：build 51 升位双处一致（project.yml 两处由
    /// Build29RegressionTests 守卫；此处复核 Info.plist）。
    func testBuild50Version() throws {
        let plist = try Self.loadSource("TingYou/Info.plist")
        XCTAssertTrue(plist.contains("<string>53</string>"),
                      "Info.plist CFBundleVersion 必须为 53")
        XCTAssertTrue(plist.contains("<string>1.4.4</string>"),
                      "Info.plist CFBundleShortVersionString 维持 1.4.4")
    }

    // MARK: - 工具

    /// 读工程源码（相对工程根的路径），口径与 Build29RegressionTests 一致。
    private static func loadSource(_ rel: String) throws -> String {
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        let path = projectDir + "/" + rel
        guard FileManager.default.fileExists(atPath: path) else {
            XCTFail("\(rel) 不存在：\(path)——路径布局变化时请同步修正本测试")
            throw NSError(domain: "TestSourceMissing", code: 1)
        }
        guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("\(rel) 不可读：\(path)")
            throw NSError(domain: "TestSourceUnreadable", code: 2)
        }
        return src
    }

    private static func projectRoot() -> String {
        let testDir = (#filePath as NSString).deletingLastPathComponent
        return (testDir as NSString).deletingLastPathComponent
    }

    /// 剔除整行注释（trim 后以 // 开头）——删除说明注释里含被断言的标识符名，
    /// 参与判定前必须剔除。
    private static func codeOnly(_ src: String) -> String {
        src.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
    }
}
