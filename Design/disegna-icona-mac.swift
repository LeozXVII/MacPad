import AppKit

// Icona dell'app Mac: un iPhone in orizzontale con una tastiera dentro, su un quadrato arrotondato navy.
// Uso: swift disegna-icona-mac.swift uscita.png

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
// Coordinate dall'alto a sinistra
ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// Quadrato arrotondato con margine e ombra, come le icone macOS
let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: c(0x000000, 0.35))
ctx.addPath(body); ctx.setFillColor(c(0x0A1433)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(body); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [c(0x1E3A8A), c(0x0A1433)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 924, y: 924), options: [])
ctx.restoreGState()

// iPhone in orizzontale
let phone = CGPath(roundedRect: CGRect(x: 192, y: 347, width: 640, height: 330), cornerWidth: 70, cornerHeight: 70, transform: nil)
ctx.addPath(phone); ctx.setFillColor(c(0xFFFFFF, 0.12)); ctx.fillPath()
ctx.addPath(phone); ctx.setStrokeColor(c(0xFFFFFF, 0.92)); ctx.setLineWidth(18); ctx.strokePath()
// Dynamic Island, sul lato sinistro
ctx.addPath(CGPath(roundedRect: CGRect(x: 224, y: 472, width: 26, height: 80), cornerWidth: 13, cornerHeight: 13, transform: nil))
ctx.setFillColor(c(0xFFFFFF, 0.92)); ctx.fillPath()

// Tastiera: 3 file da 10 tasti più la fila con la barra spaziatrice
let left: CGFloat = 272, width: CGFloat = 480, gap: CGFloat = 10, keyH: CGFloat = 38, top: CGFloat = 421
let keyW = (width - 9 * gap) / 10
func key(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat) {
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: keyH), cornerWidth: 8, cornerHeight: 8, transform: nil))
    ctx.setFillColor(c(0xFFFFFF, 0.9)); ctx.fillPath()
}
for row in 0..<3 {
    for col in 0..<10 { key(left + CGFloat(col) * (keyW + gap), top + CGFloat(row) * (keyH + gap), keyW) }
}
let lastY = top + 3 * (keyH + gap)
for col in [0, 1, 8, 9] { key(left + CGFloat(col) * (keyW + gap), lastY, keyW) }
key(left + 2 * (keyW + gap), lastY, 6 * keyW + 5 * gap)

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
