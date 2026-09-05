import Foundation
import AppKit
import Combine

/// Only settled input is evaluated. A stale answer stays visible but cannot be copied.
final class CalculatorModel: ObservableObject {
    typealias Evaluator = ([String:Any], @escaping (CalculatorResponse) -> Void) -> DispatchWorkItem
    typealias RateProvider = (String,String,Bool) async throws -> ExchangeRateSnapshot
    @Published private(set) var answer: CalculatorAnswer?
    @Published private(set) var error: String?
    @Published private(set) var pending = false
    @Published private(set) var attribution: String?
    @Published private(set) var hasRates = false
    var didChange: (() -> Void)?
    private let evaluate: Evaluator
    private let rateProvider: RateProvider
    private var generation = 0
    private var debounce: DispatchWorkItem?
    private var evaluation: DispatchWorkItem?
    private var network: Task<Void,Never>?
    private(set) var query = ""
    private(set) var evaluatedQuery = ""
    var canCopy: Bool { !pending && query == evaluatedQuery && answer?.canCopy == true }
    var hasContent: Bool { answer != nil || error != nil || hasRates }
    init(evaluate: @escaping Evaluator = { CalculatorEngine.shared.evaluate($0,completion:$1) },
         rateProvider: @escaping RateProvider = { try await ExchangeRateService.shared.quote(source:$0,target:$1,forceRefresh:$2) }) {
        self.evaluate = evaluate; self.rateProvider = rateProvider
    }
    deinit { debounce?.cancel(); evaluation?.cancel(); network?.cancel() }
    func update(_ text: String,force: Bool = false) {
        guard force || text != query else { return }
        query = text; generation += 1; let current = generation
        debounce?.cancel(); evaluation?.cancel(); network?.cancel()
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            answer = nil; error = nil; attribution = nil; hasRates = false; pending = false; evaluatedQuery = ""; didChange?(); return
        }
        pending = true
        let work = DispatchWorkItem { [weak self] in self?.calculate(text,current:current,force:force) }
        debounce = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.1,execute:work)
    }
    private func calculate(_ text: String,current: Int,force: Bool,rates: [String:String] = [:],snapshots: [ExchangeRateSnapshot] = []) {
        guard current == generation else { return }
        var request: [String:Any] = ["query":text,"locale":Locale.current.identifier,
            "rem":UserDefaults.standard.object(forKey:"calculator.rem") as? Double ?? 16,
            "automaticUnits":UserDefaults.standard.object(forKey:"calculator.automaticUnits") as? Bool ?? true]
        request["rates"] = rates
        evaluation = evaluate(request) { [weak self] response in
            guard let self,current == self.generation else { return }
            if let missing = response.currencyRequests,!missing.isEmpty {
                guard missing.count <= 12, rates.count < 24,!missing.contains(where:{$0.historical}) else {
                    self.commit(.init(error:"Historical or complex currency rates unavailable"),text:text,snapshots:[],current:current); return
                }
                guard missing.contains(where:{rates[$0.source+"-"+$0.target] == nil}) else {
                    self.commit(.init(error:"Rate unavailable"),text:text,snapshots:[],current:current); return
                }
                if !self.hasContent { self.hasRates = true; self.didChange?() }
                self.network = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        var supplied = rates, allSnapshots = snapshots
                        for pair in missing where supplied[pair.source+"-"+pair.target] == nil {
                            let snapshot = try await self.rateProvider(pair.source,pair.target,force)
                            try Task.checkCancellation()
                            supplied[pair.source+"-"+pair.target] = NSDecimalNumber(decimal:snapshot.quote.rate).stringValue
                            allSnapshots.append(snapshot)
                        }
                        guard current == self.generation else { return }
                        self.calculate(text,current:current,force:force,rates:supplied,snapshots:allSnapshots)
                    } catch {
                        guard !Task.isCancelled,current == self.generation else { return }
                        self.commit(.init(error:(error as? LocalizedError)?.errorDescription ?? "Rates unavailable"),text:text,snapshots:[],current:current)
                    }
                }
                return
            }
            self.commit(response,text:text,snapshots:snapshots,current:current)
        }
    }
    private func commit(_ response: CalculatorResponse,text: String,snapshots: [ExchangeRateSnapshot],current: Int) {
        guard current == generation else { return }
        if response.incomplete == true { pending = false; return }
        answer = response.result; error = response.error; evaluatedQuery = text
        pending = false; hasRates = !snapshots.isEmpty
        if let oldest = snapshots.min(by:{$0.quote.quotedAt < $1.quote.quotedAt}) {
            let format = DateFormatter(); format.dateStyle = .medium; format.timeStyle = .short
            attribution = (snapshots.contains(where:{$0.stale}) ? "Cached · " : "") + oldest.quote.provider + " · " + format.string(from:oldest.quote.quotedAt)
        } else { attribution = nil }
        didChange?()
    }
    func refresh() { update(query,force:true) }
    func save() { if canCopy,let answer { CalculatorHistory.shared.record(query:query,answer:answer) } }
    func copy(raw: Bool = false,includeQuery: Bool = false,questionOnly: Bool = false) {
        guard canCopy,let answer else { return }; save()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(questionOnly ? query : includeQuery ? query+" = "+answer.value : raw ? answer.raw : answer.value,forType:.string)
    }
}
