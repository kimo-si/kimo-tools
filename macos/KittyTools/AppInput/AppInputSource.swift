// 从 Carbon Text Input Sources 枚举和选择已启用的键盘输入源。

import Carbon
import Foundation
import OSLog

struct AppInputSource: Identifiable {
  let id: String
  let name: String
  let modeOwner: String?

  /// 给出目前可用且能切换到的输入源。
  static func available() -> [AppInputSource] {
    sources().compactMap(describe).sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  /// 按保存的系统 ID 查找输入源，并读出其中文模式支持信息。
  static func find(_ id: String) -> AppInputSource? {
    sources(id: id).first.flatMap(describe)
  }

  /// 读取当前生效的输入源，供切换后确认。
  static func currentID() -> String? {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
    return property(source, kTISPropertyInputSourceID)
  }

  /// 选中仍然可用的输入源。
  static func select(_ id: String) {
    guard let source = sources(id: id).first else { return }
    if TISSelectInputSource(source) != noErr { Log.appInput.debug("输入源选择失败") }
  }

  /// 系统查询过滤到已启用、可选中的键盘输入源。
  private static func sources(id: String? = nil) -> [TISInputSource] {
    var filters: [String: Any] = [
      kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
      kTISPropertyInputSourceIsSelectCapable as String: true,
    ]
    if let id { filters[kTISPropertyInputSourceID as String] = id }
    return TISCreateInputSourceList(filters as CFDictionary, false)?.takeRetainedValue()
      as? [TISInputSource] ?? []
  }

  /// 只给中文输入法查找模式进程，键盘布局只需切换输入源。
  private static func describe(_ source: TISInputSource) -> AppInputSource? {
    guard let id = property(source, kTISPropertyInputSourceID) else { return nil }
    let name = property(source, kTISPropertyLocalizedName) ?? id
    let kind = property(source, kTISPropertyInputSourceType)
    let languages =
      TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages).flatMap {
        Unmanaged<CFArray>.fromOpaque($0).takeUnretainedValue() as? [String]
      } ?? []
    let modeOwner =
      kind != kTISTypeKeyboardLayout as String && languages.contains(where: { $0.hasPrefix("zh") })
      ? property(source, kTISPropertyBundleID) : nil
    return AppInputSource(id: id, name: name, modeOwner: modeOwner)
  }

  /// TIS 的属性由输入源持有，只借用对象再转为 Swift 字符串。
  private static func property(_ source: TISInputSource, _ key: CFString) -> String? {
    TISGetInputSourceProperty(source, key).map {
      Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
    }
  }
}
