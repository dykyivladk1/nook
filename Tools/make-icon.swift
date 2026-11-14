// Renders the Nook app icon (1024x1024 PNG): macOS-style squircle with a tray symbol.
import AppKit

let out = CommandLine.arguments[1]
let S = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx

// Apple icon grid: 824pt body centred in 1024
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// soft drop shadow
ctx.saveGraphicsState()
let sh = NSShadow()
sh.shadowColor = NSColor.black.withAlphaComponent(0.28)
sh.shadowOffset = NSSize(width: 0, height: -14)
sh.shadowBlurRadius = 26
sh.set()
NSColor.white.setFill()
shape.fill()
ctx.restoreGraphicsState()

// gradient body
ctx.saveGraphicsState()
shape.addClip()
NSGradient(colors: [NSColor(srgbRed: 0.40, green: 0.78, blue: 1.00, alpha: 1),
                    NSColor(srgbRed: 0.04, green: 0.45, blue: 1.00, alpha: 1)])!
    .draw(in: body, angle: -90)
// subtle top highlight
NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: 100, y: 520, width: 824, height: 404), angle: -90)
ctx.restoreGraphicsState()

// symbol
let cfg = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let sz = sym.size
    let r = NSRect(x: (CGFloat(S) - sz.width) / 2, y: (CGFloat(S) - sz.height) / 2 - 6, width: sz.width, height: sz.height)
    ctx.saveGraphicsState()
    let ss = NSShadow()
    ss.shadowColor = NSColor.black.withAlphaComponent(0.22)
    ss.shadowOffset = NSSize(width: 0, height: -8)
    ss.shadowBlurRadius = 14
    ss.set()
    sym.draw(in: r)
    ctx.restoreGraphicsState()
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
