// Renders MONO's app icons (all muted: no neon).
//   make_icon <out.png> <style> [appearance] [palette]   one 1024×1024 icon
//   make_icon sheet <out.png> [palette]                  contact sheet of every style
//   make_icon catalog <Assets.xcassets>                  every alternate-icon set + in-app previews
// style: orbit | glass | dusk      appearance: light | dark | tinted      palette: forest | slate | bronze | graphite
import AppKit
import CoreGraphics

let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locs)!
}
func glow(_ ctx: CGContext, _ color: UInt32, _ alpha: CGFloat, at c: CGPoint, radius: CGFloat) {
    ctx.drawRadialGradient(gradient([rgb(color, alpha), rgb(color, 0)], [0, 1]), startCenter: c, startRadius: 0,
                           endCenter: c, endRadius: radius, options: [])
}

struct Palette {
    let name: String
    let nightTop, nightBottom: UInt32          // dark field
    let glowA, glowB, glowC, glowD: UInt32     // soft lights on dark fields
    let ringLight, ringMid: UInt32             // ring / glyph highlights on dark
    let glyphDark: UInt32                      // glyph on dark glass
    let glyphTop, glyphBottom: UInt32          // glyph on light glass
    let pearlTop, pearlBottom: UInt32          // light field
    let lightA, lightB, lightC: UInt32         // soft colour behind light glass
    let darkA, darkB, darkC: UInt32            // soft colour behind dark glass
}

let palettes: [String: Palette] = [
    "forest": Palette(name: "forest", nightTop: 0x15231D, nightBottom: 0x060B09, glowA: 0x3F6F57, glowB: 0x3C6B73, glowC: 0x8A7449, glowD: 0x34455F,
                      ringLight: 0xDCEBE2, ringMid: 0x6F9C84, glyphDark: 0x93BBA4, glyphTop: 0x3F7A62, glyphBottom: 0x1B3A2D,
                      pearlTop: 0xF8FAF7, pearlBottom: 0xD9E4DE, lightA: 0xA9CBB8, lightB: 0xB7C8D8, lightC: 0xE8D5B8,
                      darkA: 0x2E5A47, darkB: 0x34505F, darkC: 0x6B5A3C),
    "slate": Palette(name: "slate", nightTop: 0x161C24, nightBottom: 0x07090D, glowA: 0x44607D, glowB: 0x3A5A6B, glowC: 0x6B6A7A, glowD: 0x3A4666,
                     ringLight: 0xDDE6EF, ringMid: 0x7C9AB5, glyphDark: 0x9DB5CC, glyphTop: 0x4A6A8C, glyphBottom: 0x1D2C3D,
                     pearlTop: 0xF7F9FB, pearlBottom: 0xDAE2EA, lightA: 0xB5C8DC, lightB: 0xC8CFE0, lightC: 0xE2D8C8,
                     darkA: 0x34506B, darkB: 0x3A4A66, darkC: 0x5E5A4A),
    "bronze": Palette(name: "bronze", nightTop: 0x241C14, nightBottom: 0x0C0907, glowA: 0x7A6440, glowB: 0x5E4A38, glowC: 0x4F5E4A, glowD: 0x5A4040,
                      ringLight: 0xF0E6D6, ringMid: 0xB59A6B, glyphDark: 0xCDB48A, glyphTop: 0x8A6B3F, glyphBottom: 0x3A2B1A,
                      pearlTop: 0xFBF8F2, pearlBottom: 0xE8DDCB, lightA: 0xE6D2AC, lightB: 0xDCC3B0, lightC: 0xC8D6C0,
                      darkA: 0x6B5636, darkB: 0x5A4636, darkC: 0x44503C),
    "graphite": Palette(name: "graphite", nightTop: 0x1B1C1E, nightBottom: 0x070708, glowA: 0x55585E, glowB: 0x474A50, glowC: 0x62605A, glowD: 0x3E4147,
                        ringLight: 0xEDEEF0, ringMid: 0xA3A7AE, glyphDark: 0xC4C7CC, glyphTop: 0x5A5E66, glyphBottom: 0x26282B,
                        pearlTop: 0xF8F8F8, pearlBottom: 0xDEDEDF, lightA: 0xCDD0D4, lightB: 0xD8D6D2, lightC: 0xE4E1DC,
                        darkA: 0x3A3D42, darkB: 0x44464C, darkC: 0x4E4B46),
]

func mPath(centerX: CGFloat = 512, centerY: CGFloat = 512, width: CGFloat, height: CGFloat, vertex: CGFloat = 0.44) -> CGPath {
    let l = centerX - width / 2, r = centerX + width / 2, b = centerY - height / 2, t = centerY + height / 2
    let p = CGMutablePath()
    p.move(to: CGPoint(x: l, y: b)); p.addLine(to: CGPoint(x: l, y: t))
    p.addLine(to: CGPoint(x: centerX, y: t - height * vertex)); p.addLine(to: CGPoint(x: r, y: t)); p.addLine(to: CGPoint(x: r, y: b))
    return p
}

