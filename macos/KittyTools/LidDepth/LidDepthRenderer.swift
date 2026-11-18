// 改编自 Mac Duo（Copyright 2026 Makito，Apache-2.0）。出处与许可见 Resources/mac-duo-LICENSE.txt。
import AppKit
import Metal
import MetalPerformanceShaders
import OSLog
import QuartzCore
import Synchronization
import simd

/// 将上传完的 Metal 资源一次性交给渲染线程。
private nonisolated final class LidDepthUpload<Payload>: Sendable {
  private let payload: Mutex<Payload?>

  // 上传结束后原线程不再接触资源。
  init(_ payload: sending Payload) { self.payload = Mutex(payload) }

  // 取走资源，之后只有渲染线程使用它。
  func take() -> sending Payload? { payload.withLock { $0.take() } }
}

/// Draws the picture with Metal.
///
/// The picture sits on a black margin in one texture, with a Gaussian pyramid
/// over it. Each frame is one full screen pass.
@MainActor
final class LidDepthRenderer {

  /// Black margin around the picture, in points. Stays above the largest
  /// blur radius, so the blur reaches real black on every side.
  nonisolated private static let paddingInPoints: CGFloat = 120

  private struct Uniforms {
    var column0: SIMD4<Float>
    var column1: SIMD4<Float>
    var column2: SIMD4<Float>
    var screenAndOrigin: SIMD4<Float>
    var paddedAndBlur: SIMD4<Float>
    var shape: SIMD4<Float>
    var light: SIMD4<Float>
  }

  /// One held picture, built off the main thread and adopted on it.
  // 纹理在后台完成上传后才交给主线程，两个线程不会同时变更它。
  nonisolated struct PreparedPicture: Sendable {
    fileprivate let upload: LidDepthUpload<MTLTexture>
    let colourSpace: CGColorSpace
    let paddedOrigin: CGPoint
    let paddedSize: CGSize
    let maxLevel: Float
    let pixelScale: CGFloat
    let screenSize: CGSize
  }

  /// Where the next frame goes.
  ///
  /// A layer belongs to one view at a time, so every overlay window needs
  /// its own.
  private(set) var layer = CAMetalLayer()

  nonisolated private let device: MTLDevice
  nonisolated private let queue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private var texture: MTLTexture?
  private var screenSize: CGSize = .zero
  private var pixelScale: CGFloat = 2
  private var paddedOrigin: CGPoint = .zero
  private var paddedSize: CGSize = .zero
  private var maxLevel: Float = 0

  /// The picture a live stream writes into. `makePicture` builds its own
  /// texture instead, so only one of the two is in use at a time.
  private var liveTexture: MTLTexture?
  private var liveSize: CGSize = .zero
  private var liveScale: CGFloat = 0
  private var isLiveSource = false
  /// The newest live frame, waiting for the next drawn frame to take it.
  private var pendingFrame: LidDepthFrame?
  /// A held picture to start from, waiting for the same moment. A live
  /// frame that arrives first wins, since it is the newer of the two.
  // Buffer 由后台写完一次，随后只由 Metal 读取。
  nonisolated struct PreparedSeed: Sendable {
    fileprivate let upload: LidDepthUpload<MTLBuffer>
    let width: Int
    let height: Int
  }

  private var pendingSeed: (buffer: MTLBuffer, width: Int, height: Int)?
  private static var hasReportedPyramidFailure = false
  /// Built once, re-encoded every frame.
  private lazy var livePyramid = MPSImageGaussianPyramid(device: device, centerWeight: 0.375)

  var isReady: Bool { texture != nil }

  // 将 Metal 命令队列、设备和系统后台编译好的着色器一起交给渲染器。
  struct Resources {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
  }

  // Metal 的异步编译不会阻塞主线程，在合盖移动时提前启动。
  static func prepare() async -> Resources? {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
    else { return nil }
    do {
      let library = try await device.makeLibrary(source: LidDepthShaders.source, options: nil)
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = library.makeFunction(name: "depthVertex")
      descriptor.fragmentFunction = library.makeFunction(name: "depthFragment")
      descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
      let pipeline = try await device.makeRenderPipelineState(descriptor: descriptor)
      return Resources(device: device, queue: queue, pipeline: pipeline)
    } catch {
      LidDepthLog.geometry.error(
        "Metal 着色器编译失败：\(String(describing: error), privacy: .public)")
      return nil
    }
  }

