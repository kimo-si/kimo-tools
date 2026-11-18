// 应用激活时先确认输入源，再把同一个输入法调整到规则指定的内部状态。

import AppKit
import OSLog

struct AppInputSwitch {
  var currentSource: @MainActor () -> String?
  var source: @MainActor (String) -> AppInputSource?
  var select: @MainActor (String) -> Void
  var canSwitch: @MainActor () -> Bool
  var readMode: @MainActor (String) async -> AppInputLanguage?
  var toggleMode: @MainActor () async -> Bool
  var wait: @MainActor (Duration) async -> Void

  static let system = AppInputSwitch(
    currentSource: AppInputSource.currentID, source: AppInputSource.find,
    select: AppInputSource.select, canSwitch: AppInputMode.canSwitch,
    readMode: probeMode, toggleMode: AppInputMode.toggle,
    wait: { try? await Task.sleep(for: $0) })

  /// 等 App 稳定为前台后切换一次，只对仍在前台的应用继续处理。
  func run(_ target: AppInputTarget, frontmost: @escaping @MainActor () -> Bool) async {
    let active = { !Task.isCancelled && frontmost() && canSwitch() }
    await wait(.milliseconds(80))
    guard active(), let inputSource = source(target.sourceID) else { return }
    // macOS 可能在窗口刚切换时回写输入源，确认实际生效后才能操作内部模式。
    guard await selectSource(inputSource.id, active: active),
      let owner = inputSource.modeOwner, let language = target.language
    else { return }
    await setMode(language, owner: owner) { active() && currentSource() == inputSource.id }
  }

  /// 有限重试系统输入源切换；确认后不持续锁定。
  private func selectSource(_ id: String, active: () -> Bool) async -> Bool {
    for attempt in 0..<3 {
      guard active() else { return false }
      if currentSource() == id { return true }
      select(id)
      await wait(.milliseconds(95 + 75 * attempt))
    }
    return active() && currentSource() == id
  }

  /// 只有明确读到相反状态才切换，验证结果失败时最多再切一次。
  private func setMode(_ desired: AppInputLanguage, owner: String, active: () -> Bool) async {
    var toggles = 0
    for _ in 0..<4 {
      guard active() else { return }
      let current = await readMode(owner)
      guard active(), current != desired else { return }
      if current != nil {
        guard toggles < 2, await toggleMode() else { break }
        toggles += 1
      }
      await wait(.milliseconds(current == nil ? 110 : 300))
    }
    Log.appInput.debug("输入法内部模式未确认")
  }

  /// 根据输入源的 bundle ID 找后台输入法进程，AX 查询在后台执行。
  private static func probeMode(owner: String) async -> AppInputLanguage? {
    guard Permissions.isAccessibilityTrusted,
      let pid = NSRunningApplication.runningApplications(withBundleIdentifier: owner).first?
        .processIdentifier
    else { return nil }
    return await AppInputMode.read(pid: pid)
  }
}
