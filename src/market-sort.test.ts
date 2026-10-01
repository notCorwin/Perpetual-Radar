import assert from "node:assert/strict"
import test from "node:test"
import { chartNavigationTarget, compareMarketRows, compareMarketTurnover, wrappedMarket, type SortableRow, type SortKey } from "./market-sort.ts"

const row = (instId: string, value: number | null): SortableRow => ({
  instId, turnover24hUSDT: value ?? 0, high96: value, low96: value, takerRatio: value, volumeLog: value, oiLog: value, roc: value, maroc: value, rsi6: value, rsi12: value, rsi24: value, logBBUpper: value, logBBMiddle: value, logBBLower: value, logBBBandWidth: value,
})

test("indicator columns sort both ways and keep missing data last", () => {
  const rows = [row("Middle", 0), row("High", 2), row("Missing", null), row("Low", -2)]
  const sorted = (key: SortKey, descending: boolean) => [...rows].sort((a, b) => compareMarketRows(a, b, key, descending)).map(item => item.instId)
  for (const key of ["high96", "low96", "takerRatio", "volumeLog", "oiLog", "roc", "maroc", "rsi6", "rsi12", "rsi24", "logBBUpper", "logBBMiddle", "logBBLower", "logBBBandWidth"] as const) {
    assert.deepEqual(sorted(key, true), ["High", "Middle", "Low", "Missing"])
    assert.deepEqual(sorted(key, false), ["Low", "Middle", "High", "Missing"])
  }
})

test("turnover ranking keeps stable ties", () => {
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

test("chart navigation follows visible sorting and jumps to list first or highest turnover", () => {
  const markets = [
    { ...row("A", 30), turnover24hUSDT: 10 },
    { ...row("B", 20), turnover24hUSDT: 30 },
    { ...row("C", 10), turnover24hUSDT: 20 },
  ]
  const turnoverOrder = [...markets].sort(compareMarketTurnover).map(market => market.instId)
  const listOrder = [...markets].filter(market => market.instId !== "B")
    .sort((a, b) => compareMarketRows(a, b, "oiLog", true)).map(market => market.instId)
  assert.deepEqual(turnoverOrder, ["B", "C", "A"])
  assert.deepEqual(listOrder, ["A", "C"])
  assert.equal(chartNavigationTarget(listOrder, turnoverOrder, "C", "ArrowUp"), "A")
  assert.equal(chartNavigationTarget(listOrder, turnoverOrder, "A", "ArrowDown"), "C")
  assert.equal(chartNavigationTarget(listOrder, turnoverOrder, "A", "ArrowUp"), "C")
  assert.equal(chartNavigationTarget(listOrder, turnoverOrder, "C", "ArrowDown"), "A")
  assert.equal(chartNavigationTarget(listOrder, turnoverOrder, "C", "ArrowLeft"), "A")
  assert.equal(chartNavigationTarget(listOrder, turnoverOrder, "A", "ArrowRight"), "B")
  assert.equal(chartNavigationTarget(listOrder, turnoverOrder, "A", "ArrowLeft"), "A")
  assert.equal(chartNavigationTarget(listOrder, turnoverOrder, "B", "ArrowRight"), "B")
  assert.equal(chartNavigationTarget(listOrder, turnoverOrder, "B", "ArrowLeft"), "A")
  assert.equal(chartNavigationTarget(listOrder, turnoverOrder, "B", "ArrowUp"), "C")
  assert.equal(chartNavigationTarget(listOrder, turnoverOrder, "B", "ArrowDown"), "A")
  const ascendingOrder = [...markets].filter(market => market.instId !== "B")
    .sort((a, b) => compareMarketRows(a, b, "oiLog", false)).map(market => market.instId)
  assert.deepEqual(ascendingOrder, ["C", "A"])
  assert.equal(chartNavigationTarget(ascendingOrder, turnoverOrder, "C", "ArrowDown"), "A")
  assert.equal(chartNavigationTarget(ascendingOrder, turnoverOrder, "A", "ArrowLeft"), "C")
  assert.equal(chartNavigationTarget(ascendingOrder, turnoverOrder, "C", "ArrowRight"), "B")
})

test("chart navigation handles empty lists and independent jump targets", () => {
  for (const key of ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"] as const) {
    assert.equal(chartNavigationTarget([], [], "A", key), undefined)
  }
  assert.equal(chartNavigationTarget([], ["B"], "A", "ArrowLeft"), undefined)
  assert.equal(chartNavigationTarget([], ["B"], "A", "ArrowRight"), "B")
  assert.equal(chartNavigationTarget(["A"], [], "A", "ArrowLeft"), "A")
  assert.equal(chartNavigationTarget(["A"], [], "A", "ArrowRight"), undefined)
})

test("chart navigation stays on a single market for repeated key presses", () => {
  for (const key of ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"] as const) {
    let current = "A"
    for (let press = 0; press < 3; press++) {
      const target = chartNavigationTarget(["A"], ["A"], current, key)
      assert.equal(target, "A")
      current = target!
    }
  }
})
