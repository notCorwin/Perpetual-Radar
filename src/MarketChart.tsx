import { memo, startTransition, useCallback, useEffect, useRef, useState } from "react"
import { ArrowLeft, Camera, Check, Radio } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { chartAxis, visibleTicks } from "@/chart-axis"
import { chartHourX, chartLayout, type ChartPanel as Panel } from "@/chart-layout"
import { cn } from "@/lib/utils"
import { wrappedMarket } from "@/market-sort"

type Bar = {
  hour: number; open: number; high: number; low: number; close: number; confirmed: boolean
  vwap: number | null; ema: number | null; bollUpper: number | null; bollMiddle: number | null; bollLower: number | null
  roc: number | null; maroc: number | null; rsi6: number | null; rsi12: number | null; rsi24: number | null
  oi: number | null; buy: number | null; sell: number | null
}
export type ChartResponse = { bars: Bar[]; error: string; revision: number }
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
const legendContext = document.createElement("canvas").getContext("2d")
const legendWidth = (text: string) => {
  if (!legendContext) return text.length * 7
  const style = getComputedStyle(document.documentElement)
  legendContext.font = `${style.getPropertyValue("--chart-text-size").trim()} ${style.fontFamily}`
  return legendContext.measureText(text.replace(/\d/g, "0")).width
}
const priceTagWidth = (priceText: string, countdown: string) => {
  const padding = Number.parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--chart-price-tag-padding-x"))
  return Math.ceil(Math.max(legendWidth(priceText), legendWidth(countdown)) + padding * 2)
}
const chartGutter = (bars: Bar[]) => {
  const values = chartPriceValues(bars)
  const priceAxis = chartAxis(Math.min(...values), Math.max(...values), 8)
  const decimals = priceAxis.decimals
  const priceFormatter = new Intl.NumberFormat("en-US", { minimumFractionDigits: decimals, maximumFractionDigits: decimals })
  const rocAxis = rocAxisFor(bars)
  const oiValues = bars.flatMap(bar => bar.oi === null ? [] : [bar.oi])
  const takerAxis = chartAxis(0, Math.max(1, ...bars.map(bar => (bar.buy ?? 0) + (bar.sell ?? 0))))
  const labels = [
    ...priceAxis.ticks.map(tick => priceFormatter.format(tick)),
    `+${rocAxis.max.toFixed(rocAxis.decimals)}`, rocAxis.min.toFixed(rocAxis.decimals), "100", "0",
    ...(oiValues.length ? chartAxis(Math.min(...oiValues), Math.max(...oiValues)).ticks.map(compact) : []),
    ...takerAxis.ticks.map(compact),
  ]
  return Math.ceil(Math.max(priceTagWidth(price(bars[bars.length - 1].close), "00:00"), ...labels.map(label => 8 + legendWidth(label))))
}

