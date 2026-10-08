import type { FilterTruth, NativeMarketRow, FilterLibraryPreferences } from '@/rule-engine'

export type LongStrategy = { id: string; name: string; entryJSON: string; exitJSON: string; revision: number; updatedAt: number }
export type LongPosition = { id: string; strategyID: string; instrument: string; enteredAt: number; entryPrice: number; strategy: LongStrategy; exitedAt?: number; exitPrice?: number; exitStrategy?: LongStrategy }
export type LongDecisionRow = { instrument: string; hour: number; entry: FilterTruth; exit: FilterTruth; action: 'Wait' | 'Enter Long' | 'Hold Long' | 'Exit Long' | 'Unknown'; reason: string; price?: number; position?: LongPosition; entryTraceJSON?: string; exitTraceJSON?: string; btcExit?: boolean }
export type LongRequest = { action: string; strategyID?: string; strategy?: LongStrategy; instrument?: string; price?: number; timestamp?: number; positionID?: string; forming?: boolean }
export type LongResponse = { strategies: LongStrategy[]; positions: LongPosition[]; selectedID: string; saved?: LongStrategy; paused: boolean; decisions?: LongDecisionRow[]; rows?: NativeMarketRow[]; revision?: number; preferences?: FilterLibraryPreferences; historyProgress?: { pending: number; completed: number; error: string } }
export const requestLong = (request: LongRequest) => window.webkit.messageHandlers.radar.postMessage({ longDecision: request })
export const longPrice = (value: number | null | undefined) => value == null ? '—' : new Intl.NumberFormat('en-US', { maximumSignificantDigits: 8 }).format(value)
export const longReturn = (price: number | null | undefined, entry: number) => price == null ? null : price / entry - 1
export function longStudyRules(strategy: LongStrategy) {
  return [{ name: strategy.name + ' · Entry', filtersJSON: strategy.entryJSON }, { name: strategy.name + ' · Exit', filtersJSON: strategy.exitJSON }]
}
