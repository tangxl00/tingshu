import XCTest
@testable import TingYou

/// 检查更新回归守卫：
/// - iOS 版本必须从 IPA 资产名解析，不能拿 Release tag（Android 版本号）比较
/// - iOS 点击下载跳 IPA 直链，浏览器下载后由用户自签
final class AppUpdateTests: XCTestCase {

    // MARK: - IPA 资产名解析

    func testParseIPAVersionWithBuild() {
        let parsed = UpdateInfo.parseIPAVersion("TingYou-unsigned-1.4.6-61.ipa")
        XCTAssertEqual(parsed?.version, "1.4.6")
        XCTAssertEqual(parsed?.build, "61")
    }

    func testParseIPAVersionWithoutBuild() {
        let parsed = UpdateInfo.parseIPAVersion("TingYou-unsigned-1.4.7.ipa")
        XCTAssertEqual(parsed?.version, "1.4.7")
        XCTAssertNil(parsed?.build)
    }

    func testParseIPAVersionRejectsOtherAssets() {
        XCTAssertNil(UpdateInfo.parseIPAVersion("tingyou-android-release.apk"))
        XCTAssertNil(UpdateInfo.parseIPAVersion("TingYou-unsigned-1.4.6.ipa.sha256"))
        XCTAssertNil(UpdateInfo.parseIPAVersion("build-logs-abc.zip"))
        XCTAssertNil(UpdateInfo.parseIPAVersion("TingYou-unsigned-abc.ipa"))
    }

    // MARK: - 版本比较

    func testVersionCompare() {
        XCTAssertEqual(UpdateInfo.compare("1.4.6", "1.4.6"), 0)
        XCTAssertEqual(UpdateInfo.compare("1.4.6", "1.4.7"), -1)
        XCTAssertEqual(UpdateInfo.compare("1.4.7", "1.4.6"), 1)
        XCTAssertEqual(UpdateInfo.compare("1.10.0", "1.9.9"), 1)
        XCTAssertEqual(UpdateInfo.compare("2.0", "1.9.9"), 1)
    }

    /// 核心回归：iOS 1.4.6 面对 Release tag 1.2.7（Android 版本）时，
    /// 必须以 IPA 版本为准；没有 IPA 版本时绝不误报有更新。
    func testHasNewerUsesIPAVersionNotTag() {
        let noIPA = UpdateInfo(
            latestVersion: "1.2.8", changelog: "", htmlUrl: "", apkUrl: nil,
            ipaUrl: nil, iosVersion: nil, publishedAt: nil
        )
        XCTAssertFalse(noIPA.hasNewer, "没有 IPA 资产时不应误报更新")

        let sameIPA = UpdateInfo(
            latestVersion: "1.2.8", changelog: "", htmlUrl: "", apkUrl: nil,
            ipaUrl: "https://example.com/1.4.6.ipa", iosVersion: "1.4.6", publishedAt: nil
        )
        XCTAssertFalse(sameIPA.hasNewer, "IPA 与当前版本一致应为最新")

        let newerIPA = UpdateInfo(
            latestVersion: "1.2.8", changelog: "", htmlUrl: "", apkUrl: nil,
            ipaUrl: "https://example.com/1.4.7.ipa", iosVersion: "1.4.7", publishedAt: nil
        )
        XCTAssertTrue(newerIPA.hasNewer, "IPA 版本更高应提示更新，即使 tag 是 Android 版本号")
        XCTAssertEqual(newerIPA.displayVersion, "1.4.7")
    }

    // MARK: - 源码级守卫

    /// 静态守卫：AppUpdate 必须从 IPA 资产解析 iosVersion，并用它判断 hasNewer。
    func testAppUpdateParsesIPAVersion() throws {
        let src = try Self.source("TingYou/Services/AppUpdate.swift")
        XCTAssertTrue(src.contains("parseIPAVersion"), "必须解析 IPA 资产名")
        XCTAssertTrue(src.contains("iosVersion"), "必须有 iosVersion 字段")
        XCTAssertTrue(src.contains("return Self.compare(Self.currentVersion, iosVersion) < 0"),
                      "hasNewer 必须基于 IPA 版本比较，不能基于 Release tag")
    }

    /// 静态守卫：下载按钮优先跳 IPA 直链并说明需自签。
    func testMineScreenOpensIPAAndMentionsSideload() throws {
        let src = try Self.source("TingYou/UI/Mine/MineScreen.swift")
        XCTAssertTrue(src.contains("info.ipaUrl ?? info.htmlUrl"),
                      "下载必须优先跳 IPA 直链")
        XCTAssertTrue(src.contains("自签"), "弹窗必须提示用户需自签安装")
    }

    // MARK: - Helpers

    private static func source(_ rel: String) throws -> String {
        let fileURL = URL(fileURLWithPath: #filePath)
        let root = fileURL
            .deletingLastPathComponent()   // TingYouTests
            .deletingLastPathComponent()   // TingYou (project dir)
        let target = root.appendingPathComponent(rel)
        return try String(contentsOf: target, encoding: .utf8)
    }
}
