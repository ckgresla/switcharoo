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

    /// Candidates arrive in learned order; relevance wins, then learned order breaks ties.
    static func matchingIndices(_ query: String,in candidates: [(title: String,keywords: String)]) -> [Int] {
        candidates.enumerated().compactMap { index,item -> (Int,Int)? in
            guard let rank = score(query,in:item.title,keywords:item.keywords) else { return nil }
            return (rank,index)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map { $0.1 }
    }

    /// Recognize web addresses without treating arbitrary search text as a URL.
    static func webURL(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty,!text.contains(where: { $0.isWhitespace || $0.isNewline }),
              !text.contains("\\") else { return nil }
        let explicit = text.contains("://")
        let address = explicit ? text : "https://" + text
        guard let parts = URLComponents(string:address),
              let scheme = parts.scheme?.lowercased(),["http","https"].contains(scheme),
              parts.user == nil,parts.password == nil,
              let host = parts.host,!host.isEmpty,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              let url = parts.url else { return nil }
        if !explicit {
            let labels = host.split(separator:".",omittingEmptySubsequences:false)
            let domain = labels.count >= 2 && labels.allSatisfy { label in
                !label.isEmpty && label.first != "-" && label.last != "-" && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
            } && labels.last!.count >= 2 && labels.last!.allSatisfy { $0.isLetter }
            let ipv4 = labels.count == 4 && labels.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
            guard domain || ipv4 || host.lowercased() == "localhost" else { return nil }
        }
        return url
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
