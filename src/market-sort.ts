export type SortKey = "instId" | "momentum" | "high48" | "low48" | "takerRatio" | "volumeLog" | "roc" | "maroc" | "rsi6" | "rsi12" | "rsi24" | "bollUpper" | "bollMiddle" | "bollLower"

export type SortableRow = {
  instId: string
  momentum: number | null
  oiUsd: number | null
  high48: number | null
  low48: number | null
  oiLog: number | null
  oiSignal: "Stable" | "Building" | "Peaking" | "Unwinding" | null
  takerRatio: number | null
  volumeLog: number | null
  roc: number | null
  maroc: number | null
  rsi6: number | null
  rsi12: number | null
  rsi24: number | null
  bollUpper: number | null
  bollMiddle: number | null
  bollLower: number | null
}

export function compareMarketTurnover(a: { instId: string; turnover24hUSDT: number }, b: { instId: string; turnover24hUSDT: number }): number {
  return b.turnover24hUSDT - a.turnover24hUSDT || a.instId.localeCompare(b.instId)
}

export function marketTrend(row: { price: number | null; vwap14: number | null; ema200: number | null; ema200Slope: number | null; bollMiddle: number | null; takerRatio: number | null; roc: number | null; maroc: number | null }): "LONG" | "SHORT" | "TRAP" | null {
  const { price, vwap14, ema200, ema200Slope, bollMiddle, takerRatio, roc, maroc } = row
  if ([price, vwap14, ema200, ema200Slope, bollMiddle, takerRatio, roc, maroc].some(value => value === null || !Number.isFinite(value))) return null
  const signals = [price! - vwap14!, price! - ema200!, price! - bollMiddle!, ema200Slope!, takerRatio!, roc!, maroc!]
  return signals.every(value => value > 0) ? "LONG" : signals.every(value => value < 0) ? "SHORT" : "TRAP"
}

export function momentumScores(rows: Pick<SortableRow, "roc" | "maroc" | "oiLog" | "oiSignal" | "volumeLog">[]): (number | null)[] {
  const ready = rows.filter((row): row is { roc: number; maroc: number; oiLog: number; oiSignal: NonNullable<SortableRow["oiSignal"]>; volumeLog: number } =>
    row.roc !== null && row.maroc !== null && row.oiLog !== null && row.oiSignal !== null && row.volumeLog !== null &&
    Number.isFinite(row.roc) && Number.isFinite(row.maroc) && Number.isFinite(row.oiLog) && Number.isFinite(row.volumeLog))
  const ranks = (values: number[]) => {
    const positive = values.filter(value => value > 0).sort((a, b) => a - b)
    return new Map(positive.map((value, index) => [value, (index + 1) * 100 / positive.length]))
  }
  const rocRanks = ranks(ready.map(row => Math.abs(row.roc)))
  const marocRanks = ranks(ready.map(row => Math.abs(row.maroc)))
  const oiRanks = ranks(ready.filter(row => row.oiSignal === "Building").map(row => row.oiLog))
  const volumeRanks = ranks(ready.map(row => row.volumeLog))
  return rows.map(row => {
    if (row.roc === null || row.maroc === null || row.oiLog === null || row.oiSignal === null || row.volumeLog === null ||
      !Number.isFinite(row.roc) || !Number.isFinite(row.maroc) || !Number.isFinite(row.oiLog) || !Number.isFinite(row.volumeLog)) return null
    const priceMomentum = ((rocRanks.get(Math.abs(row.roc)) ?? 0) + (marocRanks.get(Math.abs(row.maroc)) ?? 0)) / 2
    return (priceMomentum + (row.oiSignal === "Building" ? oiRanks.get(row.oiLog) ?? 0 : 0) + (volumeRanks.get(row.volumeLog) ?? 0)) / 3
  })
}

export function compareMarketRows(a: SortableRow, b: SortableRow, key: SortKey, descending: boolean): number {
  if (key === "instId") return (descending ? -1 : 1) * a.instId.localeCompare(b.instId)

  const left = a[key]
  const right = b[key]
  if (left === null || right === null) {
    if (left !== right) return left === null ? 1 : -1
  } else {
    const difference = descending ? right - left : left - right
    if (difference) return difference
  }
  return (b.oiUsd ?? 0) - (a.oiUsd ?? 0) || a.instId.localeCompare(b.instId)
}
