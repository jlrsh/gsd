// Renders the app icon: a terminal-dark tile with a green checked box.
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

// A checked box, centred (drawn at 330 pt and scaled by k).
let side = 560.0
let k = side / 330
let box = NSRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side)
let boxPath = NSBezierPath(roundedRect: box, xRadius: 56 * k, yRadius: 56 * k)
NSColor(srgbRed: 0.30, green: 0.82, blue: 0.47, alpha: 1).setFill()
boxPath.fill()
let check = NSBezierPath()
check.move(to: NSPoint(x: box.minX + 72 * k, y: box.midY + 4 * k))
check.line(to: NSPoint(x: box.minX + 138 * k, y: box.minY + 84 * k))
check.line(to: NSPoint(x: box.maxX - 62 * k, y: box.maxY - 78 * k))
check.lineWidth = 46 * k
check.lineCapStyle = .round
check.lineJoinStyle = .round
NSColor(srgbRed: 0.05, green: 0.06, blue: 0.08, alpha: 1).setStroke()
check.stroke()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
