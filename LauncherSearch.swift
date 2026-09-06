import Foundation

enum LauncherSearch {
    /// Keep explicitly resolved and running apps even when they live outside scan roots.
    static func applicationURLs(in roots: [URL],including known: [URL]) -> [URL] {
        var urls: [URL] = [],seen = Set<String>()
        func append(_ url: URL) {
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            guard canonical.pathExtension.lowercased() == "app",
                  FileManager.default.fileExists(atPath:canonical.path),seen.insert(canonical.path).inserted else { return }
            urls.append(canonical)
        }
        known.forEach(append)
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles,.skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" { append(url) }
        }
        return urls
    }

    static func applicationName(_ candidates: [String?], url: URL) -> String {
        for candidate in candidates {
            if let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    // Lower scores rank first; nil means no match. Diacritics and case do not
    // affect matching, and all query words must occur or match as a subsequence.
    static func score(_ query: String,in title: String,keywords: String = "") -> Int? {
        func normalized(_ value: String) -> String { value.folding(options: [.caseInsensitive,.diacriticInsensitive],locale: .current).lowercased() }
        let query = normalized(query).trimmingCharacters(in: .whitespacesAndNewlines),title = normalized(title)
        if query.isEmpty { return 0 }
        if title == query { return 0 }
        if title.hasPrefix(query) { return 1 }
        if title.contains(query) { return 2 }
        let text = title+" "+normalized(keywords)
        if query.split(whereSeparator: \.isWhitespace).allSatisfy({ text.contains($0) }) { return 3 }
        var cursor = title.startIndex
        for character in query where !character.isWhitespace {
            guard let found = title[cursor...].firstIndex(of: character) else { return nil }
            cursor = title.index(after: found)
        }
        return 5
    }
}
