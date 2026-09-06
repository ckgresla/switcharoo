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
        print("10 application-name and catalog checks passed")
    }
}
