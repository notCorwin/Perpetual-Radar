import assert from "node:assert/strict"
import test from "node:test"
import { evaluateMarketOpportunity, type OpportunityInput } from "./market-opportunity.ts"
import type { BreakResult } from "./market-breaks.ts"
import type { LogBBAboveBand } from "./market-logbb.ts"
import type { PercentageValue } from "./market-percent.ts"

const event = (hoursAgo: number): BreakResult => ({ status: "event", hour: 100 * 3_600_000, hoursAgo, priorHour: 50 * 3_600_000, priorAgeHours: 50, priorPrice: 100, live: hoursAgo === 0 })
const startup = (patch: Partial<OpportunityInput> = {}): OpportunityInput => ({
  ema200Signal: "Long", priceChange: 0.4, roc: 3, maroc: 2, rsi6: 62, rsi12: 58, rsi24: 54,
  takerRatio: 12, oiChange: 2, logBBAboveBand: "middle", logBBExpansion: { hours: 2, complete: true },
  highBreakout: event(1), lowBreakdown: { status: "none" }, ...patch,
})
const pullback = (patch: Partial<OpportunityInput> = {}): OpportunityInput => startup({
  priceChange: 0.3, roc: 1, maroc: 2, rsi6: 50, rsi12: 55, rsi24: 57, takerRatio: 10, oiChange: 0.5,
  highBreakout: { status: "none" }, logBBExpansion: { hours: 0, complete: true }, ...patch,
})
const mirrorPercentage = (value: PercentageValue): PercentageValue => value === null ? null : value === "Infinity" ? "-Infinity" : value === "-Infinity" ? "Infinity" : -value
function mirror(input: OpportunityInput): OpportunityInput {
  const bands: Record<LogBBAboveBand, LogBBAboveBand> = { upper: "below", middle: "lower", lower: "middle", below: "upper" }
  return {
    ...input, ema200Signal: input.ema200Signal === "Long" ? "Short" : input.ema200Signal === "Short" ? "Long" : input.ema200Signal,
    priceChange: mirrorPercentage(input.priceChange), roc: mirrorPercentage(input.roc), maroc: mirrorPercentage(input.maroc),
    rsi6: input.rsi6 === null ? null : 100 - input.rsi6,
    rsi12: input.rsi12 === null ? null : 100 - input.rsi12,
    rsi24: input.rsi24 === null ? null : 100 - input.rsi24,
    takerRatio: input.takerRatio === null ? null : -input.takerRatio,
    logBBAboveBand: input.logBBAboveBand === null ? null : bands[input.logBBAboveBand],
    highBreakout: input.lowBreakdown, lowBreakdown: input.highBreakout,
  }
}

test("known Startup and Pullback examples have explainable scores without mutating their input", () => {
  for (const [input, setup, score, components] of [
    [startup(), "Startup", 90, { trend: 30, entry: 30, participation: 10, timing: 20, penalty: 0 }],
    [pullback(), "Pullback", 76, { trend: 30, entry: 30, participation: 6, timing: 10, penalty: 0 }],
  ] as const) {
    const before = structuredClone(input)
    const result = evaluateMarketOpportunity(input)
    assert.equal(result.direction, "Long")
    assert.equal(result.setup, setup)
    assert.equal(result.score, score)
    assert.equal(result.status, "Candidate")
    assert.deepEqual(result.components, components)
    assert.deepEqual(input, before)
    assert.ok(result.reasons.length)
  }
})

test("Long and Short mirror every directional rule, including bands, flow, heat and the chosen break", () => {
  const examples = [
    startup(), pullback(), startup({ logBBAboveBand: "upper" }), pullback({ logBBAboveBand: "lower" }),
    startup({ rsi6: 86, rsi12: 76, rsi24: 69, logBBAboveBand: "upper", logBBExpansion: { hours: 8, complete: true } }),
    startup({ roc: -1, maroc: -2, priceChange: -0.4, takerRatio: -10, oiChange: -2 }),
    startup({ logBBAboveBand: "below" }), startup({ logBBExpansion: { hours: 6, complete: false }, logBBAboveBand: "upper", rsi6: 64, rsi12: 65 }),
    startup({ takerRatio: null, oiChange: "Infinity" }), pullback({ roc: -1 }),
  ]
  for (const input of examples) {
    const long = evaluateMarketOpportunity(input), short = evaluateMarketOpportunity(mirror(input))
    assert.equal(short.direction, "Short")
    assert.equal(short.setup, long.setup)
    assert.equal(short.status, long.status)
    assert.equal(short.score, long.score)
    assert.deepEqual(short.components, long.components)
  }
})

