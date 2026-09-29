function makeChartAxis(min: number, max: number, intervals: number, maxLabels: number) {
  const span = max - min || Math.max(Math.abs(max) * 0.01, 1e-10)
  if (min === max) { min -= span / 2; max += span / 2 }
  const rawStep = span / intervals
  const power = 10 ** Math.floor(Math.log10(rawStep))
  const normalized = rawStep / power
  let step = (normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10) * power
  const round = (value: number) => Number(value.toPrecision(12))
  let lower = round(Math.floor(min / step) * step)
  let upper = round(Math.max(Math.ceil(max / step) * step, lower + step))
  while (Math.round((upper - lower) / step) + 1 > maxLabels) {
    const nextPower = 10 ** Math.floor(Math.log10(step))
    const multiple = step / nextPower
    step = (multiple < 1.5 ? 2 : multiple < 3.5 ? 5 : 10) * nextPower
    lower = round(Math.floor(min / step) * step)
    upper = round(Math.max(Math.ceil(max / step) * step, lower + step))
  }
  const ticks = Array.from({ length: Math.round((upper - lower) / step) + 1 }, (_, index) => round(lower + index * step))
  return { min: lower, max: upper, step, ticks, decimals: Math.max(0, Math.min(20, -Math.floor(Math.log10(step)))) }
}

export function chartAxis(min: number, max: number, intervals = 6) {
  return makeChartAxis(min, max, intervals, Infinity)
}

export function chartAxisForLabels(min: number, max: number, maxLabels: number) {
  const limit = Math.max(2, Math.floor(maxLabels))
  return makeChartAxis(min, max, limit - 1, limit)
}
