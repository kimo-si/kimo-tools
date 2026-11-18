#!/usr/bin/env swift
// 从 Config/brand-logo.png 生成程序坞图标和菜单栏模板图，同时生成安装映像背景。
// 用法：swift macos/brand-icons.swift [预览目录]。只用 AppKit、CoreGraphics、CoreText 和 ImageIO。

import AppKit

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let rgba = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
let cream = hex(0xFFF5F0)

// MARK: 原图处理

/// 从亮色画布分离有色外框，保留外框内的浅色图形与渐变。
func logoImage(at url: URL) -> CGImage {
  guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
    let input = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
  else { fatalError("无法读取品牌原图：\(url.path)") }
  let ctx = CGContext(
    data: nil, width: input.width, height: input.height, bitsPerComponent: 8,
    bytesPerRow: 0, space: sRGB, bitmapInfo: rgba)!
  ctx.draw(input, in: CGRect(x: 0, y: 0, width: input.width, height: input.height))
  let raster = LogoMatte(context: ctx)
  let crop = raster.removeBackdrop()
  return ctx.makeImage()!.cropping(to: crop)!
}

/// 只处理原图外缘，使用行列的有色轮廓保护内部的白色格子与加号。
struct LogoMatte {
  private static let edgePadding = 2
  private static let backdropChroma = 6
  private static let outlineChroma = 35
  private static let white = 255
  private let pixels: UnsafeMutablePointer<UInt8>
  private let width: Int
  private let height: Int
  private let rowBytes: Int
  private let sourceChroma: [UInt8]

  /// 将画布的 RGBA 像素解释为自上而下的扫描行。
  init(context: CGContext) {
    let data = context.data!.assumingMemoryBound(to: UInt8.self)
    pixels = data
    width = context.width
    height = context.height
    rowBytes = context.bytesPerRow
    // 先存原图色差，估算某个边缘像素时只读未处理的邻居。
    sourceChroma = (0..<context.height).flatMap { y in
      (0..<context.width).map { x in
        let index = y * context.bytesPerRow + x * 4
        let (r, g, b) = (data[index], data[index + 1], data[index + 2])
        return max(r, g, b) - min(r, g, b)
      }
    }
  }

  /// 找到彩色外框后清理外侧画布，并返回包含抗锯齿边缘的裁切范围。
  func removeBackdrop() -> CGRect {
    let rows = (0..<height).map { y in extent(width) { chroma(x: $0, y: y) } }
    let cols = (0..<width).map { x in extent(height) { chroma(x: x, y: $0) } }
    guard let left = cols.firstIndex(where: { $0 != nil }),
      let right = cols.lastIndex(where: { $0 != nil }),
      let top = rows.firstIndex(where: { $0 != nil }),
      let bottom = rows.lastIndex(where: { $0 != nil })
    else { fatalError("品牌原图中找不到有色外框") }
    let padding = Self.edgePadding
    for y in 0..<height {
      for x in 0..<width {
        if !isInterior(x: x, y: y, row: rows[y], column: cols[x]) {
          let alpha = coverage(x: x, y: y, row: rows[y], column: cols[x])
          unmatte(at: y * rowBytes + x * 4, coverage: alpha)
        }
      }
    }
    let x = max(0, left - padding)
    let y = max(0, top - padding)
    return CGRect(
      x: x, y: y, width: min(width, right + padding + 1) - x,
      height: min(height, bottom + padding + 1) - y)
  }

  /// 外框可由扫描线上第一个和最后一个有足够色差的像素确定。
  private func extent(_ length: Int, chroma: (Int) -> Int) -> ClosedRange<Int>? {
    let offsets = 0..<length
    guard let start = offsets.first(where: { chroma($0) >= Self.outlineChroma }),
      let end = offsets.last(where: { chroma($0) >= Self.outlineChroma })
    else { return nil }
    return start...end
  }

  /// 避开边缘处理带，直接保留外框内部的原始像素。
  private func isInterior(
    x: Int, y: Int, row: ClosedRange<Int>?, column: ClosedRange<Int>?
  ) -> Bool {
    guard let row, let column else { return false }
    let padding = Self.edgePadding
    return x - row.lowerBound >= padding && row.upperBound - x >= padding
      && y - column.lowerBound >= padding && column.upperBound - y >= padding
  }

