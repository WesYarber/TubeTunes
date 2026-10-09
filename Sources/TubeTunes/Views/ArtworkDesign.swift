import AppKit
import SwiftUI

// MARK: - Model

/// An sRGB color that can be saved with a design.
struct RGBA: Codable, Hashable {
    var r: Double, g: Double, b: Double, a: Double = 1

    static let white = RGBA(r: 1, g: 1, b: 1)
    static let black = RGBA(r: 0, g: 0, b: 0)
    static let paper = RGBA(r: 0.96, g: 0.95, b: 0.92)
    static let ink = RGBA(r: 0.13, g: 0.13, b: 0.14)
    static let cream = RGBA(r: 0.95, g: 0.91, b: 0.83)

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }

    func mixed(with other: RGBA, _ t: Double) -> RGBA {
        RGBA(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t, a: a)
    }

    func withAlpha(_ alpha: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }
}

enum ArtBackground: String, Codable, CaseIterable {
    case blur = "Blurred image", solid = "Solid color", gradient = "Gradient"
}

enum ArtFilter: String, Codable, CaseIterable {
    case none = "None", mono = "Black & white", duotone = "Duotone", vintage = "Vintage"
}

enum ArtBorder: String, Codable, CaseIterable {
    case none = "None", edge = "Edge", inset = "Inset frame"
}

enum TextPlacement: String, Codable, CaseIterable {
    case top = "Top", center = "Center", bottom = "Bottom"
}

enum TextBand: String, Codable, CaseIterable {
    case none = "None", shade = "Shade", solid = "Solid band"
}

enum ArtFont: String, Codable, CaseIterable {
    case system = "SF Bold", rounded = "Rounded", serif = "New York", mono = "Mono",
         futura = "Futura", didot = "Didot", avenir = "Avenir", typewriter = "Typewriter",
         marker = "Marker", condensed = "Condensed", gill = "Gill Sans", baskerville = "Baskerville"

    func font(size: CGFloat) -> Font {
        switch self {
        case .system: .system(size: size, weight: .bold)
        case .rounded: .system(size: size, weight: .heavy, design: .rounded)
        case .serif: .system(size: size, weight: .semibold, design: .serif)
        case .mono: .system(size: size, weight: .medium, design: .monospaced)
        case .futura: .custom("Futura-Bold", size: size)
        case .didot: .custom("Didot-Bold", size: size)
        case .avenir: .custom("AvenirNext-DemiBold", size: size)
        case .typewriter: .custom("AmericanTypewriter-Semibold", size: size)
        case .marker: .custom("MarkerFelt-Wide", size: size)
        case .condensed: .custom("HelveticaNeue-CondensedBlack", size: size)
        case .gill: .custom("GillSans-SemiBold", size: size)
        case .baskerville: .custom("Baskerville-SemiBoldItalic", size: size)
        }
    }
}

/// Everything needed to re-render a piece of artwork. Saved next to the JPEG so it can be edited later.
struct ArtworkDesign: Codable, Equatable {
    /// Source image file inside the download's folder.
    var sourceFile: String
    /// 1 fills the square (cropping the sides); smaller values show more of the image with padding.
    var scale: Double = 1
    /// Image position, as a fraction of the artwork's width.
    var offsetX: Double = 0
    var offsetY: Double = 0
    var filter: ArtFilter = .none
    var tint: RGBA = .white

    var background: ArtBackground = .blur
    var bg1: RGBA = .black
    var bg2: RGBA = .black

    var border: ArtBorder = .none
    var borderColor: RGBA = .white
    var borderWidth: Double = 0.02

    var showText = false
    var title = ""
    var subtitle = ""
    var font: ArtFont = .system
    var textColor: RGBA = .white
    var textSize: Double = 0.075
    var placement: TextPlacement = .bottom
    var band: TextBand = .shade
    var bandColor: RGBA = .black
    var uppercase = false
    var centered = true
}

