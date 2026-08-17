import AppKit

// Draws the WindowDeck app icon and writes an .iconset ready for `iconutil`.
//
// Everything is a fraction of the canvas and drawn fresh at each size rather
// than scaled down from one large render, so the small sizes stay crisp instead
// of turning to mush — 16pt is where an icon usually dies.
//
// Three windows of clearly different proportions on a warm off-white ground:
// pale glass bodies with a coloured edge, a title bar and a handle pill. The
// varied sizes are the point — grouping *unlike* windows together is what the
// app does, so three identical panes would say the wrong thing.

let squircleInset: CGFloat = 0.024
let squircleRadius: CGFloat = 0.165

func color(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
}

/// Edge colours. The bodies are these same hues taken almost to white.
let windowBlue   = color(112, 160, 220)
let windowGreen  = color(104, 194, 166)
let windowPurple = color(168, 123, 216)

/// Fractions of the canvas: x, y (from the bottom), width, height.
/// The tall pane is nearly half the icon high; the others are wide and short.
let windows: [(CGRect, NSColor)] = [
    (CGRect(x: 0.123, y: 0.171, width: 0.234, height: 0.688), windowBlue),
    (CGRect(x: 0.459, y: 0.607, width: 0.316, height: 0.231), windowGreen),
    (CGRect(x: 0.417, y: 0.225, width: 0.461, height: 0.318), windowPurple)
]

/// A constant across every window, like a real title bar — deriving it from each
/// window's own height gave the tall pane an absurdly deep header.
let titleBarHeight: CGFloat = 0.080
let windowRadius: CGFloat = 0.034
let pillSize = CGSize(width: 0.076, height: 0.0135)
let pillInset: CGFloat = 0.037

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let inset = size * squircleInset
    let body = NSRect(x: inset, y: inset, width: size - inset*2, height: size - inset*2)
    let radius = size * squircleRadius
    let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size*0.008), blur: size*0.024,
                  color: NSColor.black.withAlphaComponent(0.16).cgColor)
    NSColor.white.setFill()
    squircle.fill()
    ctx.restoreGState()

    // Essentially white, with only a hair of shading top to bottom so the tile
    // is not perfectly flat. An earlier version leant warm and bottomed out at
    // (238, 234, 229), which is far enough from neutral to read as cream — the
    // red and green channels sitting ~9 above blue is visible as yellow once it
    // fills a large area.
    ctx.saveGState()
    squircle.addClip()
    NSGradient(colors: [color(253, 253, 253), color(243, 243, 244)])?.draw(in: body, angle: -90)
    ctx.restoreGState()

    for (frame, tint) in windows {
        drawWindow(
            NSRect(x: body.minX + body.width*frame.minX,
                   y: body.minY + body.height*frame.minY,
                   width: body.width*frame.width,
                   height: body.height*frame.height),
            tint: tint, size: size, ctx: ctx
        )
    }

    image.unlockFocus()
    return image
}

private func drawWindow(_ rect: NSRect, tint: NSColor, size: CGFloat, ctx: CGContext) {
    // Capped against the pane's own width as well as the canvas: a radius that
    // suits the wide panes turns the narrow one into a phone.
    let radius = min(size*windowRadius, rect.width*0.17)
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Shadow tinted with the window's own colour, which is what makes them read
    // as coloured glass rather than as flat shapes with a grey drop shadow.
    ctx.saveGState()
    // Wide and soft rather than tight: the glow is what makes these read as lit
    // glass sitting above the ground instead of stickers pasted onto it.
    ctx.setShadow(offset: CGSize(width: 0, height: -size*0.006), blur: size*0.030,
                  color: tint.withAlphaComponent(0.38).cgColor)
    tint.blended(withFraction: 0.78, of: .white)!.setFill()
    path.fill()
    ctx.restoreGState()

    ctx.saveGState()
    path.addClip()

    // Body: barely a gradient, just enough that it is not flat colour.
    // Blended well short of white. Taking these too pale drains the colour out
    // of the glass and the three panes stop reading as three different groups.
    NSGradient(colors: [tint.blended(withFraction: 0.82, of: .white)!,
                        tint.blended(withFraction: 0.72, of: .white)!])?
        .draw(in: rect, angle: -90)

    // Title bar, a shade lighter than the body, with a hairline beneath it.
    let barHeight = size * titleBarHeight
    let bar = NSRect(x: rect.minX, y: rect.maxY - barHeight, width: rect.width, height: barHeight)
    tint.blended(withFraction: 0.90, of: .white)!.setFill()
    NSBezierPath(rect: bar).fill()
    tint.withAlphaComponent(0.34).setFill()
    NSBezierPath(rect: NSRect(x: bar.minX, y: bar.minY,
                              width: bar.width, height: max(0.5, size*0.0022))).fill()

    // The handle pill. Clamped so it cannot outgrow a narrow pane.
    let pw = min(size*pillSize.width, rect.width*0.44)
    let ph = size * pillSize.height
    let pill = NSRect(x: rect.minX + size*pillInset, y: bar.midY - ph/2, width: pw, height: ph)
    tint.blended(withFraction: 0.12, of: .white)!.setFill()
    NSBezierPath(roundedRect: pill, xRadius: ph/2, yRadius: ph/2).fill()

    ctx.restoreGState()

    tint.withAlphaComponent(0.92).setStroke()
    path.lineWidth = max(1, size*0.0050)
    path.stroke()
}

func writePNG(pixels: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try data.write(to: url)
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1]
                 : "build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// Exactly the set `iconutil` expects; a missing entry makes it reject the folder.
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, pixels) in variants {
    try writePNG(pixels: pixels, to: output.appendingPathComponent("\(name).png"))
}

print("wrote \(variants.count) images to \(output.path)")