  /// 白底混合降低色差，用临近实色像素估算抗锯齿边的覆盖率。
  private func coverage(
    x: Int, y: Int, row: ClosedRange<Int>?, column: ClosedRange<Int>?
  ) -> Double {
    let padding = Self.edgePadding
    guard let row, let column,
      x >= row.lowerBound - padding, x <= row.upperBound + padding,
      y >= column.lowerBound - padding, y <= column.upperBound + padding
    else { return 0 }
    let background = Self.backdropChroma
    let distance = max(0, chroma(x: x, y: y) - background)
    guard distance > 0 else { return 0 }
    let reference = max(
      chroma(x: max(0, x - padding), y: y), chroma(x: min(width - 1, x + padding), y: y),
      chroma(x: x, y: max(0, y - padding)), chroma(x: x, y: min(height - 1, y + padding)))
    return min(1, Double(distance) / Double(max(reference - background, distance)))
  }

  /// RGB 最大与最小分量之差用于区分彩色外框与近中性的画布。
  private func chroma(x: Int, y: Int) -> Int {
    Int(sourceChroma[y * width + x])
  }

  /// 写入去除白底混合后的预乘颜色与透明度。
  private func unmatte(at index: Int, coverage: Double) {
    let alpha = Int((coverage * Double(Self.white)).rounded())
    let whiteContribution = Self.white - alpha
    for channel in 0..<3 {
      pixels[index + channel] = UInt8(
        max(0, min(alpha, Int(pixels[index + channel]) - whiteContribution)))
    }
    pixels[index + 3] = UInt8(alpha)
  }
}

// MARK: 程序坞与菜单栏

/// 每种分辨率都从同一张透明原图取样，主体居中，画布留白对应菜单栏彩色裁切。
func appIcon(_ artwork: CGImage, pixels: Int) -> CGImage {
  let ctx = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
    space: sRGB, bitmapInfo: rgba)!
  let side = CGFloat(pixels) * (824.0 / 1024.0)
  let ratio = side / CGFloat(max(artwork.width, artwork.height))
  let width = CGFloat(artwork.width) * ratio
  let height = CGFloat(artwork.height) * ratio
  ctx.interpolationQuality = .high
  ctx.draw(
    artwork,
    in: CGRect(
      x: (CGFloat(pixels) - width) / 2, y: (CGFloat(pixels) - height) / 2,
      width: width, height: height))
  return ctx.makeImage()!
}

/// 22 × 16 pt 模板图。沿用四格的斜度，在右下格挖出加号，系统会用菜单栏前景色着色。
func statusIcon(scale: Int) -> CGImage {
  let ctx = CGContext(
    data: nil, width: 22 * scale, height: 16 * scale, bitsPerComponent: 8,
    bytesPerRow: 0, space: sRGB, bitmapInfo: rgba)!
  ctx.translateBy(x: 0, y: CGFloat(16 * scale))
  ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
  ctx.setFillColor(hex(0x000000))
  let tileSide: CGFloat = 6.3
  for origin in [point(4.75, 1), point(12.15, 1), point(4.25, 8.7), point(11.65, 8.7)] {
    let bounds = CGRect(x: 0, y: 0, width: tileSide, height: tileSide)
    var skew = CGAffineTransform(a: 1, b: 0, c: -0.09, d: 1, tx: origin.x, ty: origin.y)
    let tile = CGPath(roundedRect: bounds, cornerWidth: 1.7, cornerHeight: 1.7, transform: &skew)
    ctx.addPath(tile)
    ctx.fillPath()
  }
  clearPlus(in: ctx, center: point(14.5, 11.5))
  return ctx.makeImage()!
}

/// 在模板的右下格清出透底的加号，保证单倍像素下也有间隔。
func clearPlus(in ctx: CGContext, center: CGPoint) {
  let arm: CGFloat = 1.52
  ctx.setBlendMode(.clear)
  ctx.setLineCap(.round)
  ctx.setLineWidth(1.35)
  ctx.move(to: point(center.x - arm, center.y))
  ctx.addLine(to: point(center.x + arm, center.y))
  ctx.move(to: point(center.x, center.y - arm))
  ctx.addLine(to: point(center.x, center.y + arm))
  ctx.strokePath()
}

// MARK: 画布工具

