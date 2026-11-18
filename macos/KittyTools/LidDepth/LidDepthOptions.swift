// 合盖效果的偏好读取、取值范围和原始默认值。

import Foundation

struct LidDepthOptions: Equatable {
  let enabled: Bool
  let live: Bool
  let timeout: Bool
  let thresholdAngle: Double
  let blurSpan: Double
  let tuning: DepthTuning

  enum Setting: CaseIterable {
    case angle, span, blur, blurSpread, dim, dimSpread, lean, perspective

    var key: String {
      switch self {
      case .angle: Prefs.lidDepthAngle
      case .span: Prefs.lidDepthSpan
      case .blur: Prefs.lidDepthBlur
      case .blurSpread: Prefs.lidDepthBlurSpread
      case .dim: Prefs.lidDepthDim
      case .dimSpread: Prefs.lidDepthDimSpread
      case .lean: Prefs.lidDepthLean
      case .perspective: Prefs.lidDepthPerspective
      }
    }

    var range: ClosedRange<Double> {
      switch self {
      case .angle: 5...130
      case .span: 5...60
      case .blur: 10...160
      case .blurSpread, .dim, .perspective: 0...1
      case .dimSpread: 0.2...1
      case .lean: 0...3
      }
    }

    var defaultValue: Double {
      switch self {
      case .angle: 90
      case .span: 60
      case .blur: 135
      case .blurSpread, .perspective: 0
      case .dim, .lean: 1
      case .dimSpread: 0.5
      }
    }

    // 导入或同步来的旧值也走范围校验。
    func clamped(_ value: Double) -> Double {
      guard value.isFinite else { return defaultValue }
      return min(max(value, range.lowerBound), range.upperBound)
    }
  }

  static let defaultEnabled = true
  static let defaultLive = true
  static let defaultTimeout = false
  private static let farthestEye = 6.0
  private static let nearestEye = 1.0

  static var defaults: [String: Any] {
    var values = Dictionary(
      uniqueKeysWithValues: Setting.allCases.map { ($0.key, $0.defaultValue as Any) })
    values[Prefs.lidDepthEnabled] = defaultEnabled
    values[Prefs.lidDepthLive] = defaultLive
    values[Prefs.lidDepthTimeout] = defaultTimeout
    return values
  }

  // 读取完整的一组参数，使每次合盖使用经过校验的参数。
  init(_ defaults: UserDefaults = .standard) {
    // 未注册默认值的临时偏好域也可以读取。
    func value(_ setting: Setting) -> Double {
      setting.clamped(defaults.object(forKey: setting.key) as? Double ?? setting.defaultValue)
    }
    enabled = defaults.object(forKey: Prefs.lidDepthEnabled) as? Bool ?? Self.defaultEnabled
    live = defaults.object(forKey: Prefs.lidDepthLive) as? Bool ?? Self.defaultLive
    timeout = defaults.object(forKey: Prefs.lidDepthTimeout) as? Bool ?? Self.defaultTimeout
    thresholdAngle = value(.angle)
    blurSpan = value(.span)
    tuning = DepthTuning(
      viewingDistance: Self.farthestEye + (Self.nearestEye - Self.farthestEye)
        * value(.perspective),
      recession: value(.lean), blurEvenness: value(.blurSpread), dimReach: value(.dimSpread),
      maxBlurRadius: value(.blur), maxDim: value(.dim))
  }

  // 恢复效果参数，保留插件的添加状态。
  static func reset(_ defaults: UserDefaults = .standard) {
    for key in Self.defaults.keys { defaults.removeObject(forKey: key) }
  }
}