test("Startup honors its RSI and momentum boundaries", () => {
  const cases: [Partial<OpportunityInput>, boolean][] = [
    [{ rsi6: 50, rsi12: 50 }, false], [{ rsi6: 50.001, rsi12: 50 }, true],
    [{ rsi6: 74.999 }, true], [{ rsi6: 75 }, false],
    [{ rsi12: 49.999 }, false], [{ rsi12: 50 }, true],
    [{ rsi6: 74, rsi12: 69.999 }, true], [{ rsi6: 74, rsi12: 70 }, false],
    [{ rsi6: 58 }, false], [{ rsi6: 58.001 }, true],
    [{ rsi24: 50 }, false], [{ rsi24: 50.001 }, true],
    [{ roc: 1.999 }, false], [{ roc: 2 }, true],
    [{ maroc: 0 }, false], [{ maroc: 0.001 }, true],
  ]
  for (const [patch, matches] of cases) assert.equal(evaluateMarketOpportunity(startup(patch)).setup === "Startup", matches, JSON.stringify(patch))
})

test("Startup requires the trend-side band, a complete 1–3h expansion and at least one live confirmation", () => {
  for (const [band, matches] of [["below", false], ["lower", false], ["middle", true], ["upper", true]] as const) {
    assert.equal(evaluateMarketOpportunity(startup({ logBBAboveBand: band })).setup === "Startup", matches)
  }
  for (const [hours, matches] of [[0, false], [1, true], [3, true], [4, false]] as const) {
    assert.equal(evaluateMarketOpportunity(startup({ logBBExpansion: { hours, complete: true } })).setup === "Startup", matches)
  }
  assert.equal(evaluateMarketOpportunity(startup({ logBBExpansion: { hours: 2, complete: false } })).setup, null)
  for (const [priceChange, takerRatio, matches] of [[0, 0, false], [0.001, 0, true], [0, 0.001, true], [-1, -1, false]] as const) {
    assert.equal(evaluateMarketOpportunity(startup({ priceChange, takerRatio })).setup === "Startup", matches)
  }
})

test("Pullback honors inclusive RSI boundaries and cooling of fast momentum", () => {
  const cases: [Partial<OpportunityInput>, boolean][] = [
    [{ rsi6: 39.999 }, false], [{ rsi6: 40 }, true],
    [{ rsi6: 60, rsi12: 65 }, true], [{ rsi6: 60.001, rsi12: 65 }, false],
    [{ rsi6: 44, rsi12: 44.999 }, false], [{ rsi6: 44, rsi12: 45 }, true],
    [{ rsi12: 65 }, true], [{ rsi12: 65.001 }, false],
    [{ rsi6: 50, rsi12: 50 }, true], [{ rsi6: 50.001, rsi12: 50 }, false],
    [{ rsi24: 50 }, false], [{ rsi24: 50.001 }, true],
    [{ maroc: 0 }, false], [{ maroc: 0.001 }, true], [{ roc: -1 }, true],
  ]
  for (const [patch, matches] of cases) assert.equal(evaluateMarketOpportunity(pullback(patch)).setup === "Pullback", matches, JSON.stringify(patch))
})

