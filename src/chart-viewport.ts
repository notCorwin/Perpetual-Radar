const hour = 3_600_000

// null means the right edge follows the latest candle.
export function scrollChartEnd(endHour: number | null, latestHour: number, steps: number, oldestCachedHour = 0): number | null {
  const earliestEnd = Math.min(latestHour, oldestCachedHour + 95 * hour)
  const next = Math.max(earliestEnd, Math.min(latestHour, (endHour ?? latestHour) + steps * hour))
  return next >= latestHour ? null : next
}

export function visibleChartBars<T extends { hour: number }>(bars: T[], endHour: number): T[] {
  const firstHour = endHour - 95 * hour
  return bars.filter(bar => bar.hour >= firstHour && bar.hour <= endHour)
}
