export function chartAxis(min: number, max: number, intervals = 6) {
  const magnitude = Math.max(Math.abs(min), Math.abs(max)) || 1
  const span = max - min || magnitude / 10
  const step = Math.max(
    10 ** Math.ceil(Math.log10(span / intervals)),
    10 ** (Math.floor(Math.log10(magnitude)) - 1),
  )
  const round = (value: number) => Number(value.toPrecision(12))
  const lower = round(Math.floor(min / step) * step)
  const upper = round(Math.max(Math.ceil(max / step) * step, lower + step))
  const ticks = Array.from({ length: Math.round((upper - lower) / step) + 1 }, (_, index) => round(lower + index * step))
  return { min: lower, max: upper, step, ticks, decimals: Math.max(0, Math.min(20, -Math.floor(Math.log10(step)))) }
}

export function visibleTicks(ticks: number[], maxLabels: number) {
  if (ticks.length <= maxLabels) return ticks
  const stride = Math.ceil((ticks.length - 1) / (maxLabels - 1))
  return ticks.filter((_, index) => index % stride === 0 || index === ticks.length - 1)
}