test("Pullback stays inside the bands and needs both price and taker recovery", () => {
  for (const [band, matches] of [["below", false], ["lower", true], ["middle", true], ["upper", false]] as const) {
    assert.equal(evaluateMarketOpportunity(pullback({ logBBAboveBand: band })).setup === "Pullback", matches)
  }
  for (const [priceChange, takerRatio, matches] of [[0, 10, false], [0.001, 10, true], [0.3, 0, false], [0.3, 0.001, true], [-1, 10, false], [0.3, -1, false]] as const) {
    assert.equal(evaluateMarketOpportunity(pullback({ priceChange, takerRatio })).setup === "Pullback", matches)
  }
})

test("trend and live confirmation groups add points only for directional agreement", () => {
  assert.equal(evaluateMarketOpportunity(startup({ roc: 0 })).components?.trend, 25)
  assert.equal(evaluateMarketOpportunity(startup({ maroc: 0 })).components?.trend, 25)
  assert.equal(evaluateMarketOpportunity(startup({ rsi24: 50 })).components?.trend, 25)
  assert.equal(evaluateMarketOpportunity(startup({ roc: -1, maroc: -2, rsi24: 40 })).components?.trend, 15)
  assert.equal(evaluateMarketOpportunity(startup({ takerRatio: 0 })).components?.entry, 25)
  assert.equal(evaluateMarketOpportunity(startup({ priceChange: 0 })).components?.entry, 25)
  assert.equal(evaluateMarketOpportunity(startup({ priceChange: 0, takerRatio: 0 })).components?.entry, 0)
})

test("participation bonuses are linear, nonnegative and capped, with OI independent of direction", () => {
  for (const [takerRatio, oiChange, expected] of [[0, 0, 0], [10, 2.5, 10], [20, 5, 20], [100, 1e30, 20], [-10, -5, 0]] as const) {
    const input = startup({ takerRatio, oiChange })
    assert.equal(evaluateMarketOpportunity(input).components?.participation, expected)
    assert.equal(evaluateMarketOpportunity(mirror(input)).components?.participation, expected)
  }
  assert.equal(evaluateMarketOpportunity(startup({ takerRatio: 20, oiChange: 5 })).score, 100)
  assert.equal(evaluateMarketOpportunity(startup({ takerRatio: 100, oiChange: 1e30 })).score, 100)
})

test("break timing follows only the relevant direction and honors 3h and 12h boundaries", () => {
  for (const [hours, expected] of [[0, 20], [3, 20], [4, 15], [12, 15], [13, 10], [-1, 10], [NaN, 10]] as const) {
    assert.equal(evaluateMarketOpportunity(startup({ highBreakout: event(hours) })).components?.timing, expected)
  }
  for (const status of ["none", "loading", "insufficient-history"] as const) {
    assert.equal(evaluateMarketOpportunity(startup({ highBreakout: { status }, lowBreakdown: event(0) })).components?.timing, 10)
  }
})

test("expansion timing distinguishes Startup, no setup and Pullback, including every endpoint", () => {
  for (const [hours, expected] of [[0, 0], [1, 10], [3, 10], [4, 5], [6, 5], [7, 0]] as const) {
    assert.equal(evaluateMarketOpportunity(startup({ highBreakout: { status: "none" }, logBBExpansion: { hours, complete: true } })).components?.timing, expected)
    assert.equal(evaluateMarketOpportunity(startup({ rsi24: 40, highBreakout: { status: "none" }, logBBExpansion: { hours, complete: true } })).components?.timing, expected)
  }
  for (const [hours, expected] of [[0, 10], [2, 10], [3, 5], [5, 5], [6, 0]] as const) {
    assert.equal(evaluateMarketOpportunity(pullback({ logBBExpansion: { hours, complete: true } })).components?.timing, expected)
  }
})

test("heat penalties honor each boundary without classifying a lone band breakout as Overheated", () => {
  for (const [patch, expected] of [
    [{ rsi6: 69.999 }, 0], [{ rsi6: 70 }, 10],
    [{ rsi6: 68, rsi12: 64.999 }, 0], [{ rsi6: 68, rsi12: 65 }, 10],
    [{ logBBAboveBand: "upper" }, 10],
    [{ logBBExpansion: { hours: 3, complete: true } }, 0], [{ logBBExpansion: { hours: 4, complete: true } }, 10],
  ] as [Partial<OpportunityInput>, number][]) {
    assert.equal(evaluateMarketOpportunity(startup(patch)).components?.penalty, expected)
  }
  const outside = evaluateMarketOpportunity(startup({ logBBAboveBand: "upper" }))
  assert.equal(outside.status, "Candidate")
  assert.equal(outside.score, 80)
})

