import AppKit

// Builds immich-icon-master.png: the Immich pinwheel, inset on a white rounded-square
// tile with the standard macOS icon margin and a soft shadow.
// Usage: swift make_icon.swift [logoFraction]   (logo width as a fraction of the tile, default 0.66)
let fraction = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 0.66 : 0.66
let canvas = 1024.0
let tileSize = 824.0
let tileOrigin = (canvas - tileSize) / 2
let corner = 185.0

guard let source = NSImage(contentsOfFile: "immich-logo-source.png"),
      let sourceCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let context = CGContext(
        data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("couldn't set up drawing") }

let tile = CGRect(x: tileOrigin, y: tileOrigin, width: tileSize, height: tileSize)
let path = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.28))
context.addPath(path)
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(path)
context.clip()
let logoSize = tileSize * fraction
let logo = CGRect(x: tile.midX - logoSize / 2, y: tile.midY - logoSize / 2, width: logoSize, height: logoSize)
context.interpolationQuality = .high
context.draw(sourceCG, in: logo)
context.restoreGState()

guard let output = context.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: output)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "immich-icon-master.png"))
print("wrote immich-icon-master.png (logo \(Int(logoSize)) px on a \(Int(tileSize)) px tile)")
