import Foundation

let hourMS: Int64 = 3_600_000
let candleLookback = 250
let chartHours = 96

struct Candle {
    let hour: Int64
    let open: Double?
    let high: Double
    let low: Double
    let close: Double
    let confirmed: Bool
    let quoteVolume: Double
    let baseVolume: Double?

    init?(_ values: [String]) {
        guard values.count >= 9, let hour = Int64(values[0]), hour % hourMS == 0,
              let open = Double(values[1]),
              let high = Double(values[2]), let low = Double(values[3]),
              let close = Double(values[4]), let base = Double(values[6]),
              let quote = Double(values[7]), ["0", "1"].contains(values[8]),
              high.isFinite, low.isFinite, close.isFinite, base.isFinite, quote.isFinite,
              low > 0, high >= low, (low...high).contains(open), (low...high).contains(close), base >= 0, quote >= 0 else { return nil }
        self.hour = hour; self.open = open; self.high = high; self.low = low; self.close = close
        confirmed = values[8] == "1"; quoteVolume = quote; baseVolume = base
    }

    init(hour: Int64, high: Double, low: Double, close: Double, quoteVolume: Double, baseVolume: Double?, open: Double? = nil) {
        self.hour = hour; self.open = open; self.high = high; self.low = low; self.close = close
        confirmed = true; self.quoteVolume = quoteVolume; self.baseVolume = baseVolume
    }
}

func logChange(_ current: Double?, _ previous: Double?) -> Double? {
    guard let current, let previous, current > 0, previous > 0 else { return nil }
    return log(current / previous)
}

enum OISignal: String {
    case stable = "Stable", building = "Building", peaking = "Peaking", unwinding = "Unwinding"
}

func oiSignal(_ points: [(hour: Int64, oi: Double)]) -> OISignal? {
    guard !points.isEmpty, points.allSatisfy({ $0.oi.isFinite && $0.oi > 0 }) else { return nil }
    var start = points.count - 1
    while start > 0 && points[start].hour - points[start - 1].hour == hourMS { start -= 1 }
    let values = points[start...].map { log($0.oi) }
    guard values.count >= 9 else { return nil }

    func scale(_ window: [Double]) -> Double {
        let mean = window.reduce(0, +) / Double(window.count)
        return max(sqrt(window.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(window.count)), 0.005)
    }
    func zScore(_ value: Double, _ window: [Double]) -> Double? {
        guard window.count >= 3 else { return nil }
        let mean = window.reduce(0, +) / Double(window.count)
        return (value - mean) / scale(window)
    }
    func risingAnomaly(_ value: Double, _ window: [Double]) -> Bool {
        value > (window.last ?? value) && (zScore(value, window) ?? 0) >= 3
    }

    // ponytail: the first eight retained hours seed the initial stable regime; extend history if older episodes matter.
    var reference = Array(values.prefix(8))
    var signal = OISignal.stable
    var base = reference.last!
    var peak = base
    var peakIndex = 7
    var unwindStart = 0
    var noise = scale(reference)
    for index in 8..<values.count {
        let value = values[index]
        if signal == .stable {
            if risingAnomaly(value, reference) {
                base = values[index - 1]
                peak = value
                peakIndex = index
                noise = scale(reference)
                signal = .building
            } else if value < values[index - 1] && (zScore(value, reference) ?? 0) <= -3 {
                reference = [value]
            } else { reference.append(value) }
            continue
        }
        if value > peak {
            peak = value
            peakIndex = index
            signal = .building
            continue
        }
        if signal == .unwinding && unwindStart > 0 &&
            risingAnomaly(value, Array(values[unwindStart..<index])) {
            base = values[index - 1]
            peak = value
            peakIndex = index
            signal = .building
            continue
        }
        let previous = signal
        signal = peak - value > max(noise, (peak - base) * 0.15) ? .unwinding : .peaking
        if signal == .unwinding && previous != .unwinding { unwindStart = index }
        if index >= peakIndex + 3 &&
            abs(value - values[index - 3]) <= noise &&
            (index - 2...index).allSatisfy({ abs(values[$0] - values[$0 - 1]) <= noise }) {
            signal = .stable
            reference = Array(values[index - 2...index])
            unwindStart = 0
        }
    }
    return signal
}

func percentChange(_ current: Double?, _ previous: Double?) -> Double? {
    guard let current, let previous, previous != 0 else { return nil }
    return (current - previous) / abs(previous) * 100
}

func extremes(_ bars: [Int64: Candle], _ hour: Int64) -> (Double?, Double?) {
    var high = -Double.infinity, low = Double.infinity
    for age in 1...48 {
        guard let bar = bars[hour - Int64(age) * hourMS], bar.confirmed else { return (nil, nil) }
        high = max(high, bar.high); low = min(low, bar.low)
    }
    return (high, low)
}

func rocMaroc(_ bars: [Int64: Candle], _ hour: Int64, _ rocPeriod: Int, _ marocPeriod: Int) -> (Double?, Double?) {
    guard (1...100).contains(rocPeriod), (1...100).contains(marocPeriod) else { return (nil, nil) }
    var values: [Double] = []
    for offset in 0..<marocPeriod {
        guard let current = bars[hour - Int64(offset) * hourMS],
              let previous = bars[hour - Int64(offset + rocPeriod) * hourMS],
              (offset == 0 || current.confirmed), previous.confirmed, previous.close > 0 else {
            return (values.first, nil)
        }
        values.append((current.close / previous.close - 1) * 100)
    }
    return (values.first, values.reduce(0, +) / Double(marocPeriod))
}

func vwap14(_ bars: [Int64: Candle], _ hour: Int64) -> Double? {
    var quote = 0.0, base = 0.0
    for age in (0..<14).reversed() {
        guard let bar = bars[hour - Int64(age) * hourMS],
              (age == 0 || bar.confirmed), let volume = bar.baseVolume else { return nil }
        quote += bar.quoteVolume; base += volume
    }
    return base > 0 ? quote / base : nil
}

func rsi(_ bars: [Int64: Candle], _ hour: Int64, _ period: Int) -> Double? {
    var closes: [Double] = []
    for age in 0...candleLookback {
        guard let bar = bars[hour - Int64(age) * hourMS], age == 0 || bar.confirmed else { break }
        closes.append(bar.close)
    }
    guard closes.count > period else { return nil }
    closes.reverse()
    let changes = zip(closes.dropFirst(), closes).map(-)
    var gain = changes.prefix(period).reduce(0) { $0 + max($1, 0) } / Double(period)
    var loss = changes.prefix(period).reduce(0) { $0 + max(-$1, 0) } / Double(period)
    for change in changes.dropFirst(period) {
        gain = (gain * Double(period - 1) + max(change, 0)) / Double(period)
        loss = (loss * Double(period - 1) + max(-change, 0)) / Double(period)
    }
    return gain + loss > 0 ? 100 * gain / (gain + loss) : 50
}

func boll(_ bars: [Int64: Candle], _ hour: Int64) -> (Double?, Double?, Double?) {
    var closes: [Double] = []
    for age in 0..<20 {
        guard let bar = bars[hour - Int64(age) * hourMS], age == 0 || bar.confirmed else { return (nil, nil, nil) }
        closes.append(bar.close)
    }
    let middle = closes.reduce(0, +) / 20
    let width = 2 * sqrt(closes.reduce(0) { $0 + pow($1 - middle, 2) } / 20)
    return (middle + width, middle, middle - width)
}
