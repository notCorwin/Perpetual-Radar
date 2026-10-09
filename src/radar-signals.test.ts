import assert from 'node:assert/strict'
import { test } from 'node:test'
import { radarSignals, signalHasConflict, signalIsUnknown, signalMatches } from './radar-signals.ts'
import type { SuiteReading } from './suite-types.ts'

const reading = (instrument: string, changes: Partial<SuiteReading> = {}): SuiteReading => ({ strategyID: 'shared', revision: 2, instrument, hour: 3_600_000, provisional: false, universe: 'true', phases: { bullishSetup: { result: 'true', hour: 3_600_000 }, bearishReversal: { result: 'false', hour: 3_600_000 } }, conflict: false, action: 'Enter Long', reason: 'Setup matches', ...changes })

test('both directional lanes capture closed and forming matches against their own Universe', () => {
  const confirmed = [reading('long'), reading('short', { phases: { bearishReversal: { result: 'true', hour: 3_600_000 } } }), reading('forming', { universe: 'false' }), reading('blocked')]
  const provisional = [reading('forming', { provisional: true }), reading('blocked', { provisional: true, universe: 'false', phases: { bearishReversal: { result: 'true', hour: 7_200_000 } } })]
  const signals = radarSignals(confirmed, provisional, 'shared', 2)
  assert.deepEqual(signals.filter(s => signalMatches(s, 'bullishSetup')).map(s => s.instrument), ['long', 'forming', 'blocked'])
  assert.deepEqual(signals.filter(s => signalMatches(s, 'bearishReversal')).map(s => s.instrument), ['short'])
})

test('conflicts stay in both lanes and opposite signals in different hours are distinct', () => {
  const conflict = reading('conflict', { conflict: true, phases: { bullishSetup: { result: 'true', hour: 3_600_000 }, bearishReversal: { result: 'true', hour: 3_600_000 } } })
  const signals = radarSignals([conflict, reading('changing')], [reading('changing', { provisional: true, phases: { bearishReversal: { result: 'true', hour: 7_200_000 } } })], 'shared', 2)
  assert.equal(signals.filter(s => signalMatches(s, 'bullishSetup')).length, 2)
  assert.equal(signals.filter(s => signalMatches(s, 'bearishReversal')).length, 2)
  assert.equal(signalHasConflict(signals[0]), true)
  assert.equal(signalHasConflict(signals[1]), false)
})

test('hour selection and revision checks prevent stale or unrelated strategies from leaking into the board', () => {
  const confirmed = [reading('closed'), reading('old', { revision: 1 }), reading('other', { strategyID: 'another' })]
  const provisional = [reading('live', { provisional: true })]
  assert.deepEqual(radarSignals(confirmed, provisional, 'shared', 2, 'confirmed').map(s => s.instrument), ['closed'])
  assert.deepEqual(radarSignals(confirmed, provisional, 'shared', 2, 'provisional').map(s => s.instrument), ['live'])
})

test('Unknown inputs do not become matches or conflict and held exits survive failed Universe', () => {
  const unknown = reading('unknown', { universe: 'unknown', conflict: true })
  const exit = reading('held', { universe: 'false', action: 'Exit Long', phases: { bullishExhaustion: { result: 'true', hour: 3_600_000 } } })
  const signals = radarSignals([unknown, exit], [], 'shared', 2)
  assert.equal(signalIsUnknown(signals[0]), true)
  assert.equal(signalHasConflict(signals[0]), false)
  assert.equal(signalMatches(signals[0], 'bullishSetup'), false)
  assert.equal(signals[1].confirmed?.action, 'Exit Long')
  assert.equal(signalMatches(signals[1], 'bullishSetup'), false)
})