// MARK: - Rendering

/// Draws a design. Used for the live preview, the style thumbnails and the final 1400px JPEG.
struct ArtworkCanvas: View {
    let image: NSImage
    let design: ArtworkDesign
    let side: CGFloat

    private var aspect: CGFloat { image.size.width / max(1, image.size.height) }

    /// Size at which the image exactly covers the square.
    private var coverSize: CGSize {
        aspect >= 1 ? CGSize(width: side * aspect, height: side) : CGSize(width: side, height: side / aspect)
    }

    var body: some View {
        ZStack {
            background
            photo
            if design.showText && !(design.title.isEmpty && design.subtitle.isEmpty) {
                // Sized to the square explicitly: the image layer can be wider than the artwork.
                text.frame(width: side, height: side)
            }
            border.frame(width: side, height: side)
        }
        .frame(width: side, height: side)
        .clipped()
        // The image can extend far past the square; never let it catch clicks meant for other controls.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var background: some View {
        switch design.background {
        case .blur:
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .blur(radius: side * 0.06, opaque: true)
                .overlay(Color.black.opacity(0.18))
                .clipped()
        case .solid:
            design.bg1.color.frame(width: side, height: side)
        case .gradient:
            LinearGradient(colors: [design.bg1.color, design.bg2.color], startPoint: .top, endPoint: .bottom)
                .frame(width: side, height: side)
        }
    }

    private var photo: some View {
        let size = CGSize(width: coverSize.width * design.scale, height: coverSize.height * design.scale)
        return filtered(Image(nsImage: image).resizable())
            .frame(width: size.width, height: size.height)
            .offset(x: design.offsetX * side, y: design.offsetY * side)
    }

    @ViewBuilder private func filtered(_ image: Image) -> some View {
        switch design.filter {
        case .none: image
        case .mono: image.grayscale(1).contrast(1.1)
        case .duotone: image.grayscale(1).contrast(1.15).colorMultiply(design.tint.color)
        case .vintage: image.saturation(0.55).contrast(0.92).colorMultiply(Color(red: 1, green: 0.93, blue: 0.8))
        }
    }

    @ViewBuilder private var border: some View {
        switch design.border {
        case .none: EmptyView()
        case .edge:
            Rectangle().strokeBorder(design.borderColor.color, lineWidth: max(1, design.borderWidth * side))
        case .inset:
            Rectangle().stroke(design.borderColor.color, lineWidth: max(1, design.borderWidth * side * 0.5))
                .padding(side * 0.06)
        }
    }

    private func cased(_ s: String) -> String { design.uppercase ? s.uppercased() : s }

    private var text: some View {
        let alignment: HorizontalAlignment = design.centered ? .center : .leading
        let size = design.textSize * side
        return VStack(alignment: alignment, spacing: side * 0.008) {
            if !design.title.isEmpty {
                Text(cased(design.title)).font(design.font.font(size: size))
            }
            if !design.subtitle.isEmpty {
                Text(cased(design.subtitle)).font(design.font.font(size: size * 0.55)).opacity(0.85)
            }
        }
        .tracking(design.uppercase ? side * 0.004 : 0)
        .foregroundStyle(design.textColor.color)
        .multilineTextAlignment(design.centered ? .center : .leading)
        .lineLimit(2)
        .minimumScaleFactor(0.4)
        // A soft shadow keeps light text readable over a photo; dark text on paper doesn't need one.
        .shadow(color: design.band == .none && design.textColor.luminance > 0.5 ? .black.opacity(0.45) : .clear,
                radius: side * 0.012)
        .padding(.horizontal, side * 0.07)
        .padding(.vertical, side * (design.band == .shade ? 0.09 : 0.05))
        .frame(maxWidth: .infinity, alignment: design.centered ? .center : .leading)
        .background { band }
        .frame(maxHeight: .infinity, alignment: verticalAlignment)
    }

