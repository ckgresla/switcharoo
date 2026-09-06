import Foundation

@main struct CalculatorModelTests {
    @MainActor static func main() async throws {
        var calls: [(String,(CalculatorResponse)->Void)] = []
        let model = CalculatorModel(evaluate:{ request,completion in
            calls.append((request["query"] as! String,completion)); return DispatchWorkItem {}
        })
        func pause(_ ms: UInt64) async { try? await Task.sleep(nanoseconds:ms*1_000_000) }
        let four = CalculatorAnswer(value:"4",raw:"4",kind:"Calculation")
        model.update("2"); await pause(40); model.update("2+"); await pause(40); model.update("2+2")
        await pause(70); precondition(calls.isEmpty,"no evaluation during continuous typing")
        await pause(80); precondition(calls.count == 1 && calls[0].0 == "2+2")
        calls[0].1(.init(result:four)); precondition(model.canCopy && model.answer == four)
        model.update("2+3"); precondition(model.answer == four && !model.canCopy,"keep old result but never copy it")
        await pause(150); precondition(calls.count == 2)
        model.update("2+4"); calls[1].1(.init(result:.init(value:"5",raw:"5",kind:"Calculation")))
        precondition(model.answer == four,"ignore stale completion")
        await pause(150); calls[2].1(.init(result:.init(value:"6",raw:"6",kind:"Calculation")))
        precondition(model.canCopy && model.answer?.value == "6")
        model.update("2+"); await pause(150); calls[3].1(.init(incomplete:true))
        precondition(model.answer?.value == "6" && !model.canCopy,"incomplete input retains stable result")
        model.update(""); precondition(!model.hasContent && !model.canCopy)
        model.update("3+3"); model.update(""); await pause(150)
        precondition(calls.count == 4,"clear cancels scheduled evaluation")

        precondition(CalculatorModel.inputDelay(for:"now") == 0.02)
        precondition(CalculatorModel.inputDelay(for:" TODAY ") == 0.02)
        precondition(CalculatorModel.inputDelay(for:"2+2") == 0.1)
        precondition(CalculatorModel.inputDelay(for:"now +") == 0.1)
        model.update("now"); await pause(60)
        precondition(calls.count == 5 && calls[4].0 == "now","clock keyword uses the fast path")
        model.update("now + 2h"); calls[4].1(.init(result:four))
        precondition(model.answer == nil && !model.canCopy,"fast keywords still reject stale replies")
        model.update("")

        var rateCalls = 0
        let currency = CalculatorModel(evaluate:{ request,completion in
            DispatchQueue.main.async {
                if let rates = request["rates"] as? [String:String],rates["USD-EUR"] == "0.9" {
                    completion(.init(result:.init(value:"€90.00",raw:"90 EUR",kind:"Unit conversion")))
                } else { completion(.init(currencyRequests:[.init(source:"USD",target:"EUR",historical:false)])) }
            }
            return DispatchWorkItem {}
        },rateProvider:{ source,target,_ in
            rateCalls += 1
            return .init(quote:.init(source:source,target:target,rate:Decimal(string:"0.9")!,quotedAt:Date(),fetchedAt:Date(),provider:"Test provider"),stale:false)
        })
        currency.update("100 USD in EUR"); await pause(350)
        precondition(currency.canCopy && currency.answer?.raw == "90 EUR" && rateCalls == 1)
        precondition(currency.attribution?.contains("Test provider") == true)
        currency.refresh(); await pause(350); precondition(rateCalls == 2)

        let suite = "switcharoo.calculator.tests."+UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        var now = Date(timeIntervalSince1970:1_780_000_000)
        let history = CalculatorHistory(defaults:defaults,clock:{now})
        history.record(query:"2+2",answer:four); history.record(query:"2+2",answer:four)
        precondition(history.entries.count == 1,"deduplicate repeated queries")
        history.togglePin(history.entries[0].id)
        history.record(query:"3+1",answer:four)
        now += 120*86400
        history.record(query:"1+3",answer:four)
        precondition(Set(history.entries.map(\.query)) == ["2+2","1+3"],"expire unpinned after three months")
        let reopened = CalculatorHistory(defaults:defaults,clock:{now})
        precondition(reopened.entries == history.entries,"persistent history")
        precondition(reopened.search("2+2").count == 1)
        reopened.clearUnpinned(); precondition(reopened.entries.count == 1 && reopened.entries[0].pinned)
        reopened.delete(reopened.entries[0].id); precondition(reopened.entries.isEmpty)
        print("24 calculator interaction checks passed (20/100 ms debounce, stable results, stale completion, rates, history)")
    }
}
