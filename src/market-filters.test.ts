import assert from "node:assert/strict"
import test from "node:test"
import { evaluateMarketOpportunity } from "./market-opportunity.ts"
import { compareMarketRows, compareMarketTurnover, chartNavigationTarget } from "./market-sort.ts"
import type { MarketRow } from "./market-row.ts"
import { FILTER_FIELDS, FILTER_PRESETS, emptyMarketFilters, makeFilterRule, marketFilterPreset, matchesFilterRule, matchesMarketFilters, parseMarketFilters, previewMarketFilters, reorderFilterRules, validateFilterRule, type FilterField, type FilterOperator, type MarketFilters } from "./market-filters.ts"

function market(patch: Partial<MarketRow> = {}, metrics: Partial<MarketRow["filterMetrics"]> = {}) {
  const row: MarketRow = {
    instId: "BTC-USDT-SWAP", turnover24hUSDT: 20_000_000, ema200Signal: "Long",
    price: 110, priceChange: 1, currentLow: 95, currentHigh: 125, buy: 80, sell: 20, takerRatio: 60, oiChange: 2,
    highBreakout: { status: "event", hour: 100, hoursAgo: 0, priorHour: 0, priorAgeHours: 30, priorPrice: 120, live: true },
    lowBreakdown: { status: "none" }, highBreakout96: { status: "none" }, lowBreakdown96: { status: "none" },
    roc: 3, maroc: 2, rocChange: 50, marocChange: -10, rsi6: 62, rsi12: 58, rsi24: 54,
    logBBAboveBand: "middle", logBBExpansion: { hours: 2, complete: true },
    filterMetrics: {
      liveOpen: 105, liveClose: 110, ema200: 101, previousEMA200: 100, vwap14: 108,
      bbUpper: 120, bbMiddle: 100, bbLower: 80, priorHigh48: 120, priorHigh96: 130, priorLow48: 90, priorLow96: 85,
      oiUSD: 30_000_000, spreadPercent: 0.1, liveVolumeUSDT: 10_000, ...metrics,
    }, ...patch,
  }
  return { ...row, opportunity: evaluateMarketOpportunity(row) }
}
const rule = (field: FilterField, operator: FilterOperator, value = "", upper = "") => ({ ...makeFilterRule(field), operator, value, upper })
const config = (rules: MarketFilters["rules"], match: "all" | "any" = "all"): MarketFilters => ({ version: 1, match, rules })

test("conditions compose across indicators with AND and OR, including an empty OR", () => {
  const r = market(), conditions = [rule("emaBody", "eq", "above"), rule("rsi6", "between", "50", "70"), rule("high96", "eq", "yes")]
  assert.equal(matchesMarketFilters(r, config(conditions)), false)
  assert.equal(matchesMarketFilters(r, config(conditions, "any")), true)
  assert.equal(matchesMarketFilters(r, emptyMarketFilters()), true)
  assert.equal(matchesMarketFilters(r, config([], "any")), true)
  assert.equal(matchesMarketFilters(r, config([rule("roc", "positive"), rule("roc", "abs-gte", "3")])), true)
  assert.equal(matchesMarketFilters(r, config([rule("roc", "positive"), rule("roc", "abs-gte", "3.001")])), false)
})

test("RSI ranges include both endpoints; signed values, zero and magnitude stay distinct", () => {
  const band = rule("rsi6", "between", "30", "70")
  for (const [rsi6, expected] of [[29.999, false], [30, true], [70, true], [70.001, false]] as const) assert.equal(matchesFilterRule(market({ rsi6 }), band), expected)
  const negative = market({ roc: -2, maroc: 0 })
  assert.equal(matchesFilterRule(negative, rule("roc", "negative")), true)
  assert.equal(matchesFilterRule(negative, rule("roc", "abs-gte", "2")), true)
  assert.equal(matchesFilterRule(negative, rule("roc", "abs-lte", "2")), true)
  assert.equal(matchesFilterRule(negative, rule("maroc", "positive")), false)
  assert.equal(matchesFilterRule(negative, rule("maroc", "negative")), false)
  assert.equal(matchesFilterRule(negative, rule("maroc", "zero")), true)
})

