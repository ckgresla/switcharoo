import Foundation
import SoulverCore

struct CalculatorCurrencyRequest: Codable, Equatable {
    let source: String
    let target: String
    let historical: Bool
}
private final class SuppliedCurrencyRates: CurrencyRateProvider {
    var rates: [String:String] = [:]
    var missing: [CalculatorCurrencyRequest] = []
    func rateFor(request: CurrencyRateRequest) -> Decimal? {
        let item = CalculatorCurrencyRequest(source:request.fromCurrency,target:request.toCurrency,historical:request.date != nil)
        if !item.historical, let rate = rates[item.source+"-"+item.target].flatMap({Decimal(string:$0,locale:Locale(identifier:"en_US_POSIX"))}) { return rate }
        if !missing.contains(item) { missing.append(item) }
        return nil
    }
}

final class SoulverCalculator {
    private let provider = SuppliedCurrencyRates()
    private var calculator: Calculator?
    private var settingsKey = ""
    func evaluate(_ request: [String:Any]) -> CalculatorResponse {
        let original = request["query"] as? String ?? ""
        let query = original
            .replacingOccurrences(of:#"^\s*(.+)%\s+tip\s+on\s+(.+)$"#,with:"($2) * ($1)%",options:[.regularExpression,.caseInsensitive])
            .replacingOccurrences(of:#"^\s*ratio\s+of\s+(.+)\s+to\s+(.+)$"#,with:"($1) / ($2)",options:[.regularExpression,.caseInsensitive])
        guard query.count <= 400 else { return .init(error:"Expression is too long") }
        let trimmed = query.trimmingCharacters(in:.whitespacesAndNewlines)
        if trimmed.range(of:#"(?:[+*/^−-]|\b(?:in|to|per|of|at))\s*$"#,options:.regularExpression) != nil || query.filter({$0 == "("}).count > query.filter({$0 == ")"}).count {
            return .init(incomplete:true)
        }
        let locale = request["locale"] as? String ?? Locale.current.identifier
        let rem = max(1,min(1000,request["rem"] as? Double ?? 16))
        let automatic = request["automaticUnits"] as? Bool ?? true
        let key = "\(locale):\(rem):\(automatic):\(TimeZone.current.identifier)"
        if calculator == nil || settingsKey != key {
            var customization = EngineCustomization.standardWith(locale:Locale(identifier:locale))
            customization.currencyRateProvider = provider
            customization.featureFlags.useDefaultRatesForUnhandledCurrencies = false
            customization.customPlaces += [
                Place(name:"London",aliases:["ldn"],timeZone:TimeZone(identifier:"Europe/London")!),
                Place(name:"San Francisco",aliases:["sf"],timeZone:TimeZone(identifier:"America/Los_Angeles")!),
                Place(name:"New York",aliases:["nyc"],timeZone:TimeZone(identifier:"America/New_York")!),
                Place(name:"Los Angeles",aliases:["la"],timeZone:TimeZone(identifier:"America/Los_Angeles")!)
            ]
            customization.baseFontSize = Decimal(rem)
            let calculator = Calculator(customization:customization)
            var formatting = FormattingPreferences(); formatting.dp = 10
            formatting.resultConversionBehavior = automatic ? .automatic : .none
            calculator.formattingPreferences = formatting
            self.calculator = calculator; settingsKey = key
        }
        guard let calculator else { return .init(error:"Calculator unavailable") }
        provider.rates = request["rates"] as? [String:String] ?? [:]; provider.missing = []
        let answer = calculator.calculate(query)
        if !provider.missing.isEmpty { return .init(currencyRequests:provider.missing) }
        guard !answer.isEmptyResult,!answer.isFailedResult,!answer.isPendingResult else { return .init() }
        if case .error = answer.evaluationResult { return .init(error:answer.stringValue) }
        // Suppress app names with incidental numbers, while retaining 10K, pi, etc.
        if case .singleNumber = answer.parsedExpression?.metadata.form {
            var ignoredWord = false
            answer.parsedExpression?.metadata.semantics.enumerate(.allTokens) { if $0.type == .other { ignoredWord = true } }
            if ignoredWord { return .init() }
        }
        let raw = EvaluationResultFormatter(customization:calculator.customization,formattingPreferences:.unformatted).format(result:answer.evaluationResult).stringValue
        var kind = "Calculation"
        switch answer.evaluationResult {
        case .unitExpression: kind = "Unit conversion"
        case .unitRate,.decimalRate,.percentageRate: kind = "Rate"
        case .date,.iso8601,.timestamp: kind = "Date & time"
        case .timespan,.datespan,.laptime: kind = "Duration"
        case .percentage: kind = "Percentage"
        default: break
        }
        var swap: String?
        if case let .conversion(from,to,quantity) = answer.parsedExpression?.metadata.form {
            swap = NSDecimalNumber(decimal:quantity).stringValue+" "+to.symbol+" in "+from.symbol
        }
        return .init(result:.init(value:answer.stringValue,raw:raw,kind:kind,swap:swap))
    }
}
