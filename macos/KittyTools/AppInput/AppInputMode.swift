// 从目标输入法的状态栏识别中英文状态，必要时发送一次 Shift。

import AppKit
import ApplicationServices
import Carbon.HIToolbox

nonisolated enum AppInputMode {
  private static let attributes = [
    kAXIdentifierAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute,
  ]
  private static let modifiers: CGEventFlags = [
    .maskShift, .maskControl, .maskAlternate, .maskCommand,
  ]

  /// 只在读到明确且一致的状态标记时返回中或英，优先认搜狗的图标标识。
  static func language(from signals: [String]) -> AppInputLanguage? {
    let markers = signals.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    let sogou = markers.compactMap(sogouLanguage)
    let modes = sogou.isEmpty ? markers.compactMap(indicatorLanguage) : sogou
    guard let first = modes.first, modes.allSatisfy({ $0 == first }) else { return nil }
    return first
  }

  /// 识别搜狗状态栏图片的 AX 标识。
  private static func sogouLanguage(_ text: String) -> AppInputLanguage? {
    if text.contains("statusmodecn") { return .chinese }
    if text.contains("statusmodeen") { return .english }
    return nil
  }

  /// 只认状态文本，跳过静态应用名和「切换至」一类操作名称。
  private static func indicatorLanguage(_ text: String) -> AppInputLanguage? {
    switch text {
    case "中", "中文", "cn", "chinese mode", "中文模式", "当前：中文", "当前: 中文": .chinese
    case "a", "英", "英文", "en", "english mode", "英文模式", "当前：英文", "当前: 英文": .english
    default: nil
    }
  }

  /// 在主线程外读取输入法自己的状态元素。IPC 卡住时在限定时间内放弃。
  @concurrent static func read(pid: pid_t) async -> AppInputLanguage? {
    let app = AXUIElementCreateApplication(pid)
    let deadline = ContinuousClock.now + .milliseconds(125)
    var pending = [(app, 0)]
    var markers: [String] = []
    var visited = 0
    AXUIElementSetMessagingTimeout(app, 0.025)
    if let menu = attribute(app, kAXMenuBarAttribute), CFGetTypeID(menu) == AXUIElementGetTypeID() {
      pending.append((menu as! AXUIElement, 0))
    }
    while !pending.isEmpty, visited < 24, !Task.isCancelled, ContinuousClock.now < deadline {
      let (element, depth) = pending.removeFirst()
      visited += 1
      AXUIElementSetMessagingTimeout(element, 0.025)
      markers += attributes.compactMap { attribute(element, $0) as? String }
      if depth < 3, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
        pending.append(contentsOf: children.prefix(10).map { ($0, depth + 1) })
      }
    }
    return language(from: markers)
  }

  /// 读取单个 AX 属性，超时或没有该属性时返回空值。
  private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
  }

  /// 是否允许自动切换。系统保护的输入框保持原输入法和模式。
  static func canSwitch() -> Bool { !IsSecureEventInputEnabled() }

  /// 发送一对原生 Shift 事件。取消时也发出抬键；保留用户正在按的修饰键。
  @MainActor static func toggle() async -> Bool {
    guard canSwitch(), CGPreflightPostEventAccess(),
      CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty,
      let down = shift(down: true), let up = shift(down: false)
    else { return false }
    down.post(tap: .cghidEventTap)
    defer { up.post(tap: .cghidEventTap) }
    try? await Task.sleep(for: .milliseconds(80))
    return !Task.isCancelled
  }

  /// 系统用 flagsChanged 表示修饰键按下和抬起。
  private static func shift(down: Bool) -> CGEvent? {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Shift), keyDown: down)
    event?.type = .flagsChanged
    event?.flags = down ? [.maskShift] : []
    return event
  }
}
