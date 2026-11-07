// Renders the BedWatch app icon (1024×1024; watchOS masks it to a circle).
// Usage: swift Tools/make-icon.swift WatchApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png

import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                    bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Night-sky background: indigo at the top, deep navy at the bottom.
let sky = CGGradient(colorsSpace: space, colors: [rgb(0x3A3F9E), rgb(0x141A4A)] as CFArray,
                     locations: [0, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// Everything below sits slightly low of center so it balances inside the circular mask.
ctx.translateBy(x: 0, y: -45)

// Stars.
for (x, y, r) in [(250.0, 800.0, 9.0), (380.0, 880.0, 6.0), (520.0, 760.0, 7.0), (180.0, 640.0, 5.0),
                  (620.0, 900.0, 5.0)] {
    ctx.setFillColor(rgb(0xFFFFFF, 0.85))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

// Crescent moon: a disc with an offset disc cut out of it.
ctx.saveGState()
let moon = CGRect(x: 640, y: 640, width: 210, height: 210)
ctx.addRect(CGRect(x: 0, y: 0, width: size, height: size))
ctx.addEllipse(in: moon.offsetBy(dx: -62, dy: 44))
ctx.clip(using: .evenOdd)        // everywhere except the "bite"…
ctx.setFillColor(rgb(0xFFD66B))
ctx.fillEllipse(in: moon)        // …so the moon's edge is antialiased only once
ctx.restoreGState()

// Adjustable bed, side view: head section raised on the left, foot slightly raised on the right.
let mattress = CGMutablePath()
mattress.move(to: CGPoint(x: 205, y: 560))      // top of raised head
mattress.addLine(to: CGPoint(x: 400, y: 430))   // hinge
mattress.addLine(to: CGPoint(x: 640, y: 430))   // seat
mattress.addLine(to: CGPoint(x: 730, y: 465))   // knee
mattress.addLine(to: CGPoint(x: 840, y: 430))   // foot
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.addPath(mattress)
ctx.setStrokeColor(rgb(0xF2F0FF))
ctx.setLineWidth(78)
ctx.strokePath()

// Pillow at the head end.
ctx.saveGState()
ctx.translateBy(x: 262, y: 590)
ctx.rotate(by: 0.59)
ctx.setFillColor(rgb(0xB9C3FF))
ctx.addPath(CGPath(roundedRect: CGRect(x: -70, y: -28, width: 140, height: 56),
                   cornerWidth: 28, cornerHeight: 28, transform: nil))
ctx.fillPath()
ctx.restoreGState()

// Base frame and legs.
ctx.setFillColor(rgb(0x8E97E8))
ctx.addPath(CGPath(roundedRect: CGRect(x: 230, y: 330, width: 620, height: 50),
                   cornerWidth: 25, cornerHeight: 25, transform: nil))
ctx.fillPath()
for x in [270.0, 770.0] {
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 250, width: 44, height: 100),
                       cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.fillPath()
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