    private var verticalAlignment: Alignment {
        switch design.placement {
        case .top: .top
        case .center: .center
        case .bottom: .bottom
        }
    }

    @ViewBuilder private var band: some View {
        switch design.band {
        case .none: Color.clear
        case .solid: design.bandColor.color
        case .shade:
            let strong = design.bandColor.withAlpha(0.78).color, clear = design.bandColor.withAlpha(0).color
            switch design.placement {
            case .top: LinearGradient(colors: [strong, clear], startPoint: .top, endPoint: .bottom)
            case .bottom: LinearGradient(colors: [clear, strong], startPoint: .top, endPoint: .bottom)
            case .center: design.bandColor.withAlpha(0.45).color
            }
        }
    }

    /// The final square artwork.
    @MainActor
    static func render(_ image: NSImage, _ design: ArtworkDesign, side: CGFloat = 1400) -> CGImage? {
        let renderer = ImageRenderer(content: ArtworkCanvas(image: image, design: design, side: side))
        renderer.scale = 1
        return renderer.cgImage
    }
}

// MARK: - Palette & presets

/// Colors pulled from an image, used to generate styles that match it.
struct Palette {
    var dark: RGBA
    var light: RGBA
    var accent: RGBA
    var average: RGBA

    static let neutral = Palette(dark: .ink, light: .paper, accent: RGBA(r: 0.85, g: 0.3, b: 0.3), average: .ink)

    var swatches: [RGBA] { [dark, light, accent, average, .white, .black] }

    init(dark: RGBA, light: RGBA, accent: RGBA, average: RGBA) {
        self.dark = dark; self.light = light; self.accent = accent; self.average = average
    }

    init(image: CGImage) {
        let n = 32
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            self = .neutral
            return
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        let colors = (0..<(n * n)).map { i in
            RGBA(r: Double(pixels[i * 4]) / 255, g: Double(pixels[i * 4 + 1]) / 255, b: Double(pixels[i * 4 + 2]) / 255)
        }
        func mean(_ cs: ArraySlice<RGBA>) -> RGBA {
            let c = Double(max(1, cs.count))
            return RGBA(r: cs.map(\.r).reduce(0, +) / c, g: cs.map(\.g).reduce(0, +) / c, b: cs.map(\.b).reduce(0, +) / c)
        }
        let byLum = colors.sorted { $0.luminance < $1.luminance }
        let fifth = colors.count / 5
        var dark = mean(byLum.prefix(fifth))
        var light = mean(byLum.suffix(fifth))
        func saturation(_ c: RGBA) -> Double {
            let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
            return mx > 0 ? (mx - mn) / mx : 0
        }
        let vivid = colors.filter { max($0.r, $0.g, $0.b) > 0.35 }.sorted { saturation($0) > saturation($1) }
        var accent = vivid.isEmpty ? mean(byLum[...]) : mean(vivid.prefix(max(1, vivid.count / 10)))
        // Keep enough contrast for text.
        if dark.luminance > 0.22 { dark = dark.mixed(with: .black, 0.55) }
        if light.luminance < 0.78 { light = light.mixed(with: .white, 0.6) }
        if saturation(accent) < 0.25 { accent = accent.mixed(with: RGBA(r: 0.8, g: 0.35, b: 0.3), 0.4) }
        self.init(dark: dark, light: light, accent: accent, average: mean(colors[...]))
    }
}

struct ArtworkStyle: Identifiable {
    let name: String
    let apply: (inout ArtworkDesign) -> Void
    var id: String { name }
}

enum ArtworkStyles {
    /// Scale at which the whole image fits inside the square.
    static func containScale(aspect: Double) -> Double { aspect >= 1 ? 1 / aspect : aspect }

