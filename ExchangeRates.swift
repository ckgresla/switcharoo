import Foundation
import CoreFoundation

struct CurrencyConversionQuery: Equatable, Sendable {
    let amount: Decimal
    let source: String
    let target: String
    var pair: String { source + "-" + target }
    static let crypto = Set(["BTC", "ETH", "LTC", "DOGE", "ADA", "SOL", "XRP", "BCH", "DOT", "BNB", "USDT", "USDC", "TON", "LINK", "UNI", "POL", "XLM", "XMR", "ETC", "AVAX", "TRX", "SHIB", "NEAR", "APT", "ICP", "FIL", "ATOM", "ALGO", "EOS", "XTZ", "AAVE", "MKR", "DAI"])
    private static let fiat = Set(Locale.commonISOCurrencyCodes)
    private static let aliases = ["$":"USD", "€":"EUR", "£":"GBP", "¥":"JPY", "dollar":"USD", "dollars":"USD", "euro":"EUR", "euros":"EUR", "pound":"GBP", "pounds":"GBP", "yen":"JPY", "bitcoin":"BTC", "ether":"ETH", "won":"KRW"]
    static func currency(_ token: String) -> String? {
        if let code = aliases[token.lowercased()] { return code }
        let code = token.uppercased()
        return fiat.contains(code) || crypto.contains(code) ? code : nil
    }
    static func parse(_ text: String) -> Self? {
        guard text.count <= 160 else { return nil }
        let pattern = #"^\s*(?:convert\s+)?(?:([A-Za-z]+|[$€£¥])\s*)?([+-]?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?|[+-]?\.\d+)\s*([kKmM]\b)?\s*([A-Za-z]+|[$€£¥])?\s+(?:in|to)\s+([A-Za-z]+|[$€£¥])\s*\??\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern,options: .caseInsensitive),let match = regex.firstMatch(in: text,range: NSRange(text.startIndex...,in: text)) else { return nil }
        func group(_ i: Int) -> String { guard let r = Range(match.range(at: i),in: text) else { return "" }; return String(text[r]) }
        let before = group(1), after = group(4)
        guard (before.isEmpty != after.isEmpty),let source = currency(before.isEmpty ? after : before),let target = currency(group(5)),var amount = Decimal(string: group(2).replacingOccurrences(of: ",",with: ""),locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        if !group(3).isEmpty { amount *= group(3).lowercased() == "k" ? 1_000 : 1_000_000 }
        guard !amount.isNaN,abs(NSDecimalNumber(decimal: amount).doubleValue) <= 1e18 else { return nil }
        return Self(amount: amount,source: source,target: target)
    }
    func converted(using rate: Decimal) throws -> Decimal {
        var a = amount,b = rate,value = Decimal()
        let error = NSDecimalMultiply(&value,&a,&b,.bankers)
        guard error == .noError || error == .lossOfPrecision,!value.isNaN else { throw ExchangeRateError.invalidRate }
        return value
    }
}

struct ExchangeRateQuote: Codable, Equatable, Sendable {
    let source: String
    let target: String
    let rate: Decimal
    /// Timestamp reported by the data provider, not the time we downloaded it.
    let quotedAt: Date
    let fetchedAt: Date
    let provider: String
    var pair: String { source + "-" + target }
    var isCrypto: Bool { CurrencyConversionQuery.crypto.contains(source) || CurrencyConversionQuery.crypto.contains(target) }
    var cacheLifetime: TimeInterval { isCrypto ? 60 : 900 }
    var maximumAge: TimeInterval { isCrypto ? 86_400 : 7 * 86_400 }
    func valid(at now: Date) -> Bool {
        let number = NSDecimalNumber(decimal: rate).doubleValue
        return number.isFinite && number > 0 && !rate.isNaN && fetchedAt <= now.addingTimeInterval(300) && quotedAt <= now.addingTimeInterval(300) && now.timeIntervalSince(quotedAt) <= maximumAge && now.timeIntervalSince(fetchedAt) <= maximumAge
    }
}
struct ExchangeRateSnapshot: Equatable, Sendable {
    let quote: ExchangeRateQuote
    /// True only when a refresh failed and an older cached quote is being used.
    let stale: Bool
}
enum ExchangeRateError: Error, LocalizedError {
    case unavailable, invalidRate, unsupportedPair, responseTooLarge
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Rates unavailable. Try again."
        case .invalidRate: return "Couldn’t verify this rate."
        case .unsupportedPair: return "No Google Finance rate for this pair."
        case .responseTooLarge: return "Rate response was too large."
        }
    }
}

