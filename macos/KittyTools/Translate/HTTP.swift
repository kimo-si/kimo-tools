// 翻译服务的网络请求：JSON POST、SSE 流式读取、面向用户的中文错误信息。
// 红线：错误信息和日志里不出现请求 URL、请求头和密钥。

import Foundation
import Synchronization

nonisolated struct TranslateError: LocalizedError, Sendable, Equatable {
  /// 错误卡按它分（体检 C5，mac-whisker §3 语义色）：配置 / 密钥问题橙色、只给「打开设置」（直达这个服务的详情页）；
  /// 网络 / 服务错误红色、给「重试」（自建 AI 服务另给「打开设置」：地址可能填错）
  enum Kind: Sendable {
    /// 缺密钥、密钥不对、地址或模型没填 / 不存在（401 / 403 / 404、百度 52003 等）：重试没用，要去改设置
    case config
    /// 连不上、超时、断网（URLError）
    case network
    /// 服务端出错、太频繁、额度用完、空结果、截断、中断
    case service
  }

  let message: String
  /// HTTP 状态码（400 / 422 时调用方会降级重试）
  var status: Int?
  var kind = Kind.service

  var errorDescription: String? { message }

  static let emptyResult = TranslateError(message: "服务没有返回译文（输出额度可能被思考过程占满，可换非推理模型）")
  /// 流正常结束但服务说输出到上限了（OpenAI 兼容 / 智谱 finish_reason = length，Anthropic stop_reason = max_tokens）：
  /// 已出来的半截照常显示，但不算完成（不写历史、不自动复制、不给替换原文；体检 B19）
  static let truncated = TranslateError(message: "只翻了前一部分：超出这个服务单次输出上限")
  /// 浮窗收起、换了新会话时没出完的卡片（点重试、或再按输入翻译热键重新打开时自动重跑）
  static let interrupted = TranslateError(message: "已中断，点重试重新翻译")
  /// 心跳、思考内容都不算译文进展；超时后允许上层换服务。
  static let timedOut = TranslateError(message: "等待译文超时，请重试或切换翻译服务", kind: .network)

  /// 配置类错误（缺密钥、地址或模型没填）
  static func config(_ message: String) -> TranslateError {
    TranslateError(message: message, kind: .config)
  }
}

