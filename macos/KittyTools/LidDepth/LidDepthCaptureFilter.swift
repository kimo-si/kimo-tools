// 为合盖动效选择内建屏幕，排除 Kitty Tools 的窗口以免抓回渲染结果。

import AppKit
import ScreenCaptureKit

extension NSScreen {
  /// 合盖只影响内建屏幕。
  static var lidDepthBuiltIn: NSScreen? {
    screens.first { $0.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false }
  }
}

final class LidDepthCaptureFilter {
  private var filter: SCContentFilter?
  private var displayID: CGDirectDisplayID?
  private var captureAnchor: NSPanel?

  // 实时取画和静态取画使用同一过滤规则，授权在进入 ScreenCaptureKit 之前检查。
  func current() async throws -> SCContentFilter? {
    guard !Task.isCancelled, Permissions.isScreenRecordingAllowed, !InputBlock.isSessionAway,
      let target = NSScreen.lidDepthBuiltIn?.displayID
    else { return nil }
    if let filter, displayID == target { return filter }
    // 隐藏菜单栏图标时，系统可能不会列出本 App。用透明锚点注册本进程。
    ensureCaptureAnchor()
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard !Task.isCancelled, NSScreen.lidDepthBuiltIn?.displayID == target,
      let display = content.displays.first(where: { $0.displayID == target }),
      let ownApp = content.applications.first(where: {
        $0.processID == ProcessInfo.processInfo.processIdentifier
      })
    else { return nil }
    let result = SCContentFilter(
      display: display, excludingApplications: [ownApp], exceptingWindows: [])
    filter = result
    displayID = target
    return result
  }

  // 取画结束后收起只用于注册进程的窗口，屏幕变化时另清过滤器。
  func releaseAnchor() {
    captureAnchor?.close()
    captureAnchor = nil
  }

  // 下次取画时重新查当前显示器。
  func invalidate() {
    releaseAnchor()
    filter = nil
    displayID = nil
  }

  // 继承 Mac Duo 按进程排除的做法，锚点只在需要枚举时存在。
  private func ensureCaptureAnchor() {
    guard captureAnchor == nil, let screen = NSScreen.lidDepthBuiltIn else { return }
    let panel = NSPanel(
      contentRect: NSRect(origin: screen.frame.origin, size: NSSize(width: 1, height: 1)),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = .statusBar
    panel.collectionBehavior = [
      .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
    ]
    panel.alphaValue = 0.004
    panel.orderFrontRegardless()
    captureAnchor = panel
  }

  // 两种画面来源都以屏幕的原始像素尺寸取画。
  static func configuration(for filter: SCContentFilter) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
    configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
    configuration.showsCursor = false
    configuration.scalesToFit = false
    return configuration
  }
}