test("EMA slope and body are independent, and wicks cannot turn a body into a crossing", () => {
  const risingWithBodyBelow = market({ ema200Signal: "Short", currentHigh: 500 }, { liveOpen: 100.25, liveClose: 100.5, ema200: 101, previousEMA200: 100 })
  assert.equal(matchesFilterRule(risingWithBodyBelow, rule("emaTrend", "eq", "rising")), true)
  assert.equal(matchesFilterRule(risingWithBodyBelow, rule("emaBody", "eq", "below")), true)
  assert.equal(matchesFilterRule(risingWithBodyBelow, rule("emaSlope", "eq", "1")), true)
  for (const [open, close, expected] of [[90, 110, "cross-up"], [110, 90, "cross-down"], [100, 110, "touching"], [110, 100, "touching"], [100, 100, "touching"], [110, 110, "above"], [90, 90, "below"]] as const) {
    assert.equal(matchesFilterRule(market({}, { liveOpen: open, liveClose: close, ema200: 100 }), rule("emaBody", "eq", expected)), true)
  }
  assert.equal(matchesFilterRule(market({}, { ema200: 100, previousEMA200: 100 }), rule("emaTrend", "eq", "flat")), true)
})

test("wick breakout survives a price retreat, close breakout does not; 48h and 96h are independent", () => {
  const r = market()
  assert.equal(matchesFilterRule(r, rule("high48", "eq", "yes")), true)
  assert.equal(matchesFilterRule(r, rule("closeHigh48", "eq", "yes")), false)
  assert.equal(matchesFilterRule(r, rule("high96", "eq", "yes")), false)
  const tied = market({ currentHigh: 120, currentLow: 90 }, { liveClose: 120 })
  for (const field of ["high48", "closeHigh48", "low48"] as const) assert.equal(matchesFilterRule(tied, rule(field, "eq", "no")), true)
  const brokenLow = market({ currentLow: 80 }, { liveClose: 86 })
  assert.equal(matchesFilterRule(brokenLow, rule("low96", "eq", "yes")), true)
  assert.equal(matchesFilterRule(brokenLow, rule("closeLow48", "eq", "yes")), true)
  assert.equal(matchesFilterRule(brokenLow, rule("closeLow96", "eq", "yes")), false)
})

test("missing history never means no breakout and missing readings never pass a negation", () => {
  const unavailable = market({ roc: null, highBreakout: { status: "loading" }, highBreakout96: { status: "insufficient-history" } }, { priorHigh48: null, priorHigh96: null, liveClose: null })
  for (const field of ["high48", "high96", "recentHigh48", "recentHigh96"] as const) {
    assert.equal(matchesFilterRule(unavailable, rule(field, "eq", "no")), false)
    assert.equal(matchesFilterRule(unavailable, rule(field, "missing")), true)
  }
  assert.equal(matchesFilterRule(unavailable, rule("roc", "neq", "0")), false)
  assert.equal(matchesFilterRule(unavailable, rule("roc", "positive")), false)
  assert.equal(matchesFilterRule(unavailable, rule("roc", "missing")), true)
  assert.equal(matchesFilterRule(unavailable, rule("price", "present")), false)
  assert.equal(matchesFilterRule(market({ highBreakout: { status: "none" } }), rule("recentHigh48", "eq", "no")), true)
})

test("Bollinger equality is explicit on all three bands and keeps the existing zone convention", () => {
  for (const [price, field, zone] of [[120, "priceUpper", "middle"], [100, "priceMiddle", "lower"], [80, "priceLower", "below"]] as const) {
    const r = market({ logBBAboveBand: zone }, { liveClose: price })
    assert.equal(matchesFilterRule(r, rule(field, "eq", "equal")), true)
    assert.equal(matchesFilterRule(r, rule(field, "eq", "above")), false)
    assert.equal(matchesFilterRule(r, rule("bbZone", "eq", zone)), true)
  }
  assert.equal(matchesFilterRule(market(), rule("bbWidth", "eq", "40")), true)
})

test("OI, taker flow, RSI relationships and ROC relationships compare numbers without direction assumptions", () => {
  const r = market({ buy: 0, sell: 0, oiChange: -2, roc: -1, maroc: -2, rsi6: 40, rsi12: 50 })
  assert.equal(matchesFilterRule(r, rule("buyVsSell", "eq", "equal")), true)
  assert.equal(matchesFilterRule(r, rule("oiTrend", "eq", "falling")), true)
  assert.equal(matchesFilterRule(r, rule("rocVsMaroc", "eq", "above")), true)
  assert.equal(matchesFilterRule(r, rule("rsi6vs12", "eq", "below")), true)
  assert.equal(matchesFilterRule(market({ buy: null }), rule("buyVsSell", "neq", "below")), false)
})

