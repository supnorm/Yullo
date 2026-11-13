// Generated from Assets/YulloGlyph.svg by Assets/generate-brand-source.py.
// One approved vector supplies app icons, window headers and the menu-bar template.
import AppKit
import CoreGraphics

enum BrandArtwork {
    static let blue = CGColor(srgbRed: 36/255, green: 72/255, blue: 216/255, alpha: 1)
    static let blueColor = NSColor(srgbRed: 36/255, green: 72/255, blue: 216/255, alpha: 1)
    static let path: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 326, y: 180))
        path.addCurve(to: CGPoint(x: 399, y: 255), control1: CGPoint(x: 372, y: 180), control2: CGPoint(x: 400, y: 211))
        path.addCurve(to: CGPoint(x: 364, y: 363), control1: CGPoint(x: 398, y: 291), control2: CGPoint(x: 378, y: 329))
        path.addCurve(to: CGPoint(x: 397, y: 458), control1: CGPoint(x: 349, y: 401), control2: CGPoint(x: 355, y: 452))
        path.addCurve(to: CGPoint(x: 540, y: 319), control1: CGPoint(x: 447, y: 465), control2: CGPoint(x: 496, y: 372))
        path.addCurve(to: CGPoint(x: 690, y: 199), control1: CGPoint(x: 588, y: 261), control2: CGPoint(x: 637, y: 213))
        path.addCurve(to: CGPoint(x: 782, y: 211), control1: CGPoint(x: 729, y: 188), control2: CGPoint(x: 759, y: 193))
        path.addCurve(to: CGPoint(x: 811, y: 235), control1: CGPoint(x: 795, y: 221), control2: CGPoint(x: 807, y: 229))
        path.addCurve(to: CGPoint(x: 824, y: 285), control1: CGPoint(x: 819, y: 247), control2: CGPoint(x: 831, y: 265))
        path.addCurve(to: CGPoint(x: 738, y: 426), control1: CGPoint(x: 810, y: 324), control2: CGPoint(x: 777, y: 371))
        path.addLine(to: CGPoint(x: 580, y: 654))
        path.addCurve(to: CGPoint(x: 443, y: 812), control1: CGPoint(x: 535, y: 719), control2: CGPoint(x: 492, y: 779))
        path.addCurve(to: CGPoint(x: 313, y: 832), control1: CGPoint(x: 401, y: 840), control2: CGPoint(x: 350, y: 851))
        path.addCurve(to: CGPoint(x: 284, y: 757), control1: CGPoint(x: 281, y: 816), control2: CGPoint(x: 272, y: 787))
        path.addCurve(to: CGPoint(x: 384, y: 667), control1: CGPoint(x: 301, y: 715), control2: CGPoint(x: 338, y: 686))
        path.addLine(to: CGPoint(x: 463, y: 636))
        path.addCurve(to: CGPoint(x: 582, y: 536), control1: CGPoint(x: 515, y: 616), control2: CGPoint(x: 553, y: 583))
        path.addCurve(to: CGPoint(x: 620, y: 458), control1: CGPoint(x: 599, y: 508), control2: CGPoint(x: 614, y: 479))
        path.addCurve(to: CGPoint(x: 592, y: 435), control1: CGPoint(x: 627, y: 434), control2: CGPoint(x: 611, y: 422))
        path.addCurve(to: CGPoint(x: 530, y: 481), control1: CGPoint(x: 573, y: 448), control2: CGPoint(x: 555, y: 465))
        path.addCurve(to: CGPoint(x: 396, y: 505), control1: CGPoint(x: 485, y: 512), control2: CGPoint(x: 442, y: 510))
        path.addCurve(to: CGPoint(x: 245, y: 433), control1: CGPoint(x: 330, y: 498), control2: CGPoint(x: 277, y: 477))
        path.addCurve(to: CGPoint(x: 222, y: 294), control1: CGPoint(x: 216, y: 398), control2: CGPoint(x: 207, y: 344))
        path.addCurve(to: CGPoint(x: 326, y: 180), control1: CGPoint(x: 237, y: 241), control2: CGPoint(x: 277, y: 181))
        path.closeSubpath()
        return path
    }()

    static func iconCGImage(_ size: Int, dark: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
        context.addPath(CGPath(roundedRect: CGRect(x: 80, y: 80, width: 864, height: 864), cornerWidth: 190, cornerHeight: 190, transform: nil))
        context.setFillColor(dark ? CGColor(srgbRed: 20/255, green: 26/255, blue: 43/255, alpha: 1) : blue)
        context.fillPath()
        if size == 16 { context.translateBy(x: -8, y: 8) }
        context.addPath(path)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
        return context.makeImage()!
    }
    static let lightSettingsIcon = NSImage(cgImage: iconCGImage(128), size: NSSize(width: 32, height: 32))
    static let darkSettingsIcon = NSImage(cgImage: iconCGImage(128, dark: true), size: NSSize(width: 32, height: 32))

    // Template images adapt automatically to the menu bar's light/dark appearance.
    static let templateImage: NSImage = {
        let pointSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        for scale in [1, 2, 3] {
            let pixels = Int(pointSize) * scale
            let bounds = path.boundingBoxOfPath.insetBy(dx: -20, dy: -20)
            let context = CGContext(data: nil, width: pixels, height: pixels,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let factor = min(CGFloat(pixels) / bounds.width, CGFloat(pixels) / bounds.height)
            let x = (CGFloat(pixels) - bounds.width * factor) / 2
            let y = (CGFloat(pixels) - bounds.height * factor) / 2
            context.translateBy(x: x, y: CGFloat(pixels) - y)
            context.scaleBy(x: factor, y: -factor)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.addPath(path)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
            rep.size = image.size
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        image.accessibilityDescription = "Yullo"
        return image
    }()
}
