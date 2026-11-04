import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Usage: swift scripts/make-icon.swift <app-icon.png> [transparent-mark.png]
// Geometry is also supplied as editable SVG in Branding/.
let space = CGColorSpaceCreateDeviceRGB()
guard (2...3).contains(CommandLine.arguments.count) else { fatalError("Supply an output PNG path") }

func route() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 700, y: 300))
    path.addLine(to: CGPoint(x: 430, y: 300))
    path.addCurve(to: CGPoint(x: 300, y: 406), control1: CGPoint(x: 350, y: 300), control2: CGPoint(x: 300, y: 346))
    path.addCurve(to: CGPoint(x: 430, y: 512), control1: CGPoint(x: 300, y: 466), control2: CGPoint(x: 350, y: 512))
    path.addLine(to: CGPoint(x: 594, y: 512))
    path.addCurve(to: CGPoint(x: 724, y: 618), control1: CGPoint(x: 674, y: 512), control2: CGPoint(x: 724, y: 558))
    path.addCurve(to: CGPoint(x: 594, y: 724), control1: CGPoint(x: 724, y: 678), control2: CGPoint(x: 674, y: 724))
    path.addLine(to: CGPoint(x: 324, y: 724))
    return path
}

func render(to path: String, appIcon: Bool) {
    guard let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("Cannot create icon context") }
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)
    if appIcon {
        guard let gradient = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 0.36, green: 0.32, blue: 0.78, alpha: 1),
            CGColor(red: 0.16, green: 0.17, blue: 0.36, alpha: 1)
        ] as CFArray, locations: [0, 1]) else { fatalError("Cannot create icon gradient") }
        context.saveGState()
        context.addPath(CGPath(roundedRect: CGRect(x: 62, y: 62, width: 900, height: 900), cornerWidth: 198, cornerHeight: 198, transform: nil))
        context.clip()
        context.drawLinearGradient(gradient, start: CGPoint(x: 62, y: 62), end: CGPoint(x: 962, y: 962), options: [])
        context.restoreGState()
    }
    context.setStrokeColor(appIcon ? CGColor(gray: 1, alpha: 1) : CGColor(red: 0.30, green: 0.27, blue: 0.78, alpha: 1))
    context.setLineWidth(108)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(route())
    context.strokePath()
    context.setFillColor(CGColor(red: 0.40, green: 0.91, blue: 0.72, alpha: 1))
    context.fillEllipse(in: CGRect(x: 632.5, y: 232.5, width: 135, height: 135))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                            UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Cannot encode app icon") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot save app icon") }
}

render(to: CommandLine.arguments[1], appIcon: true)
if CommandLine.arguments.count == 3 { render(to: CommandLine.arguments[2], appIcon: false) }
