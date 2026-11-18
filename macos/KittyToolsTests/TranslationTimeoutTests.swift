// 翻译等待上限与原图部分成功的回归：只用模拟流，不读真实密钥、不访问外网、不弹窗口。

import Foundation
import Synchronization
import Testing

@testable import KittyTools

struct TranslationTimeoutTests {
  /// 模拟只有心跳、思考、空角色或坏数据的服务；这些都不能延长首段译文等待。
  @Test(arguments: [
    ": keep-alive", "{\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}",
    "{\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}", "bad json",
  ])
  func nonTranslationTrafficTimesOut(_ payload: String) async throws {
    let events = TranslationTestStream()
    let stream = aiStream(limits: .init(idle: 0.08, total: 2)) { _ in
      events.repeating(payload)
    }
    await #expect(throws: TranslateError.timedOut) { _ = try await collect(stream) }
    #expect(events.terminated.withLock { $0 } == 1)
  }

  /// 译文已有前半句，后面只有心跳时仍然超时，不把半句当成完成。
  @Test func stalledTranslationDoesNotFinishSuccessfully() async throws {
    let events = TranslationTestStream()
    let stream = aiStream(limits: .init(idle: 0.08, total: 2)) { _ in
      events.repeating(": keep-alive", first: Self.textPayload)
    }
    var latest = ""
    do {
      for try await text in stream { latest = text }
      Issue.record("停在半句的翻译不应成功")
    } catch {
      #expect(error as? TranslateError == .timedOut)
    }
    #expect(latest == "译")
    #expect(events.terminated.withLock { $0 } == 1)
  }

  /// 持续有真实译文也受总时限约束，不能靠每个 token 无限续期。
  @Test func totalDeadlineStopsAnActiveStream() async throws {
    let events = TranslationTestStream()
    let stream = aiStream(limits: .init(idle: 2, total: 0.12)) { _ in
      events.repeating(Self.textPayload)
    }
    await #expect(throws: TranslateError.timedOut) { _ = try await collect(stream) }
    #expect(events.terminated.withLock { $0 } == 1)
  }

  /// 连接迟迟不返回响应头也计入首段译文等待，不能等到开始读 SSE 才计时。
  @Test func waitingForHeadersAlsoTimesOut() async throws {
    let stream = aiStream(limits: .init(idle: 0.08, total: 2)) { _ in
      try await Task.sleep(for: .seconds(10))
      return AsyncThrowingStream { $0.finish() }
    }
    await #expect(throws: TranslateError.timedOut) { _ = try await collect(stream) }
  }

  /// 只因参数错误降档时，第二次请求仍使用同一个总预算。
  @Test func tierFallbackDoesNotRestartTheDeadline() async throws {
    let calls = Mutex(0)
    let stream = AIService.chatStream(
      url: URL(string: "https://translation.invalid/v1/chat/completions")!, headers: [:],
      body: [:], tiers: [["thinking": ["type": "disabled"]], [:]], model: UUID().uuidString,
      delta: AIService.openAIDelta, limits: .init(idle: 2, total: 0.5),
      events: { _ in
        let attempt = calls.withLock {
          $0 += 1
          return $0
        }
        try await Task.sleep(for: .milliseconds(300))
        if attempt == 1 { throw TranslateError(message: "参数不支持", status: 400) }
        return AsyncThrowingStream {
          $0.yield(Self.textPayload)
          $0.finish()
        }
      })
    await #expect(throws: TranslateError.timedOut) { _ = try await collect(stream) }
    #expect(calls.withLock { $0 } == 2)
  }

