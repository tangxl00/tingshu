import XCTest
import SwiftData
@testable import TingYou

/// build 51 · v1.4.4 返修（质检 NO-GO 放行条件）的回归守卫：
/// - P0-1 chapter_idx 基底归一化（跨端续播双向错章）
/// - P0-2 书架删除必须落云墓碑（wrapper 走 outbox，不再绕过）
/// - P1-1 聚合搜索逐源增量回填 + 单源 3s 超时护栏
/// - P1-2 push 结果 status 必须消费（failed 留队）
/// - P1-3 outbox 溢出淘汰优先保 delete / 缺 id 兜底 / save 失败不静默
/// - 音源残留：mekui 适配器与已下架 7 条白名单主机
final class Build51FeatureTests: XCTestCase {

    // MARK: - P0-1 · chapter_idx 基底归一化

    /// 质检报告的核心复算（N=6）：
    /// - iOS→PC：本地第 k 章（tingyou 1 基）写 chapter_idx=k，PC 按 0 基取 → 落第 k+1 章（晚一章）
    /// - PC→iOS：PC 合规写 k-1，本机 1 基表精确匹配 k-1 → 落第 k-1 章（早一章）
    /// 修法后两端都以 0 基写 / 以源基底读，k 恒定。
    func testTingyouChapterIdxRoundTripsWithoutShift() {
        for k in 1...6 {
            let cloud = ChapterIdxNormalization.toCloud(src: SourceRegistry.TINGYOU, localIndex: k)
            XCTAssertEqual(cloud, k - 1, "tingyou 本地第 \(k) 章必须写成云端 0 基 \(k - 1)")
            let back = ChapterIdxNormalization.toLocal(src: SourceRegistry.TINGYOU, cloudIdx: cloud)
            XCTAssertEqual(back, k, "同一章节云端回传后必须落回本地第 \(k) 章（往返零偏移）")
        }
    }

    /// 双端「同一本书首章 chapter_idx 对齐取数」：首章在云端必须统一是 0。
    func testFirstChapterChapterIdxAlignedAcrossSources() {
        // 听友FM 首章本地 1 基 = 1 → 云端 0
        XCTAssertEqual(ChapterIdxNormalization.toCloud(src: SourceRegistry.TINGYOU, localIndex: 1), 0)
        // B站 / 易听书 首章本地 0 基 = 0（SourceRouter 用 page-1 归一）→ 云端 0
        XCTAssertEqual(ChapterIdxNormalization.toCloud(src: SourceRegistry.BILI, localIndex: 0), 0)
        XCTAssertEqual(ChapterIdxNormalization.toCloud(src: SourceRegistry.YITINGSHU, localIndex: 0), 0)
        // 云端 0 回传：听友FM → 1（1 基表），B站/易听书 → 0
        XCTAssertEqual(ChapterIdxNormalization.toLocal(src: SourceRegistry.TINGYOU, cloudIdx: 0), 1)
        XCTAssertEqual(ChapterIdxNormalization.toLocal(src: SourceRegistry.BILI, cloudIdx: 0), 0)
        XCTAssertEqual(ChapterIdxNormalization.toLocal(src: SourceRegistry.YITINGSHU, cloudIdx: 0), 0)
        // 三源首章在云端口径必须完全一致（否则「同一本书」跨端仍错章）
        let firstCloudIdx: [String] = [SourceRegistry.TINGYOU, SourceRegistry.BILI, SourceRegistry.YITINGSHU]
            .map { src in
                let localFirst = ChapterIdxNormalization.isOneBased(src: src) ? 1 : 0
                return "\(ChapterIdxNormalization.toCloud(src: src, localIndex: localFirst))"
            }
        XCTAssertEqual(Set(firstCloudIdx), ["0"], "三源首章 chapter_idx 云端必须统一为 0")
    }

