// Renders the Hearthloom app icon — an original flame mark, cream on a warm
// brown gradient — from the geometry below. Run from the repository root:
//
//   xcrun swift design/app-icon/render-icon.swift
//
// It writes the same artwork twice:
//   design/app-icon/icon.svg                                (vector, for editing)
//   Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
//     (1024×1024, sRGB, fully opaque with no alpha channel, as the App Store
//      requires)
//
// Options: --png <path>  --svg <path>  --size <pixels>   (e.g. --size 60 to
// preview the icon at Home Screen size without touching the asset catalog).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Artwork (1024 × 1024 canvas, y grows downward, like SVG)

struct RGB {
    let r, g, b: Int
    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
    func cg(_ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: alpha)
    }
}

let canvas: CGFloat = 1024
let backgroundTop = RGB(r: 0x7F, g: 0x49, b: 0x21)     // warm brown
let backgroundBottom = RGB(r: 0x37, g: 0x29, b: 0x22)  // deep brown
let ember = RGB(r: 0xC4, g: 0x86, b: 0x48)             // the glow behind the flame
let cream = RGB(r: 0xFF, g: 0xD5, b: 0x96)             // the flame
let heart = RGB(r: 0xE8, g: 0x9F, b: 0x55)             // the flame's inner heart

/// Glow: a soft ember circle behind the flame, fading to nothing.
let glowCenter = CGPoint(x: 512, y: 610)
let glowRadius: CGFloat = 470
let glowStrength: CGFloat = 0.55

/// The flame: one body with three tongues — a tall one rising and leaning a
/// little right, a shorter one on each side — over a full, round base.
let flamePath = """
M 512 868 \
C 380 868 280 776 280 648 \
C 280 542 312 462 332 368 \
C 356 424 386 460 422 482 \
C 410 372 454 252 548 138 \
C 552 244 610 326 640 428 \
C 664 398 684 360 694 314 \
C 732 402 746 510 746 618 \
C 746 770 644 868 512 868 Z
"""

/// The heart of the flame: a smaller teardrop low in the body.
let heartPath = """
M 534 480 \
C 558 566 620 618 620 704 \
C 620 770 572 814 512 814 \
C 452 814 404 770 404 708 \
C 404 618 498 588 534 480 Z
"""

// MARK: - Path data (absolute M / L / C / Z only)

func parsePath(_ d: String) -> CGPath {
    let tokens = d.replacingOccurrences(of: ",", with: " ")
        .split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    let path = CGMutablePath()
    var i = 0
    func number() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i])!) }
    func point() -> CGPoint { let x = number(); return CGPoint(x: x, y: number()) }
    while i < tokens.count {
        let command = tokens[i]; i += 1
        switch command {
        case "M": path.move(to: point())
        case "L": path.addLine(to: point())
        case "C": let c1 = point(), c2 = point(); path.addCurve(to: point(), control1: c1, control2: c2)
        case "Z": path.closeSubpath()
        default: fatalError("unsupported path command \(command)")
        }
    }
    return path
}

func squash(_ d: String) -> String {
    d.split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: " ")
}

// MARK: - Raster

func renderPNG(size: Int, to url: URL) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw NSError(domain: "render-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "no bitmap context"])
    }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    // Work in the 1024 canvas with y pointing down, whatever the output size.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: CGFloat(size) / canvas, y: -CGFloat(size) / canvas)

    let linear = CGGradient(colorsSpace: space,
                            colors: [backgroundTop.cg(), backgroundBottom.cg()] as CFArray,
                            locations: [0, 1])!
    ctx.drawLinearGradient(linear, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: canvas),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    let glow = CGGradient(colorsSpace: space,
                          colors: [ember.cg(glowStrength), ember.cg(glowStrength * 0.45), ember.cg(0)] as CFArray,
                          locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0,
                           endCenter: glowCenter, endRadius: glowRadius, options: [])

    ctx.addPath(parsePath(flamePath))
    ctx.setFillColor(cream.cg())
    ctx.fillPath()

    ctx.addPath(parsePath(heartPath))
    ctx.setFillColor(heart.cg())
    ctx.fillPath()

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "render-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "can't write \(url.path)"]) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "render-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "can't finish \(url.path)"])
    }
}

// MARK: - Vector

func svg() -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- Hearthloom app icon. Generated by design/app-icon/render-icon.swift — edit the geometry there. -->
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
      <defs>
        <linearGradient id="background" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="1024">
          <stop offset="0" stop-color="\(backgroundTop.hex)"/>
          <stop offset="1" stop-color="\(backgroundBottom.hex)"/>
        </linearGradient>
        <radialGradient id="glow" gradientUnits="userSpaceOnUse" cx="\(Int(glowCenter.x))" cy="\(Int(glowCenter.y))" r="\(Int(glowRadius))">
          <stop offset="0" stop-color="\(ember.hex)" stop-opacity="\(glowStrength)"/>
          <stop offset="0.45" stop-color="\(ember.hex)" stop-opacity="\(glowStrength * 0.45)"/>
          <stop offset="1" stop-color="\(ember.hex)" stop-opacity="0"/>
        </radialGradient>
      </defs>
      <rect width="1024" height="1024" fill="url(#background)"/>
      <rect width="1024" height="1024" fill="url(#glow)"/>
      <path fill="\(cream.hex)" d="\(squash(flamePath))"/>
      <path fill="\(heart.hex)" d="\(squash(heartPath))"/>
    </svg>

    """
}

// MARK: - Main

var pngPath = "Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
var svgPath: String? = "design/app-icon/icon.svg"
var size = 1024
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let flag = args.removeFirst()
    guard let value = args.first else { fatalError("\(flag) needs a value") }
    args.removeFirst()
    switch flag {
    case "--png": pngPath = value
    case "--svg": svgPath = value == "-" ? nil : value
    case "--size": size = Int(value)!
    default: fatalError("unknown option \(flag)")
    }
}

do {
    try renderPNG(size: size, to: URL(fileURLWithPath: pngPath))
    print("wrote \(pngPath) (\(size)×\(size))")
    if let svgPath {
        try svg().write(toFile: svgPath, atomically: true, encoding: .utf8)
        print("wrote \(svgPath)")
    }
} catch {
    FileHandle.standardError.write(Data("render-icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
