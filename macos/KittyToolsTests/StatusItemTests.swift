import AppKit
import SwiftUI
import Testing

@testable import KittyTools

/// 第 9 批：菜单栏图标可隐藏（M1）、可选彩色（M2）；第四轮体检 U12①：只有真的 ⌃点才弹菜单。不建真的 StatusItem（会往菜单栏里插一个图标），
/// 只测偏好默认值、样式 → 图片、彩色图标的出图和启动器里的「退出」；不写用户的偏好
struct StatusItemTests {
  /// 默认显示、单色（只读注册域）；没存过、认不得的样式都回落单色
  @Test func prefsDefaultToVisibleTemplate() {
    Prefs.registerDefaults()
    let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
    #expect(registered[Prefs.statusItemVisible] as? Bool == true)
    #expect(registered[Prefs.statusItemStyle] as? String == "template")
    #expect(StatusItem.IconStyle(pref: nil) == .template)
    #expect(StatusItem.IconStyle(pref: "rainbow") == .template)
    #expect(StatusItem.IconStyle(pref: "color") == .color)
    #expect(StatusItem.IconStyle.allCases.map(\.title) == ["单色", "彩色"])
  }

  /// 单色模板和彩色图都有原有的点数、缩放行为和读屏名称。
  @Test func styleImages() throws {
    let template = try #require(StatusItem.IconStyle.template.image)
    #expect(template.isTemplate && template.accessibilityDescription == "kimo-tools")
    #expect(template.size == NSSize(width: 22, height: 16))
    let color = try #require(StatusItem.IconStyle.color.image)
    #expect(!color.isTemplate && color.accessibilityDescription == "kimo-tools")
    #expect(color.size == NSSize(width: 16, height: 16))
    #expect(color.representations.map(\.pixelsWide) == [16, 32])
    // 只画一次
    #expect(StatusItem.IconStyle.color.image === color)
  }

