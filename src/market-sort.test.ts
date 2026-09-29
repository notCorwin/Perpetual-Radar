import assert from "node:assert/strict"
import test from "node:test"
import { chartNavigationTarget, compareMarketRows, compareMarketTurnover, wrappedMarket, type SortableRow, type SortKey } from "./market-sort.ts"

const row = (instId: string, value: number | null): SortableRow => ({
  instId, turnover24hUSDT: value ?? 0, high48: value, low48: value, takerRatio: value, volumeLog: value, roc: value, maroc: value, rsi6: value, rsi12: value, rsi24: value, bollUpper: value, bollMiddle: value, bollLower: value,
})

test("every column sorts both ways and keeps missing data last", () => {
  const rows = [row("Middle", 0), row("High", 2), row("Missing", null), row("Low", -2)]
  const sorted = (key: SortKey, descending: boolean) => [...rows].sort((a, b) => compareMarketRows(a, b, key, descending)).map(item => item.instId)
  assert.deepEqual(sorted("instId", false), ["High", "Low", "Middle", "Missing"])
  assert.deepEqual(sorted("instId", true), ["Missing", "Middle", "Low", "High"])
  for (const key of ["high48", "low48", "takerRatio", "volumeLog", "roc", "maroc", "rsi6", "rsi12", "rsi24", "bollUpper", "bollMiddle", "bollLower"] as const) {
    assert.deepEqual(sorted(key, true), ["High", "Middle", "Low", "Missing"])
    assert.deepEqual(sorted(key, false), ["Low", "Middle", "High", "Missing"])
  }
})

test("market list and chart navigation follow descending 24h turnover with stable ties", () => {
  const markets = [
    { instId: "B", turnover24hUSDT: 20 },
    { instId: "C", turnover24hUSDT: 10 },
    { instId: "A", turnover24hUSDT: 20 },
  ]
  assert.deepEqual(markets.sort(compareMarketTurnover).map(market => market.instId), ["A", "B", "C"])
  const sortable = [row("B", 2), row("C", 1), row("A", 2)]
  assert.deepEqual(sortable.sort((a, b) => compareMarketRows(a, b, "turnover24hUSDT", true)).map(market => market.instId), ["A", "B", "C"])
})

test("chart navigation wraps at both ends", () => {
  const order = ["A", "B", "C"]
  assert.equal(wrappedMarket(order, -1), "C")
  assert.equal(wrappedMarket(order, 3), "A")
  assert.equal(wrappedMarket(order, -2), "B")
  assert.equal(wrappedMarket(["A"], -2), "A")
  assert.equal(wrappedMarket([], 0), undefined)
})

test("chart left and right arrows jump to turnover ranking endpoints", () => {
  const order = ["A", "B", "C"]
  assert.equal(chartNavigationTarget(order, "B", "ArrowLeft"), "A")
  assert.equal(chartNavigationTarget(order, "A", "ArrowLeft"), "A")
  assert.equal(chartNavigationTarget(order, "B", "ArrowRight"), "C")
  assert.equal(chartNavigationTarget(order, "C", "ArrowRight"), "C")
  assert.equal(chartNavigationTarget(order, "A", "ArrowUp"), "C")
  assert.equal(chartNavigationTarget(order, "C", "ArrowDown"), "A")
  assert.equal(chartNavigationTarget(order, "Missing", "ArrowLeft"), undefined)
  assert.equal(chartNavigationTarget([], "A", "ArrowRight"), undefined)
})
