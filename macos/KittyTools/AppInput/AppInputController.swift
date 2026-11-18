// 插件启用期间监听前台 App，每次进入时应用一条输入法规则。

import AppKit

final class AppInputController {
  private let workspace = NSWorkspace.shared
  private var activationObserver: (any NSObjectProtocol)?
  private var pending: Task<Void, Never>?
  private var observedPID: pid_t?
  private var rules = AppInputRules("[]")
  private var rulesText: String?
  private var fallback = AppInputDefaults()

  /// 配置或移除插件。在没有规则时也撤掉监听。
  func configure(enabled: Bool, defaults: UserDefaults = .standard) {
    guard enabled else {
      rulesText = nil
      stop()
      return
    }
    let text = defaults.string(forKey: Prefs.appInputRules) ?? "[]"
    let configuration = Self.fallback(from: defaults)
    guard text != rulesText || configuration != fallback else { return }
    rulesText = text
    fallback = configuration
    rules = AppInputRules(text)
    guard !rules.values.isEmpty || fallback.target != nil else {
      stop()
      return
    }
    // 开始监听 App 激活，并应用当前前台 App 的规则。
    startObserving()
    schedule(for: workspace.frontmostApplication)
  }

  /// 把已同步的偏好解析为默认规则，兼容旧版的模式偏好。
  private static func fallback(from defaults: UserDefaults) -> AppInputDefaults {
    AppInputDefaults(
      sourceID: defaults.string(forKey: Prefs.appInputDefaultSource)
        ?? AppInputRule.keepCurrentSource,
      mode: .defaultMode(
        stored: defaults.string(forKey: Prefs.appInputDefaultMode) ?? "",
        legacyPrefersChinese: defaults.object(forKey: Prefs.appInputPrefersChinese) as? Bool ?? true
      ))
  }

  /// 取下监听并取消任何等待中的切换。
  private func stop() {
    pending?.cancel()
    pending = nil
    if let activationObserver { workspace.notificationCenter.removeObserver(activationObserver) }
    activationObserver = nil
    observedPID = nil
  }

  /// 在工作区通知里读取即将进入的应用，避免误用刚离开的前台 App。
  private func startObserving() {
    guard activationObserver == nil else { return }
    activationObserver = workspace.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: workspace, queue: .main
    ) { [weak self] note in
      guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      else { return }
      MainActor.assumeIsolated {
        guard let self, app.processIdentifier != self.observedPID else { return }
        self.schedule(for: app)
      }
    }
  }

  /// 取消上一个 App 的延迟操作，只处理当前 App 的规则。
  private func schedule(for app: NSRunningApplication?) {
    pending?.cancel()
    pending = nil
    observedPID = app?.processIdentifier
    guard let app, let target = rules.target(for: app.bundleIdentifier, defaults: fallback) else {
      return
    }
    let pid = app.processIdentifier
    pending = Task { [weak self] in
      await AppInputSwitch.system.run(target) {
        self?.workspace.frontmostApplication?.processIdentifier == pid
      }
    }
  }
}