  // AppKit 图层只在主线程创建和配置。
  init(resources: Resources) {
    device = resources.device
    queue = resources.queue
    pipeline = resources.pipeline
  }

  /// A fresh layer for a new overlay window. Later frames go to this one.
  func makeLayer() -> CAMetalLayer {
    let fresh = CAMetalLayer()
    configure(fresh)
    layer = fresh
    return fresh
  }

  // 窗口服务器需要继续为屏幕下方的应用合成画面。
  private func configure(_ target: CAMetalLayer) {
    target.device = device
    target.pixelFormat = .bgra8Unorm_srgb
    target.framebufferOnly = true
    // An opaque layer covering the screen makes the window server mark
    // every window behind it as hidden, and apps stop drawing. The shader
    // writes alpha 1 everywhere, so blending gives the same picture.
    target.isOpaque = false
    // Waiting for the refresh here blocks the main thread. While a capture
    // stream leaves this app out of its own picture, the window server
    // draws the screen twice, the drawable comes back late, and the wait
    // lands a refresh later: 60 frames per second becomes 32. The display
    // link already paces the drawing.
    target.displaySyncEnabled = false
    target.needsDisplayOnBoundsChange = true
  }

  /// Puts the picture on a black margin, uploads it, and builds the pyramid.
  /// Call this off the main thread.
  @concurrent func makePicture(image: CGImage, screenSize: CGSize, pixelScale: CGFloat)
    async -> PreparedPicture?
  {
    let started = CFAbsoluteTimeGetCurrent()
    let padding = Self.paddingInPoints
    let paddedSize = CGSize(
      width: screenSize.width + 2 * padding,
      height: screenSize.height + 2 * padding
    )
    let width = Int((paddedSize.width * pixelScale).rounded())
    let height = Int((paddedSize.height * pixelScale).rounded())
    guard width > 0, height > 0 else { return nil }
    let byteCount = width * height * 4

    guard let staging = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
      return nil
    }

    let colourSpace: CGColorSpace
    if let space = image.colorSpace, space.model == .rgb {
      colourSpace = space
    } else {
      colourSpace = CGColorSpaceCreateDeviceRGB()
    }
    guard
      let context = CGContext(
        data: staging.contents(),
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colourSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue
      )
    else { return nil }
    let contextReady = CFAbsoluteTimeGetCurrent()

    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let inset = padding * pixelScale
    context.draw(
      image,
      in: CGRect(
        x: inset,
        y: inset,
        width: CGFloat(width) - 2 * inset,
        height: CGFloat(height) - 2 * inset
      ))
    let drawn = CFAbsoluteTimeGetCurrent()

