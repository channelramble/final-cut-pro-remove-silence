// Draws the app icon: a waveform with the silent middle cut out.
// usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: the rounded square sits inside a ~10% margin.
    let inset = s * 0.098
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237, cornerHeight: rect.width * 0.2237, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(red: 0.12, green: 0.10, blue: 0.28, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.36, green: 0.30, blue: 0.95, alpha: 1), CGColor(red: 0.10, green: 0.08, blue: 0.30, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // Waveform bars; the quiet ones in the middle are dimmed and bracketed by cut marks.
    let heights: [CGFloat] = [0.30, 0.55, 0.80, 0.62, 0.40, 0.07, 0.05, 0.07, 0.45, 0.72, 0.90, 0.58, 0.34]
    let silent = 5...7
    let area = rect.insetBy(dx: rect.width * 0.14, dy: rect.height * 0.2)
    let step = area.width / CGFloat(heights.count)
    let barWidth = step * 0.56
    for (i, h) in heights.enumerated() {
        let barHeight = max(area.height * h, barWidth)
        let x = area.minX + CGFloat(i) * step + (step - barWidth) / 2
        let bar = CGRect(x: x, y: area.midY - barHeight / 2, width: barWidth, height: barHeight)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        ctx.setFillColor(silent.contains(i) ? CGColor(red: 1, green: 0.45, blue: 0.5, alpha: 0.95) : CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
    }
    ctx.setStrokeColor(CGColor(red: 1, green: 0.45, blue: 0.5, alpha: 1))
    ctx.setLineWidth(max(1, s * 0.012))
    ctx.setLineDash(phase: 0, lengths: [s * 0.03, s * 0.022])
    for edge in [silent.lowerBound, silent.upperBound + 1] {
        let x = area.minX + CGFloat(edge) * step
        ctx.move(to: CGPoint(x: x, y: area.minY - area.height * 0.12))
        ctx.addLine(to: CGPoint(x: x, y: area.maxY + area.height * 0.12))
    }
    ctx.strokePath()
    ctx.restoreGState()
    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

for (name, size) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128),
                     ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try draw(size: size).write(to: output.appendingPathComponent("\(name).png"))
}
