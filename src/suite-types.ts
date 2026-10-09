import type { FilterTruth, NativeMarketRow, FilterEditorState } from '@/rule-engine'
import type { ResearchEvent, ResearchInputs, StudySpec } from '@/research-types'

export const SUITE_PHASES = [
  { key: 'bullishSetup', label: 'Bullish Setup', description: 'Checked while flat for Long entries and while Short for exits. Position readings are unavailable.' },
  { key: 'bullishExhaustion', label: 'Bullish Exhaustion', description: 'Checked while Long. Market conditions and Long entry price, return and holding time are available.' },
  { key: 'bearishReversal', label: 'Bearish Reversal', description: 'Checked while flat for Short entries and, according to the opposite policy, while Long for exits. Position readings are unavailable.' },
  { key: 'bearishExhaustion', label: 'Bearish Exhaustion', description: 'Checked while Short. Market conditions and Short entry price, return and holding time are available.' },
] as const
export type SuitePhase = typeof SUITE_PHASES[number]['key']
export type SuiteMode = 'radar' | 'research'
export const modeTitle = (mode: SuiteMode) => mode === 'radar' ? 'Perpetual Swap Radar' : 'Perpetual Swap Research'
export type SuiteExecution = { opposite: 'exitThenWait' | 'reverse' | 'dedicatedOnly'; entry: 'newPhaseEntry' | 'matchWhileFlat' }
export const defaultExecution = (): SuiteExecution => ({ opposite: 'exitThenWait', entry: 'newPhaseEntry' })
export type StrategyProfile = { id: string; mode: SuiteMode; name: string; universeJSON: string; phaseRules: Record<SuitePhase, string>; revision: number; updatedAt: number; execution: SuiteExecution }
export type SuitePosition = { id: string; strategyID: string; instrument: string; direction: 'Long' | 'Short'; enteredAt: number; entryPrice: number; strategy: StrategyProfile; exitedAt?: number; exitPrice?: number; exitStrategy?: StrategyProfile; priceReturn?: string }
export type SuiteReading = { strategyID: string; revision: number; universeTraceJSON?: string; instrument: string; hour: number; provisional: boolean; universe: FilterTruth; phases: Partial<Record<SuitePhase, { result: FilterTruth; hour: number; traceJSON?: string }>>; conflict: boolean; action: string; reason: string; price?: number; position?: SuitePosition; positionReturn?: string }
export type SuiteDraft = { profile: StrategyProfile | null; name: string; execution: SuiteExecution; rules: { json: string; source: string | null; nameDrafts: FilterEditorState['nameDrafts']; expressionDrafts: FilterEditorState['expressionDrafts']; lastValid: string | null }[] }
export type SuiteRequest = { draft?: SuiteDraft; mode: SuiteMode; action: string; profileID?: string; profile?: StrategyProfile; instrument?: string; direction?: string; price?: number; timestamp?: number; positionID?: string }
export type SuiteResponse = { draft?: SuiteDraft; profiles: StrategyProfile[]; positions: SuitePosition[]; selectedID: string; saved?: StrategyProfile; provisional?: SuiteReading[]; confirmed?: SuiteReading[]; paused?: boolean; rows?: NativeMarketRow[]; revision?: number; historyProgress?: { pending: number; completed: number; error: string } }
export const requestSuite = (request: SuiteRequest) => window.webkit.messageHandlers.radar.postMessage({ suite: request })
export const suiteRules = (profile: StrategyProfile) => [{ name: profile.name + ' · Universe', filtersJSON: profile.universeJSON }, ...SUITE_PHASES.map(phase => ({ name: profile.name + ' · ' + phase.label, filtersJSON: profile.phaseRules[phase.key] }))]
export type SuiteCapitalSettings = { initial: number; allocation: number; leverage: number; maintenanceRate: number | null; liquidationFeeBps: number | null }
export type SuiteCapital = { defaults: SuiteCapitalSettings; overrides: Record<string, SuiteCapitalSettings> }
export const defaultCapital = (): SuiteCapital => ({ defaults: { initial: 10_000, allocation: 1, leverage: 1, maintenanceRate: null, liquidationFeeBps: null }, overrides: {} })
export function suiteSpec(profiles: StrategyProfile[], execution = profiles[0]?.execution ?? defaultExecution(), capital = defaultCapital()): StudySpec {
  if (!profiles.length) throw new Error('Choose at least one complete strategy.')
  const frozen = profiles.map(source => { const p = structuredClone(source); return p.id.includes('@r') ? p : { ...p,id: p.id+'@r'+p.revision,name: p.name.slice(0,68)+' · r'+p.revision } })
  return { name: profiles[0].name + ' cycle study', kind: 'cycle', rules: frozen.flatMap(suiteRules), instruments: [], from: null, through: Math.floor(Date.now()/3_600_000)*3_600_000, direction: 'auto', sampling: 'entries', costs: null, strategySnapshots: frozen, execution: structuredClone(execution), capital: structuredClone(capital) }
}
export type SuiteTrade = { id: string; studyID: string; profileID: string; profileName: string; model: string; instrument: string; direction: string; entryTime: number; entryPrice: number; margin: number; quantity: number; exitTime?: number; exitPrice?: number; liquidationFrom?: number; liquidationThrough?: number; status: string; reason: string; uncertain: boolean; crossesSplit: boolean; profit?: number; returnValue?: number; priceReturn?: number; mfe: number; mae: number; mfeIncomplete: boolean; maeIncomplete: boolean; holdingHoursLow?: number; holdingHoursHigh?: number; fees: number; funding: number; entryEvent: ResearchEvent; exitEvent?: ResearchEvent }
export type SuiteAccount = { profileID: string; profileName: string; instrument: string; model: string; initial: number; endingEquity: number; returnValue: number; maxDrawdown?: number; observedDrawdown: number; status: string; reason?: string; openDirection?: string }
export type SuiteSummary = { profileID: string; profileName: string; model: string; instrument?: string; direction?: string; split?: string; count: number; excluded: number; open: number; incomplete: number; uncertain: number; crossSplit: number; purged: number; liquidations: number; winRate?: number; mean?: number; payoffRatio?: number; payoffInfinite: boolean; profitFactor?: number; profitFactorInfinite: boolean; profit?: number; averageHours?: number; averageHoursLow?: number; mfe?: number; mae?: number; intervalLow?: number; intervalHigh?: number }
export type SuiteStudyReport = { summaries: SuiteSummary[]; accounts: SuiteAccount[] }
export type SuiteCurvePoint = { timestamp: number; equity: number; drawdown: number; direction?: string; uncertain: boolean }
export type SuiteWorkspaceProps = { mode: SuiteMode; inputs: ResearchInputs; active: boolean; onBack: () => void; onResearch: (spec: StudySpec) => void; onSwitchMode: () => void; switchingMode: boolean }
