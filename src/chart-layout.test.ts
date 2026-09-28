import assert from "node:assert/strict"
import test from "node:test"
import { chartHourX, chartLayout, type ChartPanel } from "./chart-layout.ts"

test("stacked chart layout stays aligned and bounded", () => {
  const order: ChartPanel[] = ["price", "roc", "rsi", "oi", "taker"]
  for (const [width, height] of [[900, 700], [1440, 900], [2560, 900]]) {
    const layout = chartLayout(width, height, 48)
    assert.equal(layout.right + 48, width - 4)
    assert.ok(Math.abs((layout.panels.price[1] - layout.panels.price[0]) / (layout.panels.roc[1] - layout.panels.roc[0]) - 40 / 15) < 0.001)
    for (const [index, key] of order.entries()) {
      assert.deepEqual(layout.columns[key], layout.columns.price)
      assert.ok(layout.axisStarts[key] - layout.columns[key][1] >= 8)
      assert.ok(layout.axisStarts[key] < width)
      assert.ok(layout.columns[key][0] < layout.columns[key][1] && layout.columns[key][1] <= width)
      assert.ok(layout.panels[key][0] < layout.panels[key][1] && layout.panels[key][1] <= height)
      assert.ok(layout.headerY[key] < layout.panels[key][0])
      if (index) assert.ok(layout.panels[order[index - 1]][1] < layout.panels[key][0])
    }
  }
})

test("chart hours retain their position when candles are missing", () => {
  const hour = 3_600_000
  assert.equal(chartHourX(0, 95 * hour, 0, 960), 5)
  assert.equal(chartHourX(10 * hour, 95 * hour, 0, 960), 105)
  assert.equal(chartHourX(95 * hour, 95 * hour, 0, 960), 955)
})
