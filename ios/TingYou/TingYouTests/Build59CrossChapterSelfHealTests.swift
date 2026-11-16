import XCTest
import Observation
@testable import TingYou

/// build 59 · P1-1：**跨章 403 自愈守卫**的行为级用例（复检指出修复 4 的四条用例
/// 全部把「失败章」与「当前章」设为同一章，跨章场景零覆盖）。
///
/// 缺陷（b58 实测逐行取证）：`requestForbiddenSelfHeal` 只按 `ownerKey` 记账，
/// **从不比对 `currentChapterIdx`**，随后无条件 `rebuildForMirrorRetry()`——而该函数
/// 重载的是**当前章**。触发链：A 起播 → 用户切到 B → A 的 403 迟到（`didCancel` 是
/// 空实现、`loaderTasks` 切章从不清空）→ 清 A 缓存（正确）→ 却清空**属于 B 的**
/// `mirrorCandidates` 并重载 B：①B 被拆条重建、播放中断 ②修复 3 刚建立的镜像保护
/// 被击穿（B 下次 403 只能 `exhausted 0` 终局）③自愈额度记在 A 名下，B 失去机会。
///
/// 判别力口径：全部驱动**生产同一份实现**（`handleChapterLoadFailure` /
/// `requestForbiddenSelfHeal` / `rebuildForMirrorRetry` / `prepareCachedServe`），
/// 切章走生产入口 `playChapter(at:)`，不自造索引。「有没有偷偷重载当前章」用
/// `chapterLoadCountForTesting`（`loadCurrentChapter` 的累计调用次数）取证——
/// 镜像链条数会被「清后又装回」掩盖，重载次数不会。
final class Build59CrossChapterSelfHealTests: XCTestCase {

    // MARK: - 工具（与 Build58 同构）