/// 将十六进制颜色转换为绘制用的 sRGB。
func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(
    srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
    blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

/// 为 DMG 中的箭头绘制带圆角的三角形。
func triangle(_ ctx: CGContext, _ points: [CGPoint], _ color: CGColor, round: CGFloat) {
  let path = CGMutablePath()
  path.addLines(between: points)
  path.closeSubpath()
  ctx.setFillColor(color)
  ctx.setStrokeColor(color)
  ctx.setLineWidth(round)
  ctx.setLineJoin(.round)
  ctx.addPath(path)
  ctx.drawPath(using: .fillStroke)
}

/// 在上方为原点的画布中取一点。
func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

// MARK: DMG 窗口背景（600 × 400 pt；访达里 App 在 (150, 205)、「应用程序」在 (450, 205)，见 build-dmg.sh）

func dmgBackground(scale: Int) -> CGImage {
  let brand = hex(0xFF4D7E)
  let ctx = CGContext(
    data: nil, width: 600 * scale, height: 400 * scale, bitsPerComponent: 8, bytesPerRow: 0,
    space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.translateBy(x: 0, y: CGFloat(400 * scale))
  ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
  // 奶油底，左上一团品牌粉、右下一团淡蓝紫
  ctx.setFillColor(cream)
  ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
  for (color, center, radii) in [
    (hex(0xFF4D7E, 0.15), point(30, 0), (20.0, 355.0)),
    (hex(0xC8D8FF, 0.3), point(600, 400), (0, 340)),
  ] {
    let glow = CGGradient(
      colorsSpace: sRGB, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(
      glow, startCenter: center, startRadius: radii.0, endCenter: center, endRadius: radii.1,
      options: .drawsBeforeStartLocation)
  }
  // 字标和两行说明：水平居中，y 是基线（上下翻转的画布里字形要再翻回来）
  func text(_ string: String, _ font: NSFont, _ color: CGColor, y: CGFloat) {
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: string,
        attributes: [
          .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = point((600 - CTLineGetTypographicBounds(line, nil, nil, nil)) / 2, y)
    CTLineDraw(line, ctx)
  }
  text("kimo-tools", .systemFont(ofSize: 24, weight: .bold), hex(0xD12A5F), y: 62.5)
  // 系统字体回退到的 .PingFangUITextSC 会把「」挤成半宽，这行直接用 PingFang SC 保持全宽
  text(
    "把左边的图标拖到「应用程序」文件夹，就装好了", NSFont(name: "PingFangSC-Regular", size: 13)!,
    hex(0x000000, 0.55), y: 86)
  text(
    "首次打开被拦下时：系统设置 › 隐私与安全 › 仍要打开", .systemFont(ofSize: 11), hex(0x000000, 0.45),
    y: 366)
  // 中间的虚点弧线：零长虚线 + 圆头 = 等弧长的圆点（直径 4、间距 11.1），末端圆角三角箭头
  let arc = CGMutablePath()
  arc.move(to: point(235, 211))
  arc.addQuadCurve(to: point(355, 213.5), control: point(302, 178))
  ctx.saveGState()
  ctx.setStrokeColor(brand)
  ctx.setLineWidth(4)
  ctx.setLineCap(.round)
  ctx.setLineDash(phase: 0, lengths: [0, 11.1])
  ctx.addPath(arc)
  ctx.strokePath()
  ctx.restoreGState()
  triangle(ctx, [point(362.4, 212.6), point(354.9, 204.3), point(351.1, 213.5)], brand, round: 4)
  return ctx.makeImage()!
}

/// 整张背景：访达按 1 pt 对 1 pt 从窗口左上角贴、不缩放，用户把窗口拉大时图外露白，所以画布做大。
/// 设计区（上面 600 × 400 那张）逐像素原样贴在左上角——直接画在大画布上，CG 渐变的抖动按设备坐标走，会差 1 个色阶；
/// 外面是奶油底 + 右下那团淡蓝紫光的自然延续（圆心就在设计区右下角），逐像素算、不抖动，纯色段长，压缩后只多一百来 KB。
/// ponytail: 画布 2560 × 1600 pt 盖住 Apple 各屏默认分辨率下的全屏窗口（Pro Display XDR 的 3008 × 1692 除外），
/// 再大的窗口右 / 下还会露白；要盖就加大这里（访达 @2x 解码内存按面积涨，现在约 65 MB）
let dmgCanvas = (width: 2560, height: 1600)

func dmgCanvasImage(scale: Int) -> CGImage {
  let (width, height) = (dmgCanvas.width * scale, dmgCanvas.height * scale)
  let ctx = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!  // 本来就全不透明：不存 alpha，TIFF 小一截
  ctx.setFillColor(cream)
  ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
  // 和 dmgBackground 里那团光同参数：圆心 (600, 400)、半径 340、#C8D8FF 不透明度 0.3 → 0，叠在奶油底上
  let pixels = ctx.data!.assumingMemoryBound(to: UInt8.self)  // 第 0 行是最上面一行
  let (base, tint): ([Double], [Double]) = ([0xFF, 0xF5, 0xF0], [0xC8, 0xD8, 0xFF])
  let s = Double(scale)
  for y in Int(60 * s)..<Int(740 * s) {
    for x in Int(260 * s)..<Int(940 * s) {
      let r = hypot((Double(x) + 0.5) / s - 600, (Double(y) + 0.5) / s - 400)
      let alpha = 0.3 * max(0, 1 - r / 340)
      for c in 0..<3 {
        let value = base[c] + (tint[c] - base[c]) * alpha
        pixels[y * ctx.bytesPerRow + x * 4 + c] = UInt8(value.rounded())
      }
    }
  }
  // CG 坐标原点在左下：设计区贴到最上面
  ctx.draw(
    dmgBackground(scale: scale),
    in: CGRect(x: 0, y: height - 400 * scale, width: 600 * scale, height: 400 * scale))
  return ctx.makeImage()!
}

// MARK: 写文件

func writePNG(_ image: CGImage, to url: URL) {
  let rep = NSBitmapImageRep(cgImage: image)
  rep.size = NSSize(width: image.width, height: image.height)
  try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let artwork = logoImage(at: macos.appending(path: "Config/brand-logo.png"))
let assets = macos.appending(path: "KittyTools/Resources/Assets.xcassets")
let appIconSet = assets.appending(path: "AppIcon.appiconset")
for (points, scale) in [
  (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
] {
  let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
  writePNG(appIcon(artwork, pixels: points * scale), to: appIconSet.appending(path: name))
}
let statusSet = assets.appending(path: "StatusIcon.imageset")
try! FileManager.default.createDirectory(at: statusSet, withIntermediateDirectories: true)
writePNG(statusIcon(scale: 1), to: statusSet.appending(path: "StatusIcon.png"))
writePNG(statusIcon(scale: 2), to: statusSet.appending(path: "StatusIcon@2x.png"))
try! """
{
  "images" : [
    { "filename" : "StatusIcon.png", "idiom" : "mac", "scale" : "1x" },
    { "filename" : "StatusIcon@2x.png", "idiom" : "mac", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}

""".write(to: statusSet.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
// DMG 背景：@1x、@2x 两张合进一个 TIFF（dpi 72 / 144，访达按屏幕倍率挑）。用 ImageIO 写 Deflate：
// 画布大半是纯色，NSBitmapImageRep 只有 LZW，每条带都从头建字典，同一张图大 60%
let dmg = CGImageDestinationCreateWithURL(
  macos.appending(path: "Config/dmg-background.tiff") as CFURL, "public.tiff" as CFString, 2, nil)!
for scale in [1, 2] {
  CGImageDestinationAddImage(
    dmg, dmgCanvasImage(scale: scale),
    [
      kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale,
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 8],  // 8 = Adobe Deflate
    ] as CFDictionary)
}
precondition(CGImageDestinationFinalize(dmg))
print("已写入 AppIcon 10 张、StatusIcon @1x / @2x、DMG 背景 @1x / @2x")

// 预览：大图原样，小图按像素放大 8 倍（不插值），菜单栏放在浅 / 深两条栏上
if CommandLine.arguments.count > 1 {
  let preview = URL(fileURLWithPath: CommandLine.arguments[1])
  try! FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
  writePNG(appIcon(artwork, pixels: 1024), to: preview.appending(path: "icon-1024.png"))
  writePNG(dmgBackground(scale: 2), to: preview.appending(path: "dmg-background@2x.png"))
  func magnify(_ image: CGImage, _ factor: Int, background: CGColor?) -> CGImage {
    let ctx = CGContext(
      data: nil, width: image.width * factor, height: image.height * factor, bitsPerComponent: 8,
      bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if let background {
      ctx.setFillColor(background)
      ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    }
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    return ctx.makeImage()!
  }
  writePNG(
    magnify(appIcon(artwork, pixels: 16), 16, background: hex(0xF4EFF1)),
    to: preview.appending(path: "icon-16-x16.png"))
  writePNG(
    magnify(appIcon(artwork, pixels: 32), 8, background: hex(0xF4EFF1)),
    to: preview.appending(path: "icon-32-x8.png"))
  writePNG(
    magnify(appIcon(artwork, pixels: 64), 4, background: hex(0xF4EFF1)),
    to: preview.appending(path: "icon-64-x4.png"))
  for (scale, factor) in [(1, 16), (2, 8)] {
    writePNG(
      magnify(statusIcon(scale: scale), factor, background: hex(0xF4EFF1)),
      to: preview.appending(path: "status-\(scale)x.png"))
  }
}
