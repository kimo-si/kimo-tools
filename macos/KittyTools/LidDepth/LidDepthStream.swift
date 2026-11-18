// 改编自 Mac Duo（Copyright 2026 Makito，Apache-2.0）。出处与许可见 Resources/mac-duo-LICENSE.txt。
import AppKit
import CoreVideo
import Metal
import OSLog
import ScreenCaptureKit
import Synchronization

/// Frames are `IOSurface` backed, so wrapping one as a texture copies nothing.
/// `startCapture` takes long enough that the stream has to be started while
/// the lid is still closing rather than at the trigger angle.
@MainActor
final class LidDepthStream {

  /// Display P3 carries the same transfer function as sRGB, so the shader's
  /// sRGB pixel format decodes it correctly.
  static let colourSpaceName = CGColorSpace.displayP3

  /// Frames arrive on the stream's own queue. The newest one is kept under a
  /// lock and picked up on the main thread; the texture cache is only ever
  /// touched from the stream queue.
  private nonisolated final class Receiver: NSObject, SCStreamOutput, SCStreamDelegate {
    private let cache: CVMetalTextureCache
    private struct State {
      var newest: LidDepthFrame?
      var stopped = false
    }

    private let state = Mutex(State())

    var hasStopped: Bool { state.withLock { $0.stopped } }

    // 回调来自系统队列，用同一把锁标记流已停止。
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
      state.withLock { $0.stopped = true }
    }

    // 创建把 ScreenCaptureKit 像素缓冲包装成 Metal 纹理的缓存。
    init?(device: MTLDevice) {
      var made: CVMetalTextureCache?
      guard
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &made) == kCVReturnSuccess,
        let made
      else { return nil }
      cache = made
      super.init()
    }

    // 取出最新画面，将消费过的帧从收件箱移除。
    func takeFrame() -> LidDepthFrame? { state.withLock { $0.newest.take() } }

    // 在屏幕流的队列收下完整帧并更新最新纹理。
    func stream(
      _ stream: SCStream,
      didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
      of type: SCStreamOutputType
    ) {
      guard type == .screen,
        CMSampleBufferIsValid(sampleBuffer),
        let metadata = CMSampleBufferGetSampleAttachmentsArray(
          sampleBuffer, createIfNecessary: false)
          as? [[SCStreamFrameInfo: Any]],
        metadata.first?[.status] as? Int == SCFrameStatus.complete.rawValue,
        let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
      else { return }

      // Lets go of the surfaces nothing holds, so the pool keeps recycling.
      CVMetalTextureCacheFlush(cache, 0)

      guard let frame = LidDepthFrame(cache: cache, pixels: pixels) else { return }
      state.withLock { $0.newest = frame }
    }
  }

  private let source: LidDepthCaptureFilter
  private lazy var device = MTLCreateSystemDefaultDevice()
  private var stream: SCStream?
  private var receiver: Receiver?
  private var startTask: Task<Void, Never>?
  private var closingTask: Task<Void, Never>?
  private var lastAttempt = -Double.infinity
  private var lastHandOver: CFTimeInterval = 0
  private static let minimumHandOverInterval: TimeInterval = 1.0 / 32
  private static let retryInterval: TimeInterval = 1

  // 静态画面和实时流使用同一个过滤器。
  init(source: LidDepthCaptureFilter) { self.source = source }

  // 开始实时取画；失败或被系统停止后限速重试。
  func start() {
    if receiver?.hasStopped == true { stop() }
    let now = CACurrentMediaTime()
    guard stream == nil, startTask == nil, now - lastAttempt >= Self.retryInterval else { return }
    lastAttempt = now
    let previous = closingTask
    startTask = Task { [weak self] in
      // 等上一条流完全收尾，避免快速开关时两条流并行。
      await previous?.value
      guard !Task.isCancelled else { return }
      self?.closingTask = nil
      await self?.begin()
      guard !Task.isCancelled else { return }
      self?.startTask = nil
    }
  }

  // 立即丢弃旧帧，异步关闭系统流；新一轮会等关闭完成。
  func stop() {
    guard stream != nil || startTask != nil else { return }
    let previous = closingTask
    let starting = startTask
    let oldStream = stream
    starting?.cancel()
    startTask = nil
    stream = nil
    receiver = nil
    lastHandOver = 0
    closingTask = Task {
      await previous?.value
      await starting?.value
      if let oldStream { try? await oldStream.stopCapture() }
    }
  }

  // 取最新一帧；同一帧最多提交一次。
  func newFrame() -> LidDepthFrame? {
    let now = CACurrentMediaTime()
    guard now - lastHandOver >= Self.minimumHandOverInterval,
      let frame = receiver?.takeFrame()
    else { return nil }
    lastHandOver = now
    return frame
  }

  // 打开系统流，取消发生在打开期间时将它当场关闭。
  private func begin() async {
    do {
      guard let filter = try await source.current(), !Task.isCancelled,
        let device, let receiver = Receiver(device: device)
      else { return }
      let fresh = try makeStream(filter: filter, receiver: receiver)
      try await fresh.startCapture()
      guard !Task.isCancelled else {
        try? await fresh.stopCapture()
        return
      }
      self.receiver = receiver
      stream = fresh
    } catch {
      guard !Task.isCancelled else { return }
      LidDepthLog.capture.debug("实时取画失败：\(String(describing: error), privacy: .public)")
    }
  }

  // 只取画面，以 30 fps 送入 Metal；保留上游的 Display P3 色彩空间。
  private func makeStream(filter: SCContentFilter, receiver: Receiver) throws -> SCStream {
    let configuration = LidDepthCaptureFilter.configuration(for: filter)
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.colorSpaceName = Self.colourSpaceName
    configuration.queueDepth = 5
    let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
    try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: Self.frameQueue)
    return stream
  }

  private static let frameQueue = DispatchQueue(
    label: "KittyTools.lidDepth.frames", qos: .userInteractive)
}
