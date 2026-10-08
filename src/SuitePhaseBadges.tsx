import { Badge } from '@/components/ui/badge'
import { SUITE_PHASES, type SuiteReading } from '@/suite-types'
import { researchTime } from '@/research-types'

export function SuitePhaseBadges({ confirmed, provisional }: { confirmed?: SuiteReading; provisional?: SuiteReading }) {
  const confirmedPhases = SUITE_PHASES.filter(p => confirmed?.phases[p.key]?.result === 'true')
  const formingPhases = SUITE_PHASES.filter(p => provisional?.phases[p.key]?.result === 'true')
  return <div className="flex flex-col items-start gap-1" aria-label="Hourly market phases">
    {confirmed?.conflict && <Badge variant="destructive">Conflict</Badge>}
    {provisional?.conflict && <Badge variant="destructive">Conflict · Provisional</Badge>}
    {confirmedPhases.map(p => <Badge key={p.key} variant="secondary" title={researchTime((confirmed?.hour ?? 0)+3_600_000)}>{p.key === 'bullishSetup' ? '↑ ' : p.key === 'bearishReversal' ? '↓ ' : ''}{p.label} · Confirmed</Badge>)}
    {formingPhases.map(p => <Badge key={p.key} variant="outline">{p.label} · Provisional</Badge>)}
    {!confirmedPhases.length && !formingPhases.length && <span className="text-xs text-muted-foreground">{!confirmed ? 'No active strategy' : Object.values(confirmed.phases).some(p => p?.result === 'unknown') ? 'Unknown inputs' : 'No phase match'}</span>}
  </div>
}
