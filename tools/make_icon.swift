import AppKit

// Renders HotCopy's app icon (1024×1024 PNG) with CoreGraphics/AppKit:
// a near-black squircle with a phosphor-mint clipboard + eighth note and a
// small amber "live" dot — the app's retro-future palette.
// Usage: swift make_icon.swift <output.png>

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S: CGFloat = 1024

let mint  = NSColor(srgbRed: 0.36, green: 0.91, blue: 0.68, alpha: 1)
let amber = NSColor(srgbRed: 1.00, green: 0.66, blue: 0.24, alpha: 1)
let bgTop = NSColor(srgbRed: 0.09, green: 0.13, blue: 0.11, alpha: 1)
let bgBot = NSColor(srgbRed: 0.03, green: 0.05, blue: 0.04, alpha: 1)

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// --- squircle background with vertical gradient ---
let inset: CGFloat = 88
let side = S - inset * 2
let squircle = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: side, height: side),
                            xRadius: 196, yRadius: 196)
NSGraphicsContext.saveGraphicsState()
squircle.addClip()
NSGradient(starting: bgTop, ending: bgBot)!.draw(in: NSRect(x: 0, y: 0, width: S, height: S), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// hairline mint rim
mint.withAlphaComponent(0.30).setStroke()
squircle.lineWidth = 5
squircle.stroke()

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

// --- clipboard board ---
let boardW: CGFloat = 430, boardH: CGFloat = 520
let boardX = (S - boardW) / 2
let boardY: CGFloat = 250
NSColor(srgbRed: 0.05, green: 0.08, blue: 0.07, alpha: 1).setFill()
let board = roundedRect(boardX, boardY, boardW, boardH, 54)
board.fill()
mint.setStroke()
board.lineWidth = 18
board.stroke()

// clip at the top of the board
let clipW: CGFloat = 180, clipH: CGFloat = 92
let clip = roundedRect((S - clipW) / 2, boardY + boardH - 52, clipW, clipH, 30)
mint.setFill()
clip.fill()

// --- eighth note, with a soft phosphor glow ---
func drawNote(scale: CGFloat, color: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    let cx: CGFloat = 470, cy: CGFloat = 430
    let t = NSAffineTransform()
    t.translateX(by: cx, yBy: cy)
    t.scale(by: scale)
    t.translateX(by: -cx, yBy: -cy)
    t.concat()

    color.setFill()
    color.setStroke()

    // notehead (rotated ellipse)
    NSGraphicsContext.saveGraphicsState()
    let ht = NSAffineTransform()
    ht.translateX(by: cx, yBy: cy)
    ht.rotate(byDegrees: -22)
    ht.translateX(by: -cx, yBy: -cy)
    ht.concat()
    NSBezierPath(ovalIn: NSRect(x: cx - 95, y: cy - 70, width: 170, height: 128)).fill()
    NSGraphicsContext.restoreGraphicsState()

    // stem
    roundedRect(cx + 52, cy + 10, 26, 300, 13).fill()

    // flag
    let flag = NSBezierPath()
    flag.move(to: NSPoint(x: cx + 78, y: cy + 300))
    flag.curve(to: NSPoint(x: cx + 150, y: cy + 150),
               controlPoint1: NSPoint(x: cx + 150, y: cy + 300),
               controlPoint2: NSPoint(x: cx + 168, y: cy + 210))
    flag.curve(to: NSPoint(x: cx + 78, y: cy + 210),
               controlPoint1: NSPoint(x: cx + 140, y: cy + 205),
               controlPoint2: NSPoint(x: cx + 110, y: cy + 208))
    flag.close()
    flag.fill()
    NSGraphicsContext.restoreGraphicsState()
}
for (scale, alpha) in [(1.22, 0.10), (1.12, 0.16)] {
    drawNote(scale: scale, color: mint.withAlphaComponent(alpha))
}
drawNote(scale: 1.0, color: mint)

// --- amber "live" dot, echoing the panel's status indicator ---
amber.setFill()
NSBezierPath(ovalIn: NSRect(x: boardX + boardW - 92, y: boardY + 44, width: 46, height: 46)).fill()

NSGraphicsContext.restoreGraphicsState()

let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
