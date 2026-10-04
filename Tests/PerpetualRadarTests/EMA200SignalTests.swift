import XCTest
@testable import PerpetualRadar

final class EMA200SignalTests: XCTestCase {
    private func candle(open: Double, close: Double, confirmed: Bool = false) -> Candle {
        Candle(["0", String(open), "250", "50", String(close), "1", "1", "100", confirmed ? "1" : "0"])!
    }

    func testBodyPositionIgnoresWicksAndCandleDirection() {
        for (open, close) in [(110.0, 120.0), (120.0, 110.0), (110.0, 110.0)] {
            XCTAssertEqual(ema200Signal(candle(open: open, close: close), 100), .long)
        }
        for (open, close) in [(80.0, 90.0), (90.0, 80.0), (90.0, 90.0)] {
            XCTAssertEqual(ema200Signal(candle(open: open, close: close), 100), .short)
        }
    }

    func testCrossingOrTouchingTheLineIsUnsure() {
        for (open, close) in [(90.0, 110.0), (110.0, 90.0), (100.0, 110.0), (110.0, 100.0),
                              (100.0, 90.0), (90.0, 100.0), (100.0, 100.0)] {
            XCTAssertEqual(ema200Signal(candle(open: open, close: close), 100), .unsure)
        }
    }

    func testTheLiveCloseUpdatesTheEMALineBeforeComparingTheBody() throws {
        let live = candle(open: 100.5, close: 201)
        let ema = try XCTUnwrap(updatedEMA200(100, close: live.close))
        XCTAssertEqual(ema, 101.0049751243781, accuracy: 1e-12)
        XCTAssertEqual(ema200Signal(live, 100), .long)
        XCTAssertEqual(ema200Signal(live, ema), .unsure)
    }

    func testLiveRevisionsRecalculateFromTheCompletedEMAWithoutCompounding() throws {
        let above = candle(open: 110, close: 120)
        XCTAssertEqual(ema200Signal(above, updatedEMA200(100, close: above.close)), .long)
        let crossing = candle(open: 110, close: 90)
        XCTAssertEqual(ema200Signal(crossing, updatedEMA200(100, close: crossing.close)), .unsure)
        let below = candle(open: 90, close: 80)
        XCTAssertEqual(ema200Signal(below, updatedEMA200(100, close: below.close)), .short)
        XCTAssertEqual(try XCTUnwrap(updatedEMA200(100, close: 120)), 100.19900497512438, accuracy: 1e-12)
    }

    func testMissingLiveCandleOrEMAIsUnavailableInsteadOfUnsure() {
        let live = candle(open: 110, close: 120)
        XCTAssertNil(ema200Signal(nil, 100))
        XCTAssertNil(ema200Signal(candle(open: 110, close: 120, confirmed: true), 100))
        for ema in [nil, 0, -1, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertNil(ema200Signal(live, ema))
        }
        XCTAssertNil(updatedEMA200(nil, close: live.close))
        for value in [nil, 0, -1, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertNil(updatedEMA200(value, close: 100))
            XCTAssertNil(updatedEMA200(100, close: value))
        }
    }
}
