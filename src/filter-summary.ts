import { bodyPresentation, humanName, ruleSentence } from './filter-builder.ts'
import { expressionTemplates, type ExpressionTemplate } from './filter-expression.ts'
import { comparisons, parseFilterConfig, type EditorExpression, type FilterCombination, type FilterConfigV2, type FilterMetric, type NamedFormula, type RuleNode } from './rule-engine.ts'

// Native JSON sorts object keys and formula edits can replace rule identities.
// Match the stored configuration by its contents rather than its serialization.
export function filterConfigurationKey(config: FilterConfigV2): string {
  const value = (definition: NamedFormula) => [definition.name, definition.expression]
  const rule = (node: RuleNode): unknown[] => [node.kind, node.name, node.mode, node.left, node.comparison, node.right, node.upper, node.hours, node.minimum, node.gapHours, node.captures.map(value), node.children.map(rule)]
  return JSON.stringify([config.version, rule(config.root), config.definitions.map(value)])
}

export function filterConfigurationName(config: FilterConfigV2, combinations: FilterCombination[], preferredId: string): string {
  const key = filterConfigurationKey(config)
  const matches = (combination: FilterCombination) => {
    try { return filterConfigurationKey(parseFilterConfig(combination.filterConfigJSON ?? combination.filtersJSON)) === key }
    catch { return false }
  }
  const preferred = combinations.find(item => item.id === preferredId)
  const combination = preferred && matches(preferred) ? preferred : combinations.find(matches)
  return combination?.name ?? (!config.root.children.length && ['all', 'any'].includes(config.root.kind) ? 'All markets' : 'Custom filters')
}

export function filterRuleSummary(config: FilterConfigV2, metrics: FilterMetric[], expressions: Record<string, EditorExpression>, templates: ExpressionTemplate[] = expressionTemplates): string {
  const summarize = (node: RuleNode): string => {
    const child = () => node.children[0] ? summarize(node.children[0]) : 'No condition'
    let text: string
    switch (node.kind) {
      case 'all': case 'any':
        text = bodyPresentation(node) ? ruleSentence(node, metrics, expressions, templates)
          : !node.children.length ? 'All markets'
          : node.children.length === 1 ? child()
          : `(${node.children.map(summarize).join(node.kind === 'all' ? ' AND ' : ' OR ')})`
        break
      case 'not': text = `NOT (${child()})`; break
      case 'every': text = `${child()} · every hour for ${node.hours}h`; break
      case 'recent': text = `${child()} · at least once in ${node.hours}h`; break
      case 'count':
        text = `${child()} · ${node.comparison === 'between' ? `between ${node.minimum} and ${node.upper}` : `${comparisons.find(([key]) => key === node.comparison)?.[1] ?? node.comparison} ${node.minimum}`} times in ${node.hours}h`
        break
      case 'sequence': text = `${node.children.map(stage => `${humanName(stage.name || 'Stage')}: ${summarize(stage)}`).join(' → ')} within ${node.hours}h`; break
      default: text = ruleSentence(node, metrics, expressions, templates)
    }
    return node.mode === 'closed' ? `Closed (${text})` : text
  }
  return summarize(config.root)
}
