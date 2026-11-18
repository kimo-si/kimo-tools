// 改编自 Mac Duo（Copyright 2026 Makito，Apache-2.0）。出处与许可见 Resources/mac-duo-LICENSE.txt。
import Foundation

struct LidMotionIntent {
  private(set) var lastMovedDownTime: TimeInterval = -Double.greatestFiniteMagnitude

  // 记录明显的合盖动作，反向打开时清掉。
  mutating func update(
    angularVelocity: Double,
    at now: TimeInterval,
    closingSpeed: Double,
    openingSpeed: Double
  ) {
    if angularVelocity >= openingSpeed {
      // Opening is an intentional reversal, so an earlier close must not
      // be reused to start the effect again near the threshold.
      lastMovedDownTime = -Double.greatestFiniteMagnitude
    } else if angularVelocity <= -closingSpeed {
      lastMovedDownTime = now
    }
  }

  // 只接受时间窗口内的合盖动作。
  func wasClosingRecently(at now: TimeInterval, memoryDuration: TimeInterval) -> Bool {
    now - lastMovedDownTime < memoryDuration
  }

  // 清掉上一次合盖动作。
  mutating func reset() {
    lastMovedDownTime = -Double.greatestFiniteMagnitude
  }
}

/// How long the lid has stayed opened back above the start angle.
struct LidOpenDwell {
  private(set) var since: TimeInterval?

  // 记录停在起效角度之上的起始时间。
  mutating func update(angle: Double, at now: TimeInterval, dwellAngle: Double) {
    if angle >= dwellAngle {
      if since == nil { since = now }
    } else {
      since = nil
    }
  }

  // 判断打开后是否已在起效角度上停足够久。
  func hasDwelled(at now: TimeInterval, duration: TimeInterval) -> Bool {
    guard let since else { return false }
    return now - since >= duration
  }

  // 睡眠、预览结束或状态变化时清掉打开停留。
  mutating func reset() {
    since = nil
  }
}

struct LidDepthPolicy {
  let threshold: Double
  let hysteresis: Double

  /// A lid held at or above this angle has been opened again, even when
  /// threshold + hysteresis is past what the hinge can reach. The threshold
  /// itself, so a hinge whose limit rounds to the threshold still releases.
  var dwellAngle: Double { threshold }

  /// How far the lid must have risen above its lowest reading of the run
  /// before opening speed alone releases the effect. A sensor that reports
  /// whole degrees moves in 1° steps, and one step over a sensor refresh
  /// already reads as fast opening. A lid resting on a half-degree boundary
  /// alternates between two readings, and this keeps that from flapping the
  /// effect on and off.
  static let minimumReleaseRise: Double = 1.5

  // 结合动向、滞回和停留时间，判断是否应触发或结束。
  func wantsEffect(
    isEnabled: Bool,
    isActive: Bool,
    angle: Double,
    predictedAngle: Double,
    riseSinceLowest: Double,
    hasBeenAboveThreshold: Bool,
    wasClosingRecently: Bool,
    isClearlyOpening: Bool,
    hasDwelledOpen: Bool,
    minimumDurationElapsed: Bool
  ) -> Bool {
    guard isEnabled else { return false }

    if isActive {
      // Deliberately opening back across the configured start angle is
      // sufficient to recover even when threshold + hysteresis cannot
      // be reached by the hardware. The rise rules out a single
      // whole-degree step; a smaller opening releases through the dwell.
      if isClearlyOpening, angle >= threshold, riseSinceLowest >= Self.minimumReleaseRise {
        return false
      }

      // An opening slower than that still ends with the lid held above
      // the start angle, which releases it too.
      if hasDwelledOpen { return false }

      // Keep the ordinary release hysteresis for stationary readings and
      // sensor jitter around the start angle.
      guard minimumDurationElapsed else { return true }
      return angle < threshold + hysteresis
    }

    // A resting or opening lid below the threshold must not start the
    // effect, including while an older closing observation is remembered.
    return hasBeenAboveThreshold
      && wasClosingRecently
      && !isClearlyOpening
      && predictedAngle <= threshold
  }
}
