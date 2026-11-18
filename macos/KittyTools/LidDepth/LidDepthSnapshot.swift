// 改编自 Mac Duo（Copyright 2026 Makito，Apache-2.0）。出处与许可见 Resources/mac-duo-LICENSE.txt。
// 静态模式保留触发前的最近一帧，实时模式在首帧未到时也可以用它铺底。

import AppKit
import OSLog
import ScreenCaptureKit

final class LidDepthSnapshot {
  private let source: LidDepthCaptureFilter
  private var inFlight: Task<Void, Never>?
  private var timer: Timer?
  private(set) var latestImage: CGImage?
  private(set) var latestScreen: NSScreen?

  // 实时流和快照共用内建屏幕过滤器。
  init(source: LidDepthCaptureFilter) { self.source = source }

  // 仅在合盖移动期间保留预取的静态帧。
  func beginPrewarm(interval: TimeInterval) {
    guard timer == nil else { return }
    startCapture()
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.startCapture() }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  // 动效开始后冻结画面，保留已在途的一帧。
  func endPrewarm() {
    timer?.invalidate()
    timer = nil
  }

  // 用户移除插件、锁屏或结束动效后停止取画并释放像素。
  func stop() {
    endPrewarm()
    inFlight?.cancel()
    inFlight = nil
    latestImage = nil
    latestScreen = nil
  }

  // 等预取中的一帧，没有时立即截取。
  func captureOnce() async {
    startCapture()
    await inFlight?.value
  }

  // 每次只保留一个在途的截图任务。
  private func startCapture() {
    guard inFlight == nil else { return }
    inFlight = Task { [weak self] in
      await self?.capture()
      guard !Task.isCancelled else { return }
      self?.inFlight = nil
    }
  }

  // 校验屏幕仍存在，避免合盖进入外接显示器模式时沿用旧画面。
  private func capture() async {
    do {
      guard let screen = NSScreen.lidDepthBuiltIn, let filter = try await source.current() else {
        return
      }
      let configuration = LidDepthCaptureFilter.configuration(for: filter)
      configuration.captureResolution = .best
      let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: configuration)
      guard !Task.isCancelled, screen.displayID == NSScreen.lidDepthBuiltIn?.displayID else {
        return
      }
      latestImage = image
      latestScreen = screen
    } catch {
      guard !Task.isCancelled else { return }
      LidDepthLog.capture.debug("静态取画失败：\(String(describing: error), privacy: .public)")
    }
  }
}
