import { memo, startTransition, useCallback, useEffect, useMemo, useRef, useState } from "react"
import { flushSync } from "react-dom"
import { ArrowLeft, Camera, Radio } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { chartAxis, chartAxisForLabels } from "@/chart-axis"
import { chartCandleWidth, chartHourX, chartLayout, fitPriceTag, type ChartPanel as Panel } from "@/chart-layout"
import { livePriceTag, scrollChartEnd, visibleChartBars } from "@/chart-viewport"
import { cn } from "@/lib/utils"
import { wrappedMarket } from "@/market-sort"

type Bar = {
  hour: number; open: number; high: number; low: number; close: number; confirmed: boolean
  vwap: number | null; ema: number | null; bollUpper: number | null; bollMiddle: number | null; bollLower: number | null
  roc: number | null; maroc: number | null; rsi6: number | null; rsi12: number | null; rsi24: number | null
  oi: number | null; buy: number | null; sell: number | null
}
export type ChartResponse = { bars: Bar[]; error: string; revision: number; endHour?: number; oldestHour?: number | null; historyExhausted?: boolean; candleLoadFailed?: boolean }
export type ChartPollResponse = ChartResponse | { unchanged: true; error: string; revision: number }

const chartCache = new Map<string, { data: ChartResponse; loadedAt: number }>()
const chartLoads = new Map<string, Promise<ChartResponse>>()
const chartPreviews = new Map<string, Promise<ChartResponse>>()
function rememberChart(id: string, data: ChartResponse, loadedAt: number) {
  chartCache.delete(id)
  chartCache.set(id, { data, loadedAt })
  if (chartCache.size > 8) chartCache.delete(chartCache.keys().next().value!)
}
function loadChart(id: string): Promise<ChartResponse> {
  const pending = chartLoads.get(id)
  if (pending) return pending
  const request = window.webkit.messageHandlers.radar.postMessage({ chartInstId: id, loadChart: true }).then(result => {
    if ("unchanged" in result) throw new Error("No chart data returned")
    rememberChart(id, result, Date.now())
    return result
  }).finally(() => chartLoads.delete(id))
  chartLoads.set(id, request)
  return request
}
function previewChart(id: string): Promise<ChartResponse> {
  const cached = chartCache.get(id)
  if (cached) return Promise.resolve(cached.data)
  const pending = chartPreviews.get(id)
  if (pending) return pending
  const request = window.webkit.messageHandlers.radar.postMessage({ chartInstId: id, sinceRevision: -1 }).then(result => {
    if ("unchanged" in result) throw new Error("No chart data returned")
    if (!chartCache.has(id)) rememberChart(id, result, 0)
    return chartCache.get(id)!.data
  }).finally(() => chartPreviews.delete(id))
  chartPreviews.set(id, request)
  return request
}

const compact = (value: number | null) => value === null ? "—" : new Intl.NumberFormat("en-US", { maximumSignificantDigits: 5, notation: "compact" }).format(value)
const price = (value: number | null) => value === null ? "—" : new Intl.NumberFormat("en-US", { maximumSignificantDigits: 8 }).format(value)
const time = (hour: number) => new Date(hour).toLocaleString("en-US", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false })
const hourLabel = (hour: number) => new Date(hour).toLocaleString("en-US", { month: "short", day: "numeric", hour: "2-digit", hour12: false })
const chartPriceValues = (bars: Bar[]) => bars.flatMap(bar => [bar.low, bar.high, bar.vwap, bar.ema, bar.bollUpper, bar.bollMiddle, bar.bollLower].filter((value): value is number => value !== null))
const rocAxisFor = (bars: Bar[]) => {
  const values = bars.flatMap(bar => [bar.roc, bar.maroc].filter((value): value is number => value !== null))
  return values.length ? chartAxis(Math.min(0, ...values), Math.max(0, ...values), 8) : chartAxis(-1, 1, 8)
}
const axisLabelLimit = (panel: readonly [number, number], maximum: number) =>
  Math.min(maximum, Math.max(2, Math.floor((panel[1] - panel[0]) / 32) + 1))
const legendContext = document.createElement("canvas").getContext("2d")
const chartTextWidth = (text: string, fontSize: string) => {
  if (!legendContext) return text.length * 7
  const style = getComputedStyle(document.documentElement)
  legendContext.font = `${fontSize} ${style.fontFamily}`
  return legendContext.measureText(text.replace(/\d/g, "0")).width
}
const legendWidth = (text: string) => chartTextWidth(text, getComputedStyle(document.documentElement).getPropertyValue("--chart-text-size").trim())
const priceTagWidth = (priceText: string, countdown: string) => {
  const style = getComputedStyle(document.documentElement)
  const padding = Number.parseFloat(style.getPropertyValue("--chart-price-tag-padding-x"))
  const fontSize = style.getPropertyValue("--chart-price-tag-text-size").trim()
  return Math.ceil(Math.max(chartTextWidth(priceText, fontSize), chartTextWidth(countdown, fontSize)) + padding * 2)
}
const chartGutter = (bars: Bar[], height: number, liveClose = bars[bars.length - 1].close) => {
  const { panels } = chartLayout(0, height)
  const values = chartPriceValues(bars)
  const priceAxis = chartAxisForLabels(Math.min(...values), Math.max(...values), axisLabelLimit(panels.price, 9))
  const decimals = priceAxis.decimals
  const priceFormatter = new Intl.NumberFormat("en-US", { minimumFractionDigits: decimals, maximumFractionDigits: decimals })
  const rocAxis = rocAxisFor(bars)
  const oiValues = bars.flatMap(bar => bar.oi === null ? [] : [bar.oi])
  const takerAxis = chartAxisForLabels(0, Math.max(1, ...bars.map(bar => (bar.buy ?? 0) + (bar.sell ?? 0))), axisLabelLimit(panels.taker, 7))
  const labels = [
    ...priceAxis.ticks.map(tick => priceFormatter.format(tick)),
    `+${rocAxis.max.toFixed(rocAxis.decimals)}`, rocAxis.min.toFixed(rocAxis.decimals), "100", "0",
    ...(oiValues.length ? chartAxisForLabels(Math.min(...oiValues), Math.max(...oiValues), axisLabelLimit(panels.oi, 7)).ticks.map(compact) : []),
    ...takerAxis.ticks.map(compact),
  ]
  const style = getComputedStyle(document.documentElement)
  const tagGap = Number.parseFloat(style.getPropertyValue("--chart-price-tag-gap"))
  const tagStrokeWidth = Number.parseFloat(style.getPropertyValue("--chart-price-tag-stroke-width"))
  const tagTextSize = Number.parseFloat(style.getPropertyValue("--chart-price-tag-text-size"))
  const axisTextSize = Number.parseFloat(style.getPropertyValue("--chart-text-size"))
  const minimumScale = Math.min(1, axisTextSize / tagTextSize)
  const axisGutter = Math.max(...labels.map(label => 8 + legendWidth(label)))
  return fitPriceTag(axisGutter, priceTagWidth(price(liveClose), "00:00"), tagGap, tagStrokeWidth, minimumScale)
}

