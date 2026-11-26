// Erzeugt Resources/AppIcon.png (1024 px): weißes Klemmbrett auf violettem Verlauf
import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
    let path = NSBezierPath(roundedRect: r.insetBy(dx: 100, dy: 100), xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(red: 0.55, green: 0.45, blue: 1.00, alpha: 1),
               ending: NSColor(red: 0.27, green: 0.18, blue: 0.72, alpha: 1))!.draw(in: path, angle: -90)
    let cfg = NSImage.SymbolConfiguration(pointSize: 440, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    let sym = NSImage(systemSymbolName: "list.clipboard.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(cfg)!
    let s = sym.size
    sym.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
    return true
}
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
