// Draws the app icon: swift ios/tools/make-icon.swift ios/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// A 32 x 32 pixel-art sunset over blocky hills, scaled to 1024 x 1024 (opaque, sRGB).
let grid = 32, cell = 32, size = grid * cell
func rgb(_ hex: UInt32) -> (UInt8, UInt8, UInt8) { (UInt8(hex >> 16 & 255), UInt8(hex >> 8 & 255), UInt8(hex & 255)) }
var pixels = [[(UInt8, UInt8, UInt8)]](repeating: [(UInt8, UInt8, UInt8)](repeating: (0, 0, 0), count: grid), count: grid)

let horizon = 22
// Sky bands, top to the horizon.
let sky: [UInt32] = [0x140f3a, 0x140f3a, 0x140f3a, 0x1b1446, 0x1b1446, 0x1b1446, 0x271a5a, 0x271a5a, 0x3a1f6e, 0x3a1f6e,
                     0x522682, 0x6a2b8a, 0x83308c, 0x9c3586, 0xb33b7c, 0xc8456f, 0xd9535f, 0xe5644f,
                     0xee7643, 0xf3893a, 0xf69c35, 0xf8ae34]
for y in 0..<horizon { for x in 0..<grid { pixels[y][x] = rgb(sky[y]) } }
// Stars.
for (x, y) in [(4, 2), (11, 4), (25, 1), (28, 6), (7, 7), (20, 3), (2, 10), (30, 9)] {
    pixels[y][x] = rgb(0xfff4d6)
}
// The sun: a disc sitting on the horizon, its lower half cut by bands.
let (cx, cy, r) = (15.5, 19.0, 9.0)
for y in 0..<horizon {
    for x in 0..<grid {
        let d = ((Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)).squareRoot()
        guard d <= r else { continue }
        if y >= 17 && (y - 17) % 2 == 1 { continue }
        pixels[y][x] = rgb(d < r * 0.55 ? 0xfff1a8 : 0xffd25a)
    }
}
// Blocky hills at the sides, low in the middle so the sun shows; then the ground.
let heights = [5, 5, 6, 6, 5, 4, 3, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 3, 4, 4, 5, 6, 6, 5]
for x in 0..<grid {
    let top = horizon - heights[x]
    for y in top..<grid {
        let depth = y - top
        let color: UInt32 = depth == 0 ? 0x5fae5a : depth == 1 ? 0x3f8a4a : (y < 27 ? 0x22543a : 0x163a2b)
        pixels[y][x] = rgb(color)
    }
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
for y in 0..<grid {
    for x in 0..<grid {
        let (r, g, b) = pixels[y][x]
        ctx.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        ctx.fill(CGRect(x: x * cell, y: (grid - 1 - y) * cell, width: cell, height: cell))
    }
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
