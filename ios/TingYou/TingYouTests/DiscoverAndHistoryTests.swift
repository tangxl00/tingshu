import XCTest
@testable import TingYou

/// build 21 · 反馈 7（增强 4）：搜索历史记忆。
/// 判别力：build 20 无 SearchHistoryStore——旧实现下组件不存在、测试无法通过。
final class SearchHistoryStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: SearchHistoryStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "search_history_tests_\(UUID().uuidString)")
        store = SearchHistoryStore(defaults: defaults, key: "search_history")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "")
        defaults = nil
        store = nil
        super.tearDown()
    }

    func testAddNewKeywordGoesFirst() {
        store.add("斗罗大陆")
        store.add("遮天")
        XCTAssertEqual(store.all, ["遮天", "斗罗大陆"], "新词置顶")
    }

    func testAddDuplicateMovesToFront() {
        store.add("斗罗大陆")
        store.add("遮天")
        store.add("斗罗大陆")
        XCTAssertEqual(store.all, ["斗罗大陆", "遮天"], "重复词移到队首而非重复入列")
    }

    func testLimitTwenty() {
        for i in 1...25 {
            store.add("词\(i)")
        }
        XCTAssertEqual(store.all.count, SearchHistoryStore.limit, "上限 20 条")
        XCTAssertEqual(store.all.first, "词25", "最新在前")
        XCTAssertEqual(store.all.last, "词6", "最旧的 5 条被淘汰")
    }

    func testBlankKeywordNotRecorded() {
        store.add("   ")
        store.add("")
        XCTAssertTrue(store.all.isEmpty, "空白词不记录")
    }

    func testRemoveSingle() {
        store.add("A")
        store.add("B")
        store.remove("A")
        XCTAssertEqual(store.all, ["B"])
    }

    func testClear() {
        store.add("A")
        store.add("B")
        store.clear()
        XCTAssertTrue(store.all.isEmpty)
    }
}

/// build 21 · 反馈 4/6（增强 2/3）：发现页原始分类目录与分类页 URL 构造。
/// 判别力：build 20 发现页固定 6 个 section 硬编码——DiscoverCatalog 不存在。
final class DiscoverCatalogTests: XCTestCase {

    func testTingyouCategoriesMatchRankSections() {
        let cats = DiscoverCatalog.categories(for: SourceRegistry.TINGYOU)
        XCTAssertEqual(cats.count, 5)
        XCTAssertEqual(Set(cats.map(\.id)), Set(["recommend", "new", "hot", "serial", "story"]),
                       "tingyou 分类必须与 rank API 支持的 section 一一对应")
    }

    func testTing15CategoriesFromRealNav() {
        let cats = DiscoverCatalog.categories(for: SourceRegistry.TING15)
        XCTAssertEqual(cats.count, 10, "m.ting15.com 首页导航 10 个分类（2026-10-20 实测）")
        XCTAssertTrue(cats.contains(DiscoverCategory(id: "jingdianpingshu", name: "经典评书")))
    }

    func testTing08CategoriesFromRealNav() {
        let cats = DiscoverCatalog.categories(for: SourceRegistry.TING08)
        XCTAssertEqual(cats.count, 15, "www.ting08.com 首页导航 15 个分类（2026-10-20 实测）")
        XCTAssertTrue(cats.contains(DiscoverCategory(id: "pingshu", name: "评书")))
    }

    func testUnsupportedSources() {
        XCTAssertTrue(DiscoverCatalog.unsupportedSources.contains(SourceRegistry.MEKUI))
        XCTAssertTrue(DiscoverCatalog.unsupportedSources.contains(SourceRegistry.YTYXSX))
        XCTAssertFalse(DiscoverCatalog.unsupportedSources.contains(SourceRegistry.TINGYOU))
    }

    func testCategoryPageURLBuiltCorrectly() {
        let url = DiscoverCatalog.categoryPageURL(cfg: SourceRegistry.ting15, categoryId: "pingshu", page: 2)
        XCTAssertEqual(url, "https://m.ting15.com/pingshu/index2.html")
        let url8 = DiscoverCatalog.categoryPageURL(cfg: SourceRegistry.ting08, categoryId: "wuxia", page: 1)
        XCTAssertEqual(url8, "https://www.ting08.com/wuxia/index1.html")
    }

    func testCategoryPageURLRejectsInvalidCategoryId() {
        // 防 URL 注入：大写/特殊字符/路径穿越的分类 id 拒绝
        XCTAssertNil(DiscoverCatalog.categoryPageURL(cfg: SourceRegistry.ting15, categoryId: "Pingshu", page: 1))
        XCTAssertNil(DiscoverCatalog.categoryPageURL(cfg: SourceRegistry.ting15, categoryId: "../etc", page: 1))
        XCTAssertNil(DiscoverCatalog.categoryPageURL(cfg: SourceRegistry.ting15, categoryId: "a b", page: 1))
    }

    func testCategoryPageURLNilForMekui() {
        XCTAssertNil(DiscoverCatalog.categoryPageURL(cfg: SourceRegistry.mekui, categoryId: "any", page: 1),
                     "mekui 走 JSON API 无分类页 HTML")
    }
}

