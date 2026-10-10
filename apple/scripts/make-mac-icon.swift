// Re-frames the iOS icon for macOS: the artwork in an 824-pt rounded tile with
// a soft shadow on a transparent 1024 canvas (Apple's macOS icon grid), then
// writes every size the Mac asset catalog needs.
//   swift apple/scripts/make-mac-icon.swift apple/iOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png apple/Mac/Assets.xcassets/AppIcon.appiconset
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let art = NSImage(contentsOfFile: args[1]) else {
    print("usage: make-mac-icon.swift <icon-1024.png> <appiconset dir>")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[2])

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)  // draw in 1024-pt units at any pixel size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    shape.addClip()
    art.draw(in: tile)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! render(points * scale).write(to: outDir.appendingPathComponent(name))
        images.append(#"    { "filename" : "\#(name)", "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(points)x\#(points)" }"#)
    }
}
let contents = "{\n  \"images\" : [\n" + images.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try! contents.write(to: outDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(images.count) icons to \(outDir.path)")