    /// 基底判定与数组位置换算（0 基源首章显示「1.」用）
    func testOneBasedDetectionAndArrayPositionMapping() {
        XCTAssertTrue(ChapterIdxNormalization.isOneBased(src: SourceRegistry.TINGYOU))
        XCTAssertFalse(ChapterIdxNormalization.isOneBased(src: SourceRegistry.BILI))
        XCTAssertFalse(ChapterIdxNormalization.isOneBased(src: SourceRegistry.YITINGSHU))
        XCTAssertEqual(ChapterIdxNormalization.toArrayPosition(src: SourceRegistry.TINGYOU, localIndex: 2), 1)
        XCTAssertEqual(ChapterIdxNormalization.toArrayPosition(src: SourceRegistry.BILI, localIndex: 2), 2)
        XCTAssertEqual(ChapterIdxNormalization.fromArrayPosition(src: SourceRegistry.BILI, position: 0), 0)
    }

    /// 静态守卫：入队 / 回传四个出口都必须经归一化，不得再直接透传 chapter.index / rec.chapterIdx。
    func testNormalizationIsSingleExitInSources() throws {
        let repo = try Self.source("TingYou/Services/AlbumRepository.swift")
        XCTAssertTrue(repo.contains("ChapterIdxNormalization.toCloud(src: src, localIndex: chapter.index)"),
                      "recordHistory 入队必须经 toCloud 换算（P0-1）")
        // 入队直传防护：enqueueProgress 的 chapterIdx 形参后紧跟 positionMs。
        // 本地 HistoryModel 写入（chapterIdx: chapter.index, chapterTitle: …）按源原生基底存
        // 是设计行为（tingyou 1 基表），不在本守卫范围——只拦「入队直传」。
        XCTAssertFalse(repo.contains("chapterIdx: chapter.index, positionMs"),
                       "入队不得再直传本地 chapter.index")
        XCTAssertTrue(repo.contains("chapterIdx: cloudIdx,"),
                      "入队必须使用 toCloud 换算后的 cloudIdx")

        let engine = try Self.source("TingYou/Services/SyncEngine.swift")
        XCTAssertTrue(engine.contains("ChapterIdxNormalization.toLocal(src: src, cloudIdx: ci)"),
                      "merge 更新分支必须经 toLocal 换算")
        XCTAssertTrue(engine.contains("ChapterIdxNormalization.toLocal(\n                                            src: src, cloudIdx: rec.chapterIdx ?? 0)")
                        || engine.contains("cloudIdx: rec.chapterIdx ?? 0"),
                      "merge 插入分支必须经 toLocal 换算")
        XCTAssertTrue(engine.contains("ChapterIdxNormalization.toCloud(\n                                      src: h.src, localIndex: h.chapterIdx)")
                        || engine.contains("toCloud(\n                                      src: h.src"),
                      "快照回传必须经 toCloud 换算")
        XCTAssertFalse(engine.contains("local.chapterIdx = rec.chapterIdx ?? local.chapterIdx"),
                       "回传不得再直传云端 chapter_idx")
    }

    // MARK: - P0-2 · 书架删除落云墓碑

