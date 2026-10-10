// Renders the app icon: a terminal-dark tile with a checked box and "gsd".
//   swift apple/scripts/make-icon.swift apple/iOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png
import AppKit

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let bg = NSGradient(starting: NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1),
                    ending: NSColor(srgbRed: 0.05, green: 0.06, blue: 0.08, alpha: 1))!
bg.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)

// Checkbox
let box = NSRect(x: 212, y: 400, width: 330, height: 330)
let boxPath = NSBezierPath(roundedRect: box, xRadius: 56, yRadius: 56)
NSColor(srgbRed: 0.30, green: 0.82, blue: 0.47, alpha: 1).setFill()
boxPath.fill()
let check = NSBezierPath()
check.move(to: NSPoint(x: box.minX + 72, y: box.midY + 4))
check.line(to: NSPoint(x: box.minX + 138, y: box.minY + 84))
check.line(to: NSPoint(x: box.maxX - 62, y: box.maxY - 78))
check.lineWidth = 46
check.lineCapStyle = .round
check.lineJoinStyle = .round
NSColor(srgbRed: 0.05, green: 0.06, blue: 0.08, alpha: 1).setStroke()
check.stroke()

// Two "rows" to the right, like list lines
NSColor(srgbRed: 0.39, green: 0.62, blue: 1.0, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 600, y: 610, width: 230, height: 56), xRadius: 28, yRadius: 28).fill()
NSColor(white: 0.55, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 600, y: 470, width: 170, height: 56), xRadius: 28, yRadius: 28).fill()

let font = NSFont.monospacedSystemFont(ofSize: 250, weight: .bold)
let text = NSAttributedString(string: "gsd", attributes: [.font: font, .foregroundColor: NSColor(white: 0.93, alpha: 1)])
let ts = text.size()
text.draw(at: NSPoint(x: (size - ts.width) / 2, y: 120))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
