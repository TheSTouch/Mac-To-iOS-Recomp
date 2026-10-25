// Draws the app icon and writes app/AppIcon.icns.  Run: swift scripts/make-icon.swift
//
// TheSTouch's palette (amber tile, ink marks, as FarmManager and VirtualScreens):
// a Mac display behind an iPad, and on the iPad's screen the touch dot and ring
// from the tail of the TheSTouch S. Flat shapes only, so it still reads at 16 px.
// Coordinates are in a 1024-point design space, origin top left.
import AppKit

let amber = NSColor(red: 1.0, green: 0.757, blue: 0.027, alpha: 1)      // #ffc107
let ink = NSColor(red: 0.071, green: 0.071, blue: 0.063, alpha: 1)      // #121210
let screen = NSColor(red: 0.149, green: 0.149, blue: 0.133, alpha: 1)   // #262622

func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let cg = gc.cgContext
    cg.translateBy(x: 0, y: size)
    cg.scaleBy(x: size / 1024, y: -size / 1024)

    // macOS tile: 824 points with a 100-point margin.
    let tile = rounded(100, 100, 824, 824, 185)
    NSGradient(colors: [NSColor(red: 1.0, green: 0.827, blue: 0.302, alpha: 1), amber,
                        NSColor(red: 0.965, green: 0.71, blue: 0.0, alpha: 1)])!.draw(in: tile, angle: 90)

    // The iPad, landscape, in front and to the right.
    let pad = (x: CGFloat(452), y: CGFloat(448), w: CGFloat(392), h: CGFloat(288), r: CGFloat(46), bezel: CGFloat(24))

    // The Mac display, drawn in its own layer so the gap around the iPad can be
    // cut out of it without cutting the tile.
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    ink.setFill()
    rounded(172, 288, 440, 316, 36).fill()
    rounded(362, 594, 60, 80, 0).fill()          // neck, left of the iPad
    rounded(296, 662, 192, 30, 15).fill()        // foot
    screen.setFill()
    rounded(198, 314, 388, 264, 16).fill()
    let gap: CGFloat = 26
    cg.setBlendMode(.clear)
    rounded(pad.x - gap, pad.y - gap, pad.w + 2 * gap, pad.h + 2 * gap, pad.r + gap).fill()
    cg.setBlendMode(.normal)
    cg.endTransparencyLayer()

    ink.setFill()
    rounded(pad.x, pad.y, pad.w, pad.h, pad.r).fill()
    screen.setFill()
    rounded(pad.x + pad.bezel, pad.y + pad.bezel, pad.w - 2 * pad.bezel, pad.h - 2 * pad.bezel, pad.r - pad.bezel).fill()

    // The touch: dot and ring.
    let cx = pad.x + pad.w / 2, cy = pad.y + pad.h / 2
    amber.setFill()
    NSBezierPath(ovalIn: NSRect(x: cx - 40, y: cy - 40, width: 80, height: 80)).fill()
    let ring = NSBezierPath(ovalIn: NSRect(x: cx - 76, y: cy - 76, width: 152, height: 152))
    ring.lineWidth = 16
    amber.withAlphaComponent(0.45).setStroke()
    ring.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
if CommandLine.arguments.count == 3 {  // preview: make-icon.swift <out.png> <pixels>
    try! render(CGFloat(Int(CommandLine.arguments[2])!)).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    exit(0)
}
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", set.path, "-o", "app/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote app/AppIcon.icns" : "iconutil failed")
