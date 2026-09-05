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
        print("6 application-name checks passed")
    }
}
