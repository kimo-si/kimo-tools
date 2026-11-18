// 统一日志（os.Logger）。查看：log stream --predicate 'subsystem BEGINSWITH "com.yy.kitty-tools.native"'
// 红线：日志里不得出现密钥、请求 URL、请求头、剪贴板正文。

import Foundation
import OSLog

nonisolated enum Log {
  private static let subsystem = Bundle.main.bundleIdentifier ?? "com.yy.kitty-tools.native"
  static let storage = Logger(subsystem: subsystem, category: "storage")
  static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
  static let record = Logger(subsystem: subsystem, category: "record")
  /// 访达右键（FinderLink）：交给别的 App 打开没成
  static let finder = Logger(subsystem: subsystem, category: "finder")
  static let appInput = Logger(subsystem: subsystem, category: "app-input")
  /// 刘海岛（Island）：每块屏认成刘海 / 胶囊 / 系统灵动岛和它的几何（屏幕变了时写一次）
  static let island = Logger(subsystem: subsystem, category: "island")
  /// 刘海岛的正在播放（NowPlaying）：连不上服务、服务说 MediaRemote 不能用
  static let nowPlaying = Logger(subsystem: subsystem, category: "nowplaying")
  /// 翻译各阶段的计时；只记随机代号、阶段、耗时和数量，不记正文、地址、模型或密钥。
  static let translation = Logger(subsystem: subsystem, category: "translation")
}

/// 同一次翻译的阶段计时；整图和单次 AI 请求分别用自己的随机代号关联日志。
nonisolated struct TranslationTrace: Sendable {
  enum Stage: String, Sendable {
    case ocr, segmentation, firstText, api, render, total
  }

  let id = UUID().uuidString
  let started = ContinuousClock.now

  /// 记录某阶段已经用掉的毫秒数，不输出错误原文或翻译内容。
  func record(_ stage: Stage, since start: ContinuousClock.Instant, count: Int = 0) {
    let duration = (ContinuousClock.now - start).components
    let milliseconds = duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000
    Log.translation.info(
      "translation=\(id, privacy: .public) stage=\(stage.rawValue, privacy: .public) elapsed_ms=\(milliseconds) count=\(count)"
    )
  }
}
