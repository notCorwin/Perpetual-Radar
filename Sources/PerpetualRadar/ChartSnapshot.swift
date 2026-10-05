import AppKit

func opaqueChartSnapshot(_ image: NSImage, backgroundRGB: [Double]) -> NSImage? {
    guard backgroundRGB.count == 3, backgroundRGB.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
          let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let background = CGColor(colorSpace: colorSpace, components: backgroundRGB.map { CGFloat($0) } + [1]),
          let context = CGContext(data: nil, width: source.width, height: source.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    let rect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
    context.setFillColor(background)
    context.fill(rect)
    context.draw(source, in: rect)
    guard let result = context.makeImage() else { return nil }
    return NSImage(cgImage: result, size: image.size)
}
