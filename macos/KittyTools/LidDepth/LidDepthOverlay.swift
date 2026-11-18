// 改编自 Mac Duo（Copyright 2026 Makito，Apache-2.0）。出处与许可见 Resources/mac-duo-LICENSE.txt。
import AppKit
import Metal
import QuartzCore

/// 把 Metal 图层铺到装饰面板上。
private final class MetalHostView: NSView {
  // 直接挂载 CAMetalLayer，避开 SwiftUI 和窗口快照。
  init(layer metalLayer: CALayer, scale: CGFloat) {
    super.init(frame: .zero)
    metalLayer.contentsScale = scale
    self.layer = metalLayer
    wantsLayer = true
    layerContentsRedrawPolicy = .never
  }

  // 画面窗由代码创建。
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  // 让图层始终填满面板。
  override func layout() {
    super.layout()
    layer?.frame = bounds
  }
}

/// Owns the overlay window for one run of the effect.
@MainActor
final class LidDepthOverlay {

  private var window: NSPanel?
  /// The window of the previous run while it fades out. AppKit keeps it
  /// alive past the fade, so a new run has to take it down itself.
  private var fadingWindow: NSPanel?
  /// Built once and kept.
  private var renderer: LidDepthRenderer?
  private var rendererTask: Task<Void, Never>?
  private var rendererFailed = false
  private var pictureTask: Task<Void, Never>?

  private var screenSize: CGSize = .zero
  private var startAngle: Double = 90
  private var geometry = DepthGeometry()
  private var gradient = LidDepthGradient()
  private var tuning = DepthTuning()
  private var fadeIn: TimeInterval = 0.07
  private var hasRevealed = false
  private var pixelScale: CGFloat = 1

  var isVisible: Bool { window != nil }
  var isPictureReady: Bool { renderer?.isReady ?? false }
  var hostWindow: NSWindow? { window }

  // 开始编译着色器，已准备或正在编译时直接复用。
  @discardableResult
  func warmUp() -> Bool {
    guard renderer == nil, rendererTask == nil, !rendererFailed else { return renderer != nil }
    rendererTask = Task { [weak self] in
      let resources = await LidDepthRenderer.prepare()
      guard let self, !Task.isCancelled else { return }
      rendererTask = nil
      guard let resources else {
        rendererFailed = true
        return
      }
      renderer = LidDepthRenderer(resources: resources)
    }
    return false
  }

  // 移除插件时释放着色器和纹理缓存。
  func releaseRenderer() {
    dismiss(animated: false)
    rendererTask?.cancel()
    rendererTask = nil
    renderer = nil
    rendererFailed = false
  }

  /// Puts up a window for a live stream. It stays transparent until the
  /// first frame is absorbed.
  @discardableResult
  func showLive(
    on screen: NSScreen,
    startAngle: Double,
    tuning: DepthTuning,
    fadeIn: TimeInterval
  ) -> Bool {
    dismiss(animated: false)
    guard warmUp(), let renderer else { return false }
    self.startAngle = startAngle
    self.tuning = tuning
    self.fadeIn = fadeIn
    screenSize = screen.frame.size

    pixelScale = screen.backingScaleFactor
    guard renderer.beginLive(screenSize: screenSize, pixelScale: pixelScale) else {
      return false
    }
    makeWindow(on: screen, pixelScale: pixelScale)
    return window != nil
  }

  /// Hands one live frame to the renderer and reveals the window once the
  /// first one has landed.
  func absorb(_ frame: LidDepthFrame) {
    guard window != nil, let renderer else { return }
    renderer.absorb(frame)
    reveal()
  }

  // 实时流尚未送来首帧时，在后台把一帧截图转成临时底图。
  func seed(image: CGImage) {
    guard let window, let renderer, !renderer.isReady, pictureTask == nil else { return }
    let size = screenSize
    let scale = pixelScale
    pictureTask = Task { [weak self] in
      let seed = await renderer.prepareSeed(image: image, screenSize: size, pixelScale: scale)
      guard let self, !Task.isCancelled, self.window === window else { return }
      pictureTask = nil
      guard let seed, renderer.seed(seed) else { return }
      reveal()
    }
  }

  // 结束实时流后释放最新帧和复用纹理。
  func discardLive() {
    renderer?.discardLive()
  }