func gradientStroke(_ ctx: CGContext, _ path: CGPath, width: CGFloat, top: CGColor, bottom: CGColor, y0: CGFloat, y1: CGFloat,
                    shadow: CGColor? = nil, shadowBlur: CGFloat = 36, shadowDY: CGFloat = -16) {
    if let shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: shadowDY), blur: shadowBlur, color: shadow)
        ctx.setStrokeColor(top); ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.addPath(path); ctx.strokePath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(path); ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    ctx.drawLinearGradient(gradient([top, bottom], [0, 1]), start: CGPoint(x: 0, y: y1), end: CGPoint(x: 0, y: y0), options: extend)
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.5), rgb(0xFFFFFF, 0)], [0, 1]),
                           start: CGPoint(x: 0, y: y1), end: CGPoint(x: 0, y: y1 - (y1 - y0) * 0.5), options: extend)
    ctx.restoreGState()
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: Styles

func drawOrbit(_ ctx: CGContext, _ a: String, _ p: Palette) {
    let tinted = a == "tinted"
    ctx.drawLinearGradient(gradient(tinted ? [rgb(0x262626), rgb(0x000000)] : [rgb(p.nightTop), rgb(p.nightBottom)], [0, 1]),
                           start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])
    if !tinted { glow(ctx, p.glowA, 0.45, at: CGPoint(x: 512, y: 330), radius: 620) }
    let c = CGPoint(x: 512, y: 512), radius: CGFloat = 292, w: CGFloat = 58
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.08)); ctx.setLineWidth(w)
    ctx.addArc(center: c, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false); ctx.strokePath()
    let start = CGFloat.pi * 1.20, sweep = CGFloat.pi * 1.58
    let arc = CGMutablePath()
    arc.addArc(center: c, radius: radius, startAngle: start, endAngle: start - sweep, clockwise: true)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 56, color: rgb(tinted ? 0xFFFFFF : p.ringMid, 0.40))
    ctx.setStrokeColor(rgb(tinted ? 0xFFFFFF : p.ringMid)); ctx.setLineWidth(w); ctx.setLineCap(.round)
    ctx.addPath(arc); ctx.strokePath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(arc); ctx.setLineWidth(w); ctx.setLineCap(.round); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient(tinted ? [rgb(0xFFFFFF), rgb(0xBFBFBF)] : [rgb(p.ringLight), rgb(p.ringMid)], [0, 1]),
                           start: CGPoint(x: 220, y: 800), end: CGPoint(x: 800, y: 224), options: [])
    ctx.restoreGState()
    gradientStroke(ctx, mPath(width: 188, height: 168, vertex: 0.5), width: 30, top: rgb(0xFFFFFF), bottom: rgb(0xE8ECEA),
                   y0: 428, y1: 596, shadow: rgb(0x000000, 0.4), shadowBlur: 20, shadowDY: -8)
}

func drawGlass(_ ctx: CGContext, _ a: String, _ p: Palette) {
    let dark = a == "dark", tinted = a == "tinted"
    let bg: [CGColor] = tinted ? [rgb(0x2A2A2A), rgb(0x000000)] : dark ? [rgb(p.nightTop), rgb(p.nightBottom)] : [rgb(p.pearlTop), rgb(p.pearlBottom)]
    ctx.drawLinearGradient(gradient(bg, [0, 1]), start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])
    if !tinted {
        glow(ctx, dark ? p.darkA : p.lightA, dark ? 0.70 : 0.80, at: CGPoint(x: 230, y: 250), radius: 640)
        glow(ctx, dark ? p.darkB : p.lightB, dark ? 0.60 : 0.70, at: CGPoint(x: 830, y: 860), radius: 620)
        glow(ctx, dark ? p.darkC : p.lightC, dark ? 0.35 : 0.65, at: CGPoint(x: 880, y: 180), radius: 420)
    }
    let tile = CGRect(x: 232, y: 232, width: 560, height: 560)
    let shape = roundedRect(tile, 150)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 70, color: rgb(dark ? 0x000000 : p.glyphBottom, dark ? 0.6 : 0.26))
    ctx.addPath(shape); ctx.setFillColor(rgb(0xFFFFFF, dark ? 0.10 : 0.30)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, dark ? 0.22 : 0.65), rgb(0xFFFFFF, dark ? 0.03 : 0.08)], [0, 1]),
                           start: CGPoint(x: 300, y: 792), end: CGPoint(x: 700, y: 232), options: [])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.setLineWidth(5); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, dark ? 0.55 : 0.95), rgb(0xFFFFFF, 0.05)], [0, 1]),
                           start: CGPoint(x: 232, y: 792), end: CGPoint(x: 792, y: 232), options: [])
    ctx.restoreGState()
    let top = tinted ? rgb(0xFFFFFF) : dark ? rgb(p.ringLight) : rgb(p.glyphTop)
    let bottom = tinted ? rgb(0xBDBDBD) : dark ? rgb(p.glyphDark) : rgb(p.glyphBottom)
    gradientStroke(ctx, mPath(width: 270, height: 240, vertex: 0.5), width: 56, top: top, bottom: bottom, y0: 392, y1: 632,
                   shadow: rgb(dark ? 0x000000 : p.glyphBottom, 0.28), shadowBlur: 24, shadowDY: -10)
}

