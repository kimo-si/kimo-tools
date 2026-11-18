// 原图翻译的网络编排：最多同时翻三段，每段按设置顺序换服务；整张图共用总预算。
// 部分失败只留下该段原文，成功的段仍交给合成；取消整次任务时不交回半截结果。

import Foundation

enum ScreenshotTranslation {
  static let concurrency = 3

  typealias Stream =
    @Sendable (TranslateService, TranslateRequest) ->
    AsyncThrowingStream<String, Error>

  /// 段落结果有明确的成功或失败状态，失败时的空译文只用于告诉排版层保留原图。
  nonisolated enum SegmentResult: Sendable {
    case translated(String, TranslateService)
    case failed(TranslateError)

    var text: String {
      if case .translated(let text, _) = self { return text }
      return ""
    }

    var service: TranslateService? {
      if case .translated(_, let service) = self { return service }
      return nil
    }

    var failure: TranslateError? {
      if case .failed(let error) = self { return error }
      return nil
    }
  }

  /// 译文与原图段落保持相同下标；部分失败不写成完整翻译历史。
  nonisolated struct Batch: Sendable {
    var translations: [String]
    var service: TranslateService?
    var failures: [TranslateError]

    var notice: String? {
      failures.isEmpty ? nil : "有 \(failures.count) 段未翻译，已保留原文"
    }
  }

  /// 过滤词典与纯符号，建立整图截止时间，按原顺序收回成功和失败的段落。
  static func translate(
    _ requests: [TranslateRequest], services: [TranslateService],
    timeout: TimeInterval? = nil, finished: (Int) -> Void = { _ in },
    stream: @escaping Stream = { $0.translate($1) }
  ) async throws -> Batch {
    try Task.checkCancellation()
    let services = services.filter { !$0.kind.isDictionary }
    guard !services.isEmpty else { throw TranslateError.config("没有启用的翻译服务") }
    let pending = requests.indices.filter {
      ScreenshotOverlay.hasTranslatableContent(requests[$0].text)
    }
    let deadline = ContinuousClock.now + .seconds(timeout ?? budget(for: services))
    // 整张图共用预算，后面的段和备用服务不能重新获得一整轮等待时间。
    let outputs = try await inParallel(pending.count, limit: concurrency, finished: finished) {
      index in
      try await translateSegment(
        requests[pending[index]], services: services, deadline: deadline, stream: stream)
    }
    try Task.checkCancellation()
    var translations = requests.map(\.text)
    for (index, output) in zip(pending, outputs) { translations[index] = output.text }
    return Batch(
      translations: translations, service: outputs.compactMap(\.service).first,
      failures: outputs.compactMap(\.failure))
  }

  /// 用户配置了本机或局域网服务时保留较长预算；公网整图最多等九十秒。
  private nonisolated static func budget(for services: [TranslateService]) -> TimeInterval {
    let local = services.contains { service in
      guard let raw = service.baseURL,
        let url = AIService.endpoint(raw, service.aiProtocol ?? .openai)
      else { return false }
      return HTTP.isLocalNetwork(url)
    }
    return (local ? HTTP.Limits.local : .remote).total
  }

  /// 一段失败转成可保留原文的结果；外部取消必须继续往外抛，不能变成部分成功。
  private nonisolated static func translateSegment(
    _ request: TranslateRequest, services: [TranslateService],
    deadline: ContinuousClock.Instant, stream: @escaping Stream
  ) async throws -> SegmentResult {
    try Task.checkCancellation()
    let remaining = (deadline - .now).components
    let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
    guard seconds > 0 else { return .failed(.timedOut) }
    do {
      // 限制本段连同全部备用服务的剩余等待时间，也覆盖非 AI 翻译服务。
      return try await HTTP.withProgressTimeout(limits: .init(idle: seconds, total: seconds)) { _ in
        try await firstTranslation(request, services: services, stream: stream)
      }
    } catch {
      try Task.checkCancellation()
      if error is CancellationError { throw error }
      let failure = HTTP.userFacing(error)
      return .failed(
        failure as? TranslateError ?? TranslateError(message: failure.localizedDescription))
    }
  }

  /// 按启用顺序尝试服务，只接受完整非空译文，失败的半截内容不会覆盖原图。
  private nonisolated static func firstTranslation(
    _ request: TranslateRequest, services: [TranslateService], stream: Stream
  ) async throws -> SegmentResult {
    var failure: Error = TranslateError.emptyResult
    for service in services {
      try Task.checkCancellation()
      do {
        var latest = ""
        for try await partial in stream(service, request) {
          try Task.checkCancellation()
          latest = partial
        }
        try Task.checkCancellation()
        guard !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw TranslateError.emptyResult
        }
        return .translated(latest, service)
      } catch {
        if error is CancellationError || Task.isCancelled { throw error }
        failure = error
      }
    }
    throw failure
  }

  /// 最多 limit 个一起跑，一个完成补下一个；失败是否保留由 work 决定，取消时不再启动新工作。
  static func inParallel<T: Sendable>(
    _ count: Int, limit: Int, finished: (Int) -> Void = { _ in },
    work: @escaping @Sendable (Int) async throws -> T
  ) async throws -> [T] {
    var results = [T?](repeating: nil, count: count)
    try await withThrowingTaskGroup(of: (Int, T).self) { group in
      var next = 0
      var done = 0
      // 按下标补一项，既有并发上限也有取消检查。
      func launch() {
        guard next < count, !Task.isCancelled else { return }
        let index = next
        next += 1
        group.addTask { (index, try await work(index)) }
      }
      for _ in 0..<max(1, limit) { launch() }
      while let (index, value) = try await group.next() {
        try Task.checkCancellation()
        results[index] = value
        done += 1
        finished(done)
        launch()
      }
    }
    try Task.checkCancellation()
    assert(!results.contains { $0 == nil }, "inParallel 有位置没填上")
    return results.compactMap { $0 }
  }
}
