import { Fragment, memo, startTransition, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react"
import { ArrowDown, ArrowDownUp, ArrowUp, Radio, Search, ScanSearch, Settings2 } from "lucide-react"
import katex from "katex"
import "katex/dist/katex.min.css"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Empty, EmptyContent, EmptyDescription, EmptyHeader, EmptyTitle } from "@/components/ui/empty"
import { Field, FieldDescription, FieldError, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Popover, PopoverContent, PopoverDescription, PopoverHeader, PopoverTitle, PopoverTrigger } from "@/components/ui/popover"
import { Toggle } from "@/components/ui/toggle"
import { Input } from "@/components/ui/input"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { cn } from "@/lib/utils"
import { compareMarketRows, compareMarketTurnover, defaultSortDescending, type SortKey } from "@/market-sort"
import { PERCENT_CHANGE_DESCRIPTION, formatPercent, percentageNumber, type PercentageValue } from "@/market-percent"
import { BREAK_DESCRIPTION, describeBreak, formatBreakPriorAge, formatBreakTime, type BreakDirection, type BreakResult } from "@/market-breaks"
import { BANDWIDTH_EXPANSION_DESCRIPTION, LOG_BB_DESCRIPTION, formatBandWidthExpansion, formatLiveBand } from "@/market-logbb"
import { MarketChart, type ChartPollResponse } from "@/MarketChart"
import { OPPORTUNITY_DESCRIPTION } from "@/market-opportunity"
import { MarketOpportunity } from "@/MarketOpportunity"
import { MarketListViewport } from "@/MarketListViewport"
import { MarketRowsViewport } from "@/MarketRowsViewport"
import { MarketFilters } from "@/MarketFilters"
import { FilterExplanation } from "@/FilterExplanation"
import { keepSnapshotValue, reconcileMarketRows } from "@/market-snapshot"
import { emptyFilterConfig, initialEditorState, initialLibraryPreferences, parseFilterConfig, previewResponseIsCurrent, newRuleID, type CompileResponse, type ExplainResponse, type FilterCombination, type FilterConfigV2, type FilterEditorState, type FilterLibraryPreferences, type FilterMetric, type FilterTruth, type NativeMarketRow } from "@/rule-engine"
import { expressionTemplates, type ExpressionTemplate } from "@/filter-expression"

type WindowAppearance = { frostedBackgroundEnabled: boolean; frostedBackgroundOpacity: number }
type HistoryProgress = { pending: number; completed: number; error: string }
type Snapshot = WindowAppearance & { rows: NativeMarketRow[]; updatedAt: number | null; error: string; revision: number; filterConfigJSON: string; filterMetricsCatalog: FilterMetric[]; filterFunctions: string[]; filterFunctionCatalog: ExpressionTemplate[]; filterLibraryPreferences: FilterLibraryPreferences; marketFilterCombinations: FilterCombination[]; selectedMarketFilterCombinationID: string }
type PreviewSnapshot = Snapshot & { filterResults: Record<string, FilterTruth>; filterToken: string; historyProgress: HistoryProgress }
type UnchangedSnapshot = { unchanged: true; revision: number; error: string }
type SettingRequest = Partial<WindowAppearance> & { marketFiltersJSON?: string; filterLibraryPreferencesJSON?: string; saveMarketFilterCombination?: { name: string; filtersJSON: string }; deleteMarketFilterCombination?: string; selectedMarketFilterCombinationID?: string }
type NativeBridge = {
  postMessage(request: { rocPeriod: number; marocPeriod: number; sinceRevision: number }): Promise<Snapshot | UnchangedSnapshot>
  postMessage(request: { compileMarketFilters: { filtersJSON?: string; source?: string; previousJSON?: string } }): Promise<CompileResponse>
  postMessage(request: { previewMarketFilters: { filtersJSON: string; token: string } }): Promise<PreviewSnapshot>
  postMessage(request: { explainMarketFilters: { instId: string; filtersJSON: string; token: string } }): Promise<ExplainResponse>
  postMessage(request: SettingRequest): Promise<Snapshot>
  postMessage(request: { captureChart: { x: number; y: number; width: number; height: number; backgroundRGB: number[] } }): Promise<{ ok: boolean }>
  postMessage(request: { windowTintRGB: number[] }): Promise<{ ok: boolean }>
  postMessage(request: { chartInstId: string; loadChart?: boolean; sinceRevision?: number; chartEndHour?: number }): Promise<ChartPollResponse>
}
declare global {
  interface Window { radarAppearance?: WindowAppearance & { nativeWindowBackground?: boolean }; webkit: { messageHandlers: { radar: NativeBridge } } }
}
const ROC_PERIOD = 9
const MAROC_PERIOD = 9
const formatIndicator = (value: number | null) => value === null ? "—" : value.toFixed(2)
const priceFormatter = new Intl.NumberFormat("en-US", { maximumSignificantDigits: 8 })
const turnoverFormatter = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 2 })
const formatPrice = (value: number | null) => value === null ? "—" : priceFormatter.format(value)
const directionClass = (value: PercentageValue) => {
  const number = percentageNumber(value)
  return number === null ? "text-muted-foreground" : number > 0 ? "text-positive" : number < 0 ? "text-destructive" : ""
}
const rsiClass = (value: number | null) => value === null ? "text-muted-foreground" : value > 70 ? "text-positive" : value < 30 ? "text-destructive" : ""
const RSI_PERIODS = [6, 12, 24] as const
const mathCache = new Map<string, string>()
const math = (formula: string) => {
  if (!mathCache.has(formula)) mathCache.set(formula, katex.renderToString(formula))
  return <span className="text-xs font-medium text-foreground" dangerouslySetInnerHTML={{ __html: mathCache.get(formula)! }} />
}

