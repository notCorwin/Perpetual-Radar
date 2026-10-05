import type { NativeMarketRow } from "./rule-engine.ts"

const rowSignatures = new WeakMap<NativeMarketRow, string>()
function signature(row: NativeMarketRow): string {
  let value = rowSignatures.get(row)
  if (value === undefined) { value = JSON.stringify(row); rowSignatures.set(row, value) }
  return value
}

// Bridge replies contain fresh objects, even when the native cache is unchanged.
// Preserve row identities so typing and menu state do not redraw every contract.
export function reconcileMarketRows(previous: NativeMarketRow[], incoming: NativeMarketRow[]): NativeMarketRow[] {
  const byID = new Map(previous.map(row => [row.instId, row]))
  const next = incoming.map(row => {
    const old = byID.get(row.instId)
    return old && signature(old) === signature(row) ? old : row
  })
  return previous.length === next.length && next.every((row, index) => row === previous[index]) ? previous : next
}

export function keepSnapshotValue<T>(previous: T, incoming: T): T {
  return JSON.stringify(previous) === JSON.stringify(incoming) ? previous : incoming
}
