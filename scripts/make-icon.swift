// Renders Shout's app icon (1024×1024 PNG) with CoreGraphics.
import AppKit

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt rounded square centred in 1024.
let inset = 100.0
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(path); ctx.clip()
let colors = [NSColor(srgbRed: 0.10, green: 0.09, blue: 0.26, alpha: 1).cgColor,
              NSColor(srgbRed: 0.33, green: 0.20, blue: 0.78, alpha: 1).cgColor,
              NSColor(srgbRed: 0.62, green: 0.36, blue: 0.98, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.6, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
// Soft top highlight.
let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(hl, start: CGPoint(x: size / 2, y: rect.maxY), end: CGPoint(x: size / 2, y: rect.midY), options: [])

// Waveform bars.
let heights: [Double] = [0.18, 0.34, 0.58, 0.86, 0.62, 0.40, 0.70, 0.48, 0.26, 0.14]
let barW = 44.0, gap = 22.0
let totalW = Double(heights.count) * barW + Double(heights.count - 1) * gap
var x = size / 2 - totalW / 2
for h in heights {
    let bh = h * 470
    let bar = CGRect(x: x, y: size / 2 - bh / 2, width: barW, height: bh)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
    ctx.fillPath()
    x += barW + gap
}
ctx.restoreGState()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
