// 截图、钉图识字共用的顶部进度提示，跟随当前识别任务的生命周期。

import Foundation

@MainActor final class OCRProgress {
  private static let recognizing = "识别中…"
  private static let preparing = "正在准备识字模型…"
  private let island: Island
  private var current: UUID?

  /// 使用全局提示岛显示当前识别阶段。
  init(island: Island) {
    self.island = island
  }

  /// 新一轮接管提示，完成或取消时收掉它显示过或排队中的进度。
  func run<T>(
    preparesLocalModel: Bool, noticeDelay: Duration = .milliseconds(300), _ work: () async -> T
  ) async -> T {
    if let current { finish(current) }
    let id = UUID()
    current = id
    defer { finish(id) }
    return await withTaskCancellationHandler {
      if !Task.isCancelled, preparesLocalModel, !OCR.isPrepared() {
        await prepareModel(for: id)
      }
      // 常见小选区直接出结果，只有当前任务识别超过 0.3 秒才发提示。
      return await Island.whenSlow(after: noticeDelay) { [self] in
        guard current == id else { return }
        island.show(Self.recognizing, tone: .progress)
      } work: {
        await work()
      }
    } onCancel: {
      // Vision 或模型预热可能仍在运行，先撤下已经取消的进度。
      Task { @MainActor in self.finish(id) }
    }
  }

  /// 首次使用 Vision 时显示等待时间，模型准备好就结束这一阶段。
  private func prepareModel(for id: UUID) async {
    let note = "第一次识字要等一分钟左右，以后就快了"
    island.show(Self.preparing, detail: note, tone: .progress, symbol: "text.viewfinder")
    let started = ContinuousClock.now
    let ticker = Task {
      while true {
        try await Task.sleep(for: .seconds(1))
        guard current == id else { return }
        let seconds = (ContinuousClock.now - started).components.seconds
        island.progress(Self.preparing, detail: "\(note) · 已等 \(seconds) 秒")
      }
    }
    // 同时来的识别共用 Vision 的预热，只更新当前任务的提示。
    await OCR.prepare()
    ticker.cancel()
    if current == id { island.dismiss(ifShowing: Self.preparing) }
  }

  /// 只收当前任务的提示，旧任务晚到的清理不能收掉新任务。
  private func finish(_ id: UUID) {
    guard current == id else { return }
    current = nil
    island.dismiss(ifShowing: Self.recognizing)
    island.dismiss(ifShowing: Self.preparing)
  }
}
