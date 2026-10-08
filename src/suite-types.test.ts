import assert from 'node:assert/strict'
import { test } from 'node:test'
import { defaultCapital, defaultExecution, SUITE_PHASES, suiteSpec, type StrategyProfile } from './suite-types.ts'
const profile = (): StrategyProfile => ({id:'strategy',mode:'radar',name:'Native phases',revision:2,updatedAt:1,execution:defaultExecution(),universeJSON:'universe',phaseRules:{bullishSetup:'setup',bullishExhaustion:'long exit',bearishReversal:'reversal',bearishExhaustion:'short exit'}})

test('study snapshots freeze strategy versions, execution and independent capital overrides',()=>{
  const p=profile(), capital=defaultCapital(), execution=defaultExecution()
  capital.overrides['BTC-USDT-SWAP']={...capital.defaults,allocation:0.5}
  const spec=suiteSpec([p],execution,capital)
  p.phaseRules.bullishSetup='changed';p.execution.opposite='reverse';execution.entry='matchWhileFlat';capital.overrides['BTC-USDT-SWAP'].allocation=1
  assert.equal(spec.strategySnapshots![0].id,'strategy@r2')
  assert.equal(spec.strategySnapshots![0].phaseRules.bullishSetup,'setup')
  assert.equal(spec.execution!.entry,'newPhaseEntry')
  assert.equal(spec.capital!.overrides['BTC-USDT-SWAP'].allocation,0.5)
  assert.deepEqual(spec.rules.map(r=>r.filtersJSON),['universe','setup','long exit','reversal','short exit'])
})
test('old and new versions of one strategy have distinct frozen identities and ordered phase rules',()=>{
  const current=profile(), old={...profile(),id:'strategy@r1',revision:1,name:'Native phases · r1'}
  const spec=suiteSpec([old,current])
  assert.deepEqual(spec.strategySnapshots!.map(p=>p.id),['strategy@r1','strategy@r2'])
  assert.equal(spec.rules.length,10)
  assert.deepEqual(SUITE_PHASES.map(p=>p.label),['Bullish Setup','Bullish Exhaustion','Bearish Reversal','Bearish Exhaustion'])
  assert.equal(spec.kind,'cycle');assert.equal(spec.capital!.defaults.initial,10_000)
  assert.equal(spec.capital!.defaults.maintenanceRate,null);assert.equal(spec.capital!.defaults.liquidationFeeBps,null)
})
test('saved execution defaults are retained and an empty selection is rejected',()=>{
  const p=profile();p.execution.opposite='reverse'
  assert.equal(suiteSpec([p]).execution!.opposite,'reverse')
  assert.throws(()=>suiteSpec([]),/Choose at least one/)
})
