import AppKit

// usage: swift make-icons.swift <sf-symbol> <topHex> <botHex> <out.png> <px>
let a = CommandLine.arguments
guard a.count == 6 else { fputs("bad args\n", stderr); exit(1) }
let symbolName = a[1], topHex = a[2], botHex = a[3], outPath = a[4]
let px = Int(a[5]) ?? 1024
let size = CGFloat(px)

func color(_ hex: String) -> NSColor {
    var h = hex; if h.hasPrefix("#") { h.removeFirst() }
    let v = UInt64(h, radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((v>>16)&0xff)/255.0,
                   green: CGFloat((v>>8)&0xff)/255.0,
                   blue:  CGFloat(v&0xff)/255.0, alpha: 1)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!

// rounded-rect background with a vertical gradient
let inset = size * 0.05
let rect = NSRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width*0.225, yRadius: rect.width*0.225)
NSGraphicsContext.current!.saveGraphicsState()
bg.addClip()
NSGradient(starting: color(topHex), ending: color(botHex))!.draw(in: rect, angle: -90)
NSGraphicsContext.current!.restoreGraphicsState()

// white SF Symbol, centered
let cfg = NSImage.SymbolConfiguration(pointSize: size*0.44, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil),
   let sym = base.withSymbolConfiguration(cfg) {
    sym.isTemplate = false
    let s = sym.size
    let scale = (size*0.5) / max(s.width, s.height)
    let w = s.width*scale, h = s.height*scale
    sym.draw(in: NSRect(x: (size-w)/2, y: (size-h)/2, width: w, height: h))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
fputs("wrote \(outPath)\n", stderr)
