import assert from "node:assert/strict"
import test from "node:test"
import { chartAxis, visibleTicks } from "./chart-axis.ts"

test("axes use real powers-of-ten domains and keep labels sparse", () => {
  const price = chartAxis(90, 94.34, 8)
  assert.equal(price.max, 95)
  assert.deepEqual(price.ticks, [90, 91, 92, 93, 94, 95])
  assert.deepEqual(chartAxis(0.0000482, 0.0000491, 8).ticks, [0.000048, 0.000049, 0.00005])
  assert.deepEqual(chartAxis(2_567_200, 4_813_800).ticks, [2_000_000, 3_000_000, 4_000_000, 5_000_000])
  const taker = chartAxis(0, 519_660)
  assert.equal(taker.max, 600_000)
  assert.deepEqual(visibleTicks(taker.ticks, 4), [0, 200_000, 400_000, 600_000])
  const roc = chartAxis(-38.9, 38.9, 8)
  assert.deepEqual([roc.min, roc.max], [-40, 40])
})
