// 合盖动效的日志。只记录硬件状态、尺寸和耗时。

import Foundation
import OSLog

nonisolated enum LidDepthLog {
  private static let subsystem = Bundle.main.bundleIdentifier ?? "com.yy.kitty-tools.native"
  static let geometry = Logger(subsystem: subsystem, category: "LidDepth.Render")
  static let lid = Logger(subsystem: subsystem, category: "LidDepth.Sensor")
  static let capture = Logger(subsystem: subsystem, category: "LidDepth.Capture")
}