const Plot = memo(function Plot({ bars, hovered, width, height, now }: { bars: Bar[]; hovered: number | null; width: number; height: number; now: number }) {
  const n = bars.length
  const active = bars[hovered ?? n - 1]
  const latestHour = bars[n - 1].hour
  const firstHour = latestHour - 95 * 3_600_000
  const candleHigh = Math.max(...bars.map(bar => bar.high)), candleLow = Math.min(...bars.map(bar => bar.low))
  const { panels, columns, axisStarts, headerY, left, right } = chartLayout(width, height, chartGutter(bars))
  const x = (index: number, panel: Panel) => chartHourX(bars[index].hour, latestHour, ...columns[panel])
  const barWidth = Math.max(5, Math.min(13, (right - left) / n * 0.68))
  const takerBarWidth = Math.max(2, Math.min(9, (columns.taker[1] - columns.taker[0]) / n * 0.7))
  const priceValues = chartPriceValues(bars)
  const priceMin = Math.min(...priceValues), priceMax = Math.max(...priceValues)
  const priceAxis = chartAxis(priceMin, priceMax, 8)
  const highIndex = bars.findIndex(bar => bar.high === candleHigh), lowIndex = bars.findIndex(bar => bar.low === candleLow)
  const priceDecimals = priceAxis.decimals
  const axisPrice = new Intl.NumberFormat("en-US", { minimumFractionDigits: priceDecimals, maximumFractionDigits: priceDecimals })
  const rocAxis = rocAxisFor(bars)
  const oiValues = bars.flatMap(bar => bar.oi === null ? [] : [bar.oi])
  const oiAxis = oiValues.length ? chartAxis(Math.min(...oiValues), Math.max(...oiValues)) : null
  const maxTaker = Math.max(1, ...bars.map(bar => (bar.buy ?? 0) + (bar.sell ?? 0)))
  const takerAxis = chartAxis(0, maxTaker)
  const scale = (value: number, min: number, max: number, panel: readonly [number, number]) =>
    panel[1] - (value - min) / (max - min || 1) * (panel[1] - panel[0])
  const priceY = (value: number) => scale(value, priceAxis.min, priceAxis.max, panels.price)
  const latest = bars[n - 1]
  const latestY = priceY(latest.close)
  const latestColor = latest.close >= latest.open ? "var(--positive)" : "var(--destructive)"
  const secondsLeft = now && !latest.confirmed ? Math.max(0, Math.floor((latest.hour + 3_600_000 - now) / 1000)) : 0
  const countdown = `${String(Math.floor(secondsLeft / 60)).padStart(2, "0")}:${String(secondsLeft % 60).padStart(2, "0")}`
  const latestPrice = price(latest.close), tagWidth = priceTagWidth(latestPrice, countdown)
  const tagStyle = getComputedStyle(document.documentElement)
  const tagLineHeight = Number.parseFloat(tagStyle.getPropertyValue("--chart-text-size")) * Number.parseFloat(tagStyle.getPropertyValue("--chart-price-tag-line-height"))
  const tagPaddingY = Number.parseFloat(tagStyle.getPropertyValue("--chart-price-tag-padding-y"))
  const tagHeight = tagLineHeight * 2 + tagPaddingY * 2
  const priceTagY = Math.max(panels.price[0], Math.min(latestY - tagHeight / 2, panels.price[1] - tagHeight))
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
      segment += `${segment ? " L" : "M"}${x(index, panelKey).toFixed(1)} ${scale(value, min, max, panels[panelKey]).toFixed(1)}`
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
    upper.push(`${pointX} ${priceY(bar.bollUpper).toFixed(1)}`)
    lower.push(`${pointX} ${priceY(bar.bollLower).toFixed(1)}`)
  })
  finishBand()
  const lineStroke = (d: string, color: string, width = 1.8, opacity = 1, dash?: string) => <path d={d} fill="none" stroke={color} strokeWidth={width} strokeLinecap="round" strokeLinejoin="round" strokeDasharray={dash} opacity={opacity} />
  const lineLabel = (x: number, y: number, label: string, color = "var(--muted-foreground)") =>
    <text x={x} y={y} dominantBaseline="middle" fill={color}>{label}</text>
  const panelKeys: Panel[] = ["price", "roc", "rsi", "oi", "taker"]
  const grid = panelKeys.flatMap(key => panels[key].map((y, index) =>
    <line key={`${key}-${index}`} x1={columns[key][0]} x2={columns[key][1]} y1={y} y2={y} stroke="var(--border)" strokeWidth="1" opacity={index ? 0.32 : 0.55} />))
  const legend = (key: Panel, title: string, items: [string, string, string, string?][]) => {
    const start = columns[key][0]
    const titleWidth = legendWidth(title)
    const gap = Number.parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--chart-legend-gap"))
    const widths = items.map(([label, value, , dash]) => legendWidth(label) + 10 + legendWidth(value) + (dash === undefined ? 0 : 22))
    const available = right - start
    const required = titleWidth + widths.reduce((sum, itemWidth) => sum + itemWidth, 0) + gap * items.length
    const shrink = Math.min(1, available / required)
    let cursor = titleWidth + gap
    return <g key={title}>
      <g transform={`translate(${start},${headerY[key]}) scale(${shrink})`}>
      <text dominantBaseline="middle" fill="var(--foreground)">{title}</text>
      {items.map(([label, value, color, dash], index) => {
        const itemStart = cursor
        cursor += widths[index] + gap
        const labelStart = dash === undefined ? 0 : 22
        return <g key={label} transform={`translate(${itemStart},0)`}>
        {dash !== undefined && <line x1="0" x2="16" y1="0" y2="0" stroke={color} strokeWidth="2.4" strokeLinecap="round" strokeDasharray={dash} />}
        <text x={labelStart} dominantBaseline="middle" fill="var(--muted-foreground)">{label}</text>
        <text x={labelStart + legendWidth(label) + 10} dominantBaseline="middle" fill={color}>{value}</text>
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
    <rect x={columns.rsi[0]} y={scale(70, 0, 100, panels.rsi)} width={columns.rsi[1] - columns.rsi[0]} height={scale(30, 0, 100, panels.rsi) - scale(70, 0, 100, panels.rsi)} fill="var(--muted)" />
    {grid}
    {bars.flatMap((bar, index) => (bar.hour - firstHour) % (12 * 3_600_000) === 0 ? panelKeys.map(key => <line key={`${bar.hour}-${key}`} x1={x(index, key)} x2={x(index, key)} y1={panels[key][0]} y2={panels[key][1]} stroke="var(--border)" strokeOpacity="0.22" />) : [])}
    {bars.map((bar, index) => ({ bar, index })).filter(({ bar, index }) => index === n - 1 || (bar.hour - firstHour) % (24 * 3_600_000) === 0).map(({ bar, index }) => <text key={bar.hour} x={x(index, "taker")} y={height - 7} textAnchor={index === 0 ? "start" : index === n - 1 ? "end" : "middle"} fill="var(--muted-foreground)">{hourLabel(bar.hour)}</text>)}
    {visibleTicks(priceAxis.ticks, Math.max(2, Math.floor((panels.price[1] - panels.price[0]) / 32) + 1)).map(tick => {
      const tickY = priceY(tick)
      return <g key={tick}><line x1={columns.price[0]} x2={right} y1={tickY} y2={tickY} stroke="var(--border)" strokeOpacity="0.35" />{Math.abs(tickY - latestY) > 14 && lineLabel(axisStarts.price, tickY, axisPrice.format(tick))}</g>
    })}
    <line x1={columns.price[0]} x2={right} y1={latestY} y2={latestY} stroke={latestColor} opacity="0.5" />
    {bars.map((bar, index) => {
      const up = bar.close >= bar.open
      const color = up ? "var(--positive)" : "var(--destructive)"
      const y1 = priceY(Math.max(bar.open, bar.close)), y2 = priceY(Math.min(bar.open, bar.close))
      const buyHeight = (bar.buy ?? 0) / takerAxis.max * (panels.taker[1] - panels.taker[0])
      const sellHeight = (bar.sell ?? 0) / takerAxis.max * (panels.taker[1] - panels.taker[0])
      return <g key={bar.hour}>
        <line x1={x(index, "price")} x2={x(index, "price")} y1={priceY(bar.high)} y2={priceY(bar.low)} stroke={color} strokeWidth="1.2" />
        <rect x={x(index, "price") - barWidth / 2} y={y1} width={barWidth} height={Math.max(1.5, y2 - y1)} fill={color} />
        <rect x={x(index, "taker") - takerBarWidth / 2} y={panels.taker[1] - buyHeight} width={takerBarWidth} height={buyHeight} fill="var(--positive)" opacity="0.9" />
        <rect x={x(index, "taker") - takerBarWidth / 2} y={panels.taker[1] - buyHeight - sellHeight} width={takerBarWidth} height={sellHeight} fill="var(--destructive)" opacity="0.9" />
        <rect x={x(index, "taker") - takerBarWidth / 2} y={panels.taker[1] - buyHeight - sellHeight} width={takerBarWidth} height={sellHeight} fill="url(#sell-hatch)" opacity="0.7" />
      </g>
    })}
    {lineStroke(priceLine("bollUpper"), "var(--chart-1)", 0.8, 0.62)}
    {lineStroke(priceLine("bollMiddle"), "var(--chart-1)", 1.4)}
    {lineStroke(priceLine("bollLower"), "var(--chart-1)", 0.8, 0.62)}
    {lineStroke(priceLine("vwap"), "var(--chart-2)", 1.8)}
    {lineStroke(priceLine("ema"), "var(--chart-3)", 1.8, 0.9)}
    {lineStroke(line("rsi6", "rsi", 0, 100), "var(--chart-1)", 2.4)}
    {lineStroke(line("rsi12", "rsi", 0, 100), "var(--chart-2)", 2.4, 1, "7 4")}
    {lineStroke(line("rsi24", "rsi", 0, 100), "var(--chart-3)", 2.4, 1, "1 4")}
    {lineStroke(line("roc", "roc", rocAxis.min, rocAxis.max), "var(--chart-1)", 2.4)}
    {lineStroke(line("maroc", "roc", rocAxis.min, rocAxis.max), "var(--chart-2)", 2.4, 1, "7 4")}
    {oiAxis && lineStroke(line("oi", "oi", oiAxis.min, oiAxis.max), "var(--chart-2)", 2)}
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
    <g>
      <rect x={right} y={priceTagY} width={tagWidth} height={tagHeight} rx="4" fill={latestColor} />
      <text x={right + tagWidth / 2} y={priceTagY + tagPaddingY + tagLineHeight / 2} textAnchor="middle" dominantBaseline="middle" fill="var(--signal-foreground)">{latestPrice}</text>
      <text x={right + tagWidth / 2} y={priceTagY + tagPaddingY + tagLineHeight * 1.5} textAnchor="middle" dominantBaseline="middle" fill="var(--signal-foreground)">{countdown}</text>
    </g>
    {legend("price", "PRICE", [["VWAP14", price(active.vwap), "var(--chart-2)"], ["EMA200", price(active.ema), "var(--chart-3)"], ["BOLL20", `U ${price(active.bollUpper)}\u00a0·\u00a0M ${price(active.bollMiddle)}\u00a0·\u00a0L ${price(active.bollLower)}`, "var(--chart-1)"]])}
    {legend("roc", "ROC", [["ROC9", active.roc?.toFixed(2) ?? "—", "var(--chart-1)", ""], ["MAROC9", active.maroc?.toFixed(2) ?? "—", "var(--chart-2)", "7 4"]])}
    {legend("rsi", "RSI", [["RSI(6)", active.rsi6?.toFixed(1) ?? "—", "var(--chart-1)", ""], ["RSI(12)", active.rsi12?.toFixed(1) ?? "—", "var(--chart-2)", "7 4"], ["RSI(24)", active.rsi24?.toFixed(1) ?? "—", "var(--chart-3)", "1 4"]])}
    {legend("oi", "OPEN INTEREST", [["OI", compact(active.oi), "var(--chart-2)"]])}
    {legend("taker", "TAKER BUY / SELL", [["Buy", compact(active.buy), "var(--positive)"], ["Sell", compact(active.sell), "var(--destructive)"]])}
    {panels.rsi[1] - panels.rsi[0] >= 35 && <>{lineLabel(axisStarts.rsi, panels.rsi[0], "100")}{lineLabel(axisStarts.rsi, panels.rsi[1], "0")}</>}
    {panels.roc[1] - panels.roc[0] >= 35 && <>{lineLabel(axisStarts.roc, panels.roc[0], `+${rocAxis.max.toFixed(rocAxis.decimals)}`)}{lineLabel(axisStarts.roc, panels.roc[1], rocAxis.min.toFixed(rocAxis.decimals))}</>}
    {oiAxis && panels.oi[1] - panels.oi[0] >= 35 && visibleTicks(oiAxis.ticks, Math.max(2, Math.floor((panels.oi[1] - panels.oi[0]) / 32) + 1)).map(tick => <g key={tick}>{lineLabel(axisStarts.oi, scale(tick, oiAxis.min, oiAxis.max, panels.oi), compact(tick))}</g>)}
    {panels.taker[1] - panels.taker[0] >= 35 && visibleTicks(takerAxis.ticks, Math.max(2, Math.floor((panels.taker[1] - panels.taker[0]) / 32) + 1)).map(tick => <g key={tick}>{lineLabel(axisStarts.taker, scale(tick, takerAxis.min, takerAxis.max, panels.taker), compact(tick))}</g>)}
  </>
})

export function MarketChart({ instId, order, onSelect, onBack }: { instId: string; order: string[]; onSelect: (id: string) => void; onBack: () => void }) {
  const [displayed, setDisplayed] = useState<{ id: string; data: ChartResponse } | null>(null)
  const [hover, setHover] = useState<{ id: string; index: number } | null>(null)
  const [chartError, setChartError] = useState<{ id: string; message: string } | null>(null)
  const [warmCharts, setWarmCharts] = useState(() => new Map<string, ChartResponse>())
  const [capture, setCapture] = useState<{ id: string; status: "idle" | "copying" | "copied" | "failed"; error: string }>({ id: instId, status: "idle", error: "" })
  const chartRef = useRef<HTMLElement>(null)
  const plotRef = useRef<HTMLDivElement>(null)
  const navigationId = useRef(instId)
  const navigationFrame = useRef<number | null>(null)
  const [plotSize, setPlotSize] = useState({ width: 0, height: 0 })
  const [now, setNow] = useState(0)
  const position = order.indexOf(instId)
  const previous = wrappedMarket(order, position - 1), next = wrappedMarket(order, position + 1)
  const beforePrevious = wrappedMarket(order, position - 2), afterNext = wrappedMarket(order, position + 2)
  const chart = displayed?.id === instId ? displayed.data : chartCache.get(instId)?.data ?? warmCharts.get(instId) ?? null
  const hovered = hover?.id === instId ? hover.index : null
  const error = chartError?.id === instId ? chartError.message : chart?.error ?? ""
  const captureStatus = capture.id === instId ? capture.status : "idle"
  const captureError = capture.id === instId ? capture.error : ""
  useEffect(() => {
    if (capture.status !== "copied") return
    const timer = window.setTimeout(() => setCapture(current => current === capture ? { ...current, status: "idle" } : current), 2000)
    return () => window.clearTimeout(timer)
  }, [capture])
  const captureChart = async () => {
    const rect = chartRef.current?.getBoundingClientRect()
    if (!rect || rect.width <= 0 || rect.height <= 0) return
    setCapture({ id: instId, status: "copying", error: "" })
    try {
      await window.webkit.messageHandlers.radar.postMessage({ captureChart: { x: rect.x, y: rect.y, width: rect.width, height: rect.height } })
      setCapture({ id: instId, status: "copied", error: "" })
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
    const timer = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(timer)
  }, [])
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
          setDisplayed({ id: instId, data: result })
          warmChart(instId, result, false)
        }
        setChartError(current => current?.id === instId && current.message === result.error ? current : { id: instId, message: result.error })
      } catch (cause) {
        if (!stopped) {
          const message = cause instanceof Error ? cause.message : "Cannot load chart"
          setChartError(current => current?.id === instId && current.message === message ? current : { id: instId, message })
        }
      }
      if (!stopped) timer = window.setTimeout(refresh, 2000)
    }
    if (!chartCache.has(instId)) void previewChart(instId).then(data => {
      if (!stopped) { setDisplayed({ id: instId, data }); warmChart(instId, data, false) }
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

  const bars = chart?.bars ?? []
  const active = bars[hovered ?? bars.length - 1]
  const surfaces = new Map(warmCharts)
  if (chart?.bars.length) surfaces.set(instId, chart)
  return <main className="flex h-svh min-h-0 flex-col overflow-hidden overscroll-none text-[length:var(--chart-text-size)] font-normal tabular-nums">
    <header className="flex shrink-0 items-center gap-3 border-b px-4 py-2">
      <Button variant="ghost" size="sm" onClick={onBack}><ArrowLeft data-icon="inline-start" aria-hidden="true" />Markets</Button>
      <div className="min-w-0 flex-1">
        <h1 className="truncate text-base font-semibold tracking-tight normal-nums">{instId.replace(/-SWAP$/, "")}</h1>
        <p className="text-muted-foreground">OKX perpetual · 1h · Last 96 hours · 24h turnover rank {position + 1}/{order.length} · ↑/← higher · ↓/→ lower</p>
      </div>
      <Button variant="outline" size="sm" className={captureStatus === "copied" ? "border-ring bg-ring/15 ring-2 ring-ring/50" : ""} disabled={!bars.length || plotSize.width <= 0 || captureStatus === "copying"} onClick={() => { void captureChart() }}>{captureStatus === "copied" ? <Check data-icon="inline-start" aria-hidden="true" /> : <Camera data-icon="inline-start" aria-hidden="true" />}<span role="status" aria-live="polite">{captureStatus === "copied" ? "Copied" : captureStatus === "copying" ? "Copying…" : "Copy chart"}</span></Button>
      <Badge variant="secondary"><Radio aria-hidden="true" /><span className="text-[length:var(--chart-text-size)] font-normal">{active && !active.confirmed ? "Live candle" : "Hourly chart"}</span></Badge>
    </header>
    {error && <p role="alert" className="shrink-0 border-b px-5 py-2 text-destructive">{error}</p>}
    {captureError && <p role="alert" className="shrink-0 border-b px-5 py-2 text-destructive">{captureError}</p>}
    <section ref={chartRef} aria-label={`${instId} chart`} className="relative flex min-h-0 flex-1 flex-col bg-card">
      {active && <div className="grid shrink-0 grid-cols-[minmax(9rem,1.2fr)_repeat(4,minmax(0,1fr))] items-center border-b px-4 py-1.5" aria-live="off">
        <p className="min-w-0 truncate border-r pr-3"><span className="font-medium">{instId.replace(/-SWAP$/, "")}</span> · <span className="text-muted-foreground">{hovered === null ? "Latest" : "Selected"}</span> {time(active.hour)}{active.confirmed ? "" : " · Live"}</p>
        {([ ["Open", active.open], ["High", active.high], ["Low", active.low], ["Close", active.close] ] as const).map(([label, value]) => <div key={label} className="min-w-0 px-3">
          <span className="text-muted-foreground">{label} </span><span title={price(value)}>{price(value)}</span>
        </div>)}
      </div>}
      <div ref={plotRef} className="relative min-h-0 flex-1">
        {bars.length && plotSize.width > 0 ? [...surfaces].map(([id, data]) => <svg key={id} viewBox={`0 0 ${plotSize.width} ${plotSize.height}`} className={cn("absolute inset-0 h-full w-full focus-visible:outline-2 focus-visible:outline-ring", id !== instId && "hidden")} role="img" tabIndex={id === instId ? 0 : -1} aria-hidden={id !== instId} aria-label={`${id} 96 hour candlestick chart with VWAP14, EMA200, shaded Bollinger bands and middle line, RSI with a shaded 30 to 70 range, ROC, MAROC, open interest and taker buy and sell volume. Arrow keys switch markets by 24 hour turnover. Shift plus left or right arrow inspects candles.`} onPointerLeave={() => { if (id === instId) setHover(null) }} onKeyDown={event => {
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
          const { columns } = chartLayout(plotSize.width, plotSize.height, chartGutter(bars))
          const [start, end] = columns.price
          const latestHour = bars[bars.length - 1].hour
          let index = 0
          for (let i = 1; i < bars.length; i++) {
            if (Math.abs(chartHourX(bars[i].hour, latestHour, start, end) - svgX) < Math.abs(chartHourX(bars[index].hour, latestHour, start, end) - svgX)) index = i
          }
          setHover(current => current?.id === instId && current.index === index ? current : { id: instId, index })
        }}>
          <Plot bars={data.bars} hovered={hover?.id === id ? hover.index : null} width={plotSize.width} height={plotSize.height} now={id === instId ? now : 0} />
        </svg>) : <p className="flex h-full items-center justify-center text-muted-foreground">{chart ? "No candle data available yet" : "Loading chart…"}</p>}
      </div>
      {captureStatus === "copied" && <div aria-hidden="true" className="pointer-events-none absolute inset-0 z-10 bg-ring/50 motion-safe:animate-[chart-capture-flash_550ms_ease-out_both] motion-reduce:hidden" />}
    </section>
  </main>
}
