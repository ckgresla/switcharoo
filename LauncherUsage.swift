import Foundation
struct LauncherUsage: Codable, Equatable {
    var pinned: [String] = []
    var counts: [String:Int] = [:]
    var lastUsed: [String:Date] = [:]
    mutating func record(_ id: String,at date: Date = Date()) { counts[id] = min(counts[id,default: 0]+1,1_000_000_000); lastUsed[id] = date }
    mutating func togglePin(_ id: String) {
        if pinned.contains(id) { pinned.removeAll { $0 == id } }
        else if pinned.count < 3 { pinned.append(id) }
    }
    func ranked(available: [String],fallback: [String]) -> [String] {
        let original = Dictionary(available.enumerated().map { ($0.element,$0.offset) },uniquingKeysWith:min)
        return Array(Set(available)).sorted { a,b in
            let pa = pinned.firstIndex(of:a) ?? Int.max,pb = pinned.firstIndex(of:b) ?? Int.max
            if pa != pb { return pa < pb }
            if counts[a,default:0] != counts[b,default:0] { return counts[a,default:0] > counts[b,default:0] }
            if lastUsed[a,default:.distantPast] != lastUsed[b,default:.distantPast] { return lastUsed[a,default:.distantPast] > lastUsed[b,default:.distantPast] }
            let fa = fallback.firstIndex(of:a) ?? Int.max,fb = fallback.firstIndex(of:b) ?? Int.max
            if fa != fb { return fa < fb }
            return original[a,default:0] < original[b,default:0]
        }
    }
    func topThree(available: [String],fallback: [String]) -> [String] {
        let valid = Set(available); var result: [String] = []
        func append(_ id: String) { if result.count < 3,valid.contains(id),!result.contains(id) { result.append(id) } }
        pinned.forEach(append)
        return result
    }
}

/// Kept separate from the window so preferences survive dismissals and app restarts.
struct LauncherPreferences {
    let defaults: UserDefaults
    var commandsOpen: Bool {
        get { defaults.bool(forKey:"launcher.commands-open") }
        nonmutating set { defaults.set(newValue,forKey:"launcher.commands-open") }
    }
    var usage: LauncherUsage {
        get { guard let data = defaults.data(forKey:"launcher.usage"),let saved = try? JSONDecoder().decode(LauncherUsage.self,from:data) else { return LauncherUsage() }; return saved }
        nonmutating set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data,forKey:"launcher.usage") } }
    }
}