func drawDusk(_ ctx: CGContext, _ a: String, _ p: Palette) {
    let tinted = a == "tinted"
    ctx.drawLinearGradient(gradient(tinted ? [rgb(0x303030), rgb(0x000000)] : [rgb(p.nightTop), rgb(p.nightBottom)], [0, 1]),
                           start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])
    if !tinted {
        glow(ctx, p.glowB, 0.80, at: CGPoint(x: 170, y: 820), radius: 640)
        glow(ctx, p.glowA, 0.80, at: CGPoint(x: 880, y: 300), radius: 620)
        glow(ctx, p.glowC, 0.50, at: CGPoint(x: 720, y: 930), radius: 420)
        glow(ctx, p.glowD, 0.55, at: CGPoint(x: 120, y: 130), radius: 520)
        ctx.drawLinearGradient(gradient([rgb(0x000000, 0), rgb(0x000000, 0.35)], [0, 1]),
                               start: CGPoint(x: 512, y: 520), end: CGPoint(x: 512, y: 0), options: [])
    }
    gradientStroke(ctx, mPath(width: 410, height: 372, vertex: 0.46), width: 62, top: rgb(0xFFFFFF), bottom: rgb(0xE2E8E4),
                   y0: 326, y1: 698, shadow: rgb(0x000000, 0.4), shadowBlur: 44, shadowDY: -18)
}

func render(_ style: String, _ appearance: String, _ palette: String, size: Int = 1024) -> CGImage {
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let p = palettes[palette] ?? palettes["forest"]!
    switch style {
    case "orbit": drawOrbit(ctx, appearance, p)
    case "glass": drawGlass(ctx, appearance, p)
    default: drawDusk(ctx, appearance, p)
    }
    let full = ctx.makeImage()!
    guard size != 1024 else { return full }
    let small = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    small.interpolationQuality = .high
    small.draw(full, in: CGRect(x: 0, y: 0, width: size, height: size))
    return small.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let styles = ["orbit", "glass", "dusk"]
let paletteOrder = ["forest", "slate", "bronze", "graphite"]
let args = CommandLine.arguments

if args.count >= 3, args[1] == "sheet" {
    let pal = args.count > 3 ? args[3] : "forest"
    let cell = 440, gap = 40, pad = 40
    let w = pad * 2 + styles.count * cell + (styles.count - 1) * gap, h = pad * 2 + cell * 2 + gap
    let sheet = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    sheet.setFillColor(rgb(0x7A7F85)); sheet.fill(CGRect(x: 0, y: 0, width: w, height: h))
    for (i, d) in styles.enumerated() {
        for (row, appearance) in ["light", "dark"].enumerated() {
            let rect = CGRect(x: pad + i * (cell + gap), y: pad + (1 - row) * (cell + gap), width: cell, height: cell)
            sheet.saveGState()
            sheet.addPath(roundedRect(rect, CGFloat(cell) * 0.2237)); sheet.clip()
            sheet.draw(render(d, appearance, pal), in: rect)
            sheet.restoreGState()
        }
    }
    write(sheet.makeImage()!, to: args[2])
} else if args.count >= 3, args[1] == "catalog" {
    // Alternate icons (light + dark each) and small in-app previews. The default icon (glass · forest) is AppIcon itself.
    let root = args[2], fm = FileManager.default
    for style in styles {
        for pal in paletteOrder {
            let name = "icon-\(style)-\(pal)"
            let dir = "\(root)/\(name).appiconset"
            try? fm.removeItem(atPath: dir)
            try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            write(render(style, "light", pal), to: "\(dir)/icon.png")
            write(render(style, "dark", pal), to: "\(dir)/icon-dark.png")
            try! """
            {
              "images" : [
                { "filename" : "icon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
                { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "icon-dark.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
              ],
              "info" : { "author" : "xcode", "version" : 1 }
            }
            """.write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)

            let pdir = "\(root)/Preview-\(style)-\(pal).imageset"
            try? fm.removeItem(atPath: pdir)
            try! fm.createDirectory(atPath: pdir, withIntermediateDirectories: true)
            write(render(style, "light", pal, size: 360), to: "\(pdir)/preview.png")
            try! """
            { "images" : [ { "filename" : "preview.png", "idiom" : "universal" } ], "info" : { "author" : "xcode", "version" : 1 } }
            """.write(toFile: "\(pdir)/Contents.json", atomically: true, encoding: .utf8)
        }
    }
} else if args.count >= 3 {
    write(render(args[2], args.count > 3 ? args[3] : "light", args.count > 4 ? args[4] : "forest"), to: args[1])
} else {
    print("usage: make_icon <out.png> <orbit|glass|dusk> [light|dark|tinted] [palette] | sheet <out.png> [palette] | catalog <Assets.xcassets>")
}