    /// Scale and vertical offset that place the image near the top, leaving at least `textRoom`
    /// (a fraction of the height) free at the bottom for text — whatever the image's shape.
    static func topAligned(aspect: Double, maxScale: Double, textRoom: Double, margin: Double)
        -> (scale: Double, offsetY: Double) {
        let heightPerScale = aspect >= 1 ? 1.0 : 1 / aspect      // image height ÷ side, at scale 1
        let widthPerScale = aspect >= 1 ? aspect : 1.0
        let scale = min(maxScale, (1 - textRoom - margin) / heightPerScale, 1 / widthPerScale)
        let height = scale * heightPerScale
        return (scale, -(1 - height) / 2 + margin)
    }

    /// Tasteful starting points generated from the image's own colors.
    static func all(palette p: Palette, aspect: Double) -> [ArtworkStyle] {
        let contain = containScale(aspect: aspect)
        func reset(_ d: inout ArtworkDesign) {
            let keep = (d.sourceFile, d.title, d.subtitle)
            d = ArtworkDesign(sourceFile: keep.0)
            d.title = keep.1
            d.subtitle = keep.2
        }
        return [
            ArtworkStyle(name: "Crop") { d in reset(&d) },
            ArtworkStyle(name: "Full Frame") { d in
                reset(&d); d.scale = contain; d.background = .blur
            },
            ArtworkStyle(name: "Full Frame · Color") { d in
                reset(&d); d.scale = contain; d.background = .solid; d.bg1 = p.dark
            },
            ArtworkStyle(name: "Headline") { d in
                reset(&d); d.showText = true; d.font = .system; d.textColor = .white
                d.band = .shade; d.bandColor = .black; d.centered = false; d.textSize = 0.085
            },
            ArtworkStyle(name: "Poster") { d in
                let fit = topAligned(aspect: aspect, maxScale: contain, textRoom: 0.28, margin: 0.08)
                reset(&d); d.scale = fit.scale; d.offsetY = fit.offsetY; d.background = .solid; d.bg1 = p.dark
                d.showText = true; d.font = .futura; d.uppercase = true; d.textColor = p.light
                d.band = .none; d.textSize = 0.07
            },
            ArtworkStyle(name: "Polaroid") { d in
                let fit = topAligned(aspect: aspect, maxScale: contain * 0.88, textRoom: 0.24, margin: 0.06)
                reset(&d); d.scale = fit.scale; d.offsetY = fit.offsetY; d.background = .solid; d.bg1 = .paper
                d.showText = true; d.font = .marker; d.textColor = .ink; d.band = .none; d.textSize = 0.07
            },
            ArtworkStyle(name: "Gallery") { d in
                reset(&d); d.border = .inset; d.borderColor = .white; d.borderWidth = 0.014
            },
            ArtworkStyle(name: "Duotone") { d in
                reset(&d); d.filter = .duotone; d.tint = p.accent.mixed(with: .white, 0.25)
                d.showText = true; d.font = .condensed; d.uppercase = true; d.textColor = .white
                d.placement = .top; d.band = .none; d.centered = false; d.textSize = 0.11
            },
            ArtworkStyle(name: "Vintage") { d in
                reset(&d); d.filter = .vintage; d.showText = true; d.font = .typewriter
                d.textColor = .ink; d.band = .solid; d.bandColor = .cream; d.textSize = 0.065
            },
            ArtworkStyle(name: "Minimal") { d in
                reset(&d); d.scale = contain * 0.78; d.background = .gradient; d.bg1 = p.dark; d.bg2 = p.accent.mixed(with: p.dark, 0.35)
                d.showText = true; d.font = .avenir; d.textColor = p.light; d.band = .none
                d.centered = false; d.textSize = 0.05
            },
            ArtworkStyle(name: "Bordered") { d in
                reset(&d); d.border = .edge; d.borderColor = p.light; d.borderWidth = 0.035
            },
            ArtworkStyle(name: "Noir") { d in
                reset(&d); d.filter = .mono; d.showText = true; d.font = .didot; d.textColor = .white
                d.placement = .center; d.band = .none; d.textSize = 0.1
            },
        ]
    }
}
