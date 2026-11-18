// 改编自 Mac Duo（Copyright 2026 Makito，Apache-2.0）。出处与许可见 Resources/mac-duo-LICENSE.txt。
import CoreGraphics
import Foundation

struct DepthGeometry {

  /// Past 90 degrees the picture turns its face away from the glass.
  var maxSeparationDegrees: Double = 88

  /// Bottom-left, bottom-right, top-right, top-left.
  func corners(
    startAngle: Double,
    currentAngle: Double,
    viewingDistanceRatio: Double,
    recession: Double,
    screenSize: CGSize
  ) -> [CGPoint] {
    let width = Double(screenSize.width)
    let height = Double(screenSize.height)
    let start = startAngle * .pi / 180
    let current = currentAngle * .pi / 180
    let travel = max(startAngle - currentAngle, 0)
    let separation = min(recession * travel, maxSeparationDegrees) * .pi / 180

    // The eye in world axes, hinge at the origin.
    let reach = height * viewingDistanceRatio + height / 2 * cos(start)
    let rise = height / 2 * sin(start)

    // The same eye, measured along the glass and away from it.
    let along = reach * cos(current) + rise * sin(current)
    let depth = max(reach * sin(current) - rise * cos(current), height / 10)

    let half = width / 2
    // 按照观察点投影一个角。
    func project(_ x: Double, _ y: Double) -> CGPoint {
      let scale = depth / (depth + y * sin(separation))
      return CGPoint(
        x: half + (x - half) * scale,
        y: along + (y * cos(separation) - along) * scale
      )
    }
    return [project(0, 0), project(width, 0), project(width, height), project(0, height)]
  }
}

/// The settings that shape one frame.
struct DepthTuning: Equatable {
  var viewingDistance: Double = 2.7
  var recession: Double = 2
  var blurEvenness: Double = 0.4
  var dimReach: Double = 0.7
  var maxBlurRadius: Double = 55
  var maxDim: Double = 0.4
}