function BreakReadings({ result, direction }: { result: BreakResult; direction: BreakDirection }) {
  const description = describeBreak(result, direction)
  const hasEvent = result.status === "event"
  return <Fragment>
    <span className={cn("inline-flex items-baseline justify-end gap-1", hasEvent ? direction === "high" ? "text-positive" : "text-destructive" : "text-muted-foreground")} title={description}>
      <span className="sr-only">{direction === "high" ? "High breakout" : "Low breakdown"} </span>
      {hasEvent && <span aria-hidden="true">{direction === "high" ? "↑" : "↓"}</span>}
      {(hasEvent && result.live) || result.status === "loading" ? <Badge variant={result.status === "loading" ? "outline" : "secondary"}>{formatBreakTime(result)}</Badge> : formatBreakTime(result)}
    </span>
    <span className="text-xs text-muted-foreground" title={description}>
      <span className="sr-only">Previous {direction === "high" ? "high" : "low"} age at the break </span>{formatBreakPriorAge(result)}
    </span>
  </Fragment>
}

const MarketRowView = memo(function MarketRowView({ row, index, onSelect, onExplain }: { row: NativeMarketRow; index: number; onSelect: (id: string) => void; onExplain: (id: string) => void }) {
  return <TableRow data-market-index={index} aria-rowindex={index + 2} interactive tabIndex={0} aria-label={`View ${row.instId} chart`} onClick={() => onSelect(row.instId)} onKeyDown={event => {
    if (event.key === "Enter" || event.key === " ") { event.preventDefault(); onSelect(row.instId) }
  }}>
    <TableCell className="pl-[var(--market-table-leading-inset)] text-left" title={row.instId}>
      <span className="font-medium">{row.instId.replace(/-USDT-SWAP$/, "")}</span>
      <div className="flex justify-start gap-2 text-xs tabular-nums">
        <span>{formatPrice(row.price)}</span>
        <span className={directionClass(row.priceChange)} title={`Price change from the previous completed hour. ${PERCENT_CHANGE_DESCRIPTION}`}>{formatPercent(row.priceChange)}</span>
      </div>
      <div className="flex items-center justify-start gap-3 text-xs tabular-nums">
        <span className="flex gap-1"><span className="text-muted-foreground">Low</span><span>{formatPrice(row.currentLow)}</span></span>
        <span className="flex gap-1"><span className="text-muted-foreground">High</span><span>{formatPrice(row.currentHigh)}</span></span>
      </div>
      <div className="flex items-center justify-start gap-1 text-xs tabular-nums" title={row.turnover24hUSDT === null ? "Hourly turnover is unavailable" : `${row.turnover24hUSDT.toLocaleString("en-US", { maximumFractionDigits: 2 })} USDT`}>
        <span className="text-muted-foreground">Turnover</span><span>{row.turnover24hUSDT === null ? "—" : turnoverFormatter.format(row.turnover24hUSDT)} USDT</span>
      </div>
    </TableCell>
    <TableCell className="text-center tabular-nums"><MarketOpportunity instId={row.instId} opportunity={row.opportunity} /><Button variant="ghost" size="sm" className="mt-1" aria-label={`Explain ${row.instId} rules`} onClick={event => { event.stopPropagation(); onExplain(row.instId) }} onKeyDown={event => event.stopPropagation()}><ScanSearch data-icon="inline-start" aria-hidden="true" />Rules</Button></TableCell>
    <TableCell className="text-center tabular-nums">
      <div className="mx-auto grid w-max grid-cols-[max-content_max-content] items-baseline gap-x-3 text-right">
        <BreakReadings result={row.highBreakout} direction="high" />
        <BreakReadings result={row.lowBreakdown} direction="low" />
      </div>
    </TableCell>
    <TableCell className={cn("text-center tabular-nums", directionClass(row.takerRatio))} title={row.buy !== null && row.sell !== null ? `Buy ${row.buy.toLocaleString("en-US")} / Sell ${row.sell.toLocaleString("en-US")} contracts` : "Loading current-hour taker volume"}>{formatPercent(row.takerRatio)}</TableCell>
    <TableCell className={cn("text-center tabular-nums", directionClass(row.oiChange))}>{formatPercent(row.oiChange)}</TableCell>
    <TableCell className="text-center tabular-nums">
      <div className="mx-auto grid w-max grid-cols-[max-content_max-content] gap-x-3 text-right">
        <span className={directionClass(row.roc)}><span className="sr-only">ROC </span>{formatPercent(row.roc)}</span>
        <span className={directionClass(row.rocChange)} title={`Hourly ROC change. ${PERCENT_CHANGE_DESCRIPTION}`}><span className="sr-only">ROC hourly change </span>{formatPercent(row.rocChange)}</span>
        <span className={directionClass(row.maroc)}><span className="sr-only">MAROC </span>{formatPercent(row.maroc)}</span>
        <span className={directionClass(row.marocChange)} title={`Hourly MAROC change. ${PERCENT_CHANGE_DESCRIPTION}`}><span className="sr-only">MAROC hourly change </span>{formatPercent(row.marocChange)}</span>
      </div>
    </TableCell>
    <TableCell className="text-center tabular-nums">
      <div className="flex flex-col items-center text-xs">
        {RSI_PERIODS.map(period => <div key={period} className="flex gap-1"><span className="text-muted-foreground">{period}</span><span className={rsiClass(row[`rsi${period}`])}>{formatIndicator(row[`rsi${period}`])}</span></div>)}
      </div>
    </TableCell>
    <TableCell className="text-center tabular-nums">
      <div className="flex flex-col items-center text-xs">
        <div className="flex gap-1" title={LOG_BB_DESCRIPTION}><span className="text-muted-foreground">Live</span><span className={cn(row.logBBAboveBand === null ? "text-muted-foreground" : row.logBBAboveBand === "below" ? "text-destructive" : "text-positive")}>{formatLiveBand(row.logBBAboveBand)}</span></div>
        <div className="flex gap-1" title={BANDWIDTH_EXPANSION_DESCRIPTION}><span className="text-muted-foreground">Expansion</span><span className={cn(row.logBBExpansion && row.logBBExpansion.hours > 0 ? "text-positive" : "text-muted-foreground")}>{formatBandWidthExpansion(row.logBBExpansion)}</span></div>
      </div>
    </TableCell>
  </TableRow>
})
const MarketRows = memo(function MarketRows({ rows, onSelect, onExplain }: { rows: NativeMarketRow[]; onSelect: (id: string) => void; onExplain: (id: string) => void }) {
  return <MarketRowsViewport ids={rows.map(row => row.instId)}>{index => <MarketRowView row={rows[index]} index={index} onSelect={onSelect} onExplain={onExplain} />}</MarketRowsViewport>
})

