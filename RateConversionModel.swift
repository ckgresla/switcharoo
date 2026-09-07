import Foundation
import Combine

struct CurrencyConversion: Equatable {
    let request: CurrencyConversionQuery
    let snapshot: ExchangeRateSnapshot
    let amount: Decimal
    var raw: String { NSDecimalNumber(decimal: amount).stringValue }
    var formatted: String {
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal
        formatter.locale = Locale.current; formatter.maximumFractionDigits = 8
        formatter.minimumFractionDigits = CurrencyConversionQuery.crypto.contains(request.target) ? 0 : 2
        return (formatter.string(from: NSDecimalNumber(decimal: amount)) ?? raw) + " " + request.target
    }
    var attribution: String {
        if snapshot.quote.provider == "Identity" { return "Same currency" }
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
        return (snapshot.stale ? "Cached · " : "") + snapshot.quote.provider + " · " + formatter.string(from: snapshot.quote.quotedAt)
    }
}

/// All observable state is updated on the main actor; transport and parsing run in the service actor.
final class RateConversionModel: ObservableObject {
    typealias Provider = @Sendable (CurrencyConversionQuery,Bool) async throws -> ExchangeRateSnapshot
    @Published private(set) var request: CurrencyConversionQuery?
    @Published private(set) var conversion: CurrencyConversion?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    var didChange: (() -> Void)?
    private let provider: Provider
    private var task: Task<Void,Never>?
    private var generation = 0
    private var text = ""
    init(provider: @escaping Provider = { query,force in try await ExchangeRateService.shared.quote(source: query.source,target: query.target,forceRefresh: force) }) { self.provider = provider }
    deinit { task?.cancel() }
    func update(_ text: String,forceRefresh: Bool = false) {
        guard forceRefresh || self.text != text else { return }
        self.text = text; generation += 1; let current = generation
        task?.cancel(); conversion = nil; error = nil
        request = CurrencyConversionQuery.parse(text); loading = request != nil; didChange?()
        guard let request else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if !forceRefresh { try await Task.sleep(nanoseconds: 220_000_000) }
                let snapshot = try await self.provider(request,forceRefresh)
                try Task.checkCancellation()
                guard current == self.generation else { return }
                self.conversion = CurrencyConversion(request: request,snapshot: snapshot,amount: try request.converted(using: snapshot.quote.rate))
                self.loading = false; self.didChange?()
            } catch {
                guard !Task.isCancelled,current == self.generation else { return }
                self.loading = false
                self.error = (error as? ExchangeRateError)?.localizedDescription ?? ExchangeRateError.unavailable.localizedDescription
                self.didChange?()
            }
        }
    }
    func refresh() { update(text,forceRefresh: true) }
}
