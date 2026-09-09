import AppKit
import Foundation

// Renders the app icon — a plain clipboard, drawn as an object rather than a
// glyph — and packs it into an .icns at every size macOS asks for.
//
// Usage: swift make_icon.swift <output.icns>
//
// Each size is rendered natively from the vector description rather than
// downscaled from one master, so the small sizes stay crisp. Below 48pt the
// ruled lines are dropped: at that scale they are sub-pixel and turn the paper
// into grey mush instead of reading as text.

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let S: CGFloat = 1024

// MARK: - Palette

func hex(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}

let bgTop     = hex(0xF6F7F8)
let bgBottom  = hex(0xE3E6E9)
let board     = hex(0x55606B)
let boardEdge = hex(0x3D4650)
let paper     = hex(0xFDFDFD)
let rule      = hex(0xC7CDD3)
let clip      = hex(0x99A1A9)
let clipShade = hex(0x737B83)
let dropShadow = NSColor(srgbRed: 0.13, green: 0.17, blue: 0.21, alpha: 0.30)

// MARK: - Geometry

/// The macOS icon shape: a continuous-curvature superellipse. A plain
/// `roundedRect` has circular corners and sits subtly wrong beside other
/// Dock icons.
func squircle(in rect: NSRect, n: CGFloat = 5.0, samples: Int = 720) -> NSBezierPath {
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let path = NSBezierPath()
    for i in 0...samples {
        let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

func shadowed(color: NSColor, blur: CGFloat, dy: CGFloat, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: dy)
    shadow.set()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - The icon

/// Apple's macOS grid: an 824pt body centred in a 1024pt canvas.
let bodyRect = NSRect(x: 100, y: 100, width: 824, height: 824)

func drawIcon(showRules: Bool) {
    // Background: a plain surface with the faintest top-down shading.
    let shape = squircle(in: bodyRect)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: bgTop, ending: bgBottom)!
        .draw(in: NSRect(x: 0, y: 0, width: S, height: S), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Board: the hardboard backing. Modest corner radius — a board, not a card.
    shadowed(color: dropShadow, blur: 34, dy: -12) {
        board.setFill()
        rr(296, 176, 432, 596, 34).fill()
    }
    boardEdge.setStroke()
    let boardPath = rr(296, 176, 432, 596, 34)
    boardPath.lineWidth = 6
    boardPath.stroke()

    // Paper: inset so the board frames it on all four sides.
    shadowed(color: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.22), blur: 14, dy: -5) {
        paper.setFill()
        rr(340, 212, 344, 500, 10).fill()
    }

    if showRules {
        rule.setFill()
        for (offset, width) in [(CGFloat(372), CGFloat(252)), (280, 216), (188, 168)] {
            rr(386, 212 + offset, width, 26, 13).fill()
        }
    }

    // Clip: a base plate straddling the board's top edge, plus a smaller handle
    // above it. Two pieces is what makes it read as a clip rather than a tab.
    shadowed(color: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28), blur: 16, dy: -6) {
        clip.setFill()
        rr(512 - 104, 726, 208, 78, 22).fill()
    }
    clipShade.setFill()
    rr(512 - 62, 792, 124, 66, 26).fill()
    clip.setFill()
    rr(512 - 54, 796, 108, 54, 22).fill()
}

func renderIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let transform = NSAffineTransform()
    transform.scale(by: size / S)
    transform.concat()
    drawIcon(showRules: size >= 48)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Pack into an .icns

let iconsetURL = URL(fileURLWithPath: outPath)
    .deletingLastPathComponent()
    .appendingPathComponent("AppIcon.iconset", isDirectory: true)

try? FileManager.default.removeItem(at: iconsetURL)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    let rep = renderIcon(size: variant.pixels)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: iconsetURL.appendingPathComponent("\(variant.name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outPath]
try! iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

try? FileManager.default.removeItem(at: iconsetURL)
print("wrote \(outPath)")
