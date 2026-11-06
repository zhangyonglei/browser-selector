import XCTest
@testable import BrowserSelectorCore

final class ArgumentTemplateTests: XCTestCase {
    func testSubstitutesURLPlaceholderAndKeepsQuotedArgumentTogether() {
        let arguments = ArgumentTemplate.makeArguments(
            template: #"--incognito --user-data-dir="/tmp/my profile" {url}"#,
            url: URL(string: "https://example.com/a?b=1")!
        )
        XCTAssertEqual(
            arguments,
            ["--incognito", "--user-data-dir=/tmp/my profile", "https://example.com/a?b=1"]
        )
    }

    func testAppendsURLWhenTemplateHasNoPlaceholder() {
        let arguments = ArgumentTemplate.makeArguments(
            template: "--new-window",
            url: URL(string: "https://example.com")!
        )
        XCTAssertEqual(arguments, ["--new-window", "https://example.com"])
    }

    func testEmptyTemplateYieldsOnlyURL() {
        let arguments = ArgumentTemplate.makeArguments(
            template: "   ",
            url: URL(string: "https://example.com")!
        )
        XCTAssertEqual(arguments, ["https://example.com"])
    }

    func testSupportsSingleQuotesAndEscapedQuotes() {
        let tokens = ArgumentTemplate.tokenize(#"--profile='My Profile' --flag="a\"b" plain\ word"#)
        XCTAssertEqual(tokens, ["--profile=My Profile", "--flag=a\"b", "plain word"])
    }

    func testPlaceholderInsideQuotedArgument() {
        let arguments = ArgumentTemplate.makeArguments(
            template: #"--app="https://example.com/?from={url}""#,
            url: URL(string: "https://target.example")!
        )
        XCTAssertEqual(arguments, ["--app=https://example.com/?from=https://target.example"])
    }

    func testCollapsesRepeatedWhitespace() {
        XCTAssertEqual(ArgumentTemplate.tokenize("  a   b\tc  "), ["a", "b", "c"])
    }
}

final class LinkURLValidatorTests: XCTestCase {
    func testAcceptsHTTPAndHTTPS() {
        XCTAssertEqual(
            LinkURLValidator.normalize("https://example.com/path?q=1#frag")?.absoluteString,
            "https://example.com/path?q=1#frag"
        )
        XCTAssertNotNil(LinkURLValidator.normalize("http://example.com"))
    }

    func testAddsSchemeForBareDomain() {
        XCTAssertEqual(
            LinkURLValidator.normalize("www.example.com/a")?.absoluteString,
            "https://www.example.com/a"
        )
        XCTAssertEqual(
            LinkURLValidator.normalize("example.com")?.absoluteString,
            "https://example.com"
        )
    }

    func testStripsTrailingPunctuationAndQuotes() {
        XCTAssertEqual(
            LinkURLValidator.normalize("见 https://example.com/a）。")?.absoluteString,
            nil
        )
        XCTAssertEqual(
            LinkURLValidator.normalize("https://example.com/a）。")?.absoluteString,
            "https://example.com/a"
        )
        XCTAssertEqual(
            LinkURLValidator.normalize("“https://example.com/a”")?.absoluteString,
            "https://example.com/a"
        )
        XCTAssertEqual(
            LinkURLValidator.normalize("https://example.com/a.")?.absoluteString,
            "https://example.com/a"
        )
    }

    func testRejectsNonHTTPAndMalformedValues() {
        XCTAssertNil(LinkURLValidator.normalize("ftp://example.com/file"))
        XCTAssertNil(LinkURLValidator.normalize("https://"))
        XCTAssertNil(LinkURLValidator.normalize("hello world"))
        XCTAssertNil(LinkURLValidator.normalize("javascript:alert(1)"))
        XCTAssertNil(LinkURLValidator.normalize(""))
    }

    func testRejectsURLsWithWhitespace() {
        XCTAssertNil(LinkURLValidator.normalize("https://example.com/a b"))
        XCTAssertNil(LinkURLValidator.normalize("https://example.com/a\nhttps://example.com/b"))
    }

    func testRejectsVeryLongInput() {
        let long = "https://example.com/" + String(repeating: "a", count: 5_000)
        XCTAssertNil(LinkURLValidator.normalize(long))
    }

    func testStrictModeRejectsSchemeLessValues() {
        XCTAssertNil(LinkURLValidator.normalize("example.com", allowSchemeLess: false))
        XCTAssertNil(LinkURLValidator.normalize("www.example.com/path", allowSchemeLess: false))
        XCTAssertNotNil(
            LinkURLValidator.normalize("https://example.com/path", allowSchemeLess: false)
        )
    }
}

final class DomainRouterTests: XCTestCase {
    private let safari = BrowserEntry(id: "safari", displayName: "Safari", bundleIdentifier: "com.apple.Safari")
    private let chrome = BrowserEntry(id: "chrome", displayName: "Chrome", bundleIdentifier: "com.google.Chrome")