enum GoogleFinanceRateParser {
    static func parse(_ html: String,source: String,target: String,now: Date = Date()) throws -> ExchangeRateQuote {
        guard html.utf8.count <= 2_500_000 else { throw ExchangeRateError.responseTooLarge }
        let tags = try NSRegularExpression(pattern: #"<[^>]*\bdata-last-price\s*=[^>]*>"#,options: .caseInsensitive)
        let attributes = try NSRegularExpression(pattern: #"\b(data-[a-z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,options: .caseInsensitive)
        for tagMatch in tags.matches(in: html,range: NSRange(html.startIndex...,in: html)) {
            guard let range = Range(tagMatch.range,in: html) else { continue }
            let tag = String(html[range]); var values: [String:String] = [:]
            for match in attributes.matches(in: tag,range: NSRange(tag.startIndex...,in: tag)) {
                guard let keyRange = Range(match.range(at: 1),in: tag) else { continue }
                for i in 2...4 { if let valueRange = Range(match.range(at: i),in: tag) { values[String(tag[keyRange]).lowercased()] = String(tag[valueRange]); break } }
            }
            // Bind the price and timestamp to this exact pair; never use a related asset's price.
            guard values["data-source"] == source,values["data-target"] == target else { continue }
            guard let raw = values["data-last-price"],raw.range(of: #"^\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$"#,options: .regularExpression) != nil,let rate = Decimal(string: raw,locale: Locale(identifier: "en_US_POSIX")),let stamp = values["data-last-normal-market-timestamp"],let seconds = TimeInterval(stamp),seconds.isFinite else { throw ExchangeRateError.invalidRate }
            let quote = ExchangeRateQuote(source: source,target: target,rate: rate,quotedAt: Date(timeIntervalSince1970: seconds),fetchedAt: now,provider: "Google Finance")
            guard quote.valid(at: now) else { throw ExchangeRateError.invalidRate }
            return quote
        }
        // The redesigned Finance page embeds JSON quote tuples instead of data-* attributes.
        // Decode data only (never execute page scripts), and require both independent pair IDs.
        let chunks = try NSRegularExpression(pattern: #"AF_initDataCallback\(\{[^<]*?\bdata:\s*(\[.*?\])\s*,\s*sideChannel:"#,options: .dotMatchesLineSeparators)
        func findQuote(_ object: Any,depth: Int = 0) throws -> ExchangeRateQuote? {
            guard depth < 32,let tuple = object as? [Any] else { return nil }
            if tuple.count > 21,tuple[21] as? String == source + "-" + target,
               let identity = tuple[15] as? [Any],identity.count >= 2,
               identity[0] as? String == source,identity[1] as? String == target,
               (tuple[3] as? NSNumber)?.intValue == 3 {
                guard let prices = tuple[5] as? [Any],let price = prices.first as? NSNumber,
                      CFGetTypeID(price) != CFBooleanGetTypeID(),
                      let timestamps = tuple[17] as? [Any],let timestamp = timestamps.first as? NSNumber,
                      CFGetTypeID(timestamp) != CFBooleanGetTypeID(),
                      let rate = Decimal(string: price.stringValue,locale: Locale(identifier: "en_US_POSIX")) else { throw ExchangeRateError.invalidRate }
                let quote = ExchangeRateQuote(source:source,target:target,rate:rate,quotedAt:Date(timeIntervalSince1970:timestamp.doubleValue),fetchedAt:now,provider:"Google Finance")
                guard quote.valid(at:now) else { throw ExchangeRateError.invalidRate }
                return quote
            }
            for child in tuple { if let quote = try findQuote(child,depth:depth+1) { return quote } }
            return nil
        }
        for match in chunks.matches(in:html,range:NSRange(html.startIndex...,in:html)) {
            guard let range = Range(match.range(at:1),in:html),
                  let object = try? JSONSerialization.jsonObject(with:Data(html[range].utf8)) else { continue }
            if let quote = try findQuote(object) { return quote }
        }
        throw ExchangeRateError.unsupportedPair
    }
}

actor ExchangeRateService {
    typealias Loader = @Sendable (URL) async throws -> Data
    static let shared = ExchangeRateService()
    private var cache: [String:ExchangeRateQuote]
    private var pending: [String:Task<ExchangeRateQuote,Error>] = [:]
    private var retryAfter: [String:Date] = [:]
    private let loader: Loader
    private let clock: @Sendable () -> Date
    private let cacheURL: URL?
    static var defaultCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory,in: .userDomainMask)[0].appendingPathComponent("switcharoo/exchange-rates-v1.json")
    }
    init(cacheURL: URL? = ExchangeRateService.defaultCacheURL,clock: @escaping @Sendable () -> Date = { Date() },loader: @escaping Loader = { try await ExchangeRateService.download($0) }) {
        self.cacheURL = cacheURL; self.clock = clock; self.loader = loader
        if let cacheURL,let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,size <= 500_000,let data = try? Data(contentsOf: cacheURL),let saved = try? JSONDecoder().decode([String:ExchangeRateQuote].self,from: data) {
            cache = saved.filter { $0.key == $0.value.pair && $0.value.valid(at: clock()) }
        } else { cache = [:] }
    }
    func quote(source: String,target: String,forceRefresh: Bool = false) async throws -> ExchangeRateSnapshot {
        guard CurrencyConversionQuery.currency(source) == source,CurrencyConversionQuery.currency(target) == target else { throw ExchangeRateError.unsupportedPair }
        // Finance lists crypto against fiat; Soulver asks for rates from USD.
        if !CurrencyConversionQuery.crypto.contains(source),CurrencyConversionQuery.crypto.contains(target) {
            let inverse = try await quote(source:target,target:source,forceRefresh:forceRefresh)
            var one = Decimal(1),divisor = inverse.quote.rate,rate = Decimal()
            let status = NSDecimalDivide(&rate,&one,&divisor,.bankers)
            guard (status == .noError || status == .lossOfPrecision),!rate.isNaN,rate > 0 else { throw ExchangeRateError.invalidRate }
            return .init(quote:.init(source:source,target:target,rate:rate,quotedAt:inverse.quote.quotedAt,fetchedAt:inverse.quote.fetchedAt,provider:inverse.quote.provider),stale:inverse.stale)
        }
        let now = clock(),key = source + "-" + target
        if source == target { return .init(quote: .init(source: source,target: target,rate: 1,quotedAt: now,fetchedAt: now,provider: "Identity"),stale: false) }
        let saved = cache[key].flatMap { $0.valid(at: now) ? $0 : nil }
        if !forceRefresh,let saved,now.timeIntervalSince(saved.fetchedAt) < saved.cacheLifetime { return .init(quote: saved,stale: false) }
        if !forceRefresh,let retry = retryAfter[key],retry > now {
            if let saved { return .init(quote: saved,stale: true) }; throw ExchangeRateError.unavailable
        }
        let task: Task<ExchangeRateQuote,Error>
        if let existing = pending[key] { task = existing }
        else {
            task = Task {
                defer { pending[key] = nil }
                do {
                    var components = URLComponents(string: "https://www.google.com/finance/quote/" + key)!
                    components.queryItems = [.init(name: "hl",value: "en")]
                    let data = try await loader(components.url!)
                    guard let html = String(data: data,encoding: .utf8) else { throw ExchangeRateError.invalidRate }
                    let value = try GoogleFinanceRateParser.parse(html,source: source,target: target,now: clock())
                    cache[key] = value; retryAfter[key] = nil; save()
                    return value
                } catch { retryAfter[key] = clock().addingTimeInterval(30); throw error }
            }
            pending[key] = task
        }
        do {
            let value = try await task.value
            try Task.checkCancellation()
            return .init(quote: value,stale: false)
        } catch {
            try Task.checkCancellation()
            if let saved, saved.valid(at: clock()) { return .init(quote: saved,stale: true) }
            throw error
        }
    }
    private func save() {
        let now = clock()
        cache = cache.filter { $0.value.valid(at: now) }
        if cache.count > 256 { cache = Dictionary(uniqueKeysWithValues: cache.sorted { $0.value.fetchedAt > $1.value.fetchedAt }.prefix(256).map { ($0.key,$0.value) }) }
        guard let cacheURL,let data = try? JSONEncoder().encode(cache) else { return }
        do { try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),withIntermediateDirectories: true); try data.write(to: cacheURL,options: .atomic) } catch { /* A read-only cache must not prevent conversion. */ }
    }
    static func download(_ url: URL) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.setValue("text/html",forHTTPHeaderField: "Accept")
        let (bytes,response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,http.statusCode == 200,http.url?.host == "www.google.com" else { throw ExchangeRateError.unavailable }
        guard response.expectedContentLength <= 2_500_000 else { throw ExchangeRateError.responseTooLarge }
        var data = Data(); data.reserveCapacity(1_200_000)
        for try await byte in bytes { guard data.count < 2_500_000 else { throw ExchangeRateError.responseTooLarge }; data.append(byte) }
        return data
    }
}
