import Foundation

private let instant = Date(timeIntervalSince1970: 1_788_580_000)
private func html(_ source: String = "USD", _ target: String = "EUR", rate: String = "0.86", at: Date = instant) -> Data {
    Data("<div data-source='\(source)' data-last-price='\(rate)' data-target='\(target)' data-last-normal-market-timestamp='\(Int(at.timeIntervalSince1970))'>".utf8)
}
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock(); private var value = instant
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: Double) { lock.lock(); value += seconds; lock.unlock() }
}
private actor Transport {
    var calls = 0; var fail = false; var urls: [URL] = []
    func setFailure() { fail = true }
    func load(_ url: URL) async throws -> Data {
        calls += 1; urls.append(url)
        try await Task.sleep(nanoseconds: 40_000_000)
        if fail { throw ExchangeRateError.unavailable }
        return html()
    }
}
@main struct RateTests {
    static var checks = 0
    static func check(_ value: Bool,_ label: String) { checks += 1; if !value { fatalError("FAIL: \(label)") } }
    static func rejects(_ body: () throws -> Void,_ label: String) { do { try body(); check(false,label) } catch { check(true,label) } }
    static func main() async throws {
        let inputs: [(String,String,String,String)] = [
            ("100 USD in EUR","100","USD","EUR"),("$100 to GBP","100","USD","GBP"),
            ("convert 1,234.50 euros to dollars?","1234.5","EUR","USD"),("USD100 in GBP","100","USD","GBP"),
            ("1k USD to EUR","1000","USD","EUR"),("2m GBP in USD","2000000","GBP","USD"),
            (".25 BTC in USD","0.25","BTC","USD"),("-4 USD to EUR","-4","USD","EUR"),
            ("100 KRW to USD","100","KRW","USD"),("100 MXN to USD","100","MXN","USD"),
            ("100KRW to USD","100","KRW","USD"),("0 USD in EUR","0","USD","EUR")]
        for (text,amount,source,target) in inputs { let q = CurrencyConversionQuery.parse(text); check(q?.amount == Decimal(string: amount) && q?.source == source && q?.target == target,"parse \(text)") }
        for text in ["100 Mbps in MB/s","100 MB in GB","100 USD GBP to EUR","10 xyz to usd","1,23 USD to EUR","1e6 USD in EUR","USD in EUR","10000000000000000000 USD to EUR"] { check(CurrencyConversionQuery.parse(text) == nil,"reject \(text)") }
        let query = CurrencyConversionQuery.parse("0.1 USD to EUR")!
        check(try query.converted(using: Decimal(string:"0.2")!) == Decimal(string:"0.02"),"decimal precision")
        let valid = String(data: html(),encoding: .utf8)!
        let decoy = String(data: html("BTC","USD",rate:"90000"),encoding: .utf8)! + valid
        let quote = try GoogleFinanceRateParser.parse(decoy,source:"USD",target:"EUR",now:instant)
        check(quote.rate == Decimal(string:"0.86") && quote.quotedAt == instant,"pair-bound price and timestamp")
        for (data,label) in [(html(rate:"0"),"zero"),(html(rate:"NaN"),"nan"),(html(at:instant+301),"future"),(html(at:instant-8*86400),"expired"),(Data(valid.replacingOccurrences(of:"data-last-normal-market-timestamp",with:"ignored").utf8),"missing timestamp")] {
            rejects({ _ = try GoogleFinanceRateParser.parse(String(data:data,encoding:.utf8)!,source:"USD",target:"EUR",now:instant) },label)
        }
        rejects({ _ = try GoogleFinanceRateParser.parse(valid,source:"EUR",target:"USD",now:instant) },"wrong pair")
        rejects({ _ = try GoogleFinanceRateParser.parse(String(repeating:"x",count:2_500_001),source:"USD",target:"EUR",now:instant) },"size bound")
        for pair in ["USD-EUR","USD-GBP","BTC-USD"] {
            let payload = try String(contentsOfFile:"Tests/Fixtures/"+pair+".json",encoding:.utf8)
            let codes = pair.split(separator:"-").map(String.init)
            let page = "<script>AF_initDataCallback({key: 'ds:17', hash: '6', data:[["+payload+"]], sideChannel: {}});</script>"
            let parsed = try GoogleFinanceRateParser.parse(page,source:codes[0],target:codes[1],now:Date(timeIntervalSince1970:1788638000))
            check(parsed.rate > 0 && parsed.pair == pair,"beta quote \(pair)")
            let wrongIdentity = page.replacingOccurrences(of:"[\""+codes[0]+"\", \""+codes[1]+"\"",with:"[\"XXX\", \"YYY\"")
            rejects({ _ = try GoogleFinanceRateParser.parse(wrongIdentity,source:codes[0],target:codes[1],now:Date(timeIntervalSince1970:1788638000)) },"beta identity mismatch")
        }
        let clock = TestClock(), transport = Transport()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let cache = folder.appendingPathComponent("rates.json")
        let service = ExchangeRateService(cacheURL:cache,clock:{clock.now()},loader:{try await transport.load($0)})
        async let one = service.quote(source:"USD",target:"EUR")
        async let two = service.quote(source:"USD",target:"EUR")
        let pair = try await (one,two)
        check(pair.0 == pair.1,"coalesced same result")
        check(await transport.calls == 1,"coalesced one request")
        _ = try await service.quote(source:"USD",target:"EUR")
        check(await transport.calls == 1,"fresh cache")
        check(await transport.urls.first?.absoluteString == "https://www.google.com/finance/quote/USD-EUR?hl=en","only currency pair sent")
        let reloaded = ExchangeRateService(cacheURL:cache,clock:{clock.now()},loader:{_ in throw ExchangeRateError.unavailable})
        check(try await reloaded.quote(source:"USD",target:"EUR").stale == false,"disk cache survives restart")
        _ = try await service.quote(source:"USD",target:"USD")
        check(await transport.calls == 1,"identity needs no request")
        await transport.setFailure(); clock.advance(901)
        check(try await service.quote(source:"USD",target:"EUR").stale,"failed refresh labels cached data")
        check(await transport.calls == 2,"TTL triggers refresh")
        _ = try await service.quote(source:"USD",target:"EUR")
        check(await transport.calls == 2,"retry cooldown")
        _ = try await service.quote(source:"USD",target:"EUR",forceRefresh:true)
        check(await transport.calls == 3,"manual refresh bypasses cooldown")
        clock.advance(8*86400)
        do { _ = try await service.quote(source:"USD",target:"EUR"); check(false,"expired cache unavailable") } catch { check(true,"expired cache unavailable") }
        let crypto = try GoogleFinanceRateParser.parse(String(data:html("BTC","USD",rate:"79000"),encoding:.utf8)!,source:"BTC",target:"USD",now:instant)
        check(crypto.cacheLifetime == 60 && !crypto.valid(at:instant+86401),"short crypto cache and expiry")
        var usage = LauncherUsage()
        let available = ["a","b","c","d"]
        check(usage.topThree(available:available,fallback:["b","b","c","d"]) == [],"bar empty until pinned")
        usage.record("a",at:instant); usage.record("b",at:instant+1); usage.record("a",at:instant)
        check(usage.topThree(available:available,fallback:["c"]) == [],"usage does not populate bar")
        usage.togglePin("d"); usage.togglePin("c")
        check(usage.topThree(available:available,fallback:[]) == ["d","c"],"only pins in bar")
        usage.togglePin("b"); usage.togglePin("a")
        check(usage.pinned == ["d","c","b"],"three pin limit")
        usage.togglePin("c")
        check(usage.pinned == ["d","b"],"unpin")
        check(usage.topThree(available:["a","c"],fallback:["c"]) == [],"ignore removed pinned apps")
        let restored = try JSONDecoder().decode(LauncherUsage.self,from:JSONEncoder().encode(usage))
        check(restored == usage,"usage persistence")
        var tied = LauncherUsage(); tied.record("a",at:instant); tied.record("b",at:instant+1)
        check(tied.topThree(available:available,fallback:[]) == [],"recent use does not populate bar")
        check(usage.ranked(available:available,fallback:["c"]) == ["d","b","a","c"],"full catalog includes every item with pins first")
        check(Set(usage.ranked(available:available+available,fallback:[])) == Set(available),"full catalog deduplicates without omissions")
        let suite = "switcharoo.tests."+UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let preferences = LauncherPreferences(defaults:defaults)
        check(!preferences.commandsOpen,"first launch compact")
        preferences.commandsOpen = true; preferences.usage = usage
        let reopened = LauncherPreferences(defaults:UserDefaults(suiteName:suite)!)
        check(reopened.commandsOpen && reopened.usage == usage,"reopening restores open state and pins")
        reopened.commandsOpen = false
        check(!preferences.commandsOpen,"closing persists compact preference")
        let model = await MainActor.run { RateConversionModel(provider: { q,_ in
            if q.source == "USD" { try? await Task.sleep(nanoseconds:150_000_000) }
            return .init(quote:.init(source:q.source,target:q.target,rate:2,quotedAt:instant,fetchedAt:instant,provider:"Fixture"),stale:false)
        }) }
        await MainActor.run { model.update("100 USD in EUR",forceRefresh:true) }
        try await Task.sleep(nanoseconds:20_000_000)
        await MainActor.run { model.update("3 GBP in EUR",forceRefresh:true) }
        try await Task.sleep(nanoseconds:200_000_000)
        check(await MainActor.run { model.conversion?.amount == 6 && model.conversion?.request.source == "GBP" && !model.loading },"old response cannot replace newer query")
        await MainActor.run { model.update("ordinary app search") }
        check(await MainActor.run { model.request == nil && model.conversion == nil && !model.loading },"clear conversion for app search")
        print("\(checks) rate and launcher usage checks passed")
        if CommandLine.arguments.contains("--live") {
            let live = ExchangeRateService(cacheURL:nil)
            for (source,target) in [("USD","EUR"),("USD","GBP"),("BTC","USD")] {
                let start = Date()
                let snapshot = try await live.quote(source:source,target:target)
                let elapsed = Date().timeIntervalSince(start)
                print("LIVE \(source)-\(target): \(snapshot.quote.rate), quoted \(snapshot.quote.quotedAt.ISO8601Format()), \(String(format:"%.2f",elapsed))s")
                let cachedStart = Date(); _ = try await live.quote(source:source,target:target)
                print("CACHE \(source)-\(target): \(String(format:"%.3f",Date().timeIntervalSince(cachedStart)*1000))ms")
            }
        }
    }
}