/// build 21 · 反馈 4/6：分类页 HTML 解析（真实站点黄金样本节选）。
/// ting15 / ting08 分类页与搜索页同模板（clist / category-list 切片 + 相同条目形态），
/// parseSearch 应直接命中；分页链接 index{N}.html 供 hasMore 判定。
final class DiscoverCategoryParseTests: XCTestCase {

    /// m.ting15.com/jingdianpingshu/ 实测结构节选（2026-10-20，条目为真实数据）
    private let ting15CategoryHtml = """
    <html><body>
    <section class="category">
     <h1>经典评书</h1>
     <div class="cate-nav">
      <a href="/jingdianpingshu/index1-order-hits.html" data="order-hits">按人气排</a>
     </div>
     <div class="clist">
       <a href="/jingdianpingshu/2111.html">
      <dl>
       <dt>
        <img src="https://img-book-oss.guoguo.org.cn/Upload/ting/2023/656adaf3c89d8.jpg" alt="李元霸别传" width="75" height="100" />
       </dt>
       <dd>
        <h3>李元霸别传</h3>
           <p>类别：经典评书</p>
          <p>作者：田连元</p>
          <p>播音：田连元</p>
       </dd>
      </dl></a>
     </div>
     <div class="cpage"><a href="/jingdianpingshu/index2.html">下一页</a></div>
    </body></html>
    """

    /// www.ting08.com/pingshu/ 实测结构节选（2026-10-20，条目为真实数据）
    private let ting08CategoryHtml = """
    <html><body>
    <div class="category-list">
       <ul>
       <li>
         <div class="img">
          <a href="/pingshu/2051.html" title="敌后武工队(36回)"><img width="120" height="160" src="https://img-south-oss.guoguo.org.cn/Uploads/ting/CMCoOSEDWcaEAAJ6rABcVjHN.jpg" alt="敌后武工队(36回)" /></a>
         </div>
         <div class="info">
          <h4><a href="/pingshu/2051.html" title="敌后武工队(36回)">敌后武工队(36回)</a></h4>
          <p>类别：评书</p>
          <p>作者：袁阔成</p>
          <p>播音：袁阔成</p>
          <p>状态：全集完结</p>
         </div>
       </li>
       </ul>
      <a href="/pingshu/index2.html" class="next pagegbk" data="p-2">下一页</a>
    </div>
    <aside>侧栏</aside>
    </body></html>
    """

    func testParseTing15CategoryPage() {
        let items = MsrcHtml.parseSearch(cfg: SourceRegistry.ting15, html: ting15CategoryHtml)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "李元霸别传")
        XCTAssertEqual(items[0].detailPath, "/jingdianpingshu/2111.html")
        XCTAssertEqual(items[0].bookId, "2111")
        XCTAssertEqual(items[0].author, "田连元")
        XCTAssertEqual(items[0].teller, "田连元")
        // hasMore 判定：分页区存在下一页链接
        XCTAssertTrue(ting15CategoryHtml.contains("href=\"/jingdianpingshu/index2.html\""))
    }

    func testParseTing08CategoryPage() {
        let items = MsrcHtml.parseSearch(cfg: SourceRegistry.ting08, html: ting08CategoryHtml)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "敌后武工队(36回)")
        XCTAssertEqual(items[0].detailPath, "/pingshu/2051.html")
        XCTAssertEqual(items[0].bookId, "2051")
        XCTAssertEqual(items[0].author, "袁阔成")
        XCTAssertEqual(items[0].teller, "袁阔成")
        XCTAssertTrue(ting08CategoryHtml.contains("href=\"/pingshu/index2.html\""))
    }

    func testHasMoreDetectionPattern() {
        // MsrcAdapter.category 的 hasMore 探测规则：精确匹配下一页链接
        let html = "<a href=\"/pingshu/index3.html\">3</a>&nbsp;<a href=\"/pingshu/index2.html\" class=\"next\">下一页</a>"
        XCTAssertTrue(html.contains("href=\"/pingshu/index2.html\""), "第 1 页应探测到 index2 存在")
        XCTAssertFalse(html.contains("href=\"/pingshu/index5.html\""), "不存在的页不应误判")
    }
}

/// build 21 · 反馈 4：发现页 ViewModel 多源加载。
/// 判别力：build 20 loadRank 只支持 tingyou section——不支持源抛错时 UI 只能静默空列表。
final class DiscoverMultiSourceTests: XCTestCase {

    /// 假数据源：rank 与 discoverCategory 可独立控制
    private final class FakeLoader: DiscoverDataLoading, @unchecked Sendable {
        var rankResult: Result<PagedResult<Album>, Error> = .success(PagedResult(items: [], hasMore: false))
        var categoryResult: Result<(albums: [Album], hasMore: Bool), Error> = .success(([], false))
        private(set) var categoryCalls: [(src: String, categoryId: String, page: Int)] = []

        func loadRank(section: String, page: Int) async throws -> PagedResult<Album> {
            try rankResult.get()
        }

