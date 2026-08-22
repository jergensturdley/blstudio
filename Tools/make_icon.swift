// Generates the BlStudio app icon (1024x1024 PNG).
// Usage: swift Tools/make_icon.swift <output.png>
import AppKit
import CoreGraphics

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon_1024.png"

let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Transparent canvas
ctx.clear(CGRect(origin: .zero, size: size))

// Rounded-square badge
let inset: CGFloat = 40
let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
let radius: CGFloat = 224
let badge = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Diagonal gradient: deep indigo → violet → warm accent
let colors = [
    CGColor(red: 0.16, green: 0.10, blue: 0.42, alpha: 1.0),
    CGColor(red: 0.42, green: 0.20, blue: 0.78, alpha: 1.0),
    CGColor(red: 0.85, green: 0.35, blue: 0.55, alpha: 1.0),
] as CFArray
ctx.saveGState()
ctx.addPath(badge)
ctx.clip()
ctx.drawLinearGradient(
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!,
    start: CGPoint(x: rect.minX, y: rect.maxY),
    end: CGPoint(x: rect.maxX, y: rect.minY),
    options: []
)

// Subtle inner glow ring
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
ctx.setLineWidth(10)
ctx.addPath(badge)
ctx.strokePath()

// Sparkle dots (a nod to "generate")
func dot(_ p: CGPoint, _ r: CGFloat, _ alpha: CGFloat) {
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
}
dot(CGPoint(x: 770, y: 760), 26, 0.9)
dot(CGPoint(x: 830, y: 660), 14, 0.7)
dot(CGPoint(x: 700, y: 830), 12, 0.6)

// "bl" wordmark
let font = NSFont.systemFont(ofSize: 430, weight: .bold)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white,
    .kern: -8,
]
let text = "bl" as NSString
let textSize = text.size(withAttributes: attrs)
let textRect = CGRect(
    x: (size.width - textSize.width) / 2 - 20,
    y: (size.height - textSize.height) / 2 - 30,
    width: textSize.width,
    height: textSize.height
)
// Soft shadow under text
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30,
              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
text.draw(in: textRect, withAttributes: attrs)
ctx.restoreGState()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to render icon\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