test("infinite native percentage values keep their signs and magnitude; NaN is unavailable", () => {
  const r = market({ roc: "Infinity", maroc: "-Infinity", oiChange: "Infinity", rocChange: NaN })
  assert.equal(matchesFilterRule(r, rule("roc", "gte", "99999")), true)
  assert.equal(matchesFilterRule(r, rule("maroc", "negative")), true)
  assert.equal(matchesFilterRule(r, rule("maroc", "abs-gte", "99999")), true)
  assert.equal(matchesFilterRule(r, rule("roc", "between", "0", "100")), false)
  assert.equal(matchesFilterRule(r, rule("oiTrend", "eq", "rising")), true)
  assert.equal(matchesFilterRule(r, rule("rocChange", "missing")), true)
})

test("recent breakout timing and partial bandwidth expansion have explicit meanings", () => {
  const r = market({ logBBExpansion: { hours: 4, complete: false } })
  assert.equal(matchesFilterRule(r, rule("high48Age", "eq", "0")), true)
  assert.equal(matchesFilterRule(r, rule("highPriorAge", "gte", "30")), true)
  assert.equal(matchesFilterRule(r, rule("low48Age", "missing")), true)
  assert.equal(matchesFilterRule(r, rule("bbExpansion", "gte", "3")), true)
  assert.equal(matchesFilterRule(r, rule("bbExpansionComplete", "eq", "complete")), false)
  assert.equal(matchesFilterRule(r, rule("bbExpansionComplete", "eq", "partial")), true)
})

test("numeric validation rejects blanks, infinities, inverted ranges and invalid RSI / hour limits", () => {
  for (const invalid of [rule("roc", "gte", ""), rule("roc", "gte", " "), rule("roc", "gte", "Infinity"), rule("roc", "gte", "NaN"), rule("roc", "between", "2", "1"), rule("roc", "abs-gte", "-1"), rule("rsi6", "between", "0", "101"), rule("rsi6", "gte", "-1"), rule("high48Age", "lte", "1.5"), rule("emaBody", "eq", "unknown")]) {
    assert.ok(validateFilterRule(invalid), JSON.stringify(invalid))
    assert.equal(matchesFilterRule(market(), invalid), false)
  }
  assert.equal(validateFilterRule(rule("rsi6", "between", "0", "100")), null)
  assert.equal(validateFilterRule(rule("roc", "gte", "-2.5")), null)
})

test("draft previews use complete conditions while leaving saved filters and unfinished inputs intact", () => {
  const saved = config([rule("emaBody", "eq", "above")])
  const originalSaved = structuredClone(saved)
  const draft = config([rule("roc", "negative"), rule("rsi6", "between", "20", "")])
  const originalDraft = structuredClone(draft)
  const rows = [market(), market({ instId: "ETH-USDT-SWAP", roc: -3, rsi6: 28 }, { liveOpen: 90, liveClose: 80 })]
  const ids = (filters: MarketFilters) => rows.filter(row => matchesMarketFilters(row, filters)).map(row => row.instId)

  assert.deepEqual(ids(saved), ["BTC-USDT-SWAP"])
  assert.deepEqual(ids(previewMarketFilters(draft)), ["ETH-USDT-SWAP"])
  assert.ok(validateFilterRule(draft.rules[1]))
  assert.deepEqual(saved, originalSaved)
  assert.deepEqual(draft, originalDraft)

  const completed = { ...draft, rules: draft.rules.map(r => r.operator === "between" ? { ...r, upper: "25" } : r) }
  assert.deepEqual(ids(previewMarketFilters(completed)), [])
  assert.deepEqual(ids(saved), ["BTC-USDT-SWAP"])
})

test("incomplete preview conditions preserve AND / OR semantics and an empty preview shows all markets", () => {
  const row = market()
  const conditions = [rule("roc", "negative"), rule("rsi6", "gte", "60"), rule("high48Age", "lte", "1.5")]
  assert.equal(matchesMarketFilters(row, previewMarketFilters(config(conditions))), false)
  assert.equal(matchesMarketFilters(row, previewMarketFilters(config(conditions, "any"))), true)

  for (const match of ["all", "any"] as const) {
    const preview = previewMarketFilters(config([rule("roc", "gte", "-"), rule("rsi6", "between", "70", "30")], match))
    assert.equal(preview.match, match)
    assert.deepEqual(preview.rules, [])
    assert.equal(matchesMarketFilters(row, preview), true)
  }
  const live = previewMarketFilters(config([rule("roc", "positive")]))
  assert.equal(matchesMarketFilters(market({ roc: 1 }), live), true)
  assert.equal(matchesMarketFilters(market({ roc: -1 }), live), false)
})

