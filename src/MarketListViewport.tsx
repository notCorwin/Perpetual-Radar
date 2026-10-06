import { useLayoutEffect, useRef, type ReactNode } from "react"

export function MarketListViewport({ children }: { children: ReactNode }) {
  const viewportRef = useRef<HTMLDivElement>(null)
  const contentRef = useRef<HTMLDivElement>(null)

  useLayoutEffect(() => {
    const viewport = viewportRef.current
    const content = contentRef.current
    if (!viewport || !content) return
    const table = content.querySelector("table")
    let designWidth = Number.parseFloat(getComputedStyle(viewport).getPropertyValue("--market-list-design-width"))
    let scale = 1
    let frame: number | null = null
    let stopped = false
    const fit = () => {
      frame = null
      const available = viewport.getBoundingClientRect().width
      if (!available) return
      const width = Math.max(available, designWidth)
      content.style.width = `${width}px`
      const required = table ? table.getBoundingClientRect().width / scale : width
      if (required > width + 0.5) {
        // Retain enough room for the widest loaded row, including while filtering the list.
        designWidth = Math.ceil(required)
        content.style.width = `${designWidth}px`
      }
      scale = Math.min(1, available / designWidth)
      // Portaled dialogs retain the same design layout and typography scale.
      const root = document.documentElement.style
      root.setProperty('--market-list-scale', String(scale))
      root.setProperty('--market-list-layout-width', `${window.innerWidth / scale}px`)
      root.setProperty('--market-list-layout-height', `${window.innerHeight / scale}px`)
      content.style.minHeight = `${window.innerHeight / scale}px`
      // Keep table and KaTeX layout at their original size; scale only the finished rendering.
      content.style.transform = `scale(${scale})`
      viewport.style.height = `${content.getBoundingClientRect().height}px`
    }
    const schedule = () => {
      if (!stopped && frame === null) frame = window.requestAnimationFrame(fit)
    }
    const observer = new ResizeObserver(schedule)
    observer.observe(viewport)
    observer.observe(content)
    if (table) observer.observe(table)
    window.addEventListener("resize", schedule)
    fit()
    void document.fonts.ready.then(schedule)
    return () => {
      stopped = true
      observer.disconnect()
      window.removeEventListener("resize", schedule)
      if (frame !== null) window.cancelAnimationFrame(frame)
      for (const token of ['--market-list-scale', '--market-list-layout-width', '--market-list-layout-height']) document.documentElement.style.removeProperty(token)
    }
  }, [])

  return <div ref={viewportRef} className="w-full overflow-hidden">
    <div ref={contentRef} data-market-list-content className="origin-top-left">{children}</div>
  </div>
}