const Plot = memo(function Plot({ bars, liveBar, hovered, width, height, now, endHour }: { bars: Bar[]; liveBar: Bar; hovered: number | null; width: number; height: number; now: number; endHour: number }) {
  const n = bars.length
  const active = bars[hovered ?? n - 1]
  const latestHour = endHour
  const firstHour = endHour - 95 * 3_600_000
  const firstAtLeft = bars[0].hour === firstHour
  const candleHigh = Math.max(...bars.map(bar => bar.high)), candleLow = Math.min(...bars.map(bar => bar.low))
  const { gutter, scale: tagScale } = chartGutter(bars, height, liveBar.close)
  const { panels, columns, axisStarts, headerY, left, right } = chartLayout(width, height, gutter)
  const x = (index: number, panel: Panel) => chartHourX(bars[index].hour, latestHour, ...columns[panel])
  const barWidth = chartCandleWidth(right - left)
  const priceValues = chartPriceValues(bars)
  const priceMin = Math.min(...priceValues), priceMax = Math.max(...priceValues)
  const priceAxis = chartAxisForLabels(priceMin, priceMax, axisLabelLimit(panels.price, 9))
  const highIndex = bars.findIndex(bar => bar.high === candleHigh), lowIndex = bars.findIndex(bar => bar.low === candleLow)
  const priceDecimals = priceAxis.decimals
  const axisPrice = new Intl.NumberFormat("en-US", { minimumFractionDigits: priceDecimals, maximumFractionDigits: priceDecimals })
  const rocAxis = rocAxisFor(bars)
  const oiValues = bars.flatMap(bar => bar.oi === null ? [] : [bar.oi])
  const oiAxis = oiValues.length ? chartAxisForLabels(Math.min(...oiValues), Math.max(...oiValues), axisLabelLimit(panels.oi, 7)) : null
  const maxTaker = Math.max(1, ...bars.map(bar => (bar.buy ?? 0) + (bar.sell ?? 0)))
  const takerAxis = chartAxisForLabels(0, maxTaker, axisLabelLimit(panels.taker, 7))
  const scale = (value: number, min: number, max: number, panel: readonly [number, number]) =>
    panel[1] - (value - min) / (max - min || 1) * (panel[1] - panel[0])
  const priceY = (value: number) => scale(value, priceAxis.min, priceAxis.max, panels.price)
  const rocZeroY = scale(0, rocAxis.min, rocAxis.max, panels.roc)
  const tag = livePriceTag(liveBar, endHour, now)
  const latestY = priceY(tag.price)
  const latestColor = tag.rising ? "var(--positive)" : "var(--destructive)"
  const showCountdown = now > 0
  const secondsLeft = tag.secondsLeft
  const countdown = `${String(Math.floor(secondsLeft / 60)).padStart(2, "0")}:${String(secondsLeft % 60).padStart(2, "0")}`
  const latestPrice = price(tag.price), tagWidth = priceTagWidth(latestPrice, countdown)
  const tagStyle = getComputedStyle(document.documentElement)
  const tagFontSize = tagStyle.getPropertyValue("--chart-price-tag-text-size").trim()
  const tagLineHeight = Number.parseFloat(tagFontSize) * Number.parseFloat(tagStyle.getPropertyValue("--chart-price-tag-line-height"))
  const tagPaddingY = Number.parseFloat(tagStyle.getPropertyValue("--chart-price-tag-padding-y"))
  const tagRowGap = Number.parseFloat(tagStyle.getPropertyValue("--chart-price-tag-row-gap"))
  const tagGap = Number.parseFloat(tagStyle.getPropertyValue("--chart-price-tag-gap"))
  const tagStrokeWidth = Number.parseFloat(tagStyle.getPropertyValue("--chart-price-tag-stroke-width"))
  const tagRadius = Number.parseFloat(tagStyle.getPropertyValue("--chart-price-tag-radius"))
  const tickHalfHeight = Number.parseFloat(tagStyle.getPropertyValue("--chart-text-size")) / 2
  const tagHeight = tagLineHeight * (showCountdown ? 2 : 1) + (showCountdown ? tagRowGap : 0) + tagPaddingY * 2
  const scaledTagHeight = tagHeight * tagScale
  const priceTagY = tag.inViewport ? Math.max(panels.price[0], Math.min(latestY - scaledTagHeight / 2, panels.price[1] - scaledTagHeight)) : panels.price[0]
  const tagX = right + tagGap + tagStrokeWidth * tagScale / 2
  const line = (key: keyof Bar, panelKey: Panel, min: number, max: number) => {
    const segments: string[] = []
    let segment = ""
    bars.forEach((bar, index) => {
      const value = bar[key]
      if (typeof value !== "number" || (index > 0 && bar.hour - bars[index - 1].hour !== 3_600_000)) {
        if (segment) segments.push(segment)
        segment = ""
        if (typeof value !== "number") return
      }
      const pointY = scale(value, min, max, panels[panelKey]).toFixed(1)
      if (index === 0 && firstAtLeft) segment = `M${left} ${pointY}`
      segment += `${segment ? " L" : "M"}${x(index, panelKey).toFixed(1)} ${pointY}`
    })
    if (segment) segments.push(segment)
    return segments.join(" ")
  }
  const priceLine = (key: keyof Bar) => line(key, "price", priceAxis.min, priceAxis.max)
  const bollBands: string[] = []
  let upper: string[] = [], lower: string[] = []
  const finishBand = () => {
    if (upper.length > 1) bollBands.push(`M${upper.join(" L")} L${lower.reverse().join(" L")} Z`)
    upper = []; lower = []
  }
  bars.forEach((bar, index) => {
    if (bar.bollUpper === null || bar.bollLower === null) { finishBand(); return }
    if (index > 0 && bar.hour - bars[index - 1].hour !== 3_600_000) finishBand()
    const pointX = x(index, "price").toFixed(1)
    if (index === 0 && firstAtLeft) {
      upper.push(`${left} ${priceY(bar.bollUpper).toFixed(1)}`)
      lower.push(`${left} ${priceY(bar.bollLower).toFixed(1)}`)
    }
    upper.push(`${pointX} ${priceY(bar.bollUpper).toFixed(1)}`)
    lower.push(`${pointX} ${priceY(bar.bollLower).toFixed(1)}`)
  })
  finishBand()
  const indicatorWidth = "var(--chart-indicator-line-width)"
  const lineStroke = (d: string, color: string, width = indicatorWidth, opacity = 1, dash?: string) => <path d={d} fill="none" stroke={color} strokeWidth={width} strokeLinecap="round" strokeLinejoin="round" strokeDasharray={dash} opacity={opacity} />
  const lineLabel = (x: number, y: number, label: string, color = "var(--muted-foreground)") =>
    <text x={x} y={y} dominantBaseline="middle" fill={color}>{label}</text>
  const rectangle = (x: number, y: number, width: number, height: number) => `M${x} ${y}h${width}v${height}h${-width}Z`
  const upWicks: string[] = [], downWicks: string[] = [], upBodies: string[] = [], downBodies: string[] = []
  const buys: string[] = [], sells: string[] = []
  for (let index = 0; index < n; index++) {
    const bar = bars[index]
    const rising = bar.close >= bar.open
    const center = x(index, "price")
    const wicks = rising ? upWicks : downWicks
    const bodies = rising ? upBodies : downBodies
    wicks.push(`M${center} ${priceY(bar.high)}V${priceY(bar.low)}`)
    const top = priceY(Math.max(bar.open, bar.close))
    bodies.push(rectangle(center - barWidth / 2, top, barWidth, Math.max(1.5, priceY(Math.min(bar.open, bar.close)) - top)))
    const volumeCenter = x(index, "taker")
    const volumeX = volumeCenter - barWidth / 2
    const buyHeight = (bar.buy ?? 0) / takerAxis.max * (panels.taker[1] - panels.taker[0])
    const sellHeight = (bar.sell ?? 0) / takerAxis.max * (panels.taker[1] - panels.taker[0])
    if (buyHeight) buys.push(rectangle(volumeX, panels.taker[1] - buyHeight, barWidth, buyHeight))
    if (sellHeight) sells.push(rectangle(volumeX, panels.taker[1] - buyHeight - sellHeight, barWidth, sellHeight))
  }
  const panelKeys: Panel[] = ["price", "roc", "rsi", "oi", "taker"]
  const grid = panelKeys.flatMap(key => panels[key].map((y, index) =>
    <line key={`${key}-${index}`} x1={columns[key][0]} x2={columns[key][1]} y1={y} y2={y} stroke="var(--border)" strokeWidth="1" opacity={index ? 0.32 : 0.55} />))
  const legend = (key: Panel, items: [string, string, string][]) => {
    const gap = Number.parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--chart-legend-gap"))
    const start = columns[key][0] + gap / 2
    const widths = items.map(([label, value]) => legendWidth(label) + 10 + legendWidth(value))
    const available = right - start
    const required = widths.reduce((sum, itemWidth) => sum + itemWidth, 0) + gap * (items.length - 1)
    const shrink = Math.min(1, available / required)
    let cursor = 0
    return <g key={key}>
      <g transform={`translate(${start},${headerY[key]}) scale(${shrink})`}>
      {items.map(([label, value, color], index) => {
        const itemStart = cursor
        cursor += widths[index] + gap
        return <g key={label} transform={`translate(${itemStart},0)`}>
        <text dominantBaseline="middle" fill="var(--muted-foreground)">{label}</text>
        <text x={legendWidth(label) + 10} dominantBaseline="middle" fill={color}>{value}</text>
        </g>
      })}
      </g>
    </g>
  }
  return <>
    <defs>
      <pattern id="sell-hatch" width="4" height="4" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
        <line x1="0" x2="0" y1="0" y2="4" stroke="var(--background)" strokeWidth="1" opacity="0.55" />
      </pattern>
    </defs>
    {bollBands.map((d, index) => <path key={index} d={d} fill="var(--chart-1)" fillOpacity="0.1" />)}
    <rect x={columns.roc[0]} y={panels.roc[0]} width={columns.roc[1] - columns.roc[0]} height={rocZeroY - panels.roc[0]} fill="var(--chart-roc-positive-bg)" />
    <rect x={columns.roc[0]} y={rocZeroY} width={columns.roc[1] - columns.roc[0]} height={panels.roc[1] - rocZeroY} fill="var(--chart-roc-negative-bg)" />
    <rect x={columns.rsi[0]} y={scale(70, 0, 100, panels.rsi)} width={columns.rsi[1] - columns.rsi[0]} height={scale(30, 0, 100, panels.rsi) - scale(70, 0, 100, panels.rsi)} fill="var(--muted)" />
    {grid}
    {rocZeroY > panels.roc[0] && rocZeroY < panels.roc[1] && <line x1={columns.roc[0]} x2={columns.roc[1]} y1={rocZeroY} y2={rocZeroY} stroke="var(--muted-foreground)" strokeWidth="1" strokeOpacity="0.5" />}
    {bars.flatMap((bar, index) => (bar.hour - firstHour) % (12 * 3_600_000) === 0 ? panelKeys.map(key => <line key={`${bar.hour}-${key}`} x1={x(index, key)} x2={x(index, key)} y1={panels[key][0]} y2={panels[key][1]} stroke="var(--border)" strokeOpacity="0.22" />) : [])}
    {bars.map((bar, index) => ({ bar, index })).filter(({ bar, index }) => index === n - 1 || (bar.hour - firstHour) % (24 * 3_600_000) === 0).map(({ bar, index }) => <text key={bar.hour} x={x(index, "taker")} y={height - 7} textAnchor={index === 0 ? "start" : index === n - 1 ? "end" : "middle"} fill="var(--muted-foreground)">{hourLabel(bar.hour)}</text>)}
    {priceAxis.ticks.map(tick => {
      const tickY = priceY(tick)
      return <g key={tick}><line x1={columns.price[0]} x2={right} y1={tickY} y2={tickY} stroke="var(--border)" strokeOpacity="0.35" />{(tickY + tickHalfHeight < priceTagY || tickY - tickHalfHeight > priceTagY + scaledTagHeight) && lineLabel(axisStarts.price, tickY, axisPrice.format(tick))}</g>
    })}
    {tag.inViewport && <line x1={columns.price[0]} x2={right} y1={latestY} y2={latestY} stroke={latestColor} opacity="0.5" />}
    <path d={upWicks.join(" ")} fill="none" stroke="var(--positive)" strokeWidth="1.2" />
    <path d={downWicks.join(" ")} fill="none" stroke="var(--destructive)" strokeWidth="1.2" />
    <path d={upBodies.join(" ")} fill="var(--positive)" />
    <path d={downBodies.join(" ")} fill="var(--destructive)" />
    <path d={buys.join(" ")} fill="var(--positive)" opacity="0.9" />
    <path d={sells.join(" ")} fill="var(--destructive)" opacity="0.9" />
    <path d={sells.join(" ")} fill="url(#sell-hatch)" opacity="0.7" />
    {lineStroke(priceLine("bollUpper"), "var(--chart-1)", indicatorWidth, 0.62)}
    {lineStroke(priceLine("bollMiddle"), "var(--chart-1)")}
    {lineStroke(priceLine("bollLower"), "var(--chart-1)", indicatorWidth, 0.62)}
    {lineStroke(priceLine("vwap"), "var(--chart-2)")}
    {lineStroke(priceLine("ema"), "var(--chart-3)", indicatorWidth, 0.9)}
    {lineStroke(line("rsi6", "rsi", 0, 100), "var(--chart-1)")}
    {lineStroke(line("rsi12", "rsi", 0, 100), "var(--chart-2)", indicatorWidth, 1, "7 4")}
    {lineStroke(line("rsi24", "rsi", 0, 100), "var(--chart-3)", indicatorWidth, 1, "1 4")}
    {lineStroke(line("roc", "roc", rocAxis.min, rocAxis.max), "var(--chart-1)")}
    {lineStroke(line("maroc", "roc", rocAxis.min, rocAxis.max), "var(--chart-2)", indicatorWidth, 1, "7 4")}
    {oiAxis && lineStroke(line("oi", "oi", oiAxis.min, oiAxis.max), "var(--chart-2)")}
    {hovered !== null && panelKeys.map(key => <line key={key} x1={x(hovered, key)} x2={x(hovered, key)} y1={panels[key][0]} y2={panels[key][1]} stroke="var(--foreground)" strokeWidth="0.65" strokeDasharray="3 5" opacity="0.3" />)}
    {([[highIndex, candleHigh, "high"], [lowIndex, candleLow, "low"]] as const).map(([index, value, kind]) => {
      const markerX = x(index, "price"), label = price(value)
      const labelWidth = label.length * 6.5 + 8
      const start = index < n / 2 ? markerX + 10 : markerX - labelWidth - 10
      return <g key={kind}>
        <line x1={markerX} x2={index < n / 2 ? markerX + 10 : markerX - 10} y1={priceY(value)} y2={priceY(value)} stroke="var(--foreground)" strokeWidth="1" />
        {lineLabel(start, priceY(value), label, "var(--foreground)")}
      </g>
    })}
    <g transform={`translate(${tagX},${priceTagY}) scale(${tagScale})`}>
      <rect width={tagWidth} height={tagHeight} rx={tagRadius} fill="var(--card)" stroke={latestColor} strokeWidth="var(--chart-price-tag-stroke-width)" />
      <text x={tagWidth / 2} y={tagPaddingY + tagLineHeight / 2} textAnchor="middle" dominantBaseline="middle" fill="var(--foreground)" fontSize={tagFontSize}>{latestPrice}</text>
      {showCountdown && <text x={tagWidth / 2} y={tagPaddingY + tagLineHeight * 1.5 + tagRowGap} textAnchor="middle" dominantBaseline="middle" fill="var(--foreground)" fontSize={tagFontSize}>{countdown}</text>}
    </g>
    {legend("price", [["VWAP14", price(active.vwap), "var(--chart-2)"], ["EMA200", price(active.ema), "var(--chart-3)"], ["BOLL20", `U ${price(active.bollUpper)}\u00a0·\u00a0M ${price(active.bollMiddle)}\u00a0·\u00a0L ${price(active.bollLower)}`, "var(--chart-1)"]])}
    {legend("roc", [["ROC(9)", active.roc?.toFixed(2) ?? "—", "var(--chart-1)"], ["MAROC(9)", active.maroc?.toFixed(2) ?? "—", "var(--chart-2)"]])}
    {legend("rsi", [["RSI(6)", active.rsi6?.toFixed(1) ?? "—", "var(--chart-1)"], ["RSI(12)", active.rsi12?.toFixed(1) ?? "—", "var(--chart-2)"], ["RSI(24)", active.rsi24?.toFixed(1) ?? "—", "var(--chart-3)"]])}
    {legend("oi", [["OI", compact(active.oi), "var(--chart-2)"]])}
    {legend("taker", [["Taker Buy", compact(active.buy), "var(--positive)"], ["Taker Sell", compact(active.sell), "var(--destructive)"]])}
    {panels.rsi[1] - panels.rsi[0] >= 35 && <>{lineLabel(axisStarts.rsi, panels.rsi[0], "100")}{lineLabel(axisStarts.rsi, panels.rsi[1], "0")}</>}
    {panels.roc[1] - panels.roc[0] >= 35 && <>{lineLabel(axisStarts.roc, panels.roc[0], `+${rocAxis.max.toFixed(rocAxis.decimals)}`)}{lineLabel(axisStarts.roc, panels.roc[1], rocAxis.min.toFixed(rocAxis.decimals))}</>}
    {oiAxis && panels.oi[1] - panels.oi[0] >= 35 && oiAxis.ticks.map(tick => <g key={tick}>{lineLabel(axisStarts.oi, scale(tick, oiAxis.min, oiAxis.max, panels.oi), compact(tick))}</g>)}
    {panels.taker[1] - panels.taker[0] >= 35 && takerAxis.ticks.map(tick => <g key={tick}>{lineLabel(axisStarts.taker, scale(tick, takerAxis.min, takerAxis.max, panels.taker), compact(tick))}</g>)}
  </>
})

