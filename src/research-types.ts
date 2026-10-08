import type { ChartResponse } from '@/MarketChart'
import type { FilterCombination, FilterConfigV2, FilterMetric } from '@/rule-engine'
import type { ExpressionTemplate } from '@/filter-expression'

export const RESEARCH_HORIZONS = [1, 3, 6, 12, 24, 48] as const
export const RESEARCH_HOUR = 3_600_000
export type ResearchInputs = { filters: FilterConfigV2; combinations: FilterCombination[]; metrics: FilterMetric[]; templates: ExpressionTemplate[]; functions?: string[] }
export type StudyRule = { name: string; filtersJSON: string }
export type StudySpec = {
  name: string; kind: 'filter' | 'score' | 'comparison' | 'long'; rules: StudyRule[]; instruments: string[]
  from: number | null; through: number; direction: 'auto' | 'Long' | 'Short'; sampling: 'entries' | 'hourly'
  costs: { entryFeeBps: number; exitFeeBps: number; slippageBps: number } | null
}
export type ResearchInstrument = { id: string; listedAt?: number; delistedAt?: number; verified: boolean; contractValue?: number; source: string; observedAt: number }
export type ResearchSource = { id: string; instrument: string; kind: string; from: number; through: number; filename: string; url: string; sizeBytes?: number; archive: boolean; module?: number; cached: boolean; rawHash?: string }
export type DataPlan = { id: string; spec: StudySpec; instruments: ResearchInstrument[]; from: number; through: number; warmupHours: number; sources: ResearchSource[]; coverage: ResearchCoverage[]; cachedHours: number; requestedHours: number; warnings: string[]; unknownInstruments: string[] }
export type ResearchStudy = { id: string; spec: StudySpec; planID: string; manifestID?: string; createdAt: number; phase: string }
export type ResearchJob = { id: string; phase: string; completed: number; total: number; message: string; error: string; resultID?: string }
export type ResearchOutcome = { hours: number; gross?: number; net?: number; mfe?: number; mae?: number; reason?: string; netReason?: string }
export type ResearchEvent = { id: string; studyID: string; ruleIndex: number; instrument: string; timestamp: number; direction: string; entry: string; score?: number; scoreComplete: boolean; status: string; setup?: string; split: string; outcomes: ResearchOutcome[]; traceJSON: string; opportunityJSON: string; sources: string[] }
export type ResearchSummary = {
  group: string; ruleIndex: number; hours: number; count: number; excluded: number; netCount: number
  mean?: number; median?: number; winRate?: number; netMean?: number; netMedian?: number; netWinRate?: number
  mfe?: number; mae?: number; baseline?: number; excess?: number; intervalLow?: number; intervalHigh?: number; netIntervalLow?: number; netIntervalHigh?: number
}
export type StudyReport = { studyID: string; manifestID: string; spec: StudySpec; summaries: ResearchSummary[]; evaluated: number; unknown: number; directionless: number; commonPool: number; uncertain: number; baseline: number; warnings: string[]; completedAt: number; long?: LongStudyReport }
export type ResearchCoverage = { instrument: string; kind: string; available: number; expected: number; first?: number; last?: number; gaps: { from: number; through: number }[] }
export type DataManifest = { id: string; digest: string; from: number; through: number; parser: string; engine: string; sourceRevision: string; instruments: ResearchInstrument[]; unknownInstruments: string[]; warnings: string[]; coverage: ResearchCoverage[]; sources: ResearchSource[] }
export type ResearchChartData = ChartResponse & { endHour: number; oldestHour?: number; latestHour?: number; signalHour: number; manifestID: string }
export type ResearchRequest = { action: string; spec?: StudySpec; refresh?: boolean; planID?: string; studyID?: string; eventID?: string; offset?: number; endHour?: number; kind?: string }
export type ResearchResponse = { jobID?: string; job?: ResearchJob | null; studies?: ResearchStudy[]; plan?: DataPlan; estimatedBytes?: number; study?: ResearchStudy; report?: StudyReport | null; manifest?: DataManifest | null; events?: ResearchEvent[]; count?: number; trades?: ResearchLongTrade[]; chart?: ResearchChartData; cacheDirectory?: string; cachedRows?: number; rawFiles?: number; bytesRemoved?: number; ok?: boolean; cancelled?: boolean }
export const requestResearch = (request: ResearchRequest) => window.webkit.messageHandlers.radar.postMessage({ research: request })
export const researchPercent = (value: number | null | undefined) => value == null ? '—' : new Intl.NumberFormat('en-US', { style: 'percent', maximumFractionDigits: 3 }).format(value)
export const researchTime = (timestamp: number) => new Date(timestamp).toLocaleString('en-US', { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false, timeZone: 'UTC', timeZoneName: 'short' })
export const researchSize = (bytes: number) => new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(bytes / (bytes >= 1_000_000_000 ? 1_000_000_000 : 1_000_000)) + (bytes >= 1_000_000_000 ? ' GB' : ' MB')
export function researchDateRange(from: string, through: string, now = Date.now()): { from: number | null; through: number } {
  const start = from ? Date.parse(from + 'T00:00:00Z') : null
  const end = through ? Date.parse(through + 'T00:00:00Z') + 24 * RESEARCH_HOUR : now
  if (start !== null && !Number.isFinite(start) || !Number.isFinite(end)) throw new Error('Choose valid dates.')
  const last = Math.min(end, Math.floor(now / RESEARCH_HOUR) * RESEARCH_HOUR)
  if (start !== null && start >= last) throw new Error('The start date must precede the last completed hour.')
  return { from: start, through: last }
}

export type ResearchLongTrade = { id: string; studyID: string; instrument: string; entryTime: number; entryPrice?: number; exitTime?: number; exitPrice?: number; status: string; uncertain: boolean; unknownHours: number; crossesSplit: boolean; entryEvent: ResearchEvent; exitEvent?: ResearchEvent; outcome: ResearchOutcome }
export type LongStudyReport = { closed: number; open: number; incomplete: number; uncertain: number; grossProfit?: number; netProfit?: number; profitFactor?: number; averageHours?: number }
