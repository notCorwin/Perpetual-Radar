export type SortKey = "instId" | "turnover24hUSDT" | "high48" | "low48" | "takerRatio" | "volumeLog" | "oiLog" | "roc" | "maroc" | "rsi6" | "rsi12" | "rsi24" | "bollUpper" | "bollMiddle" | "bollLower"

export type SortableRow = {
  instId: string
  turnover24hUSDT: number
  high48: number | null
  low48: number | null
  takerRatio: number | null
  volumeLog: number | null
  oiLog: number | null
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

export function wrappedMarket(order: string[], index: number): string | undefined {
  return order.length ? order[((index % order.length) + order.length) % order.length] : undefined
}

export function chartNavigationTarget(order: string[], currentId: string, key: "ArrowUp" | "ArrowDown" | "ArrowLeft" | "ArrowRight"): string | undefined {
  const index = order.indexOf(currentId)
  if (index < 0) return undefined
  if (key === "ArrowLeft") return order[0]
  if (key === "ArrowRight") return order[order.length - 1]
  return wrappedMarket(order, index + (key === "ArrowUp" ? -1 : 1))
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
  return compareMarketTurnover(a, b)
}