    /// 客户端必须存在 progress delete 的 op 类型（原来只有收藏一处 delete）
    func testProgressDeleteOpExistsAndPayloadShape() {
        let suite = "b51-p02-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SyncLocalStore(defaults: defaults)

        // 未登录：不得入队（与既有 enqueue 语义一致）
        store.enqueueProgressDelete(src: SourceRegistry.TINGYOU, albumId: 12345, detailPath: nil)
        XCTAssertEqual(store.outboxCount, 0, "未登录时删除墓碑不得入队")

        store.saveCredentials(SyncLocalStore.Credentials(
            accessToken: "atk", refreshToken: "rtk", userId: "u1", email: "a@b.c",
            deviceId: "d1", accessExpireAtMs: 1, refreshExpireAtMs: 2))
        store.enqueueProgressDelete(src: SourceRegistry.TINGYOU, albumId: 12345, detailPath: nil)
        let ops = store.loadOutbox()
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].entity, "progress", "必须是 progress 实体（服务端该分支 op==='delete' 落墓碑）")
        XCTAssertEqual(ops[0].op, "delete", "op 必须是 delete（否则云端永不落墓碑、条目会复活）")
        XCTAssertEqual(ops[0].payload.album?.bookId, "12345", "payload 必须带 bookKey 所需的 album")
        XCTAssertNil(ops[0].payload.chapterIdx, "墓碑不带进度字段")
    }

    /// 收藏删除沿用既有墓碑出口（唯一入口 enqueueFavoriteDelete）
    func testFavoriteDeleteOpShape() {
        let suite = "b51-p02f-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SyncLocalStore(defaults: defaults)
        store.saveCredentials(SyncLocalStore.Credentials(
            accessToken: "atk", refreshToken: "rtk", userId: "u1", email: "a@b.c",
            deviceId: "d1", accessExpireAtMs: 1, refreshExpireAtMs: 2))
        store.enqueueFavoriteDelete(src: SourceRegistry.BILI, albumId: 1, detailPath: "BV1xx")
        let ops = store.loadOutbox()
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].entity, "favorite")
        XCTAssertEqual(ops[0].op, "delete")
        XCTAssertEqual(ops[0].payload.album?.bvid, "BV1xx", "bili 的 bookKey 用 bvid")
    }

    /// 静态守卫：书架三条删除路径必须经仓储（不再直写 SwiftData 绕过 outbox）
    func testShelfDeletePathsGoThroughRepository() throws {
        let shelf = try Self.source("TingYou/UI/Shelf/ShelfScreen.swift")
        XCTAssertTrue(shelf.contains("repo.deleteFavorite(src: f.src"),
                      "滑删收藏必须经 AlbumRepository（本地删 + favorite delete 入队）")
        XCTAssertTrue(shelf.contains("repo.deleteHistory(src: h.src"),
                      "滑删历史必须经 AlbumRepository（本地删 + progress delete 入队）")
        XCTAssertTrue(shelf.contains("await repo.clearAllHistories()"),
                      "清空历史必须经 AlbumRepository（逐条落墓碑）")

        let repo = try Self.source("TingYou/Services/AlbumRepository.swift")
        XCTAssertTrue(repo.contains("enqueueProgressDelete(src: src, albumId: albumId"),
                      "deleteHistory 必须入 progress delete")
        XCTAssertTrue(repo.contains("enqueueProgressDelete(src: h.src, albumId: h.albumId"),
                      "clearAllHistories 必须逐条入 progress delete")
    }

    // MARK: - P1-1 · 聚合搜索超时不拖垮整体

    /// 单源超时（3s 护栏）：一个源 30s 不返回时，其余源结果必须已产出、
    /// 且慢源以失败源名透出（不阻塞整轮、也不误报整体失败）。
    func testSlowSourceIsGuardedByTimeout() async {
        let suite = "b51-p11-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SourceEnabledStore(defaults: defaults)

        let searcher = B51FakeSearcher()
        searcher.results = [
            SourceRegistry.TINGYOU: [Self.album(1, "听友书", src: SourceRegistry.TINGYOU)],
            SourceRegistry.YITINGSHU: [Self.album(3, "易听书", src: SourceRegistry.YITINGSHU)],
        ]
        // B站模拟「挂住 30s」（弱网 / 站点慢响应）
        searcher.delayBySource[SourceRegistry.BILI] = 30_000_000_000

        let start = Date()
        let outcome = await AggregateSearcher(searcher: searcher, enabledStore: store)
            .search(keyword: "书", timeout: .milliseconds(600))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 3.0, "单源 30s 挂起不得拖住整轮（护栏生效），实测 \(elapsed)s")
        XCTAssertEqual(outcome.albums.map(\.title), ["听友书", "易听书"],
                       "其余源结果必须照常产出，且仍按固定序拼接")
        XCTAssertEqual(outcome.failedSourceNames, ["B站"], "超时源按失败源如实透出")
        XCTAssertFalse(outcome.allFailed, "只有一源超时不算整体失败")
    }

    /// 增量回填：慢源未返回时，快源结果必须已通过 onPartial 上屏（不再等全源收齐）
    func testPartialCallbackFillsFastSourcesFirst() async {
        let suite = "b51-p11b-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SourceEnabledStore(defaults: defaults)

        let searcher = B51FakeSearcher()
        searcher.results = [SourceRegistry.TINGYOU: [Self.album(1, "听友书", src: SourceRegistry.TINGYOU)]]
        searcher.delayBySource[SourceRegistry.BILI] = 30_000_000_000
        searcher.delayBySource[SourceRegistry.YITINGSHU] = 30_000_000_000

        // 收集所有 partial（MainActor 回调，用锁保护计数）
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var snapshots: [(count: Int, pending: Int)] = []
        }
        let box = Box()

        _ = await AggregateSearcher(searcher: searcher, enabledStore: store)
            .search(keyword: "书", timeout: .milliseconds(500)) { partial in
                box.lock.lock()
                box.snapshots.append((partial.albums.count, partial.pendingSourceCount))
                box.lock.unlock()
            }

        box.lock.lock()
        let snaps = box.snapshots
        box.lock.unlock()
        XCTAssertFalse(snaps.isEmpty, "必须有增量回调（逐源回填）")
        XCTAssertTrue(snaps.contains { $0.count == 1 && $0.pending >= 1 },
                      "首个回调应只有 1 条结果、仍有源未返回——证明是先上屏而非收齐后一次性给")
    }

    /// 单源超时的默认值是 3s（质检给出的护栏值），易听书 live 探测另设 2s
    func testTimeoutBudgetConstants() {
        XCTAssertEqual(AggregateSearcher.perSourceTimeout, .seconds(3), "单源护栏必须是 3s")
        XCTAssertEqual(YitingshuAdapter.liveSearchTimeout, .seconds(2), "易听书 live 探测必须单独 2s 上限")
    }

    // MARK: - P1-2 · push 结果 status 消费

    /// failed / 缺 id 的 op 必须留队（只有 success/duplicate 才移除）
    func testPushOnlyRemovesSuccessOrDuplicate() throws {
        let engine = try Self.source("TingYou/Services/SyncEngine.swift")
        XCTAssertTrue(engine.contains("case \"success\", \"duplicate\", \"ok\":"),
                      "只有 success/duplicate 计入已处理")
        XCTAssertTrue(engine.contains("lastPushFailedCount = failed"), "failed 必须计数（P1-2）")
        XCTAssertTrue(engine.contains("lastPushUnhandledCount = chunk.count"),
                      "缺 client_op_id 必须记账（P1-3 兜底）")
        XCTAssertTrue(engine.contains("store.removeOutbox(opIds: handled)"),
                      "必须只按 handled 移除，不能按整批 chunk 移除")
        XCTAssertFalse(engine.contains("store.removeOutbox(opIds: chunk.map"),
                       "禁止按整批 client_op_id 移除（那正是失败 op 静默丢失的原实现）")
    }

    // MARK: - P1-3 · outbox 三处边界

    /// 溢出淘汰优先保 delete（900 上限 + 含墓碑时不挤掉墓碑）
    func testOverflowEvictsUpsertBeforeDelete() {
        let suite = "b51-p13-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SyncLocalStore(defaults: defaults)
        store.saveCredentials(SyncLocalStore.Credentials(
            accessToken: "atk", refreshToken: "rtk", userId: "u1", email: "a@b.c",
            deviceId: "d1", accessExpireAtMs: 1, refreshExpireAtMs: 2))

        // 先放一条墓碑（最早入队，按理最该被淘汰）
        store.enqueueProgressDelete(src: SourceRegistry.TINGYOU, albumId: 999, detailPath: nil)
        // 再灌满 upsert，超出 cap 一条
        for i in 0..<SyncLocalStore.outboxCap {
            store.enqueueFavoriteUpsert(src: SourceRegistry.TINGYOU, albumId: Int64(i),
                                        title: "书\(i)", author: nil, coverUrl: nil, detailPath: nil)
        }
        XCTAssertEqual(store.outboxCount, SyncLocalStore.outboxCap, "总条数收敛到上限")
        XCTAssertTrue(store.loadOutbox().contains { $0.entity == "progress" && $0.op == "delete" },
                      "溢出必须优先淘汰 upsert，墓碑不得被挤掉（否则删除会复活）")
        XCTAssertEqual(store.droppedOpsTotal, 1, "淘汰必须记账（不再静默）")
        XCTAssertEqual(store.droppedDeleteTotal, 0, "正常淘汰不应丢任何 delete")
    }

    /// merge 落库失败必须不静默（try? 已移除）
    func testMergeDoesNotSwallowSaveError() throws {
        // 负向断言必须剥掉行注释再扫：SyncEngine 里「原 `try? ctx.save()` 把落库失败吞成 nil」
        // 是改动说明注释（合法保留），直接 contains 会误伤。
        let engine = Self.strippingLineComments(try Self.source("TingYou/Services/SyncEngine.swift"))
        XCTAssertFalse(engine.contains("try? ctx.save()"),
                       "merge 不得再用 try? 吞掉落库失败（违背「落库失败不允许静默」）")
        XCTAssertTrue(engine.contains("print(\"❌ sync merge save failed"),
                      "save 失败必须打印")
        XCTAssertTrue(engine.contains("return false"), "save 失败必须回传失败，调用方不得推进游标")
        XCTAssertTrue(engine.contains("guard merged else { return false }"),
                      "落库失败不得推进 server_seq 游标")
    }

    // MARK: - 音源残留（属「去掉多余音源」主题）

    /// 书音FM 死代码必须整体删除（不再随包编译）
    func testMekuiAdapterRemoved() {
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectDir + "/TingYou/Services/MekuiAdapter.swift"),
                       "MekuiAdapter.swift 必须删除（221 行死代码曾随包编译进 IPA）")
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectDir + "/TingYouTests/MekuiAdapterTests.swift"),
                       "MekuiAdapterTests.swift 必须随适配器删除")
    }

    /// 已下架源 7 条主机不得留在证书白名单（收敛，但不误伤在役三源）
    func testDelistedHostsConvergedFromAllowlist() {
        let delisted = [
            "m.ting15.com", "www.ting08.com",
            "m.mekui.com", "api.mekui.com",
            "api.aikeu.com", "mp3.aikeu.com",
            "shuyinfm.oss-cn-hangzhou.aliyuncs.com",
        ]
        for host in delisted {
            XCTAssertFalse(PinnedDomainAllowlist.isAllowed(host), "已下架源主机 \(host) 必须从白名单摘除")
        }
        // 必守口径：在役三源 + 云同步必须仍放行
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("tingyou.fm"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("file.hgeuz.cn"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("api.bilibili.com"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("www.yitingshu.com"))
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("aod.cos.tx.xmcdn.com"))
        XCTAssertFalse(PinnedDomainAllowlist.isAllowed("xmcdn.com"), "易听书未整域放行 xmcdn.com")
        XCTAssertTrue(PinnedDomainAllowlist.isAllowed("tingshu-d2gjera4688800c8e.service.tcloudbase.com"))
    }

    /// 版本升位：b51 双处一致（project.yml 由 Build29 守卫，此处复核 Info.plist）
    func testBuild51Version() throws {
        let plist = try Self.source("TingYou/Info.plist")
        XCTAssertTrue(plist.contains("<string>55</string>"), "Info.plist CFBundleVersion 必须为 55")
        XCTAssertTrue(plist.contains("<string>1.4.4</string>"), "CFBundleShortVersionString 维持 1.4.4")
    }

    // MARK: - 工具

    private static func album(_ id: Int64, _ title: String, src: String) -> Album {
        Album(albumId: id, title: title, author: nil, teller: nil, coverUrl: nil, intro: nil,
              category: nil, categoryId: nil, type: nil, typeId: nil, status: nil,
              chapterCount: nil, updatedAt: nil, playCount: nil, available: true,
              source: src, detailPath: "/\(id)")
    }

    private static func source(_ rel: String) throws -> String {
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        let path = projectDir + "/" + rel
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    /// 剥掉每行首个 `//` 之后的注释段（含说明性反引号代码引用），供负向 contains 守卫使用。
    /// 粗粒度即可：目标文件里的 `https://` 会被截断，但不影响本守卫的匹配串。
    private static func strippingLineComments(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                if let r = line.range(of: "//") {
                    return String(line[line.startIndex..<r.lowerBound])
                }
                return String(line)
            }
            .joined(separator: "\n")
    }

    /// 可按源注入延迟的假搜索路由（P1-1 护栏用）
    final class B51FakeSearcher: SourceSearching, @unchecked Sendable {
        var results: [String: [Album]] = [:]
        var delayBySource: [String: UInt64] = [:]
        func search(src: String, keyword: String) async throws -> [Album] {
            if let d = delayBySource[src] { try? await Task.sleep(nanoseconds: d) }
            return results[src] ?? []
        }
    }
}