    func testMatchesHostCaseInsensitively() {
        let router = DomainRouter(
            rules: [DomainRule(pattern: #"github\.com$"#, browserID: chrome.id)]
        )
        XCTAssertEqual(
            router.browserID(for: URL(string: "https://GitHub.com/openai")!),
            chrome.id
        )
        XCTAssertNil(router.browserID(for: URL(string: "https://example.com")!))
    }

    func testFirstMatchingRuleWins() {
        let router = DomainRouter(
            rules: [
                DomainRule(pattern: #"corp\.com$"#, browserID: safari.id),
                DomainRule(pattern: #".*"#, browserID: chrome.id)
            ]
        )
        XCTAssertEqual(
            router.browserID(for: URL(string: "https://wiki.corp.com/page")!),
            safari.id
        )
        XCTAssertEqual(
            router.browserID(for: URL(string: "https://example.com")!),
            chrome.id
        )
    }

    func testMatchesFullURLWhenPatternIncludesScheme() {
        let router = DomainRouter(
            rules: [DomainRule(pattern: #"^https://.*\.docs\.example\.com/"#, browserID: safari.id)]
        )
        XCTAssertEqual(
            router.browserID(for: URL(string: "https://team.docs.example.com/view")!),
            safari.id
        )
    }

    func testInvalidDisabledAndEmptyRulesAreSkipped() {
        let router = DomainRouter(
            rules: [
                DomainRule(pattern: "(", browserID: safari.id),
                DomainRule(pattern: #"example\.com$"#, browserID: chrome.id, isEnabled: false),
                DomainRule(pattern: #".*"#, browserID: "")
            ]
        )
        XCTAssertNil(router.browserID(for: URL(string: "https://example.com")!))
        XCTAssertFalse(DomainRouter.isValidPattern("("))
        XCTAssertTrue(DomainRouter.isValidPattern(#"example\.com$"#))
    }
}

final class AppConfigTests: XCTestCase {
    func testMinimalJSONFallsBackToDefaults() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(config.version, AppConfig.currentVersion)
        XCTAssertEqual(config.behavior.clipboardFallbackDelayMilliseconds, 50)
        XCTAssertFalse(config.behavior.panelOnlyWithCommandModifier)
        XCTAssertEqual(config.targetApplications.count, 3)
        XCTAssertTrue(config.targetApplications.contains { $0.bundleIdentifier == "com.tencent.xinWeChat" })
    }

    func testDecodingToleratesMissingFieldsAndClampsDelay() throws {
        let json = """
        {
          "behavior": { "clipboardFallbackDelayMilliseconds": 5000 },
          "targetApplications": [{ "bundleIdentifier": "com.example.chat" }]
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.behavior.clipboardFallbackDelayMilliseconds, 1_000)
        XCTAssertEqual(config.targetApplications.first?.mode, .swallowAndReplay)
        XCTAssertEqual(config.targetApplications.first?.isEnabled, true)
        XCTAssertEqual(config.targetApplications.first?.displayName, "")
    }

    func testRoundTrip() throws {
        var config = AppConfig()
        config.behavior.panelOnlyWithCommandModifier = true
        config.browsers = [
            BrowserEntry(
                id: "chrome",
                displayName: "Chrome",
                bundleIdentifier: "com.google.Chrome",
                argumentsTemplate: "--incognito {url}"
            )
        ]
        config.routingRules = [DomainRule(pattern: #"github\.com$"#, browserID: "chrome")]
        config.exclusions = ExclusionRules(
            bundleIdentifiers: ["com.example.skip"],
            windowTitleSubstrings: ["会议"]
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testMergePreservesUserSettingsAndAddsDiscoveredBrowsers() {
        var config = AppConfig()
        config.browsers = [
            BrowserEntry(
                id: "com.google.Chrome",
                displayName: "我的 Chrome",
                bundleIdentifier: "com.google.Chrome",
                applicationPath: "/Applications/Google Chrome.app",
                argumentsTemplate: "--incognito {url}"
            )
        ]
        config.defaultBrowserID = "com.google.Chrome"

        let changed = config.merge(discovered: [
            DiscoveredBrowser(
                bundleIdentifier: "com.google.Chrome",
                displayName: "Google Chrome",
                applicationPath: "/Applications/Google Chrome.app"
            ),
            DiscoveredBrowser(
                bundleIdentifier: "com.apple.Safari",
                displayName: "Safari",
                applicationPath: "/Applications/Safari.app"
            )
        ])

        XCTAssertTrue(changed)
        XCTAssertEqual(config.browsers.count, 2)
        XCTAssertEqual(config.browsers[0].displayName, "我的 Chrome")
        XCTAssertEqual(config.browsers[0].argumentsTemplate, "--incognito {url}")
        XCTAssertEqual(config.browsers[1].id, "com.apple.Safari")
        XCTAssertEqual(config.defaultBrowserID, "com.google.Chrome")
    }

    func testMergeDoesNotOverwriteManualEntryWithSameBundleID() {
        var config = AppConfig()
        let manual = BrowserEntry.makeManual(
            displayName: "Portable Chromium",
            applicationPath: "/Users/me/Apps/Chromium.app",
            bundleIdentifier: "org.chromium.Chromium",
            argumentsTemplate: "--user-data-dir=/tmp/p"
        )
        config.browsers = [manual]

        config.merge(discovered: [
            DiscoveredBrowser(
                bundleIdentifier: "org.chromium.Chromium",
                displayName: "Chromium",
                applicationPath: "/Applications/Chromium.app"
            )
        ])

        XCTAssertEqual(config.browsers.count, 1)
        XCTAssertEqual(config.browsers[0].applicationPath, "/Users/me/Apps/Chromium.app")
        XCTAssertEqual(config.browsers[0].argumentsTemplate, "--user-data-dir=/tmp/p")
    }

    func testSanitizeDeduplicatesButKeepsEditingRows() {
        var config = AppConfig()
        config.targetApplications = [
            TargetApplication(displayName: "A", bundleIdentifier: "com.example.a"),
            TargetApplication(displayName: "A2", bundleIdentifier: "com.example.a"),
            TargetApplication(displayName: "草稿", bundleIdentifier: "")
        ]
        config.exclusions = ExclusionRules(
            bundleIdentifiers: [" com.example.skip ", ""],
            windowTitleSubstrings: ["  会议  "]
        )

        config.sanitize()

        XCTAssertEqual(config.targetApplications.count, 2)
        XCTAssertTrue(config.targetApplications.contains { $0.bundleIdentifier.isEmpty })
        XCTAssertEqual(config.exclusions.bundleIdentifiers, ["com.example.skip"])
        XCTAssertEqual(config.exclusions.windowTitleSubstrings, ["会议"])
    }

    func testEffectiveDefaultBrowserFallsBackToFirstEnabled() {
        var config = AppConfig()
        config.browsers = [
            BrowserEntry(id: "a", displayName: "A", isEnabled: false),
            BrowserEntry(id: "b", displayName: "B")
        ]
        XCTAssertEqual(config.effectiveDefaultBrowser?.id, "b")

        config.defaultBrowserID = "a"
        XCTAssertEqual(config.effectiveDefaultBrowser?.id, "b")
    }
}

final class ConfigStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserSelectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCreatesDefaultsOnFirstLaunch() {
        let url = directory.appendingPathComponent("config.json")
        let store = ConfigStore(fileURL: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.config.targetApplications.count, 3)
    }

    func testUpdatePersistsAndReloads() {
        let url = directory.appendingPathComponent("config.json")
        let store = ConfigStore(fileURL: url)

        store.update { config in
            config.behavior.panelOnlyWithCommandModifier = true
            config.browsers = [BrowserEntry(id: "safari", displayName: "Safari")]
            config.defaultBrowserID = "safari"
        }

        let reloaded = ConfigStore(fileURL: url)
        XCTAssertTrue(reloaded.config.behavior.panelOnlyWithCommandModifier)
        XCTAssertEqual(reloaded.config.browsers.first?.displayName, "Safari")
        XCTAssertEqual(reloaded.config.defaultBrowserID, "safari")
    }

    func testCorruptConfigIsArchivedAndReplacedWithDefaults() throws {
        let url = directory.appendingPathComponent("config.json")
        try Data("not json".utf8).write(to: url)

        let store = ConfigStore(fileURL: url)
        XCTAssertEqual(store.config.targetApplications.count, 3)

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(contents.contains { $0.hasPrefix("config.corrupt-") })
        XCTAssertTrue(contents.contains("config.json"))
    }

    func testChangeCallbackFiresOnceForRealChanges() {
        let url = directory.appendingPathComponent("config.json")
        let store = ConfigStore(fileURL: url)

        var changes = 0
        store.onChange = { _ in changes += 1 }

        store.update { $0.defaultBrowserID = "missing" }
        XCTAssertEqual(changes, 1)

        store.update { $0.defaultBrowserID = "missing" }
        XCTAssertEqual(changes, 1)
    }
}
