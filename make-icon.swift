// Draws the CardValet app icon (dark blue tile, ID card, gold key) into CardValet.icns. Run: swift make-icon.swift
import Cocoa
func hex(_ h: Int) -> CGColor { CGColor(red: CGFloat((h >> 16) & 255)/255, green: CGFloat((h >> 8) & 255)/255, blue: CGFloat(h & 255)/255, alpha: 1) }
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!; NSGraphicsContext.current = ctx
    let g = ctx.cgContext
    let s = CGFloat(px) * 0.82 / 180, off = CGFloat(px) * 0.09
    g.translateBy(x: off, y: CGFloat(px) - off); g.scaleBy(x: s, y: -s)
    func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ c: Int) {
        g.setFillColor(hex(c)); g.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)); g.fillPath()
    }
    func circ(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: Int) { g.setFillColor(hex(c)); g.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2*r, height: 2*r)) }
    rr(0, 0, 180, 180, 40, 0x14305a)
    rr(22, 34, 136, 92, 10, 0xf4f6fa)
    circ(58, 66, 14, 0x14305a)
    g.setFillColor(hex(0x14305a)); g.move(to: CGPoint(x: 36, y: 102)); g.addQuadCurve(to: CGPoint(x: 80, y: 102), control: CGPoint(x: 58, y: 78)); g.addLine(to: CGPoint(x: 80, y: 110)); g.addLine(to: CGPoint(x: 36, y: 110)); g.closePath(); g.fillPath()
    rr(92, 56, 52, 7, 3, 0x9aa8bf); rr(92, 72, 40, 7, 3, 0x9aa8bf); rr(92, 88, 46, 7, 3, 0x9aa8bf)
    circ(110, 138, 17, 0xf0b429); circ(110, 138, 7, 0x14305a)
    rr(125, 134, 44, 9, 2, 0xf0b429); rr(150, 143, 7, 11, 1, 0xf0b429); rr(161, 143, 7, 8, 1, 0xf0b429)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let dir = "CardValet.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
}
