import AppKit
// Renders the 1024px app icon: red rounded square with a white music note on a play badge.
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 1.0, green: 0.30, blue: 0.36, alpha: 1), NSColor(red: 0.80, green: 0.05, blue: 0.20, alpha: 1)])!
    .draw(in: path, angle: -90)
let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = note.size
    note.draw(in: NSRect(x: (size - s.width) / 2 - 20, y: (size - s.height) / 2 + 10, width: s.width, height: s.height))
}
let badge = NSBezierPath(ovalIn: NSRect(x: 600, y: 170, width: 250, height: 250))
NSColor.white.setFill(); badge.fill()
let tri = NSBezierPath()
tri.move(to: NSPoint(x: 690, y: 230)); tri.line(to: NSPoint(x: 690, y: 360)); tri.line(to: NSPoint(x: 800, y: 295)); tri.close()
NSColor(red: 0.85, green: 0.08, blue: 0.22, alpha: 1).setFill(); tri.fill()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
