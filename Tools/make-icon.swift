import AppKit

// Usage: swift Tools/make-icon.swift App/Assets.xcassets/AppIcon.appiconset/icon-1024.png
// 1024x1024 app icon: blue gradient, white TV outline with a play triangle, small remote.
let size = 1024.0
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let colors = [NSColor(red: 0.16, green: 0.47, blue: 1.0, alpha: 1).cgColor,
              NSColor(red: 0.37, green: 0.20, blue: 0.93, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setFillColor(NSColor.white.cgColor)
// TV body
let tv = CGRect(x: 170, y: 330, width: 684, height: 440)
ctx.setLineWidth(46)
ctx.addPath(CGPath(roundedRect: tv, cornerWidth: 70, cornerHeight: 70, transform: nil))
ctx.strokePath()
// Stand
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 380, y: 230)); ctx.addLine(to: CGPoint(x: 644, y: 230)); ctx.strokePath()
ctx.move(to: CGPoint(x: 512, y: 300)); ctx.addLine(to: CGPoint(x: 512, y: 235)); ctx.strokePath()
// Play triangle
ctx.move(to: CGPoint(x: 450, y: 450)); ctx.addLine(to: CGPoint(x: 450, y: 650)); ctx.addLine(to: CGPoint(x: 625, y: 550))
ctx.closePath(); ctx.fillPath()
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