test("each overheating combination requires all its members and exact thresholds", () => {
  const cases: [Partial<OpportunityInput>, boolean][] = [
    [{ rsi6: 79.999, rsi12: 70 }, false], [{ rsi6: 80, rsi12: 70 }, true],
    [{ rsi6: 80, rsi12: 69.999 }, false],
    [{ logBBAboveBand: "upper", rsi6: 74.999 }, false], [{ logBBAboveBand: "upper", rsi6: 75 }, true],
    [{ logBBAboveBand: "middle", rsi6: 75 }, false],
    [{ logBBAboveBand: "upper", rsi6: 64, rsi12: 65, logBBExpansion: { hours: 5, complete: true } }, false],
    [{ logBBAboveBand: "upper", rsi6: 64, rsi12: 65, logBBExpansion: { hours: 6, complete: true } }, true],
    [{ logBBAboveBand: "upper", rsi6: 64, rsi12: 64.999, logBBExpansion: { hours: 6, complete: true } }, false],
    [{ logBBAboveBand: "middle", rsi6: 64, rsi12: 65, logBBExpansion: { hours: 6, complete: true } }, false],
  ]
  for (const [patch, expected] of cases) {
    assert.equal(evaluateMarketOpportunity(startup(patch)).status === "Overheated", expected, JSON.stringify(patch))
    assert.equal(evaluateMarketOpportunity(mirror(startup(patch))).status === "Overheated", expected, JSON.stringify(patch))
  }
})

test("expansion lower bounds cannot earn early timing but do confirm sufficiently long heat", () => {
  const young = evaluateMarketOpportunity(startup({ logBBExpansion: { hours: 2, complete: false } }))
  assert.equal(young.setup, null)
  assert.equal(young.status, "Watch")
  assert.equal(young.components?.timing, 10)
  assert.ok(young.reasons.some(reason => reason.includes("lower bound")))
  const long = evaluateMarketOpportunity(startup({ rsi6: 64, rsi12: 65, logBBAboveBand: "upper", logBBExpansion: { hours: 6, complete: false } }))
  assert.equal(long.status, "Overheated")
  assert.equal(long.components?.timing, 10)
  assert.equal(long.components?.penalty, 30)
  assert.equal(evaluateMarketOpportunity(pullback({ logBBExpansion: { hours: 0, complete: false } })).components?.timing, 0)
})

test("Candidate uses the rounded 65-point threshold, and a high score alone cannot replace a setup", () => {
  const input = startup({ logBBAboveBand: "upper", highBreakout: { status: "none" }, oiChange: 0, takerRatio: 8.98 })
  const watch = evaluateMarketOpportunity(input)
  assert.equal(watch.setup, "Startup")
  assert.equal(watch.score, 64)
  assert.equal(watch.status, "Watch")
  const candidate = evaluateMarketOpportunity({ ...input, takerRatio: 9 })
  assert.equal(candidate.score, 65)
  assert.equal(candidate.status, "Candidate")
  const unformed = evaluateMarketOpportunity(startup({ rsi6: 64, rsi12: 64, takerRatio: 100, oiChange: 100 }))
  assert.ok(unformed.score! >= 65)
  assert.equal(unformed.setup, null)
  assert.equal(unformed.status, "Watch")
})

