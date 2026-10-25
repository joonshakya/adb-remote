// Usage: swift Tools/make-viewer-icon.swift AndroidViewer/res/drawable-nodpi/ic_photos.png
// Photo glyph for the TV viewer: rounded frame, sun and mountains, soft white on transparent.
import AppKit

let size = 384
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let white = NSColor(white: 1, alpha: 0.85).cgColor
ctx.setStrokeColor(white)
ctx.setFillColor(white)
ctx.setLineWidth(22)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)
// Frame
let frame = CGRect(x: 40, y: 64, width: 304, height: 256)
ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 44, cornerHeight: 44, transform: nil))
ctx.strokePath()
// Sun
ctx.fillEllipse(in: CGRect(x: 236, y: 220, width: 52, height: 52))
// Mountains
ctx.move(to: CGPoint(x: 64, y: 96))
ctx.addLine(to: CGPoint(x: 150, y: 200))
ctx.addLine(to: CGPoint(x: 210, y: 140))
ctx.addLine(to: CGPoint(x: 246, y: 172))
ctx.addLine(to: CGPoint(x: 320, y: 96))
ctx.closePath()
ctx.fillPath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
