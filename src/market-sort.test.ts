import assert from "node:assert/strict"
import test from "node:test"
import { chartNavigationTarget, compareMarketRows, compareMarketTurnover, defaultSortDescending, wrappedMarket, type SortableRow, type SortKey } from "./market-sort.ts"
import type { BreakEvent, BreakResult } from "./market-breaks.ts"

const row = (instId: string, value: number | null): SortableRow => ({
  instId, turnover24hUSDT: value ?? 0, highBreakout: { status: "none" }, lowBreakdown: { status: "none" }, takerRatio: value, oiChange: value, roc: value, maroc: value, rsi6: value, rsi12: value, rsi24: value, logBBAboveBand: null, logBBExpansion: null,
})

test("indicator columns sort both ways and keep missing data last", () => {
  const rows = [row("Middle", 0), row("High", 2), row("Missing", null), row("Low", -2)]
  const sorted = (key: SortKey, descending: boolean) => [...rows].sort((a, b) => compareMarketRows(a, b, key, descending)).map(item => item.instId)
  for (const key of ["takerRatio", "oiChange", "roc", "maroc", "rsi6", "rsi12", "rsi24"] as const) {
    assert.deepEqual(sorted(key, true), ["High", "Middle", "Low", "Missing"])
    assert.deepEqual(sorted(key, false), ["Low", "Middle", "High", "Missing"])
  }
})

test("live band sorting ranks Upper, Middle, Lower, and below, keeping missing values last", () => {
  const rows: SortableRow[] = [
    { ...row("Lower", 100), logBBAboveBand: "lower" },
    { ...row("Missing", 100), logBBAboveBand: null },
    { ...row("Upper", 100), logBBAboveBand: "upper" },
    { ...row("Below", 100), logBBAboveBand: "below" },
    { ...row("Middle", 100), logBBAboveBand: "middle" },
  ]
  assert.equal(defaultSortDescending("logBBAboveBand"), true)
  for (const [descending, expected] of [[true, ["Upper", "Middle", "Lower", "Below", "Missing"]], [false, ["Below", "Lower", "Middle", "Upper", "Missing"]]] as const) {
    assert.deepEqual([...rows].sort((a, b) => compareMarketRows(a, b, "logBBAboveBand", descending)).map(item => item.instId), expected)
  }
})

test("expansion sorting uses hours, including zero and lower bounds, and stable turnover ties", () => {
  const rows: SortableRow[] = [
    { ...row("Short", 100), logBBExpansion: { hours: 2, complete: true } },
    { ...row("Missing", 100), logBBExpansion: null },
    { ...row("Stopped", 100), logBBExpansion: { hours: 0, complete: true } },
    { ...row("Long", 200), logBBExpansion: { hours: 6, complete: true } },
    { ...row("AtLeast", 100), logBBExpansion: { hours: 6, complete: false } },
  ]
  assert.equal(defaultSortDescending("logBBExpansion"), true)
  for (const [descending, expected] of [[true, ["Long", "AtLeast", "Short", "Stopped", "Missing"]], [false, ["Stopped", "Short", "Long", "AtLeast", "Missing"]]] as const) {
    assert.deepEqual([...rows].sort((a, b) => compareMarketRows(a, b, "logBBExpansion", descending)).map(item => item.instId), expected)
  }
})

const breakEvent = (hoursAgo: number, priorAgeHours: number, live = false): BreakEvent => ({
  status: "event", hour: (100 - hoursAgo) * 3_600_000, hoursAgo, priorHour: (100 - hoursAgo - priorAgeHours) * 3_600_000, priorAgeHours, priorPrice: 200, live,
})
const breakRow = (instId: string, result: BreakResult, turnover = 50): SortableRow => ({ ...row(instId, turnover), highBreakout: result, lowBreakdown: result })

test("break time sorts newest first, prior age sorts longest first, and all missing states stay last", () => {
  const rows = [
    breakRow("Oldest", breakEvent(47, 48)),
    breakRow("Missing", { status: "none" }),
    breakRow("Recent", breakEvent(3, 37)),
    breakRow("Live", breakEvent(0, 12, true)),
    breakRow("Young", { status: "insufficient-history" }),
    breakRow("Loading", { status: "loading" }),
  ]
  const sorted = (key: SortKey, descending: boolean) => [...rows].sort((a, b) => compareMarketRows(a, b, key, descending)).map(item => item.instId)
  for (const key of ["highBreakout", "lowBreakdown"] as const) {
    assert.equal(defaultSortDescending(key), false)
    assert.deepEqual(sorted(key, false), ["Live", "Recent", "Oldest", "Loading", "Missing", "Young"])
    assert.deepEqual(sorted(key, true), ["Oldest", "Recent", "Live", "Loading", "Missing", "Young"])
  }
  for (const key of ["highBreakoutPriorAge", "lowBreakdownPriorAge"] as const) {
    assert.equal(defaultSortDescending(key), true)
    assert.deepEqual(sorted(key, true), ["Oldest", "Recent", "Live", "Loading", "Missing", "Young"])
    assert.deepEqual(sorted(key, false), ["Live", "Recent", "Oldest", "Loading", "Missing", "Young"])
  }
  assert.equal(defaultSortDescending("oiChange"), true)
})

test("break sorting uses the selected direction and stable turnover and instrument ties", () => {
  const rows = [
    { ...breakRow("High", breakEvent(1, 48)), lowBreakdown: breakEvent(10, 2) },
    { ...breakRow("Low", breakEvent(10, 2)), lowBreakdown: breakEvent(1, 48) },
  ]
  for (const [key, expected] of [["highBreakout", "High"], ["lowBreakdown", "Low"], ["highBreakoutPriorAge", "High"], ["lowBreakdownPriorAge", "Low"]] as const) {
    assert.equal([...rows].sort((a, b) => compareMarketRows(a, b, key, defaultSortDescending(key)))[0].instId, expected)
  }
  const ties = [breakRow("B", breakEvent(3, 37), 30), breakRow("C", breakEvent(3, 37), 10), breakRow("A", breakEvent(3, 37), 30)]
  for (const key of ["highBreakout", "lowBreakdown", "highBreakoutPriorAge", "lowBreakdownPriorAge"] as const) {
    for (const descending of [true, false]) {
      assert.deepEqual([...ties].sort((a, b) => compareMarketRows(a, b, key, descending)).map(item => item.instId), ["A", "B", "C"])
    }
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
    .sort((a, b) => compareMarketRows(a, b, "oiChange", true)).map(market => market.instId)
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
    .sort((a, b) => compareMarketRows(a, b, "oiChange", false)).map(market => market.instId)
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
