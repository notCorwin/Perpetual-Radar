import katex from 'katex'
import 'katex/dist/katex.min.css'
const cache = new Map<string, string>()
export function MathHeading({ formula, label }: { formula: string; label: string }) {
  if (!cache.has(formula)) cache.set(formula, katex.renderToString(formula, { throwOnError: false, output: 'htmlAndMathml' }))
  return <span title={label} aria-label={label} dangerouslySetInnerHTML={{ __html: cache.get(formula)! }} />
}