test("conditions reorder in both directions without changing values, matching or the saved configuration", () => {
  for (const match of ["all", "any"] as const) {
    const saved = config([rule("emaBody", "eq", "above"), rule("rsi6", "between", "50", "70"), rule("roc", "negative")], match)
    const original = structuredClone(saved)
    const [first, second, third] = saved.rules
    const forward = reorderFilterRules(saved, first.id, third.id)
    assert.deepEqual(forward.rules, [second, third, first])
    assert.equal(forward.match, match)
    assert.deepEqual(parseMarketFilters(JSON.stringify(forward)), forward)
    assert.deepEqual(saved, original)

    const backward = reorderFilterRules(forward, first.id, second.id)
    assert.deepEqual(backward, saved)
    for (const row of [market(), market({ roc: -3, rsi6: 28 })]) {
      assert.equal(matchesMarketFilters(row, forward), matchesMarketFilters(row, saved))
      assert.equal(matchesMarketFilters(row, backward), matchesMarketFilters(row, saved))
    }
  }
})

test("unchanged or unavailable reorder targets leave the draft intact, including unfinished conditions", () => {
  const draft = config([rule("rsi6", "between", "30", ""), rule("roc", "positive")])
  const [first, second] = draft.rules
  assert.equal(reorderFilterRules(draft, first.id, first.id), draft)
  assert.equal(reorderFilterRules(draft, "missing", second.id), draft)
  assert.equal(reorderFilterRules(draft, first.id, "missing"), draft)
  const reordered = reorderFilterRules(draft, first.id, second.id)
  assert.deepEqual(reordered.rules, [second, first])
  assert.ok(validateFilterRule(reordered.rules[1]))
  assert.deepEqual(previewMarketFilters(reordered).rules, [second])
})

test("configuration roundtrips, discards unknown or invalid rules, and deduplicates ids", () => {
  const valid = config([rule("roc", "positive"), rule("roc", "abs-gte", "2")], "any")
  assert.deepEqual(parseMarketFilters(JSON.stringify(valid)), valid)
  const noisy = { ...valid, rules: [...valid.rules, valid.rules[0], { ...valid.rules[0], id: "bad", field: "unknown" }, { ...valid.rules[0], id: "bad-operator", operator: "invalid" }, { ...valid.rules[0], id: "bad-number", operator: "gte", value: "" }, null] }
  assert.deepEqual(parseMarketFilters(JSON.stringify(noisy)), valid)
  for (const value of [undefined, "broken", "[]", "null", '{"version":2,"match":"all","rules":[]}']) assert.deepEqual(parseMarketFilters(value), emptyMarketFilters())
})

test("presets remain editable valid configurations and filter all chart navigation targets without changing scores", () => {
  for (const preset of FILTER_PRESETS) assert.ok(marketFilterPreset(preset.id).rules.every(r => validateFilterRule(r) === null))
  const rows = [market(), market({ instId: "OTHER-USDT-SWAP", turnover24hUSDT: 500_000_000 }, { liveOpen: 90, liveClose: 80 })]
  const original = structuredClone(rows)
  const filters = marketFilterPreset("long")
  const visible = rows.filter(r => matchesMarketFilters(r, filters))
  assert.equal(visible.length, 1)
  const list = [...visible].sort((a, b) => compareMarketRows(a, b, "opportunity", true)).map(r => r.instId)
  const turnover = [...visible].sort(compareMarketTurnover).map(r => r.instId)
  for (const key of ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"] as const) assert.equal(chartNavigationTarget(list, turnover, list[0], key), "BTC-USDT-SWAP")
  assert.deepEqual(rows, original)
})

test("every available field can be inspected and sparse data does not throw", () => {
  const r = market()
  for (const field of Object.keys(FILTER_FIELDS) as FilterField[]) assert.equal(validateFilterRule(rule(field, "present")), null)
  const sparse = market({ filterMetrics: {} as MarketRow["filterMetrics"] })
  for (const field of Object.keys(FILTER_FIELDS) as FilterField[]) assert.doesNotThrow(() => matchesFilterRule(sparse, rule(field, "present")))
  assert.equal(matchesFilterRule(r, rule("turnover", "eq", "20")), true)
  assert.equal(matchesFilterRule(r, rule("oiUSD", "eq", "30")), true)
})