test("extreme OI cannot overcome heat and totals stay within 0–100", () => {
  const hot = evaluateMarketOpportunity(startup({ rsi6: 86, rsi12: 76, rsi24: 69, roc: 20, maroc: 10, priceChange: 4, takerRatio: 30, oiChange: 1000, logBBAboveBand: "upper", logBBExpansion: { hours: 8, complete: true }, highBreakout: event(0) }))
  assert.equal(hot.status, "Overheated")
  assert.equal(hot.score, 30)
  const exhausted = evaluateMarketOpportunity(startup({ rsi6: 90, rsi12: 80, rsi24: 40, roc: -1, maroc: -2, priceChange: -1, takerRatio: -10, oiChange: -5, logBBAboveBand: "upper", logBBExpansion: { hours: 8, complete: true }, highBreakout: { status: "none" } }))
  assert.equal(exhausted.score, 0)
  assert.equal(exhausted.status, "Overheated")
})

test("every missing or invalid core indicator yields an unscored Incomplete result", () => {
  const keys = ["ema200Signal", "priceChange", "roc", "maroc", "rsi6", "rsi12", "rsi24", "logBBAboveBand", "logBBExpansion"] as const
  for (const key of keys) {
    const result = evaluateMarketOpportunity(startup({ [key]: null }))
    assert.equal(result.status, "Incomplete", key)
    assert.equal(result.score, null, key)
    assert.equal(result.components, null, key)
    assert.ok(result.reasons.some(reason => reason.includes("unavailable")), key)
  }
  for (const key of ["priceChange", "roc", "maroc"] as const) {
    for (const value of ["Infinity", "-Infinity", Infinity, -Infinity, NaN] as const) {
      assert.equal(evaluateMarketOpportunity(startup({ [key]: value })).status, "Incomplete", key)
    }
  }
  for (const key of ["rsi6", "rsi12", "rsi24"] as const) {
    for (const value of [-0.001, 100.001, Infinity, -Infinity, NaN]) {
      assert.equal(evaluateMarketOpportunity(startup({ [key]: value })).status, "Incomplete", key)
    }
    for (const value of [0, 100]) assert.notEqual(evaluateMarketOpportunity(startup({ [key]: value })).status, "Incomplete", key)
  }
  for (const hours of [-1, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
    assert.equal(evaluateMarketOpportunity(startup({ logBBExpansion: { hours, complete: true } })).status, "Incomplete")
  }
  assert.equal(evaluateMarketOpportunity(startup({ ema200Signal: "Invalid" as OpportunityInput["ema200Signal"] })).status, "Incomplete")
  assert.equal(evaluateMarketOpportunity(startup({ logBBAboveBand: "invalid" as LogBBAboveBand })).status, "Incomplete")
  assert.equal(evaluateMarketOpportunity(startup({ logBBExpansion: { hours: 1, complete: "true" as unknown as boolean } })).status, "Incomplete")
})

test("missing, non-finite or invalid optional flow adds zero without redistributing weights", () => {
  for (const value of [null, NaN, Infinity, -Infinity, -100.001, 100.001]) {
    const result = evaluateMarketOpportunity(startup({ takerRatio: value, oiChange: 0 }))
    assert.equal(result.components?.participation, 0)
    assert.ok(result.reasons.some(reason => reason.startsWith("Taker imbalance is unavailable")))
  }
  for (const value of [null, NaN, Infinity, -Infinity, "Infinity", "-Infinity"] as const) {
    const result = evaluateMarketOpportunity(startup({ oiChange: value }))
    assert.equal(result.components?.participation, 6)
    assert.equal(result.score, 86)
    assert.ok(result.reasons.some(reason => reason.startsWith("OI change is unavailable")))
  }
  const both = evaluateMarketOpportunity(startup({ takerRatio: null, oiChange: null }))
  assert.equal(both.score, 75)
  assert.equal(both.status, "Candidate")
  assert.equal(evaluateMarketOpportunity(pullback({ takerRatio: null })).setup, null)
})

test("Unsure remains an uncommitted zero-point Watch when core data is complete", () => {
  const result = evaluateMarketOpportunity(startup({ ema200Signal: "Unsure", oiChange: 1000, takerRatio: 100 }))
  assert.equal(result.direction, null)
  assert.equal(result.setup, null)
  assert.equal(result.score, 0)
  assert.equal(result.status, "Watch")
  assert.equal(evaluateMarketOpportunity(startup({ ema200Signal: "Unsure", roc: null })).status, "Incomplete")
})
