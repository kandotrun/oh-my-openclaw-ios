import AppKit
import Foundation

// Reproducible geometric app artwork; no external brand assets.
let size = 1024
let cgContext = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let context = NSGraphicsContext(cgContext: cgContext, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor(calibratedRed: 0.16, green: 0.35, blue: 0.91, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
let bubble = NSBezierPath(roundedRect: NSRect(x: 196, y: 235, width: 632, height: 560), xRadius: 210, yRadius: 210)
NSColor.white.setStroke()
bubble.lineWidth = 46
bubble.stroke()
let tail = NSBezierPath()
tail.move(to: NSPoint(x: 280, y: 300))
tail.line(to: NSPoint(x: 256, y: 178))
tail.line(to: NSPoint(x: 404, y: 246))
tail.lineWidth = 46
tail.lineJoinStyle = .round
tail.lineCapStyle = .round
tail.stroke()
for x in [390, 512, 634] {
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: x - 30, y: 485, width: 60, height: 60)).fill()
}
NSGraphicsContext.restoreGraphicsState()
let directory = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let bitmap = NSBitmapImageRep(cgImage: cgContext.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("AppIcon.png"))