    let levels = Int(floor(log2(Double(max(width, height))))) + 1
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm_srgb,
      width: width,
      height: height,
      mipmapped: true
    )
    descriptor.usage = [.shaderRead, .shaderWrite]
    descriptor.storageMode = .private
    guard var texture = device.makeTexture(descriptor: descriptor),
      let commands = queue.makeCommandBuffer(),
      let blit = commands.makeBlitCommandEncoder()
    else { return nil }
    blit.copy(
      from: staging,
      sourceOffset: 0,
      sourceBytesPerRow: width * 4,
      sourceBytesPerImage: byteCount,
      sourceSize: MTLSize(width: width, height: height, depth: 1),
      to: texture,
      destinationSlice: 0,
      destinationLevel: 0,
      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
    )
    blit.endEncoding()

    MPSImageGaussianPyramid(device: device, centerWeight: 0.375)
      .encode(commandBuffer: commands, inPlaceTexture: &texture, fallbackCopyAllocator: nil)
    commands.commit()
    await commands.completed()
    guard commands.status == .completed else { return nil }
    let finished = CFAbsoluteTimeGetCurrent()

    LidDepthLog.geometry.notice(
      """
      metal texture \(width)x\(height) px, \(levels) levels: \
      context \((contextReady - started) * 1000, format: .fixed(precision: 1)) ms, \
      draw \((drawn - contextReady) * 1000, format: .fixed(precision: 1)) ms, \
      gpu \((finished - drawn) * 1000, format: .fixed(precision: 1)) ms
      """
    )
    return PreparedPicture(
      upload: LidDepthUpload(texture),
      colourSpace: colourSpace,
      paddedOrigin: CGPoint(x: -padding, y: -padding),
      paddedSize: paddedSize,
      maxLevel: Float(levels - 1),
      pixelScale: pixelScale,
      screenSize: screenSize
    )
  }

  // MARK: - Live source

  /// Prepares the picture for a live stream. The margin is filled with black
  /// once; every frame after that only overwrites the interior. Nothing is
  /// drawn until the first frame lands.
  @discardableResult
  func beginLive(screenSize: CGSize, pixelScale: CGFloat) -> Bool {
    let padding = Self.paddingInPoints
    let padded = CGSize(
      width: screenSize.width + 2 * padding,
      height: screenSize.height + 2 * padding
    )
    let width = Int((padded.width * pixelScale).rounded())
    let height = Int((padded.height * pixelScale).rounded())
    guard width > 0, height > 0 else { return false }

    if liveTexture == nil || liveSize != padded || liveScale != pixelScale {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm_srgb,
        width: width,
        height: height,
        mipmapped: true
      )
      // `renderTarget` is only there for the one clear that blacks the
      // margin.
      descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
      descriptor.storageMode = .private
      guard let fresh = device.makeTexture(descriptor: descriptor) else { return false }
      clearToBlack(fresh)
      liveTexture = fresh
      liveSize = padded
      liveScale = pixelScale
    }

    texture = nil
    isLiveSource = true
    self.screenSize = screenSize
    self.pixelScale = pixelScale
    paddedOrigin = CGPoint(x: -padding, y: -padding)
    paddedSize = padded
    maxLevel = Float(Int(floor(log2(Double(max(width, height))))))
    layer.colorspace = CGColorSpace(name: LidDepthStream.colourSpaceName)
    layer.drawableSize = CGSize(
      width: screenSize.width * pixelScale,
      height: screenSize.height * pixelScale
    )
    return true
  }

  // 把截图转到实时画面的色彩空间，在后台准备供 Metal 上传的缓冲区。
  @concurrent func prepareSeed(image: CGImage, screenSize: CGSize, pixelScale: CGFloat)
    async -> PreparedSeed?
  {
    let width = Int((screenSize.width * pixelScale).rounded())
    let height = Int((screenSize.height * pixelScale).rounded())
    guard width > 0, height > 0 else { return nil }
    let bytesPerRow = width * 4
    guard
      let staging = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
      let space = CGColorSpace(name: CGColorSpace.displayP3),
      let context = CGContext(
        data: staging.contents(), width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: bytesPerRow, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return PreparedSeed(upload: LidDepthUpload(staging), width: width, height: height)
  }

  // 只有实时首帧还没到，静态帧才会成为临时画面。
  func seed(_ seed: PreparedSeed) -> Bool {
    guard isLiveSource, let liveTexture, texture == nil, let buffer = seed.upload.take()
    else { return false }
    pendingSeed = (buffer, seed.width, seed.height)
    texture = liveTexture
    return true
  }

  // 暂存最新实时画面，由下一次渲染排队上传。
  func absorb(_ frame: LidDepthFrame) {
    guard isLiveSource, liveTexture != nil else { return }
    pendingFrame = frame
    pendingSeed = nil
    // The texture object is the one the next pass reads, and the copy into
    // it is encoded ahead of that pass.
    texture = liveTexture
  }

  /// Copies the newest frame into the picture and rebuilds the pyramid.
  private func absorbPending(into commands: MTLCommandBuffer) {
    guard var target = liveTexture, pendingFrame != nil || pendingSeed != nil else { return }
    let inset = Int((Self.paddingInPoints * pixelScale).rounded())
    guard let blit = commands.makeBlitCommandEncoder() else { return }
    if let frame = pendingFrame {
      frame.withTexture { texture in
        let width = min(texture.width, target.width - 2 * inset)
        let height = min(texture.height, target.height - 2 * inset)
        guard width > 0, height > 0 else { return }
        blit.copy(
          from: texture,
          sourceSlice: 0,
          sourceLevel: 0,
          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
          sourceSize: MTLSize(width: width, height: height, depth: 1),
          to: target,
          destinationSlice: 0,
          destinationLevel: 0,
          destinationOrigin: MTLOrigin(x: inset, y: inset, z: 0)
        )
      }
      commands.addCompletedHandler { [frame] _ in
        withExtendedLifetime(frame) {}
      }
    } else if let seed = pendingSeed {
      let width = min(seed.width, target.width - 2 * inset)
      let height = min(seed.height, target.height - 2 * inset)
      guard width > 0, height > 0 else {
        blit.endEncoding()
        return
      }
      blit.copy(
        from: seed.buffer,
        sourceOffset: 0,
        sourceBytesPerRow: seed.width * 4,
        sourceBytesPerImage: seed.width * 4 * seed.height,
        sourceSize: MTLSize(width: width, height: height, depth: 1),
        to: target,
        destinationSlice: 0,
        destinationLevel: 0,
        destinationOrigin: MTLOrigin(x: inset, y: inset, z: 0)
      )
    }
    pendingFrame = nil
    pendingSeed = nil
    blit.endEncoding()
    let built = livePyramid.encode(
      commandBuffer: commands,
      inPlaceTexture: &target,
      fallbackCopyAllocator: nil
    )
    if !built, !Self.hasReportedPyramidFailure {
      Self.hasReportedPyramidFailure = true
      LidDepthLog.geometry.error("live pyramid in place encode returned false")
    }
    liveTexture = target
    texture = target
  }

  /// Frees the live picture.
  func discardLive() {
    pendingFrame = nil
    pendingSeed = nil
    if isLiveSource { texture = nil }
    isLiveSource = false
    liveTexture = nil
    liveSize = .zero
    liveScale = 0
  }

  // 把实时画面的边缘清成黑色，完成后才执行同队列的后续渲染。
  private func clearToBlack(_ target: MTLTexture) {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    guard let commands = queue.makeCommandBuffer(),
      let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
    else { return }
    encoder.endEncoding()
    // 后续提交在同一个队列里，底色先完成，无需等 GPU。
    commands.commit()
  }

  // MARK: - Still source

  // 使用后台建好的静态纹理，同时更新图层颜色与像素尺寸。
  func adopt(_ picture: PreparedPicture) {
    isLiveSource = false
    texture = picture.upload.take()
    // Without a tag the window server treats the drawable as sRGB and
    // converts it to the display space.
    layer.colorspace = picture.colourSpace
    paddedOrigin = picture.paddedOrigin
    paddedSize = picture.paddedSize
    maxLevel = picture.maxLevel
    pixelScale = picture.pixelScale
    screenSize = picture.screenSize
    layer.drawableSize = CGSize(
      width: picture.screenSize.width * picture.pixelScale,
      height: picture.screenSize.height * picture.pixelScale
    )
  }

  // 窗口自己持有旧图层直到淡出结束；渲染器释放对旧 drawable 的引用。
  func release() {
    texture = nil
    layer = CAMetalLayer()
  }

  /// - Parameter corners: the picture corners projected onto the screen, in
  ///   points, listed bottom-left, bottom-right, top-right, top-left.
  func render(
    corners: [CGPoint],
    blurStrength: Double,
    dimStrength: Double,
    hingeFloor: Double,
    dimHingeFloor: Double,
    dimReach: Double,
    maxBlurRadius: Double,
    maxDim: Double
  ) {
    guard let commands = queue.makeCommandBuffer() else { return }
    absorbPending(into: commands)
    guard let texture, screenSize.width > 0, screenSize.height > 0,
      let drawable = layer.nextDrawable()
    else {
      commands.commit()
      return
    }

    let forward = LidDepthProjection.matrix(
      width: Double(screenSize.width),
      height: Double(screenSize.height),
      to: corners.map { SIMD2(Double($0.x), Double($0.y)) }
    )
    let inverse = forward.inverse

    // 着色器的每列按 SIMD4 对齐。
    func column(_ index: Int) -> SIMD4<Float> {
      let c = inverse[index]
      return SIMD4(Float(c.x), Float(c.y), Float(c.z), 0)
    }
    var uniforms = Uniforms(
      column0: column(0),
      column1: column(1),
      column2: column(2),
      screenAndOrigin: SIMD4(
        Float(screenSize.width), Float(screenSize.height),
        Float(paddedOrigin.x), Float(paddedOrigin.y)
      ),
      paddedAndBlur: SIMD4(
        Float(paddedSize.width), Float(paddedSize.height),
        Float(maxBlurRadius * Double(pixelScale)), Float(blurStrength)
      ),
      shape: SIMD4(Float(hingeFloor), Float(maxDim), Float(pixelScale), maxLevel),
      light: SIMD4(Float(dimHingeFloor), Float(dimStrength), Float(dimReach), 0)
    )

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = drawable.texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
      commands.commit()
      return
    }
    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
    encoder.setFragmentTexture(texture, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    commands.present(drawable)
    commands.commit()
  }
}
