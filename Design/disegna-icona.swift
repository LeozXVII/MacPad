import AppKit

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

// Sfondo: gradiente navy
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [c(0x1E3A8A), c(0x0A1433)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: size, y: size), options: [])

// Un MacBook visto dall'alto: onde in cima, tastiera al centro, trackpad sotto.

// Onde del wireless
let center = CGPoint(x: 512, y: 335)
ctx.setStrokeColor(c(0xFFFFFF)); ctx.setLineWidth(30); ctx.setLineCap(.round)
for radius: CGFloat in [70, 135, 200] {
    let points = stride(from: 225.0, through: 315.0, by: 1.0).map { deg -> CGPoint in
        let a = deg * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(cos(a)), y: center.y + radius * CGFloat(sin(a)))
    }
    let arc = CGMutablePath()
    arc.addLines(between: points)
    ctx.addPath(arc); ctx.strokePath()
}
ctx.setFillColor(c(0xFFFFFF))
ctx.fillEllipse(in: CGRect(x: center.x - 24, y: center.y - 24, width: 48, height: 48))

// Tastiera: 4 file da 10 tasti più la fila con la barra spaziatrice
let left: CGFloat = 192, width: CGFloat = 640, gap: CGFloat = 14, keyH: CGFloat = 40, top: CGFloat = 410
let keyW = (width - 9 * gap) / 10
func key(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat) {
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: keyH), cornerWidth: 9, cornerHeight: 9, transform: nil))
    ctx.setFillColor(c(0xFFFFFF, 0.9)); ctx.fillPath()
}
for row in 0..<4 {
    for col in 0..<10 { key(left + CGFloat(col) * (keyW + gap), top + CGFloat(row) * (keyH + gap), keyW) }
}
let lastY = top + 4 * (keyH + gap)
for col in [0, 1, 8, 9] { key(left + CGFloat(col) * (keyW + gap), lastY, keyW) }
key(left + 2 * (keyW + gap), lastY, 6 * keyW + 5 * gap)

// Trackpad
let pad = CGPath(roundedRect: CGRect(x: 382, y: 705, width: 260, height: 165), cornerWidth: 30, cornerHeight: 30, transform: nil)
ctx.addPath(pad); ctx.setFillColor(c(0xFFFFFF, 0.16)); ctx.fillPath()
ctx.addPath(pad); ctx.setStrokeColor(c(0xFFFFFF, 0.9)); ctx.setLineWidth(14); ctx.strokePath()

// L'icona iOS deve essere opaca: ricopio su un'immagine senza alfa
let cg = ctx.makeImage()!
let opaque = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
opaque.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
let out = NSBitmapImageRep(cgImage: opaque.makeImage()!)
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
