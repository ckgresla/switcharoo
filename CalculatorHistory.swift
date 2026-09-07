import Foundation
import Combine

struct CalculatorHistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let query: String
    var answer: CalculatorAnswer
    var date: Date
    var pinned: Bool
}
final class CalculatorHistory: ObservableObject {
    static let shared = CalculatorHistory()
    @Published private(set) var entries: [CalculatorHistoryEntry]
    private let defaults: UserDefaults
    private let clock: () -> Date
    init(defaults: UserDefaults = .standard,clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.clock = clock
        entries = defaults.data(forKey:"calculator.history.v1").flatMap { try? JSONDecoder().decode([CalculatorHistoryEntry].self,from:$0) } ?? []
        prune()
    }
    private func prune() {
        let cutoff = Calendar.current.date(byAdding:.month,value:-3,to:clock())!
        entries.removeAll { !$0.pinned && $0.date < cutoff }
    }
    private func save() {
        prune()
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data,forKey:"calculator.history.v1") }
    }
    func record(query: String,answer: CalculatorAnswer) {
        guard answer.canCopy,!query.isEmpty else { return }
        if let index = entries.firstIndex(where:{$0.query == query}) {
            entries[index].answer = answer; entries[index].date = clock()
        } else { entries.insert(.init(id:UUID(),query:query,answer:answer,date:clock(),pinned:false),at:0) }
        save()
    }
    func togglePin(_ id: UUID) { if let i = entries.firstIndex(where:{$0.id == id}) { entries[i].pinned.toggle(); save() } }
    func delete(_ id: UUID) { entries.removeAll { $0.id == id }; save() }
    func clearUnpinned() { entries.removeAll { !$0.pinned }; save() }
    func search(_ text: String) -> [CalculatorHistoryEntry] {
        entries.filter { text.isEmpty || $0.query.localizedCaseInsensitiveContains(text) || $0.answer.value.localizedCaseInsensitiveContains(text) }
            .sorted { $0.pinned != $1.pinned ? $0.pinned : $0.date > $1.date }
    }
}
