import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
// Build 121 launch layers, derived from the approved wordmark (no new artwork):
//
//   xcrun swiftc -O scripts/kyro-brand/split_wordmark.swift -o /tmp/split_wordmark
//   /tmp/split_wordmark iosApp/iosApp/Kyro/KyroBrand.xcassets/KyroXWordmark.imageset/KyroXWordmark.png \
//       KyroXWordmarkKyro.png KyroXWordmarkX.png preview.png
//
// Separates the silver "Kyro" from the crimson X, its bevel and glow. Both outputs keep the
// source's 1825x498 canvas, so they overlay exactly where the original draws. The column
// thresholds (1150, 1188) are measured on that artwork: the "o" ends near column 1182.
let a = CommandLine.arguments
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let w = img.width, h = img.height
var px = [UInt8](repeating: 0, count: w*h*4)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
var kyro = px, xl = px
var mixed = 0, total = 0
for i in stride(from: 0, to: px.count, by: 4) {
  let al = Double(px[i+3]); if al == 0 { continue }
  total += 1
  // unpremultiply
  let r = Double(px[i]) * 255 / al, g = Double(px[i+1]) * 255 / al, b = Double(px[i+2]) * 255 / al
  let redness = r - (g + b) / 2
  let x = (i / 4) % w
  let mx = max(r, g, b), mn = min(r, g, b)
  let saturation = mx > 0 ? (mx - mn) / mx : 0
  let silver = saturation < 0.22 && mx > 100
  var wgt = min(1, max(0, (redness - 25) / 60))
  // Right of the "o" (silver ends near column 1185), every non-silver pixel is the X's
  // body, bevel or glow.
  // Between the "o" and the X, only reddish pixels (the X's lower-left bevel) move with the X;
  // neutral grey there is the "o"'s own shadow edge.
  if x >= 1150 && !silver && redness > 6 { wgt = 1 }
  // The "o" ends near column 1182; beyond it, silver pixels are the X's own highlights.
  if x >= 1188 { wgt = 1 }
  if wgt > 0 && wgt < 1 { mixed += 1 }
  for c in 0..<4 {
    xl[i+c] = UInt8((Double(px[i+c]) * wgt).rounded())
    kyro[i+c] = UInt8((Double(px[i+c]) * (1 - wgt)).rounded())
  }
}
func write(_ buf: [UInt8], _ path: String) {
  var b = buf
  let c = CGContext(data: &b, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let out = c.makeImage()!
  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, out, nil); CGImageDestinationFinalize(dest)
}
write(kyro, a[2]); write(xl, a[3])
// preview: both layers on dark backdrop, X offset to the right to show separation
var pv = [UInt8](repeating: 0, count: w*h*2*4)
let pc = CGContext(data: &pv, width: w, height: h*2, bitsPerComponent: 8, bytesPerRow: w*4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
pc.setFillColor(CGColor(red: 0.06, green: 0.035, blue: 0.047, alpha: 1)); pc.fill(CGRect(x: 0, y: 0, width: w, height: h*2))
func img(_ buf: [UInt8]) -> CGImage { var b = buf; return CGContext(data: &b, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()! }
pc.draw(img(kyro), in: CGRect(x: 0, y: h, width: w, height: h))
pc.draw(img(xl), in: CGRect(x: 0, y: h, width: w, height: h))
pc.draw(img(kyro), in: CGRect(x: -120, y: 0, width: w, height: h))
pc.draw(img(xl), in: CGRect(x: 80, y: 0, width: w, height: h))
let pimg = pc.makeImage()!
let pd = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[4]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(pd, pimg, nil); CGImageDestinationFinalize(pd)
print("pixels \(total), mixed \(mixed)")
