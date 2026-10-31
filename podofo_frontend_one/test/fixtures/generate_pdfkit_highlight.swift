// Regenerate on macOS:
// swift test/fixtures/generate_pdfkit_highlight.swift test/fixtures/pdfkit_highlight.pdf
// This is a PDFKit-produced fixture, not an automated interaction with Preview.
import AppKit
import PDFKit

let data = NSMutableData()
var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 200)
let consumer = CGDataConsumer(data: data)!
let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
context.beginPDFPage(nil)
context.endPDFPage()
context.closePDF()
let document = PDFDocument(data: data as Data)!
let highlight = PDFAnnotation(
    bounds: CGRect(x: 30, y: 100, width: 120, height: 20),
    forType: .highlight, withProperties: nil)
highlight.quadrilateralPoints = [
    NSValue(point: CGPoint(x: 0, y: 20)), NSValue(point: CGPoint(x: 120, y: 20)),
    NSValue(point: CGPoint(x: 0, y: 0)), NSValue(point: CGPoint(x: 120, y: 0)),
]
highlight.color = NSColor.systemYellow.withAlphaComponent(0.4)
highlight.contents = "PDFKit imported highlight"
highlight.userName = "Fixture author"
highlight.modificationDate = Date(timeIntervalSince1970: 1700000000)
document.page(at: 0)!.addAnnotation(highlight)
precondition(document.write(to: URL(fileURLWithPath: CommandLine.arguments[1])))
