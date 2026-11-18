// 改编自 Mac Duo（Copyright 2026 Makito，Apache-2.0）。出处与许可见 Resources/mac-duo-LICENSE.txt。
import Foundation

/// How far out of focus the picture is at a given height, and how much light
/// it has lost. Height is 0 at the hinge edge and 1 at the far edge.
struct LidDepthGradient {

  /// Exponent on the closing travel. Values above 1 start slowly.
  var blurCurve: Double = 1.6

  /// Exponent on the closing travel for the dimming.
  var dimCurve: Double = 0.7

  /// Dimming at the hinge edge, as a fraction of the dimming at the far
  /// edge.
  var dimHingeFloor: Double = 0.2

  // 计算当前合盖行程的模糊强度。
  func blurStrength(progress: Double) -> Double {
    pow(min(max(progress, 0), 1), blurCurve)
  }

  // 计算当前合盖行程的渐暗强度。
  func dimStrength(progress: Double) -> Double {
    pow(min(max(progress, 0), 1), dimCurve)
  }
}