function App() {
  const revision = useRef(-1)
  const backgroundOpacityDraftDirty = useRef(false)
  const appliedJSON = useRef("")
  const compileEpoch = useRef(0)
  const previewEpoch = useRef(0)
  const [ready, setReady] = useState(false)
  const [listFilters, setListFilters] = useState<FilterConfigV2>(emptyFilterConfig)
  const [filterDraft, setFilterDraft] = useState<FilterConfigV2 | null>(null)
  const [editor, setEditor] = useState<FilterEditorState>(initialEditorState)
  const [compilation, setCompilation] = useState<CompileResponse & { key: string; pending: boolean }>({ key: "", pending: true, diagnostics: [] })
  const [lastValidJSON, setLastValidJSON] = useState<string | null>(null)
  const [previewJSON, setPreviewJSON] = useState<string | null>(null)
  const [results, setResults] = useState<Record<string, FilterTruth>>({})
  const [history, setHistory] = useState<HistoryProgress | null>(null)
  const [metrics, setMetrics] = useState<FilterMetric[]>([])
  const [functions, setFunctions] = useState<string[]>([])
  const [templates, setTemplates] = useState<ExpressionTemplate[]>(expressionTemplates)
  const [libraryPreferences, setLibraryPreferences] = useState<FilterLibraryPreferences>(initialLibraryPreferences)
  const librarySaveEpoch = useRef(0), librarySavePending = useRef(false)
  const [filterCombinations, setFilterCombinations] = useState<FilterCombination[]>([])
  const [filterCombinationId, setFilterCombinationId] = useState("")
  const [rows, setRows] = useState<NativeMarketRow[]>([])
  const [status, setStatus] = useState("Connecting")
  const [error, setError] = useState("")
  const [updatedAt, setUpdatedAt] = useState<number | null>(null)
  const [query, setQuery] = useState("")
  const [frostedBackgroundEnabled, setFrostedBackgroundEnabled] = useState(window.radarAppearance?.frostedBackgroundEnabled ?? true)
  const [frostedBackgroundOpacity, setFrostedBackgroundOpacity] = useState(window.radarAppearance?.frostedBackgroundOpacity ?? 0.3)
  const [backgroundOpacityDraft, setBackgroundOpacityDraft] = useState(String(window.radarAppearance?.frostedBackgroundOpacity ?? 0.3))
  const [backgroundOpacityError, setBackgroundOpacityError] = useState("")
  const [sort, setSort] = useState<SortKey>("opportunity")
  const [descending, setDescending] = useState(true)
  const [selected, setSelected] = useState<string | null>(null)
  const [explanationOpen, setExplanationOpen] = useState(false)
  const [explainingId, setExplainingId] = useState<string | null>(null)
  const explainMarket = useCallback((id: string) => { setExplainingId(id); setExplanationOpen(true) }, [])
  const draftJSON = JSON.stringify(filterDraft ?? listFilters)
  const compileKey = editor.source === null ? draftJSON : `source:${editor.source}`
  const editorExpressions = useMemo(() => ({ ...editor.expressionDrafts, ...compilation.expressions }), [editor.expressionDrafts, compilation.expressions])
  const compiling = compilation.pending || compilation.key !== compileKey
  const valid = !compiling && compilation.diagnostics.length === 0 && Boolean(compilation.configJSON)
  useLayoutEffect(() => {
    document.documentElement.dataset.frostedBackground = String(frostedBackgroundEnabled)
    document.documentElement.dataset.translucentBackground = String(frostedBackgroundEnabled && frostedBackgroundOpacity < 1)
    document.documentElement.style.setProperty("--window-background-opacity", String(frostedBackgroundEnabled ? frostedBackgroundOpacity : 1))
    if (!window.radarAppearance?.nativeWindowBackground) return
    document.documentElement.dataset.nativeWindowBackground = "true"
    const updateTint = () => {
      const canvas = document.createElement("canvas")
      canvas.width = canvas.height = 1
      const context = canvas.getContext("2d")!
      context.fillStyle = getComputedStyle(document.documentElement).getPropertyValue("--window-background-tint")
      context.fillRect(0, 0, 1, 1)
      const rgb = Array.from(context.getImageData(0, 0, 1, 1).data).slice(0, 3).map(value => value / 255)
      void window.webkit.messageHandlers.radar.postMessage({ windowTintRGB: rgb }).catch(() => {})
    }
    const theme = window.matchMedia("(prefers-color-scheme: dark)")
    updateTint()
    theme.addEventListener("change", updateTint)
    return () => theme.removeEventListener("change", updateTint)
  }, [frostedBackgroundEnabled, frostedBackgroundOpacity])
  const acceptSnapshot = (snapshot: Snapshot) => {
    if (snapshot.revision < revision.current) return false
    const includeData = revision.current === -1 || "filterResults" in snapshot
    revision.current = snapshot.revision
    if (includeData) setRows(current => reconcileMarketRows(current, snapshot.rows))
    setFrostedBackgroundEnabled(snapshot.frostedBackgroundEnabled)
    setFrostedBackgroundOpacity(snapshot.frostedBackgroundOpacity)
    if (!backgroundOpacityDraftDirty.current && document.activeElement?.id !== "background-opacity") setBackgroundOpacityDraft(String(snapshot.frostedBackgroundOpacity))
    if (appliedJSON.current !== snapshot.filterConfigJSON) {
      appliedJSON.current = snapshot.filterConfigJSON
      setListFilters(parseFilterConfig(snapshot.filterConfigJSON))
    }
    setFilterCombinations(current => keepSnapshotValue(current, snapshot.marketFilterCombinations))
    setFilterCombinationId(snapshot.selectedMarketFilterCombinationID)
    setMetrics(current => keepSnapshotValue(current, snapshot.filterMetricsCatalog))
    setFunctions(current => keepSnapshotValue(current, snapshot.filterFunctions))
    setTemplates(current => keepSnapshotValue(current, snapshot.filterFunctionCatalog ?? expressionTemplates))
    if (!librarySavePending.current) setLibraryPreferences(current => keepSnapshotValue(current, snapshot.filterLibraryPreferences ?? initialLibraryPreferences()))
    setUpdatedAt(snapshot.updatedAt)
    setError(snapshot.error)
    setReady(true)
    return true
  }
  useEffect(() => {
    let stopped = false
    const load = async () => {
      try {
        const snapshot = await window.webkit.messageHandlers.radar.postMessage({ rocPeriod: ROC_PERIOD, marocPeriod: MAROC_PERIOD, sinceRevision: -1 })
        if (stopped) return
        if (!("unchanged" in snapshot)) acceptSnapshot(snapshot)
        setStatus("Live")
      } catch (cause) {
        if (stopped) return
        setError(cause instanceof Error ? cause.message : "Cannot connect to the native collector")
        setStatus("Reconnecting")
        timer = window.setTimeout(load, 2000)
      }
    }
    let timer: number
    void load()
    return () => { stopped = true; window.clearTimeout(timer) }
  }, [])
  useEffect(() => {
    if (!ready) return
    const epoch = ++compileEpoch.current
    let stopped = false
    setCompilation(current => ({ ...current, key: compileKey, pending: true, diagnostics: [] }))
    const timer = window.setTimeout(async () => {
      try {
        const request = editor.source === null ? { filtersJSON: draftJSON } : { source: editor.source, previousJSON: draftJSON }
        const response = await window.webkit.messageHandlers.radar.postMessage({ compileMarketFilters: request })
        if (stopped || epoch !== compileEpoch.current) return
        setCompilation(current => ({ ...current, ...response, key: compileKey, pending: false }))
        if (response.diagnostics.length === 0 && response.configJSON) {
          setLastValidJSON(response.configJSON)
          if (editor.source !== null) setFilterDraft(parseFilterConfig(response.configJSON))
        }
      } catch (cause) {
        if (!stopped && epoch === compileEpoch.current) setCompilation(current => ({ ...current, key: compileKey, pending: false, diagnostics: [cause instanceof Error ? cause.message : "Compilation failed."] }))
      }
    }, 150)
    return () => { stopped = true; window.clearTimeout(timer) }
    // Formula compilation replaces the visual draft. Its own source remains the input until a visual edit.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready, compileKey])
  useEffect(() => {
    if (!lastValidJSON) return
    let stopped = false
    let timer: number
    const epoch = ++previewEpoch.current
    const token = `${epoch}:${newRuleID()}`
    const refresh = async () => {
      try {
        const snapshot = await window.webkit.messageHandlers.radar.postMessage({ previewMarketFilters: { filtersJSON: lastValidJSON, token } })
        if (stopped || epoch !== previewEpoch.current) return
        if (previewResponseIsCurrent(snapshot, token, revision.current)) startTransition(() => {
          if (!acceptSnapshot(snapshot)) return
          setResults(current => keepSnapshotValue(current, snapshot.filterResults))
          setPreviewJSON(lastValidJSON)
          setHistory(current => keepSnapshotValue(current, snapshot.historyProgress))
          setStatus("Live")
        })
      } catch (cause) {
        if (stopped) return
        setStatus("Reconnecting")
        setError(cause instanceof Error ? cause.message : "Cannot preview native rules")
      }
      if (!stopped) timer = window.setTimeout(refresh, 2000)
    }
    void refresh()
    return () => { stopped = true; window.clearTimeout(timer) }
  }, [lastValidJSON])

  const matchedRows = useMemo(() => rows.filter(row => results[row.instId] === "true"), [rows, results])
  const searchedRows = useMemo(() => rows.filter(row => row.instId.toLowerCase().includes(query.trim().toLowerCase())), [rows, query])
  const visible = useMemo(() => searchedRows.filter(row => results[row.instId] === "true").sort((a, b) => compareMarketRows(a, b, sort, descending)), [searchedRows, results, sort, descending])
  const unknownCount = searchedRows.filter(row => results[row.instId] === "unknown").length
  const listOrder = useMemo(() => visible.map(row => row.instId), [visible])
  const turnoverOrder = useMemo(() => [...matchedRows].sort(compareMarketTurnover).map(row => row.instId), [matchedRows])
  const saveFilters = async (filters: FilterConfigV2) => {
    acceptSnapshot(await window.webkit.messageHandlers.radar.postMessage({ marketFiltersJSON: JSON.stringify(filters) }))
    setFilterDraft(null)
    setEditor(current => ({ ...current, source: null }))
  }
  const saveLibraryPreferences = async (preferences: FilterLibraryPreferences) => {
    const previous = libraryPreferences, epoch = ++librarySaveEpoch.current
    librarySavePending.current = true
    setLibraryPreferences(preferences)
    try {
      const snapshot = await window.webkit.messageHandlers.radar.postMessage({ filterLibraryPreferencesJSON: JSON.stringify(preferences) })
      if (epoch === librarySaveEpoch.current) { librarySavePending.current = false; acceptSnapshot(snapshot) }
    } catch (cause) {
      if (epoch === librarySaveEpoch.current) { librarySavePending.current = false; setLibraryPreferences(previous) }
      throw cause
    }
  }
  const saveFilterCombination = async (name: string, filters: FilterConfigV2) => {
    const snapshot = await window.webkit.messageHandlers.radar.postMessage({ saveMarketFilterCombination: { name, filtersJSON: JSON.stringify(filters) } })
    acceptSnapshot(snapshot)
    const saved = snapshot.marketFilterCombinations.find(combination => combination.name === name.trim())
    if (!saved) throw new Error("Cannot find the saved combination. Try again.")
    return saved
  }
  const selectFilterCombination = async (id: string) => { acceptSnapshot(await window.webkit.messageHandlers.radar.postMessage({ selectedMarketFilterCombinationID: id })) }
  const deleteFilterCombination = async (id: string) => { acceptSnapshot(await window.webkit.messageHandlers.radar.postMessage({ deleteMarketFilterCombination: id })) }
  const changeSort = (key: SortKey) => {
    if (sort === key) setDescending(!descending)
    else { setSort(key); setDescending(defaultSortDescending(key)) }
  }

  const saveSetting = (request: SettingRequest) => {
    void window.webkit.messageHandlers.radar.postMessage(request)
      .then(acceptSnapshot)
      .catch(cause => setError(cause instanceof Error ? cause.message : "Cannot save setting"))
  }

  const saveBackgroundOpacity = () => {
    const value = Number(backgroundOpacityDraft)
    if (!backgroundOpacityDraft.trim() || !Number.isFinite(value) || value < 0 || value > 1) {
      setBackgroundOpacityError("Enter a number from 0 to 1.")
      return
    }
    backgroundOpacityDraftDirty.current = false
    setBackgroundOpacityError("")
    setBackgroundOpacityDraft(String(value))
    if (value !== frostedBackgroundOpacity) saveSetting({ frostedBackgroundOpacity: value })
  }

  const header = (label: string, key: SortKey, content: ReactNode = label, description?: string) => {
    const SortIcon = sort !== key ? ArrowDownUp : descending ? ArrowDown : ArrowUp
    return <Button variant="ghost" size="xs" className={cn("h-auto min-h-(--control-height-xs) gap-1", key === "turnover24hUSDT" && "border-l-0 pl-0")} onClick={() => changeSort(key)} aria-label={`Sort by ${label}`} aria-pressed={sort === key} title={description}>
      {content}<SortIcon data-icon="inline-end" aria-hidden="true" />
    </Button>
  }

  if (selected) return <MarketChart instId={selected} listOrder={listOrder} turnoverOrder={turnoverOrder} onSelect={setSelected} onBack={() => setSelected(null)} />

  return (
    <MarketListViewport>
    <main className="flex min-h-[inherit] flex-col">
      <header className="flex items-center gap-3 border-b px-4 py-3 whitespace-nowrap">
        <h1 className="text-base font-semibold tracking-tight">Perpetual Radar</h1>
        <span className="text-xs text-muted-foreground">OKX · USDT swaps · 1h</span>
        <span className="text-xs tabular-nums text-muted-foreground">{visible.length} / {rows.length} markets</span>
        <Popover onOpenChange={open => { if (!open && backgroundOpacityDraftDirty.current) saveBackgroundOpacity() }}>
          <PopoverTrigger asChild><Button variant="outline"><Settings2 data-icon="inline-start" aria-hidden="true" />Settings</Button></PopoverTrigger>
          <PopoverContent align="end">
            <PopoverHeader><PopoverTitle>Settings</PopoverTitle><PopoverDescription>Customize the window background.</PopoverDescription></PopoverHeader>
            <FieldGroup>
              <Field orientation="horizontal">
                <FieldLabel htmlFor="frosted-background">Frosted background</FieldLabel>
                <Toggle id="frosted-background" variant="outline" pressed={frostedBackgroundEnabled} onPressedChange={enabled => saveSetting({ frostedBackgroundEnabled: enabled })} aria-label="Enable frosted background">{frostedBackgroundEnabled ? "On" : "Off"}</Toggle>
              </Field>
              <Field data-invalid={Boolean(backgroundOpacityError)} data-disabled={!frostedBackgroundEnabled}>
                <FieldLabel htmlFor="background-opacity">Background opacity</FieldLabel>
                <Input id="background-opacity" name="frostedBackgroundOpacity" type="number" min="0" max="1" step="0.05" inputMode="decimal" autoComplete="off" disabled={!frostedBackgroundEnabled} aria-describedby={backgroundOpacityError ? "background-opacity-description background-opacity-error" : "background-opacity-description"} aria-invalid={Boolean(backgroundOpacityError)} value={backgroundOpacityDraft} onChange={event => { backgroundOpacityDraftDirty.current = true; setBackgroundOpacityDraft(event.target.value); setBackgroundOpacityError("") }} onBlur={saveBackgroundOpacity} onKeyDown={event => { if (event.key === "Enter") event.currentTarget.blur() }} />
                <FieldDescription id="background-opacity-description">0 reveals more of the blurred desktop; 1 is solid. Text and charts stay opaque.</FieldDescription>
                {backgroundOpacityError && <FieldError id="background-opacity-error" role="alert">{backgroundOpacityError}</FieldError>}
              </Field>
            </FieldGroup>
          </PopoverContent>
        </Popover>
        <Button variant="outline" size="sm" onClick={() => setExplanationOpen(true)}><ScanSearch data-icon="inline-start" aria-hidden="true" />Explain markets</Button>
        <div className="relative ml-auto w-64 shrink-0">
          <Search className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" aria-hidden="true" />
          <Input aria-label="Search contracts" placeholder="Search contracts" value={query} onChange={event => setQuery(event.target.value)} className="pl-8" />
        </div>
        <Badge variant={status === "Live" ? "secondary" : "outline"} aria-live="polite">
          <Radio aria-hidden="true" />{status}
        </Badge>
        <span className="text-xs text-muted-foreground">{updatedAt ? `Updated ${new Date(updatedAt).toLocaleTimeString("en-US")}` : "Waiting for data"}</span>
      </header>
      <MarketFilters filters={listFilters} draft={filterDraft} editor={editor} onEditorChange={setEditor} onDraftChange={setFilterDraft} onApply={saveFilters} combinations={filterCombinations} combinationId={filterCombinationId} onSelectCombination={selectFilterCombination} onSaveCombination={saveFilterCombination} onDeleteCombination={deleteFilterCombination} metrics={metrics} functions={functions} templates={templates} preferences={libraryPreferences} onPreferences={saveLibraryPreferences} rows={rows} results={results} previewJSON={previewJSON} revision={revision.current} onExplain={explainMarket} units={compilation.units ?? {}} expressions={editorExpressions} formula={compilation.formula ?? "true"} diagnostics={compilation.diagnostics} valid={valid} compiling={compiling} requiredHours={compilation.requiredHours ?? 0} matches={visible.length} total={searchedRows.length} unknown={unknownCount} previewPending={lastValidJSON !== previewJSON} history={history} />
      <FilterExplanation open={explanationOpen} onOpenChange={setExplanationOpen} instId={explainingId} onSelect={setExplainingId} rows={rows} results={results} filtersJSON={previewJSON} revision={revision.current} metrics={metrics} expressions={editorExpressions} units={compilation.units ?? {}} templates={templates} />
      {error && <p role="alert" className="border-b px-4 py-2 text-sm text-destructive">{error}</p>}
      <section aria-label="Perpetual swap markets" className="flex-1">
        <Table className="table-auto" data-market-count={visible.length} aria-rowcount={visible.length + 1}>
          <TableHeader>
            <TableRow>
              <TableHead className="py-1.5 pl-[var(--market-table-leading-inset)] text-left" aria-sort={sort === "turnover24hUSDT" ? descending ? "descending" : "ascending" : "none"}>
                <div className="flex flex-col items-start">
                  {header("Turnover", "turnover24hUSDT")}
                </div>
              </TableHead>
              <TableHead className="text-center" aria-sort={sort === "opportunity" ? descending ? "descending" : "ascending" : "none"}>{header("Opportunity", "opportunity", undefined, OPPORTUNITY_DESCRIPTION)}</TableHead>
              <TableHead className="py-1.5 text-center" aria-sort={["highBreakout", "highBreakoutPriorAge", "lowBreakdown", "lowBreakdownPriorAge"].includes(sort) ? descending ? "descending" : "ascending" : "none"}>
                <div className="mx-auto grid w-max grid-cols-[max-content_max-content] items-center gap-x-3">
                  {header("High breakout · 48h", "highBreakout", undefined, BREAK_DESCRIPTION)}
                  {header("High age", "highBreakoutPriorAge", undefined, "Sort by the previous high's age at the breakout, longest first. Tied highs use the most recent occurrence.")}
                  {header("Low breakdown · 48h", "lowBreakdown", undefined, BREAK_DESCRIPTION)}
                  {header("Low age", "lowBreakdownPriorAge", undefined, "Sort by the previous low's age at the breakdown, longest first. Tied lows use the most recent occurrence.")}
                </div>
              </TableHead>
              <TableHead className="text-center" aria-sort={sort === "takerRatio" ? descending ? "descending" : "ascending" : "none"}>{header("Taker buy-sell ratio", "takerRatio", math(String.raw`\frac{Buy_t-Sell_t}{Buy_t+Sell_t}\times100\%`))}</TableHead>
              <TableHead className="text-center" aria-sort={sort === "oiChange" ? descending ? "descending" : "ascending" : "none"}>{header("OI Relative Change", "oiChange", undefined, `Hourly OI relative change. ${PERCENT_CHANGE_DESCRIPTION}`)}</TableHead>
              <TableHead className="py-1.5 text-center" aria-sort={sort === "roc" || sort === "maroc" ? descending ? "descending" : "ascending" : "none"}>
                <div className="flex flex-col items-center">
                  {header(`ROC ${ROC_PERIOD}`, "roc", <span>ROC<sub>{ROC_PERIOD}</sub> (%)</span>, `${ROC_PERIOD}-hour price change. ${PERCENT_CHANGE_DESCRIPTION}`)}
                  {header(`MAROC ${MAROC_PERIOD}`, "maroc", <span>MAROC<sub>{MAROC_PERIOD}</sub> (%)</span>, `Mean of the latest ${MAROC_PERIOD} hourly ROC readings, as a percentage.`)}
                </div>
              </TableHead>
              <TableHead className="py-1.5 text-center" aria-sort={sort.startsWith("rsi") ? descending ? "descending" : "ascending" : "none"}>
                <div className="flex flex-col items-center">
                  {RSI_PERIODS.map(period => <Fragment key={period}>{header(`RSI ${period}`, `rsi${period}`, <span>RSI<sub>{period}</sub></span>)}</Fragment>)}
                </div>
              </TableHead>
              <TableHead className="py-1.5 text-center" aria-sort={sort.startsWith("logBB") ? descending ? "descending" : "ascending" : "none"}>
                <div className="flex flex-col items-center">
                  {header("Log BB · Live", "logBBAboveBand", undefined, LOG_BB_DESCRIPTION)}
                  {header("Bandwidth expansion", "logBBExpansion", undefined, BANDWIDTH_EXPANSION_DESCRIPTION)}
                </div>
              </TableHead>
            </TableRow>
          </TableHeader>
          {visible.length ? <MarketRows rows={visible} onSelect={setSelected} onExplain={explainMarket} /> : <TableBody><TableRow><TableCell colSpan={8} className="py-12">
              <Empty>
                <EmptyHeader><EmptyTitle>{rows.length ? "No matching contracts" : "Waiting for contracts"}</EmptyTitle><EmptyDescription>{rows.length ? "Adjust the rules or search. Explain markets includes unmatched and unknown contracts." : "OKX hourly data is loading. All universe restrictions are visible in Filters."}</EmptyDescription></EmptyHeader>
                <EmptyContent>
                  {filterDraft !== null && <Button variant="outline" size="sm" onClick={() => { setFilterDraft(null); setEditor(current => ({ ...current, source: null })) }}>Discard preview</Button>}
                  {listFilters.root.children.length > 0 && <Button variant="outline" size="sm" onClick={() => { void saveFilters(emptyFilterConfig()).catch(cause => setError(cause instanceof Error ? cause.message : "Cannot clear filters")) }}>Clear all rules</Button>}
                  {query && <Button variant="ghost" size="sm" onClick={() => setQuery("")}>Clear search</Button>}
                </EmptyContent>
              </Empty>
            </TableCell></TableRow></TableBody>}
        </Table>
      </section>
    </main>
    </MarketListViewport>
  )
}

export default App