  /// 有真实进展时按最后一次出字续期，正常慢速生成不会按首字的截止时间提前中断。
  @Test func newTextExtendsTheIdleDeadline() async throws {
    let stream = aiStream(limits: .init(idle: 0.3, total: 3)) { _ in
      AsyncThrowingStream { continuation in
        let task = Task {
          do {
            for _ in 0..<6 {
              continuation.yield(Self.textPayload)
              try await Task.sleep(for: .milliseconds(100))
            }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
    #expect(try await collect(stream) == String(repeating: "译", count: 6))
  }

  /// 正常完成的流保持最终文本，结束后不会被计时器改成失败。
  @Test func completedStreamKeepsItsResult() async throws {
    let stream = aiStream(limits: .init(idle: 2, total: 2)) { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(Self.textPayload)
        continuation.finish()
      }
    }
    #expect(try await collect(stream) == "译")
  }

  /// 原有输出上限错误不能被时限包装吞掉，半截正文仍只算截断。
  @Test func truncationRemainsAnError() async throws {
    let stream = aiStream(limits: .init(idle: 2, total: 2)) { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(Self.textPayload)
        continuation.yield("{\"choices\":[{\"finish_reason\":\"length\"}]}")
        continuation.finish()
      }
    }
    await #expect(throws: TranslateError.truncated) { _ = try await collect(stream) }
  }

  /// 取消立刻终止生产流并保留取消语义，不能等到九十秒的总时限。
  @Test func cancellingStopsTheUnderlyingStream() async throws {
    let events = TranslationTestStream()
    let task = Task {
      try await collect(
        aiStream(limits: .init(idle: 30, total: 90)) { _ in
          events.repeating(Self.textPayload)
        })
    }
    while events.started.withLock({ $0 }) == 0 { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    // 外层 AsyncThrowingStream 的取消可早于生产任务收尾；按状态等，别把调度延迟当成泄漏。
    for _ in 0..<100 where events.terminated.withLock({ $0 }) == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(events.terminated.withLock { $0 } == 1)
  }

  private nonisolated static let textPayload = "{\"choices\":[{\"delta\":{\"content\":\"译\"}}]}"

  /// 绕过真实网络和钥匙串，只替换 SSE 来源与测试时限，执行正式的 AI 累积和超时路径。
  private func aiStream(
    limits: HTTP.Limits,
    events: @escaping @Sendable (URLRequest) async throws -> AsyncThrowingStream<String, Error>
  ) -> AsyncThrowingStream<String, Error> {
    AIService.chatStream(
      url: URL(string: "https://translation.invalid/v1/chat/completions")!, headers: [:],
      body: [:], tiers: [[:]], model: UUID().uuidString, delta: AIService.openAIDelta,
      limits: limits, events: events)
  }

  /// 消费和取消都与正式调用方一致，流的正常迭代结束不代表被取消的任务成功。
  private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
    var latest = ""
    for try await text in stream {
      try Task.checkCancellation()
      latest = text
    }
    try Task.checkCancellation()
    return latest
  }
}

struct ScreenshotTranslationTests {
  /// 一段失败，其他段照常成功；符号不请求，译文仍与原段落按下标一一对应。
  @Test func failedSegmentKeepsOtherTranslations() async throws {
    var done: [Int] = []
    let batch = try await ScreenshotTranslation.translate(
      requests(["first", "second", "---", "third"]), services: [service("primary")],
      finished: { done.append($0) },
      stream: { _, request in
        AsyncThrowingStream { continuation in
          if request.text == "second" {
            continuation.finish(throwing: TranslateError.timedOut)
          } else {
            continuation.yield("译文 " + request.text)
            continuation.finish()
          }
        }
      })
    #expect(batch.translations == ["译文 first", "", "---", "译文 third"])
    #expect(batch.service?.id == "primary")
    #expect(batch.failures == [.timedOut])
    #expect(batch.notice == "有 1 段未翻译，已保留原文")
    #expect(done == [1, 2, 3])
  }

  /// 首个服务失败后仍按顺序换备用服务，词典不会拿来翻整段文字。
  @Test func fallbackSkipsDictionaries() async throws {
    let calls = Mutex<[String]>([])
    let batch = try await ScreenshotTranslation.translate(
      requests(["paragraph"]),
      services: [.builtin(.youdaoDict), service("first"), service("second")],
      stream: { service, _ in
        calls.withLock { $0.append(service.id) }
        return AsyncThrowingStream { continuation in
          if service.id == "first" {
            continuation.finish(throwing: TranslateError.timedOut)
          } else {
            continuation.yield("译文")
            continuation.finish()
          }
        }
      })
    #expect(calls.withLock { $0 } == ["first", "second"])
    #expect(batch.translations == ["译文"])
    #expect(batch.service?.id == "second" && batch.failures.isEmpty)
    #expect(batch.notice == nil)
  }

  /// 整图预算耗尽后，排队段落直接保留原文，不再每三段重新等一个完整超时周期。
  @Test func imageDeadlineStopsQueuedRequests() async throws {
    let events = TranslationTestStream()
    let batch = try await ScreenshotTranslation.translate(
      requests(["one", "two", "three", "four", "five"]), services: [service("primary")],
      timeout: 0.12, stream: { _, _ in events.repeating("") })
    #expect(batch.translations == ["", "", "", "", ""])
    #expect(batch.failures == Array(repeating: .timedOut, count: 5))
    #expect(batch.service == nil)
    #expect(events.started.withLock { $0 } == 3)
    #expect(events.terminated.withLock { $0 } == 3)
  }

  /// 一段先成功，另一段用完预算时仍交回成功的部分。
  @Test func imageDeadlinePreservesFinishedSegments() async throws {
    let events = TranslationTestStream()
    let batch = try await ScreenshotTranslation.translate(
      requests(["fast", "slow"]), services: [service("primary")], timeout: 0.12,
      stream: { _, request in
        if request.text == "slow" { return events.repeating("") }
        return AsyncThrowingStream {
          $0.yield("已翻译")
          $0.finish()
        }
      })
    #expect(batch.translations == ["已翻译", ""])
    #expect(batch.failures == [.timedOut])
    #expect(batch.service?.id == "primary")
  }

  /// 截断的半句不能覆盖原图，必须按失败段处理。
  @Test func truncatedSegmentKeepsOriginal() async throws {
    let batch = try await ScreenshotTranslation.translate(
      requests(["paragraph"]), services: [service("primary")],
      stream: { _, _ in
        AsyncThrowingStream {
          $0.yield("只出了一半")
          $0.finish(throwing: TranslateError.truncated)
        }
      })
    #expect(batch.translations == [""] && batch.service == nil)
    #expect(batch.failures == [.truncated])
  }

  /// 外部取消不交回部分结果，也不继续启动排队段落。
  @Test func imageCancellationStopsAllWork() async throws {
    let events = TranslationTestStream()
    let task = Task {
      try await ScreenshotTranslation.translate(
        requests(["one", "two", "three", "four"]), services: [service("primary")],
        stream: { _, _ in events.repeating("") })
    }
    while events.started.withLock({ $0 }) < 3 { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(events.started.withLock { $0 } == 3)
    #expect(events.terminated.withLock { $0 } == 3)
  }

  /// 测试专用服务，不会从真实用户配置或钥匙串取值。
  private func service(_ id: String) -> TranslateService {
    TranslateService(id: id, kind: .ai, name: id)
  }

  /// 所有段使用同一方向，保持原图翻译的语言规则。
  private func requests(_ texts: [String]) -> [TranslateRequest] {
    texts.map { TranslateRequest(text: $0, from: .en, to: .zhHans) }
  }
}

/// 可取消的假 SSE 生产者，记下启动和结束次数以检查后台任务是否被回收。
private nonisolated final class TranslationTestStream: Sendable {
  let started = Mutex(0)
  let terminated = Mutex(0)

  /// 持续返回指定内容，直到消费者关闭流；首个内容可用来模拟已经出字后卡住。
  func repeating(_ payload: String, first: String? = nil) -> AsyncThrowingStream<String, Error> {
    started.withLock { $0 += 1 }
    return AsyncThrowingStream { continuation in
      if let first { continuation.yield(first) }
      let task = Task {
        do {
          while true {
            try Task.checkCancellation()
            continuation.yield(payload)
            try await Task.sleep(for: .milliseconds(10))
          }
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { [self] _ in
        task.cancel()
        terminated.withLock { $0 += 1 }
      }
    }
  }
}