    private func isolatedSkipStore() -> SkipSettingsStore {
        let suite = "Build59CrossChapter-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("无法创建隔离 UserDefaults suite：\(suite)")
            return SkipSettingsStore()
        }
        return SkipSettingsStore(defaults: defaults)
    }

    private func makeAlbum(src: String, albumId: Int64, title: String = "跨章测试书") -> Album {
        Album(albumId: albumId, title: title, author: nil, teller: nil,
              coverUrl: nil, intro: nil, category: nil, categoryId: nil,
              type: nil, typeId: nil, status: nil, chapterCount: nil,
              updatedAt: nil, playCount: nil, available: true,
              source: src, detailPath: nil)
    }

    private func oneBasedChapters(_ n: Int) -> [Chapter] {
        (1...n).map { Chapter(chapterId: Int64($0), index: $0,
                              title: "第\($0)章", durationSec: 1_500) }
    }

    /// 该书的第 n 章占位 URI（生产构造口径：`chapterIdx: ch.index`）。
    private func key(_ album: Album, _ chapter: Chapter) -> String {
        PlayUri.build(src: album.source, albumId: album.albumId, chapterIdx: chapter.index)
    }

    private static let biliUrl = "https://upos-sz-mirrorcos.bilivideo.com/audio/x.m4s?sig=aaa"
    private static let biliMirror1 = "https://upos-sz-mirrorali.bilivideo.com/audio/x.m4s?sig=bbb"
    private static let biliMirror2 = "https://cn-sh-cc-01.akamaized.net/audio/x.m4s?sig=ccc"

    // MARK: - 用例① A 迟到 403 到达时当前章为 B

    /// 行为级（b58 实现必红：它会清 B 的镜像链 + 重载 B + 把额度记给 A）。
    ///
    /// 断言四件事，正对缺陷的三重后果：
    /// * A 的缓存被清（正确行为，必须保留——否则 A 再成为当前章会踩同一条过期直链）；
    /// * B 的 `mirrorCandidates` 条数不变（修复 3 的镜像保护不被击穿）；
    /// * B 未被重载（`loadCurrentChapter` 次数不变 ⇒ 条目没被拆条重建 ⇒ 播放不中断）；
    /// * 自愈额度没记到 A 名下（计数仍 0 ⇒ B 仍有自己的机会）。
    @MainActor
    func testLateForbiddenForPreviousChapterDoesNotTouchCurrentChapter() throws {
        let album = makeAlbum(src: SourceRegistry.BILI, albumId: 9100)
        let chapters = oneBasedChapters(4)
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(0), startPosMs: 120_000, silentWrite: false)

        // A = 第 1 章（数组位置 0）；先给它准备一条会过期的签名直链缓存。
        let keyA = key(album, chapters[0])
        pm.seedResolvedCacheForTesting(key: keyA, url: Self.biliUrl)
        XCTAssertEqual(pm.prepareCachedServe(forKey: keyA), Self.biliUrl, "前置：A 的缓存可命中")

        // 用户切到 B（第 2 章），B 播放中；修复 3 从缓存补好 B 的镜像链。
        pm.playChapter(at: 1)
        XCTAssertEqual(pm.currentChapterIdx, 1, "前置：当前章已切到 B")
        pm.setMirrorChainForTesting([Self.biliMirror1, Self.biliMirror2])
        XCTAssertEqual(pm.mirrorCandidatesCountForTesting, 2, "前置：B 的镜像链已装好 2 条")

        let loadsBefore = pm.chapterLoadCountForTesting
        let idxBefore = pm.currentChapterIdx

        // A 的 403 迟到（异步信号：A 早已不是当前章）。
        pm.handleChapterLoadFailure(ownerKey: keyA, statusCode: 403,
                                    sourceHost: "upos-sz-mirrorcos.bilivideo.com")

        XCTAssertNil(pm.prepareCachedServe(forKey: keyA),
                     "A 的过期缓存必须仍被清掉（修复 2 的淘汰语义不得因跨章守卫而丢失）")
        XCTAssertEqual(pm.mirrorCandidatesCountForTesting, 2,
                       "跨章迟到 403 不得清空当前章 B 的镜像链（修复 3 的镜像保护不被击穿）")
        XCTAssertEqual(pm.chapterLoadCountForTesting, loadsBefore,
                       "跨章迟到 403 不得重载当前章 B（重载即拆条重建 = 播放中断 + 镜像链重建）")
        XCTAssertEqual(pm.currentChapterIdx, idxBefore, "当前章必须仍是 B（不得被迟到的旧章信号改道）")
        XCTAssertEqual(pm.forbiddenSelfHealCountForTesting, 0,
                       "跨章迟到 403 不得记账：那一刻没有为任何章执行自愈，额度不得记到 A 名下")
    }

    /// 行为级（缺陷后果③）：A 的迟到 403 之后，B **自己**的 403 仍必须能自愈一次。
    /// 旧实现里 A 的 403 已把额度记在 A 名下、且已重载过 B——B 真遇到 403 时只能终局。
    @MainActor
    func testCurrentChapterKeepsItsOwnSelfHealChanceAfterPreviousChapterSignal() throws {
        let album = makeAlbum(src: SourceRegistry.BILI, albumId: 9101)
        let chapters = oneBasedChapters(4)
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(0), startPosMs: 0, silentWrite: false)
        pm.playChapter(at: 1)
        pm.setMirrorChainForTesting([Self.biliMirror1, Self.biliMirror2])
        let keyA = key(album, chapters[0])
        let keyB = key(album, chapters[1])

        pm.handleChapterLoadFailure(ownerKey: keyA, statusCode: 403, sourceHost: "bilivideo.com")
        XCTAssertEqual(pm.forbiddenSelfHealCountForTesting, 0, "前置：A 的迟到信号不占额度")
        XCTAssertEqual(pm.mirrorCandidatesCountForTesting, 2, "前置：B 的镜像链仍在")

        // B 自己真的 403（当前章 = B）：必须自愈一次，且清掉 B 自己的过期链。
        pm.handleChapterLoadFailure(ownerKey: keyB, statusCode: 403, sourceHost: "bilivideo.com")
        XCTAssertEqual(pm.forbiddenSelfHealCountForTesting, 1,
                       "当前章 B 必须拿到自己的那一次自愈（不得被 A 的迟到信号剥夺）")
        XCTAssertEqual(pm.mirrorCandidatesCountForTesting, 0,
                       "B 自愈时清的是 B 自己的同批过期链（这才是应当被清的那一条）")
    }

    // MARK: - 用例② A 重新成为当前章后再遇 403 仍能自愈一次

    /// 行为级：额度按**装载轮次**重置——A 重新成为当前章必然经过一次主动装载
    ///（点章 / 切章 / 重试），那一轮账清空 ⇒ A 重新获得一次自愈机会。
    /// 这同时回答复检问题「迟到 403 的章节再次成为当前章时是否还有自愈机会」：有。
    @MainActor
    func testPreviousChapterRegainsOneSelfHealWhenItBecomesCurrentAgain() throws {
        let album = makeAlbum(src: SourceRegistry.BILI, albumId: 9102)
        let chapters = oneBasedChapters(4)
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(0), startPosMs: 0, silentWrite: false)
        let keyA = key(album, chapters[0])

        pm.playChapter(at: 1)                                  // 切到 B
        pm.handleChapterLoadFailure(ownerKey: keyA, statusCode: 403, sourceHost: "bilivideo.com")
        XCTAssertEqual(pm.forbiddenSelfHealCountForTesting, 0, "前置：跨章时 A 未用额度")

        pm.playChapter(at: 0)                                  // 用户又点回 A（新的一轮装载）
        XCTAssertEqual(pm.currentChapterIdx, 0, "前置：A 重新成为当前章")
        pm.setMirrorChainForTesting([Self.biliMirror1, Self.biliMirror2])

        let loadsBefore = pm.chapterLoadCountForTesting
        pm.handleChapterLoadFailure(ownerKey: keyA, statusCode: 403, sourceHost: "bilivideo.com")

        XCTAssertEqual(pm.forbiddenSelfHealCountForTesting, 1,
                       "A 重新成为当前章后必须重新获得一次自愈机会（否则该章永久终局）")
        XCTAssertEqual(pm.chapterLoadCountForTesting, loadsBefore + 1,
                       "这一次是**当前章**的 403：必须真的重载当前章（现解析拿新签名）")
        XCTAssertEqual(pm.mirrorCandidatesCountForTesting, 0,
                       "当前章自愈时清同批过期链，等现解析重新装链")
    }

    // MARK: - 用例③ 同章二次 403 终局（跨章场景下的护栏）

    /// 行为级：同一章（当前章）第二次 403 不再自愈、不再重载，计数保持 1。
    /// 防 403 风暴：签名若整体失效，无限自愈会打出 playurl 请求风暴并触发 B站 412 风控。
    @MainActor
    func testSameChapterSecondForbiddenIsTerminalEvenAfterChapterSwitch() throws {
        let album = makeAlbum(src: SourceRegistry.BILI, albumId: 9103)
        let chapters = oneBasedChapters(4)
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(0), startPosMs: 0, silentWrite: false)
        pm.playChapter(at: 1)                                  // B 为当前章
        let keyB = key(album, chapters[1])

        pm.handleChapterLoadFailure(ownerKey: keyB, statusCode: 403, sourceHost: "bilivideo.com")
        XCTAssertEqual(pm.forbiddenSelfHealCountForTesting, 1, "第一次当前章 403 自愈一次")
        let loadsAfterFirst = pm.chapterLoadCountForTesting

        pm.handleChapterLoadFailure(ownerKey: keyB, statusCode: 403, sourceHost: "bilivideo.com")
        XCTAssertEqual(pm.forbiddenSelfHealCountForTesting, 1,
                       "同章第二次 403 不得再自愈（防 playurl 风暴 + 412 风控）")
        XCTAssertEqual(pm.chapterLoadCountForTesting, loadsAfterFirst,
                       "终局判定不得再重载（否则等于换了个方式继续打 playurl）")
        XCTAssertEqual(pm.currentChapterIdx, 1, "终局后当前章不变（错误由 .failed 分支透出）")
    }

    /// 行为级：非当前章的 403 连续到达也不会挤占额度，且始终不重载当前章。
    ///（把「迟到信号」这件事与「来几次」解耦：不是靠次数撞额度，而是靠归属判定。）
    @MainActor
    func testRepeatedLateSignalsForOtherChapterNeverReloadCurrentChapter() throws {
        let album = makeAlbum(src: SourceRegistry.BILI, albumId: 9104)
        let chapters = oneBasedChapters(4)
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(0), startPosMs: 0, silentWrite: false)
        pm.playChapter(at: 2)                                  // C 为当前章
        pm.setMirrorChainForTesting([Self.biliMirror1])
        let keyA = key(album, chapters[0])
        let loadsBefore = pm.chapterLoadCountForTesting

        for _ in 0..<3 {
            pm.handleChapterLoadFailure(ownerKey: keyA, statusCode: 403, sourceHost: "bilivideo.com")
        }

        XCTAssertEqual(pm.chapterLoadCountForTesting, loadsBefore,
                       "三次旧章迟到信号都不得触发任何重载")
        XCTAssertEqual(pm.mirrorCandidatesCountForTesting, 1, "当前章 C 的镜像链始终不动")
        XCTAssertEqual(pm.forbiddenSelfHealCountForTesting, 0, "始终不记账")
        XCTAssertEqual(pm.currentChapterIdx, 2, "当前章始终是 C")
    }

    /// 行为级：同书同源但**不同章**的 key 不因章号 coincidences 被判为当前章；
    /// 不同书（albumId 不同）即使章号相同也必须判为非当前章（纵深防御）。
    @MainActor
    func testGuardComparesSourceAlbumAndChapterIndex() throws {
        let album = makeAlbum(src: SourceRegistry.BILI, albumId: 9105)
        let chapters = oneBasedChapters(4)
        let pm = PlaybackManager(playbackRepository: nil, skipStore: isolatedSkipStore())
        pm.prepareQueue(album: album, chapters: chapters,
                        start: .arrayPosition(1), startPosMs: 0, silentWrite: false)
        let loadsBefore = pm.chapterLoadCountForTesting

        // 同章号、不同书：不得判为当前章。
        let otherAlbumKey = PlayUri.build(src: SourceRegistry.BILI, albumId: 9999,
                                          chapterIdx: chapters[1].index)
        pm.handleChapterLoadFailure(ownerKey: otherAlbumKey, statusCode: 403, sourceHost: "bilivideo.com")
        XCTAssertEqual(pm.forbiddenSelfHealCountForTesting, 0, "不同 albumId 的 403 不得自愈当前章")
        XCTAssertEqual(pm.chapterLoadCountForTesting, loadsBefore, "不得因它重载当前章")

        // 同书同源、别的章：不得判为当前章。
        let otherChapterKey = key(album, chapters[2])
        pm.handleChapterLoadFailure(ownerKey: otherChapterKey, statusCode: 403, sourceHost: "bilivideo.com")
        XCTAssertEqual(pm.forbiddenSelfHealCountForTesting, 0, "别的章号的 403 不得自愈当前章")
        XCTAssertEqual(pm.chapterLoadCountForTesting, loadsBefore, "不得因它重载当前章")
    }

    // MARK: - 形态守卫（声明级 needle + 剔整行注释）

    /// P1-1 的接线与**顺序**必须可从源码证：守卫在清链之前、清链在重载之前。
    /// 顺序是本缺陷的本质——b58 里「清链 + 重载」无条件执行，且中间没有当前章比对。
    func testSelfHealGuardOrderIsWiredInProduction() throws {
        let code = Self.codeOnly(try Self.source("TingYou/Playback/PlaybackManager.swift"))

        let healBody = Self.functionBody(of: code, needle: "func requestForbiddenSelfHeal")
        XCTAssertFalse(healBody.isEmpty, "必须截到 requestForbiddenSelfHeal 函数体")

        guard let guardIdx = healBody.range(of: "isCurrentChapterOwnerKey(ownerKey)")?.lowerBound else {
            XCTFail("自愈必须先比对 ownerKey 是否指向当前章（P1-1 的唯一判别点）")
            return
        }
        guard let clearIdx = healBody.range(of: "mirrorCandidates = []")?.lowerBound else {
            XCTFail("自愈必须清同批过期镜像链")
            return
        }
        guard let rebuildIdx = healBody.range(of: "rebuildForMirrorRetry()")?.lowerBound else {
            XCTFail("自愈必须复用镜像重建唯一生产入口（另写一套会漏传 silentWrite）")
            return
        }
        XCTAssertLessThan(guardIdx, clearIdx,
                          "当前章守卫必须在清镜像链之前（否则先清已把当前章的保护击穿）")
        XCTAssertLessThan(clearIdx, rebuildIdx, "清链必须在重载之前")
        XCTAssertTrue(healBody.contains("guard self.isCurrentChapterOwnerKey"),
                      "必须是 guard 早退（不是 if 里包一层仍在后面继续跑）")

        // 记账必须在守卫之后：跨章迟到信号不得插入 forbiddenSelfHealKeys。
        guard let insertIdx = healBody.range(of: "forbiddenSelfHealKeys.insert")?.lowerBound else {
            XCTFail("自愈必须按章记账（只自愈一次）")
            return
        }
        XCTAssertLessThan(guardIdx, insertIdx,
                          "记账必须在当前章守卫之后（跨章迟到 403 不得占用额度）")

        // 判定函数本身必须真的比对 src / albumId / 章 index（不是恒 true 的占位）。
        let predicate = Self.functionBody(of: code, needle: "func isCurrentChapterOwnerKey")
        XCTAssertFalse(predicate.isEmpty, "必须截到 isCurrentChapterOwnerKey 函数体")
        XCTAssertTrue(predicate.contains("parsed.src == album.source"), "必须比对源")
        XCTAssertTrue(predicate.contains("parsed.albumId == album.albumId"), "必须比对书")
        XCTAssertTrue(predicate.contains(".index == parsed.chapterIdx"),
                      "必须把当前章 Chapter.index 与 URI 的 chapter_idx 比对（同章不同书不得混判）")

        // 判定与重载必须在同一主线程时点原子完成（否则守卫与重载之间仍可被切章插队）。
        XCTAssertTrue(healBody.contains("Thread.isMainThread"),
                      "自愈必须在主线程判定（currentChapterIdx 是主线程状态）")
        XCTAssertTrue(healBody.contains("DispatchQueue.main.async"),
                      "非主线程调用必须切主队列，且与判定同批执行")
    }

    /// 零回退：b55–b58 闸门标识符与镜像重建唯一入口，本版不得因新增守卫而退化。
    func testGateIdentifiersStillIntact() throws {
        let code = Self.codeOnly(try Self.source("TingYou/Playback/PlaybackManager.swift"))
        XCTAssertEqual(code.components(separatedBy: "guard !historyWriteSuppressed").count - 1, 1,
                       "recordHistory 入口闸门必须唯一（b55 P1-2）")
        let releaseCalls = code.split(separator: "\n").filter {
            $0.contains("releaseHistorySuppression()") && !$0.contains("private func")
        }
        XCTAssertEqual(releaseCalls.count, 2,
                       "releaseHistorySuppression 全库必须恰 2 处调用（b56 P1-A 零回退）")
        XCTAssertTrue(code.contains("} else if !keepMirrorChain {"),
                      "闸门分支必须仍是 else if !keepMirrorChain（镜像重建不解除抑制）")
        let rebuild = Self.functionBody(of: code, needle: "func rebuildForMirrorRetry")
        XCTAssertTrue(rebuild.contains("silentWrite: self.historyWriteSuppressed"),
                      "rebuildForMirrorRetry 仍是镜像重建唯一生产入口的内部透传点")
        // 自愈的调用点仍只有「当前章守卫放行后的那一处」（本轮未新增重建调用点）。
        let rebuildCalls = code.split(separator: "\n").filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.contains("rebuildForMirrorRetry()") && !t.hasPrefix("func ")
        }
        XCTAssertEqual(rebuildCalls.count, 3,
                       "rebuildForMirrorRetry 生产调用点仍为 3 处（statusObserver / 看门狗 / 自愈）")
    }

    // MARK: - 工具：源码读取 / 剔注释 / 截函数体（与 Build58 同实现）

    private static func source(_ rel: String) throws -> String {
        let testDir = (#filePath as NSString).deletingLastPathComponent
        let projectDir = (testDir as NSString).deletingLastPathComponent
        let path = projectDir + "/" + rel
        guard FileManager.default.fileExists(atPath: path) else {
            XCTFail("\(rel) 不存在：\(path)——路径布局变化时请同步修正本测试")
            throw NSError(domain: "Build59CrossChapterSelfHealTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "missing source \(rel)"])
        }
        guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("\(rel) 不可读：\(path)")
            throw NSError(domain: "Build59CrossChapterSelfHealTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "unreadable source \(rel)"])
        }
        return src
    }

    private static func codeOnly(_ src: String) -> String {
        src.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func functionBody(of code: String, needle: String) -> String {
        let lines = code.split(separator: "\n").map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains(needle) }) else { return "" }
        var body: [String] = []
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if Self.isFunctionDeclarationLine(trimmed) && !body.isEmpty { break }
            body.append(line)
        }
        return body.joined(separator: "\n")
    }

    private static func isFunctionDeclarationLine(_ trimmed: String) -> Bool {
        let modifiers = ["", "private ", "fileprivate ", "internal ", "public ",
                         "override ", "final ", "static ", "private static ",
                         "fileprivate static ", "class "]
        return modifiers.contains { mod in
            trimmed.hasPrefix(mod + "func ") || trimmed.hasPrefix(mod + "deinit {")
        }
    }
}
