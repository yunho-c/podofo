// Independent check of the saved annotation and its appearance in Apple's renderer.
import AppKit
import PDFKit

let path = CommandLine.arguments[1]
guard let document = PDFDocument(url: URL(fileURLWithPath: path)),
      let page = document.page(at: 0) else { fatalError("Cannot open PDF") }
let bounds = page.bounds(for: .cropBox)
let sideways = page.rotation % 180 != 0
let size = NSSize(width: (sideways ? bounds.height : bounds.width) * 2,
                  height: (sideways ? bounds.width : bounds.height) * 2)
let thumbnail = page.thumbnail(of: size, for: .cropBox)
guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let context = CGContext(data: nil, width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: image.width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Cannot render PDF") }
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
let data = context.data!.assumingMemoryBound(to: UInt8.self)
var redPixels = 0
for i in stride(from: 0, to: image.width * image.height * 4, by: 4) {
    if data[i] > 240 && data[i+1] < 30 && data[i+2] < 30 { redPixels += 1 }
}
let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: path + ".png"))
let result: [String: Any] = [
    "types": page.annotations.map { $0.type ?? "" },
    "appearances": page.annotations.map { $0.hasAppearanceStream },
    "redPixels": redPixels,
]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
