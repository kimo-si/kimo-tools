// 改编自 Mac Duo（Copyright 2026 Makito，Apache-2.0）。出处与许可见 Resources/mac-duo-LICENSE.txt。
import Foundation

/// Turns the sensor's 10 Hz steps into a value that changes smoothly at the
/// display refresh rate.
///
/// Semi-implicit Euler stays stable while `frequency * dt` is below 2. The
/// caller clamps `dt`.
struct LidDepthSpring {
  var value: Double
  var velocity: Double = 0

  /// Radians per second. Higher follows the target faster and smooths less.
  var frequency: Double = 16

  // 以当前读数开始插值。
  init(value: Double = 0) {
    self.value = value
  }

  // 按照屏幕实际帧间隔推进阻尼弹簧。
  mutating func advance(to target: Double, dt: Double) {
    let acceleration = frequency * frequency * (target - value) - 2 * frequency * velocity
    velocity += acceleration * dt
    value += velocity * dt
  }

  // 切换动效时清空速度和旧位置。
  mutating func reset(to newValue: Double) {
    value = newValue
    velocity = 0
  }
}
