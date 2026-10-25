// Usage: swift Tools/make-cursor.swift AndroidViewer/res/drawable-nodpi/ic_cursor.png
// Black arrow pointer with a white border (tip at the top-left pixel) drawn by the TV app when it can't add a real mouse.
import AppKit

let w = 72, h = 108
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// CoreGraphics is bottom-up: flip so (0,0) is the top-left tip.
ctx.translateBy(x: 0, y: CGFloat(h))
ctx.scaleBy(x: 1, y: -1)
let arrow = CGMutablePath()
arrow.move(to: CGPoint(x: 4, y: 4))
arrow.addLine(to: CGPoint(x: 4, y: 84))
arrow.addLine(to: CGPoint(x: 24, y: 66))
arrow.addLine(to: CGPoint(x: 38, y: 100))
arrow.addLine(to: CGPoint(x: 52, y: 94))
arrow.addLine(to: CGPoint(x: 38, y: 62))
arrow.addLine(to: CGPoint(x: 64, y: 62))
arrow.closeSubpath()
ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: NSColor(white: 0, alpha: 0.5).cgColor)
ctx.addPath(arrow)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.addPath(arrow)
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineWidth(5)
ctx.setLineJoin(.round)
ctx.strokePath()
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
