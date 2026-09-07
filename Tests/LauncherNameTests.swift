import Foundation
@main struct LauncherNameTests {
    static func main() {
        let url = URL(fileURLWithPath:"/Applications/TeX/hintview.app")
        let cases: [([String?],String)] = [
            (["", "hintview"], "hintview"),
            ([" \n\t", "hintview"], "hintview"),
            ([nil, nil], "hintview"),
            (["", ""], "hintview"),
            (["Localized Name", "InternalName"], "Localized Name"),
            (["  Running App  "], "Running App")
        ]
        for (names, expected) in cases {
            precondition(LauncherSearch.applicationName(names,url:url) == expected)
        }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:fixture) }
        let root = fixture.appendingPathComponent("Applications")
        let scanned = root.appendingPathComponent("Editor.app")
        let finder = fixture.appendingPathComponent("CoreServices/Finder.app")
        let external = fixture.appendingPathComponent("Outside/Running.app")
        for url in [scanned,finder,external] { try! FileManager.default.createDirectory(at:url,withIntermediateDirectories:true) }
        let discovered = LauncherSearch.applicationURLs(in:[root],including:[finder,external,scanned,finder,fixture.appendingPathComponent("Missing.app")])
        let paths = discovered.map(\.path)
        precondition(paths.contains(finder.resolvingSymlinksInPath().path),"Finder survives scans outside CoreServices")
        precondition(paths.contains(external.resolvingSymlinksInPath().path),"running apps outside scan roots survive")
        precondition(paths.filter{$0 == scanned.resolvingSymlinksInPath().path}.count == 1,"deduplicate seeded/scanned apps")
        precondition(discovered.count == 3,"skip unavailable apps")
        let names = ["find-my":"Find My","finder":"Finder","other":"Other"]
        var usage = LauncherUsage()
        func matches(_ query: String,_ saved: LauncherUsage) -> [String] {
            let ordered = saved.ranked(available:["find-my","finder","other"],fallback:[])
            return LauncherSearch.matchingIndices(query,in:ordered.map { (names[$0]!,"") }).map { ordered[$0] }
        }
        precondition(matches("find",usage).first == "find-my")
        usage.record("finder")
        precondition(matches("find",usage).first == "finder","launch frequency breaks matching ties")
        usage.record("find-my",at:.distantPast)
        precondition(matches("find",usage).first == "finder","recency breaks equal launch counts")
        usage.record("find-my")
        precondition(matches("find",usage).first == "find-my","ranking adapts to later choices")
        precondition(matches("finder",usage).first == "finder","exact name wins over usage")
        precondition(matches("zzzzz",usage).isEmpty,"usage never introduces unrelated results")
        let suite = "switcharoo.search-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let preferences = LauncherPreferences(defaults:defaults)
        preferences.usage = usage
        precondition(matches("find",LauncherPreferences(defaults:defaults).usage) == matches("find",usage),"learned ordering survives reload")
        let valid = [
            ("https://example.com/a?q=one%20two#part","https://example.com/a?q=one%20two#part"),
            ("  https://example.com  ","https://example.com"),
            ("example.com/path","https://example.com/path"),
            ("www.example.com","https://www.example.com"),
            ("http://localhost:8894/","http://localhost:8894/"),
            ("localhost:8894","https://localhost:8894"),
            ("127.0.0.1:8894/","https://127.0.0.1:8894/"),
            ("https://example.com/a?x=1&y=2","https://example.com/a?x=1&y=2")
        ]
        for (input,expected) in valid { precondition(LauncherSearch.webURL(input)?.absoluteString == expected,"URL: " + input) }
        let invalid = ["finder","now","1 + 2","3.14","1.5gb","2.5m","hello world.com","https://","javascript:alert(1)","file:///tmp/a","mailto:a@example.com","https://user:pass@example.com","https://example.com:99999","example..com","https://example.com\nother.com"]
        for input in invalid { precondition(LauncherSearch.webURL(input) == nil,"not a web address: " + input) }
        print("40 application-name, catalog, learned ranking, and URL checks passed")
    }
}
