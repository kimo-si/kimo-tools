// 应用输入法的偏好。按 bundle ID 保存输入源与输入法内部的中英文模式。

import Foundation

nonisolated struct AppInputRule: Codable, Equatable, Identifiable, Sendable {
  static let keepCurrentSource = ""

  enum Mode: String, Codable, CaseIterable, Sendable {
    case follow, unchanged, chinese, english
    static let defaultChoices: [Self] = [.unchanged, .chinese, .english]

    /// 设置页显示的选项。
    var title: String {
      switch self {
      case .follow: "跟随默认模式"
      case .unchanged: "保持当前模式"
      case .chinese: "中文"
      case .english: "英文"
      }
    }

    /// 解析需要切换到的输入法内部状态。
    func target(defaultLanguage: AppInputLanguage? = nil) -> AppInputLanguage? {
      switch self {
      case .follow: defaultLanguage
      case .unchanged: nil
      case .chinese: .chinese
      case .english: .english
      }
    }

    /// 沿用升级前的「优先中文」偏好，直到用户选定新的默认模式。
    static func defaultMode(stored: String, legacyPrefersChinese: Bool) -> Self {
      if let mode = Self(rawValue: stored), defaultChoices.contains(mode) { return mode }
      return legacyPrefersChinese ? .chinese : .unchanged
    }
  }

  let id: String
  var name: String
  var sourceID: String
  var mode: Mode = .follow
}

nonisolated enum AppInputLanguage: Equatable, Sendable {
  case chinese, english
}

/// 一次应用切换要选中的输入源和可选的内部语言模式。
nonisolated struct AppInputTarget: Equatable, Sendable {
  let sourceID: String
  let language: AppInputLanguage?
}

/// 所有应用的默认配置。空输入源表示未配置默认切换。
nonisolated struct AppInputDefaults: Equatable, Sendable {
  var sourceID = AppInputRule.keepCurrentSource
  var mode = AppInputRule.Mode.chinese

  /// 有默认输入法时，未配置的 App 才会自动切换。
  var target: AppInputTarget? {
    guard sourceID != AppInputRule.keepCurrentSource else { return nil }
    return AppInputTarget(sourceID: sourceID, language: mode.target())
  }
}

nonisolated struct AppInputRules: Equatable, Sendable {
  private(set) var values: [AppInputRule]

  /// 从设置读出规则，每个 bundle ID 取一条。
  init(_ json: String) {
    let decoded = (try? JSONDecoder().decode([AppInputRule].self, from: Data(json.utf8))) ?? []
    var seen: Set<String> = []
    values = decoded.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
  }

  /// 找到单个 App 的规则。
  func rule(for id: String) -> AppInputRule? { values.first { $0.id == id } }

  /// 优先使用 App 自己的规则，包括明确选择不自动切换的例外。
  func target(for id: String?, defaults: AppInputDefaults) -> AppInputTarget? {
    guard let id, let rule = rule(for: id) else { return defaults.target }
    guard rule.sourceID != AppInputRule.keepCurrentSource else { return nil }
    let language = rule.mode.target(defaultLanguage: defaults.mode.target())
    return AppInputTarget(sourceID: rule.sourceID, language: language)
  }

  /// 新增或更新规则，按稳定顺序编码供设置同步。
  mutating func save(_ rule: AppInputRule) {
    remove(rule.id)
    values.append(rule)
    values.sort { $0.id < $1.id }
  }

  /// 去除单个 App 的规则。
  mutating func remove(_ id: String) { values.removeAll { $0.id == id } }

  /// 把当前规则列表编码为偏好字符串。
  func encoded() -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(values)).map { String(decoding: $0, as: UTF8.self) }
  }
}
