import Foundation

struct FilterMetricInfo: Sendable {
    let key: String, label: String, group: String, description: String, unit: String
    let numeric: Bool
    var snapshot: [String: Any] { ["key": key, "label": label, "group": group, "description": description, "unit": unit, "numeric": numeric,
        "choices": FilterCatalog.choices(for: key).map { ["value": $0.value, "label": $0.label] }] }
}

enum FilterCatalog {
    struct Choice: Sendable { let value: String, label: String }
    static func choices(for key: String) -> [Choice] {
        switch key {
        case "emaTrend", "oiTrend": return [.init(value: "rising", label: "Rising"), .init(value: "flat", label: "Flat"), .init(value: "falling", label: "Falling")]
        case "emaBody": return [.init(value: "above", label: "Entire body above"), .init(value: "below", label: "Entire body below"), .init(value: "cross-up", label: "Crossing upward"), .init(value: "cross-down", label: "Crossing downward"), .init(value: "touching", label: "Touching EMA200")]
        case "candleDirection": return [.init(value: "above", label: "Bullish"), .init(value: "below", label: "Bearish"), .init(value: "equal", label: "Doji")]
        case "priceEMA", "rsi6vs12", "rsi12vs24", "rocVsMaroc", "buyVsSell", "priceUpper", "priceMiddle", "priceLower", "priceVWAP": return [.init(value: "above", label: "Above / greater"), .init(value: "equal", label: "Equal"), .init(value: "below", label: "Below / less")]
        case "high48", "high96", "closeHigh48", "closeHigh96", "low48", "low96", "closeLow48", "closeLow96", "recentHigh48", "recentHigh96", "recentLow48", "recentLow96": return [.init(value: "yes", label: "Yes"), .init(value: "no", label: "No")]
        case "bbZone": return [.init(value: "upper", label: "Above upper"), .init(value: "middle", label: "Middle < price ≤ upper"), .init(value: "lower", label: "Lower < price ≤ middle"), .init(value: "below", label: "At / below lower")]
        case "bbExpansionComplete": return [.init(value: "complete", label: "Complete"), .init(value: "partial", label: "Lower bound (≥)")]
        case "opportunityStatus": return ["Candidate", "Watch", "Overheated", "Incomplete"].map { .init(value: $0, label: $0) }
        case "opportunityDirection": return ["Long", "Short"].map { .init(value: $0, label: $0) }
        case "opportunitySetup": return ["Startup", "Pullback"].map { .init(value: $0, label: $0) }
        default: return []
        }
    }
    static let metrics: [FilterMetricInfo] = [
        .init(key: "emaTrend", label: "EMA200 trend", group: "EMA & live candle", description: "Live EMA200 compared with the previous completed hour's EMA200.", unit: "category", numeric: false),
        .init(key: "emaSlope", label: "EMA200 hourly slope (%)", group: "EMA & live candle", description: "Percentage change of live EMA200 from the previous completed EMA200.", unit: "%", numeric: true),
        .init(key: "emaBody", label: "Live body vs EMA200", group: "EMA & live candle", description: "Open and live close only; wicks do not affect this relation. Touching includes equality at either end.", unit: "category", numeric: false),
        .init(key: "priceEMA", label: "Live price vs EMA200", group: "EMA & live candle", description: "Live close compared with the current EMA200, including the live candle.", unit: "category", numeric: false),
        .init(key: "emaDistance", label: "Distance from EMA200 (%)", group: "EMA & live candle", description: "Signed (live close − EMA200) / EMA200 × 100%.", unit: "%", numeric: true),
        .init(key: "candleDirection", label: "Live candle direction", group: "EMA & live candle", description: "Live close compared with its open.", unit: "category", numeric: false),
        .init(key: "bodyChange", label: "Live body change (%)", group: "EMA & live candle", description: "Signed change from live open to live close; excludes wicks.", unit: "%", numeric: true),
        .init(key: "candleRange", label: "Live high–low range (%)", group: "EMA & live candle", description: "(Live high − live low) / live low × 100%.", unit: "%", numeric: true),
        .init(key: "rsi6", label: "RSI6", group: "RSI", description: "Live RSI over 6 one-hour periods; 0–100.", unit: "0–100", numeric: true),
        .init(key: "rsi12", label: "RSI12", group: "RSI", description: "Live RSI over 12 one-hour periods; 0–100.", unit: "0–100", numeric: true),
        .init(key: "rsi24", label: "RSI24", group: "RSI", description: "Live RSI over 24 one-hour periods; 0–100.", unit: "0–100", numeric: true),
        .init(key: "rsi6vs12", label: "RSI6 vs RSI12", group: "RSI", description: "Compare the fast and medium RSI readings.", unit: "category", numeric: false),
        .init(key: "rsi12vs24", label: "RSI12 vs RSI24", group: "RSI", description: "Compare the medium and slow RSI readings.", unit: "category", numeric: false),
        .init(key: "roc", label: "ROC9 (%)", group: "Momentum", description: "9-hour price change. Use Positive / Negative and Absolute value ≥ as separate conditions.", unit: "%", numeric: true),
        .init(key: "maroc", label: "MAROC9 (%)", group: "Momentum", description: "Mean of nine hourly ROC9 readings, in percent.", unit: "%", numeric: true),
        .init(key: "rocVsMaroc", label: "ROC vs MAROC", group: "Momentum", description: "Compare the current ROC and MAROC readings.", unit: "category", numeric: false),
        .init(key: "rocChange", label: "ROC hourly change (%)", group: "Momentum", description: "(ROC − previous ROC) / |previous ROC| × 100%.", unit: "%", numeric: true),
        .init(key: "marocChange", label: "MAROC hourly change (%)", group: "Momentum", description: "(MAROC − previous MAROC) / |previous MAROC| × 100%.", unit: "%", numeric: true),
        .init(key: "high48", label: "Live wick breaks 48h high", group: "Breakouts", description: "Live high strictly exceeds the previous 48 completed hourly highs. A retreat does not undo a wick break.", unit: "category", numeric: false),
        .init(key: "high96", label: "Live wick breaks 96h high", group: "Breakouts", description: "Live high strictly exceeds the previous 96 completed hourly highs.", unit: "category", numeric: false),
        .init(key: "closeHigh48", label: "Live close above 48h high", group: "Breakouts", description: "Live close is still strictly above the previous 48 completed hourly highs.", unit: "category", numeric: false),
        .init(key: "closeHigh96", label: "Live close above 96h high", group: "Breakouts", description: "Live close is still strictly above the previous 96 completed hourly highs.", unit: "category", numeric: false),
        .init(key: "low48", label: "Live wick breaks 48h low", group: "Breakouts", description: "Live low strictly falls below the previous 48 completed hourly lows.", unit: "category", numeric: false),
        .init(key: "low96", label: "Live wick breaks 96h low", group: "Breakouts", description: "Live low strictly falls below the previous 96 completed hourly lows.", unit: "category", numeric: false),
        .init(key: "closeLow48", label: "Live close below 48h low", group: "Breakouts", description: "Live close is still strictly below the previous 48 completed hourly lows.", unit: "category", numeric: false),
        .init(key: "closeLow96", label: "Live close below 96h low", group: "Breakouts", description: "Live close is still strictly below the previous 96 completed hourly lows.", unit: "category", numeric: false),
        .init(key: "recentHigh48", label: "Recent 48h high breakout", group: "Breakouts", description: "At least one 48h high breakout in the live hour or previous 47 hours. Loading or insufficient history is unavailable.", unit: "category", numeric: false),
        .init(key: "recentHigh96", label: "Recent 96h high breakout", group: "Breakouts", description: "At least one 96h high breakout in the live hour or previous 47 hours.", unit: "category", numeric: false),
        .init(key: "recentLow48", label: "Recent 48h low breakdown", group: "Breakouts", description: "At least one 48h low breakdown in the live hour or previous 47 hours.", unit: "category", numeric: false),
        .init(key: "recentLow96", label: "Recent 96h low breakdown", group: "Breakouts", description: "At least one 96h low breakdown in the live hour or previous 47 hours.", unit: "category", numeric: false),
        .init(key: "high48Age", label: "48h breakout age (h)", group: "Breakouts", description: "Hours since the latest 48h high breakout, within the 48h search window. Live is 0; no event is unavailable.", unit: "hours", numeric: true),
        .init(key: "high96Age", label: "96h breakout age (h)", group: "Breakouts", description: "Hours since the latest 96h high breakout, within the 48h search window. Live is 0.", unit: "hours", numeric: true),
        .init(key: "low48Age", label: "48h breakdown age (h)", group: "Breakouts", description: "Hours since the latest 48h low breakdown. Live is 0; no event is unavailable.", unit: "hours", numeric: true),
        .init(key: "low96Age", label: "96h breakdown age (h)", group: "Breakouts", description: "Hours since the latest 96h low breakdown. Live is 0.", unit: "hours", numeric: true),
        .init(key: "highPriorAge", label: "Previous high age at break (h)", group: "Breakouts", description: "Age of the previous 48h high at the latest breakout; tied highs use the most recent occurrence.", unit: "hours", numeric: true),
        .init(key: "buyVsSell", label: "Buy vs Sell", group: "Participation", description: "Compare current-hour taker buy and sell contract volumes, including zero volumes.", unit: "category", numeric: false),
        .init(key: "takerRatio", label: "Taker imbalance (%)", group: "Participation", description: "(Buy − Sell) / (Buy + Sell) × 100%; −100 to 100.", unit: "%", numeric: true),
        .init(key: "buy", label: "Taker Buy (contracts)", group: "Participation", description: "Current-hour taker buy volume in contracts.", unit: "contracts", numeric: true),
        .init(key: "sell", label: "Taker Sell (contracts)", group: "Participation", description: "Current-hour taker sell volume in contracts.", unit: "contracts", numeric: true),
        .init(key: "oiTrend", label: "OI trend", group: "Participation", description: "Current OI compared with the previous completed hourly OI; rising / flat / falling.", unit: "category", numeric: false),
        .init(key: "oiChange", label: "OI hourly change (%)", group: "Participation", description: "(OI − previous OI) / |previous OI| × 100%; includes infinite changes from zero.", unit: "%", numeric: true),
        .init(key: "oiUSD", label: "Open interest (M USD)", group: "Participation", description: "Current open interest in millions of USD.", unit: "M USD", numeric: true),
        .init(key: "priceUpper", label: "Live price vs Log BB upper", group: "Bands & VWAP", description: "Live close compared with the 20h upper log-price Bollinger band. Equality is explicit.", unit: "category", numeric: false),
        .init(key: "priceMiddle", label: "Live price vs Log BB middle", group: "Bands & VWAP", description: "Live close compared with the 20h middle log-price Bollinger band.", unit: "category", numeric: false),
        .init(key: "priceLower", label: "Live price vs Log BB lower", group: "Bands & VWAP", description: "Live close compared with the 20h lower log-price Bollinger band.", unit: "category", numeric: false),
        .init(key: "bbZone", label: "Log BB price zone", group: "Bands & VWAP", description: "Matches the list's highest band strictly below the live price. Equality belongs to the lower zone.", unit: "category", numeric: false),
        .init(key: "bbWidth", label: "Log BB bandwidth (%)", group: "Bands & VWAP", description: "(Upper − Lower) / Middle × 100% for the live 20h bands.", unit: "%", numeric: true),
        .init(key: "bbExpansion", label: "Known bandwidth expansion (h)", group: "Bands & VWAP", description: "Known consecutive hours of expanding bandwidth. A ≥ reading is a lower bound: use Expansion history = Complete for an exact duration.", unit: "hours", numeric: true),
        .init(key: "bbExpansionComplete", label: "Expansion history", group: "Bands & VWAP", description: "Complete identifies the start of the expansion run; Lower bound means older history is unavailable.", unit: "category", numeric: false),
        .init(key: "priceVWAP", label: "Live price vs VWAP14", group: "Bands & VWAP", description: "Live close compared with the volume-weighted average price over 14 hours.", unit: "category", numeric: false),
        .init(key: "vwapDistance", label: "Distance from VWAP14 (%)", group: "Bands & VWAP", description: "Signed (live close − VWAP14) / VWAP14 × 100%.", unit: "%", numeric: true),
        .init(key: "price", label: "Live price (USDT)", group: "Market & opportunity", description: "Current live hourly close in USDT.", unit: "USDT", numeric: true),
        .init(key: "priceChange", label: "Hourly price change (%)", group: "Market & opportunity", description: "Live close compared with the previous completed hourly close.", unit: "%", numeric: true),
        .init(key: "turnover", label: "24h turnover (M USDT)", group: "Market & opportunity", description: "24-hour turnover in millions of USDT.", unit: "M USDT", numeric: true),
        .init(key: "spread", label: "Bid–ask spread (%)", group: "Market & opportunity", description: "Current ticker spread in percent.", unit: "%", numeric: true),
        .init(key: "liveVolume", label: "Live candle volume (USDT)", group: "Market & opportunity", description: "Current hourly candle's accumulated quote volume in USDT.", unit: "USDT", numeric: true),
        .init(key: "opportunityStatus", label: "Opportunity status", group: "Market & opportunity", description: "Current ranking classification. Scores are unchanged by filtering.", unit: "category", numeric: false),
        .init(key: "opportunityDirection", label: "Opportunity direction", group: "Market & opportunity", description: "EMA200 body direction used by Opportunity. Unclear direction is unavailable.", unit: "category", numeric: false),
        .init(key: "opportunitySetup", label: "Opportunity setup", group: "Market & opportunity", description: "Startup or Pullback; no matching setup is unavailable.", unit: "category", numeric: false),
        .init(key: "opportunityScore", label: "Opportunity score", group: "Market & opportunity", description: "Current score, 0–100. Incomplete markets have no score.", unit: "number", numeric: true),
        .init(key: "Symbol", label: "Contract symbol", group: "Universe", description: "OKX instrument ID; no hidden symbol exclusions.", unit: "text", numeric: false),
        .init(key: "ListingAgeMonths", label: "Listing age (months)", group: "Universe", description: "Completed Gregorian calendar months in UTC since listing.", unit: "months", numeric: true),
        .init(key: "Open", label: "Candle open", group: "Candle", description: "Hourly candle opening price.", unit: "USDT", numeric: true),
        .init(key: "High", label: "Candle high", group: "Candle", description: "Hourly candle high.", unit: "USDT", numeric: true),
        .init(key: "Low", label: "Candle low", group: "Candle", description: "Hourly candle low.", unit: "USDT", numeric: true),
        .init(key: "Close", label: "Candle close", group: "Candle", description: "Live or completed hourly close.", unit: "USDT", numeric: true),
        .init(key: "Volume", label: "Quote volume", group: "Candle", description: "Hourly quote volume in USDT.", unit: "USDT", numeric: true),
    ]
    static let fields = Set(metrics.map(\.key))
    static let numericFields = Set(metrics.filter(\.numeric).map(\.key))
    static let aliases = ["price": "price", "close": "Close", "open": "Open", "high": "High", "low": "Low", "volume": "Volume", "symbol": "Symbol", "listingagemonths": "ListingAgeMonths", "oi": "oiUSD", "buy": "buy", "sell": "sell"]
    static func key(_ name: String) -> String? { fields.contains(name) ? name : aliases[name.lowercased()] ?? metrics.first { $0.key.lowercased() == name.lowercased() }?.key }
    static let functions = ["EMA(n)", "RSI(n)", "ROC(n)", "MAROC(rocN, meanN)", "LogBBUpper(n, deviations)", "LogBBMiddle(n, deviations)", "LogBBLower(n, deviations)", "VWAP(n)", "PriorHigh(n)", "PriorLow(n)", "BreakoutAge(n, searchHours)", "BreakdownAge(n, searchHours)", "abs(x)", "mean(x, n)", "sum(x, n)", "highest(x, n)", "lowest(x, n)", "stddev(x, n)", "lag(x, n)", "change(x, n)", "closed(x)", "live(x)", "all(...)", "any(...)", "NOT condition", "between(x, min, max)", "positive(x)", "negative(x)", "zero(x)", "available(x)", "unavailable(x)", "every(condition, hours)", "recent(condition, hours)", "count(condition, hours, \"gte\", minimum)", "crossUp(left, right)", "crossDown(left, right)", "sequence(hours, stage(\"break\", condition, gapHours, capture(\"level\", expression)), stage(\"retest\", condition, gapHours))"]
}
