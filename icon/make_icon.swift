import AppKit
// Draws the MDView app icon (1024x1024 PNG) with CoreGraphics; no external assets.
let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset: CGFloat = 100
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.28); shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.15, alpha: 1).setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.23, alpha: 1),
                        NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1)])!.draw(in: path, angle: -90)
    // Text "MD" and a small accent bar (markdown "down" cue)
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let font = NSFont.systemFont(ofSize: 390, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: para, .kern: -14]
    let str = NSAttributedString(string: "MD", attributes: attrs)
    let strSize = str.size()
    str.draw(in: NSRect(x: 0, y: (size - strSize.height) / 2 + 40, width: size, height: strSize.height))
    let bar = NSBezierPath(roundedRect: NSRect(x: 330, y: 268, width: 364, height: 44), xRadius: 22, yRadius: 22)
    NSColor(calibratedRed: 0.35, green: 0.63, blue: 1.0, alpha: 1).setFill(); bar.fill()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 512 - 70, y: 250)); arrow.line(to: NSPoint(x: 512 + 70, y: 250)); arrow.line(to: NSPoint(x: 512, y: 170)); arrow.close()
    NSColor(calibratedRed: 0.35, green: 0.63, blue: 1.0, alpha: 1).setFill(); arrow.fill()
    return true
}
let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
rep.size = NSSize(width: size, height: size)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out) \(rep.pixelsWide)x\(rep.pixelsHigh)")