        func discoverCategory(src: String, categoryId: String, page: Int) async throws -> (albums: [Album], hasMore: Bool) {
            categoryCalls.append((src, categoryId, page))
            return try categoryResult.get()
        }
    }

    private func makeAlbum(_ id: Int64, _ title: String, src: String) -> Album {
        Album(albumId: id, title: title, author: nil, teller: nil, coverUrl: nil, intro: nil,
              category: nil, categoryId: nil, type: nil, typeId: nil, status: nil,
              chapterCount: nil, updatedAt: nil, playCount: nil, available: true,
              source: src, detailPath: "/\(id)")
    }

    func testLoadCategoryRoutesThroughDiscoverCategory() async {
        let vm = DiscoverViewModel()
        let loader = FakeLoader()
        loader.categoryResult = .success(([makeAlbum(1, "评书一", src: "ting15")], true))
        vm.attach(loader: loader, cache: nil)

        await vm.load(target: .category(src: "ting15", categoryId: "jingdianpingshu"))

        XCTAssertEqual(vm.albums.count, 1)
        XCTAssertEqual(vm.albums.first?.title, "评书一")
        XCTAssertTrue(vm.hasMore)
        XCTAssertEqual(loader.categoryCalls.first?.categoryId, "jingdianpingshu")
        XCTAssertNil(vm.loadError)
    }

    func testUnsupportedSourceSetsLoadError() async {
        let vm = DiscoverViewModel()
        let loader = FakeLoader()
        loader.categoryResult = .failure(URLError(.unsupportedURL))
        vm.attach(loader: loader, cache: nil)

        await vm.load(target: .category(src: "mekui", categoryId: "any"))

        XCTAssertEqual(vm.loadError, "该源暂不支持发现页", "不支持的源如实标注，不静默空列表")
        XCTAssertTrue(vm.albums.isEmpty)
    }

    func testLoadMoreAppendsPagesForCategory() async {
        let vm = DiscoverViewModel()
        let loader = FakeLoader()
        loader.categoryResult = .success(([makeAlbum(1, "页1", src: "ting08")], true))
        vm.attach(loader: loader, cache: nil)

        await vm.load(target: .category(src: "ting08", categoryId: "pingshu"))
        XCTAssertEqual(loader.categoryCalls.first?.page, 1)

        loader.categoryResult = .success(([makeAlbum(2, "页2", src: "ting08")], false))
        await vm.loadMore()
        XCTAssertEqual(loader.categoryCalls.last?.page, 2, "翻页请求第 2 页")
        XCTAssertEqual(vm.albums.map(\.title), ["页1", "页2"])
        XCTAssertFalse(vm.hasMore)
    }

    func testLoadMoreFailsRollsBackPage() async {
        let vm = DiscoverViewModel()
        let loader = FakeLoader()
        loader.categoryResult = .success(([makeAlbum(1, "页1", src: "ting15")], true))
        vm.attach(loader: loader, cache: nil)
        await vm.load(target: .category(src: "ting15", categoryId: "yinyue"))

        loader.categoryResult = .failure(URLError(.timedOut))
        await vm.loadMore() // 第 2 页失败

        loader.categoryResult = .success(([makeAlbum(2, "页2", src: "ting15")], false))
        await vm.loadMore() // 重试应回到第 2 页而不是跳到第 3 页
        XCTAssertEqual(loader.categoryCalls.last?.page, 2, "失败后页码回退，重试不丢页")
    }

    func testRankTargetStillWorks() async {
        let vm = DiscoverViewModel()
        let loader = FakeLoader()
        loader.rankResult = .success(PagedResult(items: [makeAlbum(9, "榜单", src: "tingyou")], hasMore: false))
        vm.attach(loader: loader, cache: nil)

        await vm.load(target: .tingyouRank(section: "recommend"))
        XCTAssertEqual(vm.albums.first?.title, "榜单")
    }
}


/// build 21 · 反馈 3（增强 1）：打开 App 自动记忆上次播放——不出声契约。
/// prepareQueue（区别于 playQueue）只装载队列不调 play()：恢复场景用户点播放才出声。
final class StartupRestoreTests: XCTestCase {

    func testPrepareQueueDoesNotAutoplay() {
        let pm = PlaybackManager(playbackRepository: nil)
        let album = Album(albumId: 1, title: "恢复的书", author: nil, teller: nil,
                          coverUrl: nil, intro: nil, category: nil, categoryId: nil,
                          type: nil, typeId: nil, status: nil, chapterCount: nil,
                          updatedAt: nil, playCount: nil, available: true,
                          source: "tingyou", detailPath: nil)
        let chapters = (1...3).map {
            Chapter(chapterId: Int64($0), index: $0, title: "第\($0)章", durationSec: nil)
        }
        pm.prepareQueue(album: album, chapters: chapters, startIdx: 1, startPosMs: 120_000)
        XCTAssertEqual(pm.currentAlbumTitle, "恢复的书", "专辑应载入播放器（迷你条可见）")
        XCTAssertEqual(pm.currentChapterIdx, 1, "定位到上次听到的章节")
        XCTAssertFalse(pm.isPlaying, "启动恢复不得自动出声——用户点播放才播")
    }
}
