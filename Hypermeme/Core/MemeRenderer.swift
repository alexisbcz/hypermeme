import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws captions onto an image. The preview and the export both come from here, so what the
/// editor shows is what gets pasted.
nonisolated enum MemeRenderer {
    /// Small templates are enlarged to this width so the text stays sharp.
    static let minimumExportWidth = 1000.0

    /// Draws at `width` pixels wide; nil uses the export size.
    static func render(_ image: CGImage, document: MemeDocument, width: Double? = nil) -> CGImage? {
        let imageWidth = Double(image.width)
        let scale = (width ?? max(imageWidth, minimumExportWidth)) / imageWidth
        let drawnHeight = (Double(image.height) * scale).rounded()
        let canvas = CGSize(
            width: (imageWidth * scale).rounded(),
            height: (drawnHeight * (1 + document.captionStrip)).rounded()
        )
        guard let context = CGContext(
            data: nil,
            width: Int(canvas.width),
            height: Int(canvas.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: canvas))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: canvas.width, height: drawnHeight))

        for box in document.boxes where !box.text.isEmpty {
            draw(box, in: context, canvas: canvas)
        }
        return context.makeImage()
    }

    /// The captions alone, for drawing over a video: transparent, except for the white caption
    /// strip above the picture. `size` is the picture's; the result is taller by the strip.
    static func captions(_ document: MemeDocument, size: CGSize) -> CGImage? {
        let canvas = CGSize(width: size.width.rounded(), height: (size.height * (1 + document.captionStrip)).rounded())
        guard let context = CGContext(
            data: nil,
            width: Int(canvas.width),
            height: Int(canvas.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(origin: .zero, size: canvas))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: size.height.rounded(), width: canvas.width, height: canvas.height - size.height.rounded()))
        for box in document.boxes where !box.text.isEmpty {
            draw(box, in: context, canvas: canvas)
        }
        return context.makeImage()
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: Text

    private static func draw(_ box: TextBox, in context: CGContext, canvas: CGSize) {
        let rect = CGRect(
            x: box.x * canvas.width,
            y: (1 - box.y - box.height) * canvas.height,
            width: box.width * canvas.width,
            height: box.height * canvas.height
        )
        guard rect.width > 1, rect.height > 1 else { return }
        let text = box.allCaps ? box.text.uppercased() : box.text
        let inset = max(2, canvas.width * 0.006)
        let room = CGSize(width: rect.width - inset * 2, height: rect.height - inset * 2)
        let maximum = box.maxFontSize.map { $0 * canvas.height } ?? canvas.height / 3
        let size = fittedSize(text, font: box.font, in: room, maximum: maximum)
        let framesetter = framesetter(text, font: box.font, size: size, align: box.align)
        let needed = suggestedSize(framesetter, width: room.width)

        let top: CGFloat
        switch box.verticalAlign {
        case .top: top = rect.maxY - inset
        case .middle: top = rect.midY + needed.height / 2
        case .bottom: top = rect.minY + inset + needed.height
        }
        // A little taller than needed, or Core Text can drop the last line.
        let path = CGPath(rect: CGRect(x: 0, y: -needed.height - 2, width: room.width, height: needed.height + 2), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)

        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: -box.rotation * .pi / 180)
        context.translateBy(x: rect.minX + inset - rect.midX, y: top - rect.midY)
        context.textMatrix = .identity
        context.setLineJoin(.round)
        context.setLineCap(.round)

        if box.shadow {
            context.setShadow(offset: .zero, blur: size * 0.18, color: color(box.outline, alpha: 0.8))
        }
        context.setStrokeColor(color(box.outline))
        context.setLineWidth(max(1, size * 0.11))
        context.setTextDrawingMode(.stroke)
        CTFrameDraw(frame, context)

        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setFillColor(color(box.color))
        context.setTextDrawingMode(.fill)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    /// The largest size at which `text` fits, without breaking a word across lines.
    static func fittedSize(_ text: String, font: MemeFont, in room: CGSize, maximum: CGFloat) -> CGFloat {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        func fits(_ size: CGFloat) -> Bool {
            let longest = words.map { lineWidth($0, font: font, size: size) }.max() ?? 0
            guard longest <= room.width else { return false }
            let needed = suggestedSize(framesetter(text, font: font, size: size, align: .left), width: room.width)
            return needed.height <= room.height
        }
        var low: CGFloat = 4
        var high = max(maximum, low)
        guard !fits(high) else { return high }
        while high - low > 0.5 {
            let middle = (low + high) / 2
            if fits(middle) { low = middle } else { high = middle }
        }
        return low
    }

    private static func lineWidth(_ text: String, font: MemeFont, size: CGFloat) -> CGFloat {
        let line = CTLineCreateWithAttributedString(attributed(text, font: font, size: size, align: .left))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    private static func suggestedSize(_ framesetter: CTFramesetter, width: CGFloat) -> CGSize {
        CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil
        )
    }

    private static func framesetter(_ text: String, font: MemeFont, size: CGFloat, align: HorizontalAlign) -> CTFramesetter {
        CTFramesetterCreateWithAttributedString(attributed(text, font: font, size: size, align: align))
    }

    private static func attributed(_ text: String, font: MemeFont, size: CGFloat, align: HorizontalAlign) -> CFAttributedString {
        var alignment: CTTextAlignment = switch align {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        let style = withUnsafeBytes(of: &alignment) { bytes in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: bytes.count, value: bytes.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: CTFontCreateWithName(font.postScriptName as CFString, size, nil),
            kCTParagraphStyleAttributeName: style,
            // Lets one draw pass stroke and the next fill, with the colors set on the context.
            kCTForegroundColorFromContextAttributeName: true,
        ]
        return CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
    }

    /// Reads "#RRGGBB"; anything else is black.
    private static func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return CGColor(
            srgbRed: CGFloat(value >> 16 & 0xFF) / 255,
            green: CGFloat(value >> 8 & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }
}
