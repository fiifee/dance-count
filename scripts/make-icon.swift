// Renders the 1024×1024 app icon: swift scripts/make-icon.swift <out.png>
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let colors = [NSColor(red: 0.10, green: 0.04, blue: 0.16, alpha: 1).cgColor, NSColor(red: 0.45, green: 0.05, blue: 0.25, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])

// Eight beat dots along the bottom, 1 and 5 larger and pink.
for i in 0..<8 {
    let big = i == 0 || i == 4
    let r = big ? 34.0 : 22.0
    let x = 152 + Double(i) * 103
    let rect = CGRect(x: x - r, y: 230 - r, width: 2 * r, height: 2 * r)
    ctx.setFillColor(i == 0 ? NSColor(red: 1, green: 0.25, blue: 0.45, alpha: 1).cgColor : NSColor(white: 1, alpha: big ? 0.9 : 0.45).cgColor)
    ctx.fillEllipse(in: rect)
}

let text = "1" as NSString
let font = NSFont.systemFont(ofSize: 560, weight: .heavy)
let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(red: 1, green: 0.25, blue: 0.45, alpha: 1)]
let textSize = text.size(withAttributes: attributes)
text.draw(at: NSPoint(x: (size - textSize.width) / 2, y: 330), withAttributes: attributes)
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