  /// 彩色从最大表示缩放，32 px 的小表示不会覆盖 1024 px 源图。
  @Test func colorIconUsesLargeRepresentation() throws {
    let icon = NSImage(size: NSSize(width: 32, height: 32))
    icon.addRepresentation(Self.solid(.red, pixels: 32))
    icon.addRepresentation(Self.solid(.green, pixels: 1024))
    let rep = try #require(
      StatusItem.menuBarImage(from: icon).representations.last as? NSBitmapImageRep)
    let center = try #require(rep.colorAt(x: 16, y: 16)?.usingColorSpace(.sRGB))
    #expect(center.greenComponent > 0.9 && center.redComponent < 0.1)
  }

  /// 彩色版保留原图的透明圆角、蓝紫渐变、浅色格子和右下加号。
  @Test func colorIconIsTheWholeAppIcon() throws {
    let rep = try #require(StatusItem.colorIcon.representations.last as? NSBitmapImageRep)
    #expect(rep.pixelsWide == 32 && rep.pixelsHigh == 32)
    let pixel = { (x: Int, y: Int) in rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) }
    for (x, y) in [(0, 0), (31, 0), (0, 31), (31, 31)] {
      #expect((pixel(x, y)?.alphaComponent ?? 1) < 0.05, "角 \(x),\(y)")
    }
    let blue = try #require(pixel(13, 1))
    #expect(blue.alphaComponent > 0.9 && blue.blueComponent > 0.8 && blue.redComponent < 0.4)
    let violet = try #require(pixel(28, 26))
    #expect(violet.alphaComponent > 0.9 && violet.blueComponent > 0.8 && violet.redComponent > 0.45)
    let tile = try #require(pixel(10, 10))
    #expect(tile.redComponent > 0.8 && tile.greenComponent > 0.8 && tile.blueComponent > 0.85)
    let plus = try #require(pixel(20, 21))
    #expect(plus.redComponent > 0.8 && plus.greenComponent > 0.8 && plus.blueComponent > 0.85)
  }

  /// 什么时候弹菜单（U12①）：当前事件是鼠标事件时——右键、左键点并带 ⌃；读屏「按下」、键盘导航（当前事件是按键，
  /// 读屏的组合键带 ⌃）是左键的意思（开主界面）。当前事件不是鼠标事件（macOS 27 的菜单栏在进程外）时看此刻：
  /// 鼠标键按着、⌃ 也按着才算 ⌃点
  @Test func onlyRealControlClicksShowTheMenu() {
    func menu(
      _ type: NSEvent.EventType?, _ flags: NSEvent.ModifierFlags, pressed: Int = 0,
      held: NSEvent.ModifierFlags = []
    ) -> Bool {
      StatusItem.showsMenu(type: type, flags: flags, pressedButtons: pressed, held: held)
    }
    #expect(menu(.rightMouseUp, []))
    #expect(menu(.rightMouseDown, .control))
    #expect(menu(.leftMouseUp, .control))
    #expect(menu(.leftMouseDown, [.control, .option]))
    #expect(!menu(.leftMouseUp, []))
    // 鼠标事件以事件上的修饰键为准，不看此刻
    #expect(!menu(.leftMouseUp, [], pressed: 1, held: .control))
    // 读屏 / 键盘：鼠标键没按着，⌃ 按着也不算
    #expect(!menu(.keyDown, [.control, .option], held: [.control, .option]))
    #expect(!menu(nil, .control, held: .control))
    // 拿不到那一下点击：此刻鼠标键和 ⌃ 都按着才算
    #expect(menu(.appKitDefined, [], pressed: 1, held: .control))
    #expect(menu(nil, [], pressed: 1, held: [.control]))
    #expect(!menu(nil, [], pressed: 1, held: []))
    #expect(!menu(.systemDefined, [], pressed: 0, held: .control))
  }

  /// 启动器内置动作最后是「退出 Kitty Tools」（菜单栏图标隐藏时只剩这里能退出），符号 power、通用家族灰
  /// 「有新版本」的小圆点压在图标右上角、不出按钮：两种图标（22 × 16 剪影、16 × 16 彩色）、按钮翻不翻转都一样
  @Test func updateBadgeSitsOnIconCorner() {
    let bounds = NSRect(x: 0, y: 0, width: 24, height: 22)
    for icon in [NSSize(width: 22, height: 16), NSSize(width: 16, height: 16)] {
      let flipped = StatusItem.badgeFrame(icon: icon, in: bounds, flipped: true)
      let upright = StatusItem.badgeFrame(icon: icon, in: bounds, flipped: false)
      #expect(bounds.contains(flipped) && bounds.contains(upright))
      #expect(flipped.size == NSSize(width: 6, height: 6) && flipped.minX == upright.minX)
      #expect(flipped.midX > bounds.midX + icon.width / 2 - 6)
      // 上边：翻转坐标里 y 小，不翻转时 y 大
      #expect(flipped.midY < bounds.midY && upright.midY > bounds.midY)
    }
  }

  @Test func launcherCanQuit() throws {
    let quit = try #require(LauncherItem.actions().last)
    #expect(quit.target == "quit" && quit.title == "退出 kimo-tools" && quit.symbol == "power")
    #expect(MenuExtra.quit.color == Style.Family.general && MenuExtra.quit.section == nil)
    #expect(
      LauncherMatch.score("quit", item: quit) > 0 && LauncherMatch.score("tuichu", item: quit) > 0)
    #expect(
      LauncherItem.actions(.init(checksUpdates: true)).suffix(2).map(\.target) == [
        "updates", "quit",
      ])
    // 图标隐藏后搜「Kitty Tools」是想回设置：App 那一行要比「退出 Kitty Tools」「关于 Kitty Tools」排得靠前
    let app = AppCatalog.item(path: "/Applications/kimo-tools.app")
    for query in ["kimo", "kimo-tools", "KIMO-TOOLS"] {
      #expect(
        LauncherMatch.score(query, item: app) > LauncherMatch.score(query, item: quit), "\(query)")
    }
  }

  /// 「退出 Kitty Tools」↩ 不确认、不记使用：同分时排在系统命令和 App 后面——「退出」「tuichu」先是要再按一次确认的
  /// 「全部退出」，「qu」「qui」先是标题更长的 QuickTime Player（假路径，只看名字）
  @Test func quitRanksLastOnTies() throws {
    let quit = try #require(LauncherItem.actions().last)
    let quickTime = AppCatalog.item(path: "/Applications/QuickTime Player.app")
    let items = [quit, quickTime] + SystemCommands.items
    let expected = [
      ("退出", "quitall"), ("tuichu", "quitall"), ("qu", quickTime.target), ("qui", quickTime.target),
    ]
    for (query, first) in expected {
      let ranked = LauncherMatch.rank(items, query: query) { _ in (0, 0) }
      #expect(ranked.first?.target == first, "\(query)")
      #expect(ranked.contains { $0.target == "quit" }, "\(query)")
    }
  }

  /// 设置侧栏搜「菜单栏」「状态栏」「图标」「隐藏」「彩色」都能到通用页
  @Test func sidebarSearchFindsMenuBarIcon() {
    for word in ["菜单栏", "状态栏", "图标", "隐藏", "彩色"] {
      #expect(SettingsPage.general.matches(word), "\(word)")
    }
  }

  private static func solid(_ color: NSColor, pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    color.setFill()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
    NSGraphicsContext.restoreGraphicsState()
    rep.size = NSSize(width: 32, height: 32)
    return rep
  }
}