export function MarketChart({ instId, order, onSelect, onBack }: { instId: string; order: string[]; onSelect: (id: string) => void; onBack: () => void }) {
  const [displayed, setDisplayed] = useState<{ id: string; data: ChartResponse } | null>(null)
  const [historyBars, setHistoryBars] = useState<{ id: string; bars: Bar[] } | null>(null)
  const [historyBoundary, setHistoryBoundary] = useState<{ id: string; oldestHour: number } | null>(null)
  const [windowEnd, setWindowEnd] = useState<{ id: string; hour: number } | null>(null)
  const [historyLoading, setHistoryLoading] = useState<string | null>(null)
  const [historyRetry, setHistoryRetry] = useState(0)
  const windowEndRef = useRef<{ id: string; hour: number } | null>(null)
  const wheelPixels = useRef(0)
  const wheelFrame = useRef<number | null>(null)
  const historyRequests = useRef(new Map<string, Promise<ChartPollResponse>>())
  const loadedHistoryBuckets = useRef(new Set<string>())
  const requestedHistoryEnds = useRef(new Set<string>())
  const [hover, setHover] = useState<{ id: string; index: number } | null>(null)
  const [chartError, setChartError] = useState<{ id: string; message: string } | null>(null)
  const [warmCharts, setWarmCharts] = useState(() => new Map<string, ChartResponse>())
  const [capture, setCapture] = useState<{ id: string; status: "idle" | "copying" | "flashing" | "failed"; error: string }>({ id: instId, status: "idle", error: "" })
  const chartRef = useRef<HTMLElement>(null)
  const plotRef = useRef<HTMLDivElement>(null)
  const navigationId = useRef(instId)
  const navigationFrame = useRef<number | null>(null)
  const [plotSize, setPlotSize] = useState({ width: 0, height: 0 })
  const [now, setNow] = useState(Date.now)
  const position = order.indexOf(instId)
  const previous = wrappedMarket(order, position - 1), next = wrappedMarket(order, position + 1)
  const beforePrevious = wrappedMarket(order, position - 2), afterNext = wrappedMarket(order, position + 2)
  const historicalEnd = windowEnd?.id === instId ? windowEnd.hour : null
  const chart = chartCache.get(instId)?.data ?? (displayed?.id === instId ? displayed.data : null) ?? warmCharts.get(instId) ?? null
  const cachedBars = useMemo(() => {
    const merged = new Map<number, Bar>()
    for (const bar of chart?.bars ?? []) merged.set(bar.hour, bar)
    if (historyBars?.id === instId) for (const bar of historyBars.bars) merged.set(bar.hour, bar)
    const live = chart?.bars.at(-1)
    if (live && !live.confirmed) merged.set(live.hour, live)
    return [...merged.values()].sort((a, b) => a.hour - b.hour)
  }, [chart, historyBars, instId])
  const oldestCachedHour = cachedBars[0]?.hour ?? Infinity
  const hovered = hover?.id === instId ? hover.index : null
  const error = chartError?.id === instId ? chartError.message : chart?.error ?? ""
  const captureStatus = capture.id === instId ? capture.status : "idle"
  const captureError = capture.id === instId ? capture.error : ""
  useEffect(() => {
    if (capture.status !== "flashing") return
    const timer = window.setTimeout(() => setCapture(current => current === capture ? { ...current, status: "idle" } : current), 550)
    return () => window.clearTimeout(timer)
  }, [capture])
  const captureChart = async () => {
    const rect = chartRef.current?.getBoundingClientRect()
    if (!rect || rect.width <= 0 || rect.height <= 0) return
    setCapture({ id: instId, status: "copying", error: "" })
    try {
      await window.webkit.messageHandlers.radar.postMessage({ captureChart: { x: rect.x, y: rect.y, width: rect.width, height: rect.height } })
      setCapture({ id: instId, status: "flashing", error: "" })
    } catch (cause) {
      setCapture({ id: instId, status: "failed", error: cause instanceof Error ? cause.message : "Could not copy chart screenshot" })
    }
  }
  const warmChart = useCallback((id: string, data: ChartResponse, deferred = true) => {
    if (!data.bars.length) return
    const update = () => setWarmCharts(current => {
      if (current.get(id) === data) return current
      const updated = new Map(current)
      updated.delete(id)
      updated.set(id, data)
      if (updated.size > 7) updated.delete(updated.keys().next().value!)
      return updated
    })
    if (deferred) startTransition(update)
    else update()
  }, [])
  useEffect(() => {
    const element = plotRef.current
    if (!element) return
    const observer = new ResizeObserver(([entry]) => setPlotSize({ width: entry.contentRect.width, height: entry.contentRect.height }))
    observer.observe(element)
    return () => observer.disconnect()
  }, [])
  useEffect(() => {
    const element = plotRef.current
    if (!element) return
    const preventPageScroll = (event: WheelEvent) => event.preventDefault()
    element.addEventListener("wheel", preventPageScroll, { passive: false })
    return () => element.removeEventListener("wheel", preventPageScroll)
  }, [])
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(timer)
  }, [])
  useEffect(() => {
    if (historicalEnd === null) return
    const bucket = `${instId}:${Math.floor(historicalEnd / (96 * 3_600_000))}`
    const needsCandles = historicalEnd - 95 * 3_600_000 <= oldestCachedHour + 48 * 3_600_000
    const key = `${instId}:${historicalEnd}`
    if ((!needsCandles && loadedHistoryBuckets.current.has(bucket)) || requestedHistoryEnds.current.has(key)) return
    let stopped = false
    const timer = window.setTimeout(() => {
      setHistoryLoading(key)
      void (async () => {
        try { await historyRequests.current.get(instId) } catch { /* retry the newest position */ }
        if (stopped || windowEndRef.current?.id !== instId || windowEndRef.current.hour !== historicalEnd) return
        requestedHistoryEnds.current.add(key)
        const request = window.webkit.messageHandlers.radar.postMessage({ chartInstId: instId, chartEndHour: historicalEnd })
        historyRequests.current.set(instId, request)
        try {
          const result = await request
        if (!("unchanged" in result) && result.historyExhausted && result.oldestHour !== null && result.oldestHour !== undefined) {
          const oldestHour = result.oldestHour
          setHistoryBoundary(current => current?.id === instId && current.oldestHour === oldestHour ? current : { id: instId, oldestHour })
        }
        if (stopped || windowEndRef.current?.id !== instId || windowEndRef.current.hour !== historicalEnd || "unchanged" in result) return
        if (!result.candleLoadFailed) loadedHistoryBuckets.current.add(bucket)
        setHistoryBars(current => {
          const merged = new Map<number, Bar>(current?.id === instId ? current.bars.map(bar => [bar.hour, bar]) : [])
          for (const bar of result.bars) merged.set(bar.hour, bar)
          const first = historicalEnd - 499 * 3_600_000
          const last = historicalEnd + 249 * 3_600_000
          return { id: instId, bars: [...merged.values()].filter(bar => bar.hour >= first && bar.hour <= last).sort((a, b) => a.hour - b.hour) }
        })
        setHover(null)
        if (result.endHour !== undefined && result.endHour !== historicalEnd) {
          const latestHour = chartCache.get(instId)?.data.bars.at(-1)?.hour ?? result.bars.at(-1)?.hour ?? result.endHour
          const next = result.endHour >= latestHour ? null : { id: instId, hour: result.endHour }
          windowEndRef.current = next
          setWindowEnd(next)
        }
        setChartError({ id: instId, message: result.error })
        setHistoryLoading(null)
        } catch (cause) {
          if (!stopped && windowEndRef.current?.id === instId && windowEndRef.current.hour === historicalEnd) {
            setChartError({ id: instId, message: cause instanceof Error ? cause.message : "Cannot load history" })
            setHistoryLoading(null)
          }
        } finally {
          if (historyRequests.current.get(instId) === request) historyRequests.current.delete(instId)
        }
      })()
    }, 80)
    return () => { stopped = true; window.clearTimeout(timer) }
  }, [instId, historicalEnd, oldestCachedHour, historyRetry])
  useEffect(() => {
    wheelPixels.current = 0
    if (wheelFrame.current !== null) window.cancelAnimationFrame(wheelFrame.current)
    wheelFrame.current = null
  }, [instId])
  useEffect(() => {
    let stopped = false
    let timer: number
    let lastLoad = chartCache.get(instId)?.loadedAt ?? 0
    let revision = chartCache.get(instId)?.data.revision ?? -1
    const refresh = async () => {
      try {
        const shouldLoad = Date.now() - lastLoad >= 60_000
        const result = shouldLoad ? await loadChart(instId) : await window.webkit.messageHandlers.radar.postMessage({ chartInstId: instId, sinceRevision: revision })
        if (stopped) return
        if (shouldLoad) lastLoad = chartCache.get(instId)?.loadedAt ?? Date.now()
        if (!("unchanged" in result)) {
          revision = result.error ? -1 : result.revision
          if (!shouldLoad) rememberChart(instId, result, lastLoad)
          if (windowEndRef.current?.id !== instId) setDisplayed({ id: instId, data: result })
          warmChart(instId, result, false)
        }
        if (windowEndRef.current?.id !== instId) setChartError(current => current?.id === instId && current.message === result.error ? current : { id: instId, message: result.error })
      } catch (cause) {
        if (!stopped) {
          const message = cause instanceof Error ? cause.message : "Cannot load chart"
          if (windowEndRef.current?.id !== instId) setChartError(current => current?.id === instId && current.message === message ? current : { id: instId, message })
        }
      }
      if (!stopped) timer = window.setTimeout(refresh, 2000)
    }
    if (!chartCache.has(instId)) void previewChart(instId).then(data => {
      if (!stopped) { if (windowEndRef.current?.id !== instId) setDisplayed({ id: instId, data }); warmChart(instId, data, false) }
    }).catch(() => {})
    void refresh()
    return () => { stopped = true; window.clearTimeout(timer) }
  }, [instId, warmChart])

  useEffect(() => {
    let stopped = false
    for (const id of new Set([beforePrevious, previous, next, afterNext])) {
      if (!id || id === instId) continue
      void previewChart(id).then(data => { if (!stopped) warmChart(id, data) }).catch(() => {})
      if ((id === previous || id === next) && !chartCache.get(id)?.loadedAt) {
        void loadChart(id).then(data => { if (!stopped) warmChart(id, data) }).catch(() => {})
      }
    }
    return () => { stopped = true }
  }, [instId, beforePrevious, previous, next, afterNext, warmChart])

  useEffect(() => {
    const navigate = (event: KeyboardEvent) => {
      if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey || event.defaultPrevented) return
      if (!(event.key === "ArrowUp" || event.key === "ArrowDown" || event.key === "ArrowLeft" || event.key === "ArrowRight")) return
      event.preventDefault()
      const index = order.indexOf(navigationId.current)
      const id = index < 0 ? undefined : wrappedMarket(order, index + (event.key === "ArrowUp" || event.key === "ArrowLeft" ? -1 : 1))
      if (id && id !== navigationId.current) {
        navigationId.current = id
        if (navigationFrame.current === null) navigationFrame.current = window.requestAnimationFrame(() => {
          navigationFrame.current = null
          onSelect(navigationId.current)
        })
      }
    }
    window.addEventListener("keydown", navigate)
    return () => {
      window.removeEventListener("keydown", navigate)
      if (navigationFrame.current !== null) window.cancelAnimationFrame(navigationFrame.current)
    }
  }, [order, onSelect])

  const viewportEnd = historicalEnd ?? chart?.bars.at(-1)?.hour ?? 0
  const bars = useMemo(() => visibleChartBars(cachedBars, viewportEnd), [cachedBars, viewportEnd])
  const moveHistory = (steps: number) => {
    const latestHour = chartCache.get(instId)?.data.bars.at(-1)?.hour ?? bars.at(-1)?.hour
    if (latestHour === undefined || steps === 0) return
    const current = windowEndRef.current?.id === instId ? windowEndRef.current.hour : null
    const nextHour = scrollChartEnd(current, latestHour, steps, Number.isFinite(oldestCachedHour) ? oldestCachedHour : 0)
    if (nextHour === current) { wheelPixels.current = 0; return }
    const next = nextHour === null ? null : { id: instId, hour: nextHour }
    requestedHistoryEnds.current.clear()
    windowEndRef.current = next
    setWindowEnd(next)
    setHover(null)
  }
  const active = bars[hovered ?? bars.length - 1]
  const atHistoryBoundary = historicalEnd !== null && historyBoundary?.id === instId
    && historicalEnd === Math.min(chart?.bars.at(-1)?.hour ?? historicalEnd, historyBoundary.oldestHour + 95 * 3_600_000)
  const warmSurfaces = useMemo(() => new Map([...warmCharts].map(([id, data]) => [id, { ...data, bars: visibleChartBars(data.bars, data.bars.at(-1)?.hour ?? 0) }])), [warmCharts])
  const surfaces = new Map(warmSurfaces)
  if (bars.length && chart) surfaces.set(instId, { ...chart, bars, endHour: viewportEnd })
  return <main className="flex h-svh min-h-0 flex-col overflow-hidden overscroll-none text-[length:var(--chart-text-size)] font-normal tabular-nums">
    <header className="flex shrink-0 items-center gap-3 border-b px-4 py-2">
      <Button variant="ghost" size="sm" onClick={onBack}><ArrowLeft data-icon="inline-start" aria-hidden="true" />Markets</Button>
      <div className="min-w-0 flex-1">
        <h1 className="truncate text-base font-semibold tracking-tight normal-nums">{instId.replace(/-SWAP$/, "")}</h1>
        <p className="text-muted-foreground">OKX perpetual · 1h · {historicalEnd === null ? "Latest 96 hours" : `History through ${time(historicalEnd)}`} · Scroll chart for history · 24h turnover rank {position + 1}/{order.length} · ↑/← higher · ↓/→ lower</p>
      </div>
      <Button variant="outline" size="sm" disabled={!bars.length || plotSize.width <= 0 || captureStatus === "copying"} onClick={() => { void captureChart() }}><Camera data-icon="inline-start" aria-hidden="true" />{captureStatus === "copying" ? "Copying…" : "Copy chart"}</Button>
      <span role="status" className="sr-only">{captureStatus === "flashing" ? "Chart copied to clipboard" : ""}</span>
      <Badge variant="secondary"><Radio aria-hidden="true" /><span className="text-[length:var(--chart-text-size)] font-normal">{historicalEnd !== null ? "History" : active && !active.confirmed ? "Live candle" : "Hourly chart"}</span></Badge>
    </header>
    {error && <div role="alert" className="flex shrink-0 items-center gap-3 border-b px-5 py-2 text-destructive">{error}{historicalEnd !== null && <Button variant="outline" size="sm" onClick={() => {
      requestedHistoryEnds.current.delete(`${instId}:${historicalEnd}`)
      loadedHistoryBuckets.current.delete(`${instId}:${Math.floor(historicalEnd / (96 * 3_600_000))}`)
      setHistoryRetry(value => value + 1)
    }}>Retry</Button>}</div>}
    {captureError && <p role="alert" className="shrink-0 border-b px-5 py-2 text-destructive">{captureError}</p>}
    <section ref={chartRef} aria-label={`${instId} chart`} className="relative flex min-h-0 flex-1 flex-col bg-card">
      {active && <div className="grid shrink-0 grid-cols-[minmax(9rem,1.2fr)_repeat(4,minmax(0,1fr))] items-center border-b px-4 py-1.5" aria-live="off">
        <p className="min-w-0 truncate border-r pr-3"><span className="font-medium">{instId.replace(/-SWAP$/, "")}</span> · <span className="text-muted-foreground">{hovered === null ? historicalEnd === null ? "Latest" : "Window end" : "Selected"}</span> {time(active.hour)}{active.confirmed ? "" : " · Live"}</p>
        {([ ["Open", active.open], ["High", active.high], ["Low", active.low], ["Close", active.close] ] as const).map(([label, value]) => <div key={label} className="min-w-0 px-3">
          <span className="text-muted-foreground">{label} </span><span title={price(value)}>{price(value)}</span>
        </div>)}
      </div>}
      <div ref={plotRef} className="relative min-h-0 flex-1 overflow-hidden" onWheel={event => {
        const horizontal = Math.abs(event.deltaX) > Math.abs(event.deltaY)
        const delta = horizontal ? event.deltaX : -event.deltaY
        wheelPixels.current += delta * (event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? 240 : 1)
        if (wheelFrame.current !== null || Math.abs(wheelPixels.current) < 12) return
        wheelFrame.current = window.requestAnimationFrame(() => {
          wheelFrame.current = null
          const steps = Math.trunc(wheelPixels.current / 12)
          wheelPixels.current -= steps * 12
          flushSync(() => moveHistory(steps))
        })
      }}>
        <div className="relative h-full w-full">
        {bars.length && plotSize.width > 0 ? [...surfaces].map(([id, data]) => <svg key={id} viewBox={`0 0 ${plotSize.width} ${plotSize.height}`} className={cn("absolute inset-0 h-full w-full focus-visible:outline-2 focus-visible:outline-ring", id !== instId && "hidden")} role="img" tabIndex={id === instId ? 0 : -1} aria-hidden={id !== instId} aria-label={`${id} 96 hour candlestick chart with VWAP14, EMA200, shaded Bollinger bands and middle line, RSI with a shaded 30 to 70 range, ROC, MAROC, open interest and taker buy and sell volume. Scroll to review history; returning to the latest candle resumes automatic following. Arrow keys switch markets by 24 hour turnover. Shift plus left or right arrow inspects candles.`} onPointerLeave={() => { if (id === instId) setHover(null) }} onKeyDown={event => {
          if (id !== instId) return
          if (event.shiftKey && (event.key === "ArrowLeft" || event.key === "ArrowRight")) {
            event.preventDefault()
            setHover(current => ({ id: instId, index: Math.max(0, Math.min(bars.length - 1, (current?.id === instId ? current.index : bars.length - 1) + (event.key === "ArrowLeft" ? -1 : 1))) }))
          } else if (event.key === "Home" || event.key === "End") {
            event.preventDefault()
            setHover({ id: instId, index: event.key === "Home" ? 0 : bars.length - 1 })
          }
        }} onPointerMove={event => {
          if (id !== instId) return
          const rect = event.currentTarget.getBoundingClientRect()
          const svgX = event.clientX - rect.left
          const { columns } = chartLayout(plotSize.width, plotSize.height, chartGutter(bars, plotSize.height, chart?.bars.at(-1)?.close).gutter)
          const [start, end] = columns.price
          const latestHour = viewportEnd
          let index = 0
          for (let i = 1; i < bars.length; i++) {
            if (Math.abs(chartHourX(bars[i].hour, latestHour, start, end) - svgX) < Math.abs(chartHourX(bars[index].hour, latestHour, start, end) - svgX)) index = i
          }
          setHover(current => current?.id === instId && current.index === index ? current : { id: instId, index })
        }}>
          <Plot bars={data.bars} liveBar={id === instId ? chart?.bars.at(-1) ?? data.bars.at(-1)! : data.bars.at(-1)!} hovered={hover?.id === id ? hover.index : null} width={plotSize.width} height={plotSize.height} now={id === instId ? now : 0} endHour={data.endHour ?? data.bars.at(-1)!.hour} />
        </svg>) : <p className="flex h-full items-center justify-center text-muted-foreground">{chart ? "No candle data available yet" : "Loading chart…"}</p>}
        {historicalEnd !== null && historyLoading === `${instId}:${historicalEnd}` && <span role="status" className="pointer-events-none absolute right-4 top-2 rounded-md bg-card/90 px-2 py-1 text-muted-foreground">Loading history…</span>}
        {atHistoryBoundary && <span role="status" className="pointer-events-none absolute right-4 top-2 rounded-md bg-card/90 px-2 py-1 text-muted-foreground">Start of available history</span>}
        </div>
      </div>
      {captureStatus === "flashing" && <div aria-hidden="true" className="pointer-events-none absolute inset-0 z-10 bg-[var(--chart-capture-flash)] motion-safe:animate-[chart-capture-flash_550ms_ease-out_both] motion-reduce:hidden" />}
    </section>
  </main>
}
