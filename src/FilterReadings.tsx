import { valueLabel } from '@/filter-builder'
import type { ExpressionTemplate } from '@/filter-expression'
import type { EditorExpression, FilterMetric } from '@/rule-engine'

export type ReadingContext = { metrics: FilterMetric[]; expressions: Record<string, EditorExpression>; units: Record<string, string>; templates: ExpressionTemplate[] }
export function FilterReadings({ readings, metrics, expressions, units, templates }: ReadingContext & { readings: Record<string, string> }) {
  return <dl className="grid grid-cols-[minmax(0,1fr)_minmax(0,1fr)] gap-x-3 gap-y-1 text-xs tabular-nums">{Object.entries(readings).map(([name, reading]) => {
    const source = name.replace(/^(Previous |Maximum: )/, '')
    const unit = expressions[source]?.unit ?? units[source] ?? metrics.find(metric => metric.key.toLowerCase() === source.toLowerCase())?.unit
    return <div key={name} className="contents"><dt className="break-words text-muted-foreground">{valueLabel(name, metrics, expressions, templates)}</dt><dd className="break-words text-right">{reading}{!reading.startsWith('Unknown:') && unit && !['category', 'constant', 'text', 'source unit'].includes(unit) ? ` ${unit}` : ''}</dd></div>
  })}</dl>
}
