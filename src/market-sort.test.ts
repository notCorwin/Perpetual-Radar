import assert from "node:assert/strict"
import test from "node:test"
import { compareMarketRows, marketTrend, matchesMarketFilter, momentumScores, type SortableRow, type SortKey } from "./market-sort.ts"

const row = (instId: string, value: number | null): SortableRow => ({
  instId, momentum: value, oiUsd: 1, high48: value, low48: value, oiLog: value, takerRatio: value, volumeLog: value, roc: value, maroc: value, rsi6: value, rsi12: value, rsi24: value, bollUpper: value, bollMiddle: value, bollLower: value,
})

test("every column sorts both ways and keeps missing data last", () => {
  const rows = [row("Middle", 0), row("High", 2), row("Missing", null), row("Low", -2)]
  const sorted = (key: SortKey, descending: boolean) => [...rows].sort((a, b) => compareMarketRows(a, b, key, descending)).map(item => item.instId)
  assert.deepEqual(sorted("instId", false), ["High", "Low", "Middle", "Missing"])
  assert.deepEqual(sorted("instId", true), ["Missing", "Middle", "Low", "High"])
  for (const key of ["momentum", "high48", "low48", "takerRatio", "volumeLog", "roc", "maroc", "rsi6", "rsi12", "rsi24", "bollUpper", "bollMiddle", "bollLower"] as const) {
    assert.deepEqual(sorted(key, true), ["High", "Middle", "Low", "Missing"])
    assert.deepEqual(sorted(key, false), ["Low", "Middle", "High", "Missing"])
  }
})

test("momentum equally weights price, positive OI, and positive volume change", () => {
  const scores = momentumScores([
    { roc: 2, maroc: 2, oiLog: 0.3, volumeLog: 0.4 },
    { roc: -2, maroc: -2, oiLog: -0.3, volumeLog: -0.4 },
    { roc: -1, maroc: -1, oiLog: 0.1, volumeLog: 0.2 },
    { roc: 0, maroc: 0, oiLog: 0, volumeLog: 0 },
    { roc: 2, maroc: 2, oiLog: 0.3, volumeLog: -0.4 },
    { roc: null, maroc: 2, oiLog: 0.3, volumeLog: 0.4 },
    { roc: 2, maroc: 2, oiLog: 0.3, volumeLog: null },
  ])
  assert.equal(scores[0], 100)
  assert.ok(Math.abs(scores[1]! - 100 / 3) < 1e-9)
  assert.ok(scores[2]! > scores[1]!)
  assert.equal(scores[3], 0)
  assert.ok(Math.abs(scores[4]! - 200 / 3) < 1e-9)
  assert.equal(scores[5], null)
  assert.equal(scores[6], null)
})

test("trend requires all four price and Taker directions to agree", () => {
  const base = { price: 100, vwap14: 90, ema200: 95, bollMiddle: 99, takerRatio: 5 }
  assert.equal(marketTrend(base), "LONG")
  assert.equal(marketTrend({ price: 100, vwap14: 110, ema200: 105, bollMiddle: 101, takerRatio: -5 }), "SHORT")
  assert.equal(marketTrend({ ...base, takerRatio: -5 }), "TRAP")
  assert.equal(marketTrend({ ...base, bollMiddle: 100 }), "TRAP")
  assert.equal(marketTrend({ ...base, takerRatio: 0 }), "TRAP")
  assert.equal(marketTrend({ ...base, ema200: null }), null)
})

test("TRAP view includes every TRAP while default view keeps its existing filters", () => {
  assert.equal(matchesMarketFilter({ roc: 1, maroc: -1, trend: "TRAP" }, true), true)
  assert.equal(matchesMarketFilter({ roc: 1, maroc: 1, trend: "LONG" }, true), false)
  assert.equal(matchesMarketFilter({ roc: 1, maroc: -1, trend: "LONG" }, false), false)
  assert.equal(matchesMarketFilter({ roc: 1, maroc: 1, trend: "LONG" }, false), true)
  assert.equal(matchesMarketFilter({ roc: null, maroc: null, trend: null }, false), true)
})