nonisolated enum HTTP {
  /// 空闲时间按有效译文计算，总时间覆盖连接、参数降级和生成；本机模型保留较长的预算。
  struct Limits: Sendable {
    var idle: TimeInterval
    var total: TimeInterval
    static let remote = Limits(idle: 30, total: 90)
    static let local = Limits(idle: 180, total: 600)
  }

  /// 按地址选择网络和有效译文共用的时限。
  static func limits(for url: URL) -> Limits {
    isLocalNetwork(url) ? .local : .remote
  }

  /// 翻译使用独立会话，设置真正的总时限，不让 SSE 心跳把请求无限延长。
  static func session(for url: URL) -> URLSession {
    isLocalNetwork(url) ? localSession : remoteSession
  }

  private static let remoteSession = makeSession(.remote)
  private static let localSession = makeSession(.local)

  /// 总时限也覆盖非流式接口和错误响应体的读取。
  private static func makeSession(_ limits: Limits) -> URLSession {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = limits.idle
    configuration.timeoutIntervalForResource = limits.total
    return URLSession(configuration: configuration)
  }

  /// 构造 JSON 请求，沿用同一份网络空闲时限。
  static func request(_ url: URL, headers: [String: String], json: [String: Any]) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = limits(for: url).idle
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = try? JSONSerialization.data(withJSONObject: json)
    return request
  }

  /// 只由真实译文更新的进度；定时器睡到下一个截止时间，不随心跳或每个 token 创建新任务。
  final class Progress: Sendable {
    private let started = ContinuousClock.now
    private let latest = Mutex(ContinuousClock.now)

    /// 只有出现新的非空译文时续期，纯思考和重复内容不能续期。
    func receivedText() { latest.withLock { $0 = .now } }

    /// 等待无译文进展或整次请求用完预算；调用方负责抛出统一的超时错误。
    func waitForExpiration(_ limits: Limits) async throws {
      let deadline = started + .seconds(limits.total)
      while true {
        let next = min(deadline, latest.withLock { $0 } + .seconds(limits.idle))
        try await Task.sleep(until: next, clock: .continuous)
        try Task.checkCancellation()
        let idleUntil = latest.withLock { $0 } + .seconds(limits.idle)
        if ContinuousClock.now >= min(deadline, idleUntil) { return }
      }
    }
  }

  /// 请求与截止时间竞速，完成、报错、取消都收掉另一条任务；取消不能冒充翻译成功。
  static func withProgressTimeout<T: Sendable>(
    limits: Limits, work: @escaping @Sendable (Progress) async throws -> T
  ) async throws -> T {
    try Task.checkCancellation()
    let progress = Progress()
    return try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await work(progress) }
      group.addTask {
        try await progress.waitForExpiration(limits)
        throw TranslateError.timedOut
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw CancellationError() }
      try Task.checkCancellation()
      return result
    }
  }

  /// 一次性请求，返回解析好的 JSON
  static func send(_ request: URLRequest) async throws -> [String: Any] {
    let (data, response) = try await perform {
      try await session(for: request.url!).data(for: request)
    }
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    try check(response, object)
    return object
  }

  /// SSE：逐行给出 `data:` 之后的内容（遇到 [DONE] 结束）
  static func events(_ request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
    let (bytes, response) = try await perform {
      try await session(for: request.url!).bytes(for: request)
    }
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      defer { bytes.task.cancel() }
      var body = Data()
      for try await byte in bytes.prefix(64 * 1024) { body.append(byte) }
      try check(response, (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
    }
    return AsyncThrowingStream { continuation in
      let task = Task {
        defer { bytes.task.cancel() }
        do {
          for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            continuation.yield(payload)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: userFacing(error))
        }
      }
      continuation.onTermination = { _ in
        task.cancel()
        bytes.task.cancel()
      }
    }
  }

  /// 2xx 也可能在 JSON 里带 error 字段
  static func check(_ response: URLResponse, _ object: [String: Any]) throws {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let serverMessage = message(in: object)
    guard (200..<300).contains(status), serverMessage == nil else {
      throw TranslateError(
        message: describe(status: status, serverMessage: serverMessage), status: status,
        kind: [401, 403, 404].contains(status) ? .config : .service)
    }
  }

  /// 错误 JSON 里的说明：error.message → 字符串 error → 顶层 message
  static func message(in object: [String: Any]) -> String? {
    if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
      return message
    }
    if let error = object["error"] as? String, !error.isEmpty { return error }
    if object["error"] != nil, let message = object["message"] as? String { return message }
    return nil
  }

  private static func describe(status: Int, serverMessage: String?) -> String {
    let base =
      switch status {
      case 401, 403: "密钥无效或没有权限"
      case 404: "服务地址或模型不存在"
      case 429: "请求太频繁或额度已用完"
      case 500...: "服务暂时不可用（\(status)）"
      default: "请求失败（\(status)）"
      }
    guard let serverMessage, !serverMessage.isEmpty else { return base }
    return "\(base)：\(serverMessage.prefix(160))"
  }

  /// 发请求一律包这一层：连不上、超时、断网报成统一的中文网络错误（`.network`），不让原始 URLError 被包成服务类错误
  static func perform<T>(_ body: () async throws -> T) async throws -> T {
    do { return try await body() } catch { throw userFacing(error) }
  }

  static func userFacing(_ error: Error) -> Error {
    guard let urlError = error as? URLError else { return error }
    if urlError.code == .cancelled { return CancellationError() }
    let message =
      switch urlError.code {
      case .timedOut: "请求超时，请检查网络或服务地址"
      case .notConnectedToInternet, .networkConnectionLost: "网络不可用"
      case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: "连不上服务地址"
      case .secureConnectionFailed, .serverCertificateUntrusted: "HTTPS 连接失败（证书问题）"
      default: "网络错误（\(urlError.code.rawValue)）"
      }
    return TranslateError(message: message, kind: .network)
  }

  /// 本机或局域网地址：回环、私网 / 链路本地 IP、localhost、*.local、不带点的主机名
  static func isLocalNetwork(_ url: URL) -> Bool {
    guard let host = url.host()?.lowercased() else { return false }
    if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") && !host.contains(":")
    {
      return true
    }
    if host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") {
      return host.contains(":")
    }
    let parts = host.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return false }
    switch (parts[0], parts[1]) {
    case (127, _), (10, _), (192, 168), (169, 254): return true
    case (172, 16...31): return true
    default: return false
    }
  }
}