  // 静态模式上传触发时的一帧，上传完成之后才让面板可见。
  func show(
    image: CGImage,
    on screen: NSScreen,
    startAngle: Double,
    tuning: DepthTuning,
    fadeIn: TimeInterval
  ) {
    dismiss(animated: false)
    // The screenshot's screen can be stale once the lid shuts into
    // clamshell mode, so no window goes up at its old frame.
    guard let displayID = screen.displayID, displayID == NSScreen.lidDepthBuiltIn?.displayID else {
      return
    }
    guard warmUp(), let renderer else { return }
    self.startAngle = startAngle
    self.tuning = tuning
    self.fadeIn = fadeIn
    screenSize = screen.frame.size

    let pixelScale =
      screen.frame.width > 0
      ? CGFloat(image.width) / screen.frame.width
      : screen.backingScaleFactor

    makeWindow(on: screen, pixelScale: pixelScale)
    guard let window else { return }

    preparePicture(image, window: window, renderer: renderer, pixelScale: pixelScale)
  }

  // 只有本轮窗口仍在时，才接受完成上传的静态纹理。
  private func preparePicture(
    _ image: CGImage, window: NSPanel, renderer: LidDepthRenderer, pixelScale: CGFloat
  ) {
    let size = screenSize
    pictureTask = Task { [weak self] in
      let picture = await renderer.makePicture(
        image: image, screenSize: size, pixelScale: pixelScale)
      guard let self, !Task.isCancelled, self.window === window else { return }
      pictureTask = nil
      guard let picture else {
        dismiss(animated: false)
        return
      }
      renderer.adopt(picture)
      update(progress: 0, currentAngle: startAngle, tuning: tuning)
      reveal()
    }
  }

  // 创建不抢焦点、鼠标可穿透、只盖住内建屏幕的面板。
  private func makeWindow(on screen: NSScreen, pixelScale: CGFloat) {
    guard let renderer else { return }
    let view = MetalHostView(layer: renderer.makeLayer(), scale: pixelScale)
    view.frame = NSRect(origin: .zero, size: screenSize)
    view.autoresizingMask = [.width, .height]

    let window = NSPanel(
      contentRect: screen.frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    window.contentView = view
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.isReleasedWhenClosed = false
    // 盖住桌面，截图选区和状态屏等系统级交互层留在它上方。
    window.level = .statusBar
    window.hidesOnDeactivate = false
    window.animationBehavior = .none
    window.collectionBehavior = [
      .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
    ]
    window.setFrame(screen.frame, display: false)
    window.alphaValue = 0
    window.orderFrontRegardless()
    hasRevealed = false
    self.window = window
  }

  /// Fades the window in once, and only once the picture has something to
  /// draw.
  private func reveal() {
    guard let window, !hasRevealed, renderer?.isReady == true else { return }
    hasRevealed = true
    guard fadeIn > 0 else {
      window.alphaValue = 1
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = fadeIn
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      window.animator().alphaValue = 1
    }
  }

  // 投影当前角度，并按开合行程计算模糊与亮度。
  func update(progress: Double, currentAngle: Double, tuning: DepthTuning) {
    guard let renderer, renderer.isReady else { return }
    self.tuning = tuning
    renderer.render(
      corners: geometry.corners(
        startAngle: startAngle,
        currentAngle: currentAngle,
        viewingDistanceRatio: tuning.viewingDistance,
        recession: tuning.recession,
        screenSize: screenSize
      ),
      blurStrength: gradient.blurStrength(progress: progress),
      dimStrength: gradient.dimStrength(progress: progress),
      hingeFloor: tuning.blurEvenness,
      dimHingeFloor: gradient.dimHingeFloor,
      dimReach: tuning.dimReach,
      maxBlurRadius: tuning.maxBlurRadius,
      maxDim: tuning.maxDim
    )
  }

  // 收起面板并使尚未上传完成的旧帧失效。
  func dismiss(animated: Bool, duration: TimeInterval = 0.22) {
    closeFadingWindow()
    guard let window else { return }
    self.window = nil
    pictureTask?.cancel()
    pictureTask = nil
    renderer?.release()

    guard animated else {
      window.orderOut(nil)
      window.close()
      return
    }

    fadingWindow = window
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      window.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.fadingWindow === window else { return }
        self.fadingWindow = nil
        window.orderOut(nil)
        window.close()
      }
    }
  }

  /// Takes down a window that is still fading.
  private func closeFadingWindow() {
    guard let fadingWindow else { return }
    self.fadingWindow = nil
    fadingWindow.orderOut(nil)
    fadingWindow.close()
  }
}
