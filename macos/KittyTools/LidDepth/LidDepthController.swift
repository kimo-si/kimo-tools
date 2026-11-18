// 改编自 Mac Duo（Copyright 2026 Makito，Apache-2.0）。出处与许可见 Resources/mac-duo-LICENSE.txt。
import AppKit
import OSLog
import Observation
import QuartzCore

/// 读取开合角度，按上游的触发策略控制取画和渲染。
@Observable
final class LidDepthController {
  private(set) var currentAngle: Double?
  private(set) var isSensorAvailable = false
  private(set) var isActive = false

  private struct Layout: Equatable {
    var displayID: CGDirectDisplayID?
    var frame: CGRect?

    // 只比较布局，屏幕背光或色彩变化不需要重建捕获。
    static var current: Self {
      let screen = NSScreen.lidDepthBuiltIn
      return Self(displayID: screen?.displayID, frame: screen?.frame)
    }
  }

  private enum Pause: Hashable { case sleep, displaysAsleep, inactiveSession }

  enum PreviewBlocker {
    case disabled, unavailable, permission, busy
  }

  @ObservationIgnored var hostIsBusy: () -> Bool = { false }
  @ObservationIgnored private var preferences = LidDepthOptions()
  private let source = LidDepthCaptureFilter()
  @ObservationIgnored private lazy var snapshotter = LidDepthSnapshot(source: source)
  @ObservationIgnored private lazy var streamer = LidDepthStream(source: source)
  private let overlay = LidDepthOverlay()
  @ObservationIgnored private var sensor: LidAngleSensor?
  @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  @ObservationIgnored private var pauses: Set<Pause> = []
  @ObservationIgnored private var isStarted = false
  @ObservationIgnored private var hasScreenAccess = false
  @ObservationIgnored private var nextStillAttempt: TimeInterval = 0
  @ObservationIgnored private var isPrewarming = false

  @ObservationIgnored private var pictureTask: Task<Void, Never>?
  @ObservationIgnored private var pollTimer: Timer?
  @ObservationIgnored private var pollInterval: TimeInterval = 0
  @ObservationIgnored private var displayLink: CADisplayLink?
  @ObservationIgnored private var lastFrameTime: CFTimeInterval = 0
  @ObservationIgnored private var lastPublishTime: CFTimeInterval = 0

  @ObservationIgnored private var rawAngle: Double = 0
  /// Degrees per second, negative while the lid closes.
  @ObservationIgnored private var angularVelocity: Double = 0
  @ObservationIgnored private var lastChangedAngle: Double?
  @ObservationIgnored private var lastChangeTime: CFTimeInterval = 0
  @ObservationIgnored private var lastClosingTime: CFTimeInterval = -.greatestFiniteMagnitude
  @ObservationIgnored private var visualAngle = LidDepthSpring()
  @ObservationIgnored private var consecutiveFailedReads = 0
  @ObservationIgnored private var startedAt: CFTimeInterval = 0
  @ObservationIgnored private var preview: PreviewRun?
  private var isSuspended: Bool { !pauses.isEmpty }
  @ObservationIgnored private var isCapturePending = false
  @ObservationIgnored private var motionIntent = LidMotionIntent()
  @ObservationIgnored private var openDwell = LidOpenDwell()
  /// Where the lid last moved to by more than `timeoutMovementThreshold`,
  /// and when. The timeout counts from there.
  @ObservationIgnored private var timeoutReferenceAngle: Double?
  @ObservationIgnored private var timeoutReferenceTime: CFTimeInterval = 0
  /// Set when the timeout ends the effect, cleared once the lid rises back
  /// above the threshold. Closing further from the same resting spot must
  /// not retrigger it.
  @ObservationIgnored private var timeoutAwaitingRelease = false
  /// The setting as last seen, so flipping it drops stale tracking.
  @ObservationIgnored private var wasTimeoutEnabled = false
  /// True while `beginClosingOut()` is easing the picture back to flat.
  @ObservationIgnored private var isClosingOut = false
  @ObservationIgnored private var closingOutStartedAt: CFTimeInterval = 0
  @ObservationIgnored private var builtInLayout = Layout()
  @ObservationIgnored private var peakAngle: Double = 0
  /// The lowest reading since the effect started. Opening releases only
  /// once the lid has risen `LidDepthPolicy.minimumReleaseRise` above it.
  @ObservationIgnored private var lowestRunAngle: Double = 0

  private static let idlePollInterval: TimeInterval = 1.0 / 8
  private static let activePollInterval: TimeInterval = 1.0 / 30
  private static let fadeInDuration: TimeInterval = 0.07
  /// Degrees above the pre-warm zone at which polling speeds up.
  private static let fastPollMargin: Double = 20
  private static let hysteresis: Double = 4
  private static let prewarmCeiling: Double = 70
  private static let prewarmSpeed: Double = 8
  private static let prewarmLinger: TimeInterval = 2
  private static let stillPrewarmInterval: TimeInterval = 0.25
  private static let stillRetryInterval: TimeInterval = 0.5

  /// Closing speed that counts as a deliberate close, in degrees per second.
  /// A still lid reads under 0.5.
  private static let triggerClosingSpeed: Double = 2

  /// Opening speed that counts as a deliberate reversal, in degrees per second.
  private static let triggerOpeningSpeed: Double = 2

  /// How long after the lid last moved down the effect may still start.
  private static let closingMemory: TimeInterval = 1.5

  private static let predictionSpeedFloor: Double = 40

  /// Sensor latency the prediction adds on top of the reading's own age.
  private static let predictionLatency: TimeInterval = 0.04

  /// The ordinary hysteresis release waits this long. A prediction can fire
  /// while the last reading is still above the trigger angle, but deliberate
  /// opening is allowed to release immediately.
  private static let minimumEffectDuration: TimeInterval = 0.35

  /// How long a lid held above the start angle waits before it counts as
  /// opened again, for openings slower than `triggerOpeningSpeed`.
  private static let openDwellDuration: TimeInterval = 1

  /// Movement within this many degrees counts as holding still.
  private static let timeoutMovementThreshold: Double = 2

  /// How long the lid has to hold still before the timeout ends the effect.
  private static let timeoutStillDuration: TimeInterval = 2

  /// How close the eased angle must get to flat before the last frame
  /// snaps there. Half a degree short, the dim curve still darkens the top
  /// of the picture by several percent, and the fade would then reveal a
  /// brighter screen underneath.
  private static let closingOutSettleEpsilon: Double = 0.05

  /// Safety cap, in case the spring never quite settles.
  private static let closingOutMaxDuration: TimeInterval = 1.2

  /// A scripted angle sweep, so the settings panel can show the effect
  /// without the lid moving. It feeds the same path the sensor feeds.
  private struct PreviewRun {
    let startedAt: CFTimeInterval
    let open: Double
    let shut: Double
    let closing: CFTimeInterval = 1.4
    let hold: CFTimeInterval = 0.8
    let opening: CFTimeInterval = 0.6

    /// `nil` once the run is over.
    func angle(at now: CFTimeInterval) -> Double? {
      let elapsed = now - startedAt
      if elapsed < closing { return open + (shut - open) * (elapsed / closing) }
      if elapsed < closing + hold { return shut }
      if elapsed < closing + hold + opening {
        return shut + (open - shut) * ((elapsed - closing - hold) / opening)
      }
      return nil
    }
  }

  // 添加、移除和偏好同步都走同一个入口。
  func configure(enabled: Bool) {
    guard enabled else { return stop() }
    let newOptions = LidDepthOptions()
    guard !isStarted || newOptions != preferences else { return }
    if newOptions.enabled != preferences.enabled || newOptions.live != preferences.live
      || newOptions.thresholdAngle != preferences.thresholdAngle
    {
      if isStarted { resetRun() }
    }
    preferences = newOptions
    if isStarted {
      if !preferences.enabled, !isSuspended { currentAngle = sensor?.angle() }
      resumePolling()
    } else {
      start()
    }
  }

  // 只有已添加插件才探测硬件并安装系统监听。
  private func start() {
    isStarted = true
    let sensor = LidAngleSensor()
    guard sensor.isAvailable else { return }
    self.sensor = sensor
    isSensorAvailable = true
    currentAngle = sensor.angle()
    builtInLayout = .current
    // 添加或启动只查授权，系统弹框由设置里的按钮发起。
    checkScreenAccess()
    observeSystemEvents()
    resumePolling()
  }

  // 移除时撤销系统监听、窗口、取画和传感器句柄。
  func stop() {
    guard isStarted else { return }
    isStarted = false
    stopPolling()
    for (center, token) in observers { center.removeObserver(token) }
    observers.removeAll()
    pauses.removeAll()
    resetRun()
    overlay.releaseRenderer()
    source.invalidate()
    sensor = nil
    currentAngle = nil
    isSensorAvailable = false
    hasScreenAccess = false
  }

  // 立即取消当前效果，包括异步等待中的一帧。
  private func stopEffectAndCapture() {
    preview = nil
    isActive = false
    isClosingOut = false
    stopDisplayLink()
    overlay.dismiss(animated: false)
    stopCapture()
  }

  // 结束预热、静态帧和实时流，释放屏幕抓取用的锚点和纹理。
  private func stopCapture() {
    pictureTask?.cancel()
    pictureTask = nil
    isCapturePending = false
    isPrewarming = false
    nextStillAttempt = 0
    snapshotter.stop()
    streamer.stop()
    source.releaseAnchor()
    overlay.discardLive()
  }

  // 清掉上一次的移动趋势与超时，避免睡醒或改设置后直接触发。
  private func resetRun() {
    stopEffectAndCapture()
    lastChangedAngle = nil
    angularVelocity = 0
    lastClosingTime = -.greatestFiniteMagnitude
    motionIntent.reset()
    openDwell.reset()
    peakAngle = 0
    consecutiveFailedReads = 0
    timeoutReferenceAngle = nil
    timeoutAwaitingRelease = false
    wasTimeoutEnabled = false
  }

  // 授权变化时起停轮询；已关掉效果时只在设置需要时读取一次角度。
  func checkScreenAccess() {
    guard isStarted, isSensorAvailable else { return }
    let allowed = Permissions.isScreenRecordingAllowed
    guard allowed != hasScreenAccess else { return }
    hasScreenAccess = allowed
    if !allowed { resetRun() }
    resumePolling()
  }

  // 用同一条渲染链路模拟合盖和打开。返回原因让入口沿用 Kitty Tools 提示。
  func runPreview() -> PreviewBlocker? {
    guard isStarted, preferences.enabled else { return .disabled }
    guard isSensorAvailable, builtInLayout.displayID != nil else { return .unavailable }
    checkScreenAccess()
    guard hasScreenAccess else { return .permission }
    guard !isSuspended, !hostIsBusy(), preview == nil, !isActive else { return .busy }
    resetRun()
    preview = PreviewRun(
      startedAt: CACurrentMediaTime(),
      open: max(
        preferences.thresholdAngle + Self.hysteresis + 5, min(preferences.thresholdAngle + 35, 130)),
      shut: max(preferences.thresholdAngle - preferences.blurSpan * 1.15, 5)
    )
    setPollInterval(Self.activePollInterval)
    return nil
  }

  // MARK: - Polling

  // 轮询只在已授权、有效会话和效果开启期间使用。
  private func resumePolling() {
    guard isStarted, isSensorAvailable, !isSuspended, preferences.enabled, hasScreenAccess else {
      stopPolling()
      return
    }
    setPollInterval(Self.idlePollInterval)
  }

  // 停掉计时器，允许下一次以相同频率重新添加。
  private func stopPolling() {
    pollTimer?.invalidate()
    pollTimer = nil
    pollInterval = 0
  }

  // 醒来、静止和移动时切换轮询频率。
  private func setPollInterval(_ interval: TimeInterval) {
    guard pollInterval != interval else { return }
    pollInterval = interval
    pollTimer?.invalidate()
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
    RunLoop.main.add(timer, forMode: .common)
    pollTimer = timer
  }

  // 每次读一个样本；宿主临时占用屏幕时结束当前动效。
  private func poll() {
    guard !isSuspended else { return }
    guard let angle = sampleAngle() else { return }
    rawAngle = angle
    peakAngle = max(peakAngle, angle)
    if isActive { lowestRunAngle = min(lowestRunAngle, angle) }
    if preview == nil { publish(angle: angle) }
    updateVelocity(with: angle)
    let now = CACurrentMediaTime()
    if isActive || isClosingOut || isPrewarming || preview != nil || recentlyClosing(at: now),
      hostIsBusy()
    {
      resetRun()
      return
    }
    openDwell.update(angle: angle, at: now, dwellAngle: effectPolicy.dwellAngle)
    reconcile(angle: angle)
    let wantsFast =
      preview != nil || isActive || isClosingOut || recentlyClosing(at: now)
      || (angularVelocity.magnitude >= Self.triggerClosingSpeed
        && angle <= preferences.thresholdAngle + Self.fastPollMargin)
    setPollInterval(wantsFast ? Self.activePollInterval : Self.idlePollInterval)
  }

  // 预览用模拟角度；硬件读数连续出错则退出当前效果。
  private func sampleAngle() -> Double? {
    if let preview {
      if let angle = preview.angle(at: CACurrentMediaTime()) { return angle }
      resetRun()
      setPollInterval(Self.idlePollInterval)
      return nil
    }
    guard let angle = sensor?.angle() else {
      consecutiveFailedReads += 1
      if consecutiveFailedReads > 30 { resetRun() }
      return nil
    }
    consecutiveFailedReads = 0
    return angle
  }

  // 只有刚发生合盖动作时才允许预热。
  private func recentlyClosing(at now: TimeInterval) -> Bool {
    now - lastClosingTime < Self.prewarmLinger
  }

  private var effectPolicy: LidDepthPolicy {
    LidDepthPolicy(threshold: preferences.thresholdAngle, hysteresis: Self.hysteresis)
  }

  /// Whether the picture belongs on screen for this angle. It widens the
  /// angle for release and keeps a lid held below the angle showing, unless
  /// the timeout ends it first.
  private func wantsEffect(angle: Double) -> Bool {
    // `builtInLayout` is kept current by the screen change observer, so
    // this does not enumerate the screens on every sample.
    guard preferences.enabled, builtInLayout.displayID != nil else { return false }
    if preferences.timeout != wasTimeoutEnabled {
      timeoutReferenceAngle = nil
      timeoutAwaitingRelease = false
      wasTimeoutEnabled = preferences.timeout
    }

    let now = CACurrentMediaTime()
    let threshold = preferences.thresholdAngle
    let minimumDurationElapsed = now - startedAt > Self.minimumEffectDuration

    if !isActive, preferences.timeout, timeoutAwaitingRelease {
      guard angle >= threshold else { return false }
      timeoutAwaitingRelease = false
    }

    let wanted = effectPolicy.wantsEffect(
      isEnabled: preferences.enabled,
      isActive: isActive,
      angle: angle,
      predictedAngle: predictedAngle(),
      riseSinceLowest: angle - lowestRunAngle,
      hasBeenAboveThreshold: peakAngle >= threshold,
      wasClosingRecently: motionIntent.wasClosingRecently(
        at: now,
        memoryDuration: Self.closingMemory
      ),
      isClearlyOpening: angularVelocity >= Self.triggerOpeningSpeed,
      hasDwelledOpen: openDwell.hasDwelled(at: now, duration: Self.openDwellDuration),
      minimumDurationElapsed: minimumDurationElapsed
    )

    // The timeout only cuts short a run the policy would keep showing.
    if isActive, wanted, minimumDurationElapsed,
      preferences.timeout, isPastTimeout(angle: angle)
    {
      timeoutAwaitingRelease = true
      return false
    }
    return wanted
  }

  /// True once the angle has held within `timeoutMovementThreshold` of its
  /// last significant position for `timeoutStillDuration`.
  private func isPastTimeout(angle: Double) -> Bool {
    let now = CACurrentMediaTime()
    if let reference = timeoutReferenceAngle,
      abs(angle - reference) <= Self.timeoutMovementThreshold
    {
      return now - timeoutReferenceTime >= Self.timeoutStillDuration
    }
    timeoutReferenceAngle = angle
    timeoutReferenceTime = now
    return false
  }

  /// Brings the screen in line with `wantsEffect` on every sample. A run
  /// whose screenshot failed is retried here.
  private func reconcile(angle: Double) {
    guard preferences.enabled, !isSuspended else { return }
    let wanted = wantsEffect(angle: angle)
    if wanted != isActive {
      LidDepthLog.lid.notice(
        """
        \(wanted ? "start" : "end", privacy: .public) raw \(angle, format: .fixed(precision: 2)) \
        predicted \(self.predictedAngle(), format: .fixed(precision: 2)) \
        velocity \(self.angularVelocity, format: .fixed(precision: 1)) deg/s \
        snapshot \(self.snapshotter.latestImage != nil)
        """
      )
      setActive(wanted)
      return
    }
    if isActive {
      if preferences.live { streamer.start() }
      if !overlay.isVisible { presentPicture() }
      if overlay.isVisible, !overlay.isPictureReady { requestStillPicture() }
      // A visible overlay with no link would sit at its first frame.
      if overlay.isVisible, displayLink == nil { startDisplayLink() }
    } else if !isClosingOut {
      // The ease back to flat still draws the live picture, and this
      // would free it.
      updatePrewarm(angle: angle, ceiling: preferences.thresholdAngle + Self.prewarmCeiling)
    }
  }

  // 由相邻的不同角度估算速度，抑制重复读数带来的抖动。
  private func updateVelocity(with angle: Double) {
    let now = CACurrentMediaTime()
    guard let last = lastChangedAngle else {
      lastChangedAngle = angle
      lastChangeTime = now
      return
    }
    if angle != last {
      let dt = now - lastChangeTime
      if dt > 0.001 {
        let instant = (angle - last) / dt
        angularVelocity = 0.5 * instant + 0.5 * angularVelocity
      }
      lastChangedAngle = angle
      lastChangeTime = now
    } else if now - lastChangeTime > 0.4 {
      angularVelocity = 0
    }
    motionIntent.update(
      angularVelocity: angularVelocity,
      at: now,
      closingSpeed: Self.triggerClosingSpeed,
      openingSpeed: Self.triggerOpeningSpeed
    )
    if angularVelocity >= Self.triggerOpeningSpeed {
      lastClosingTime = -.greatestFiniteMagnitude
    } else if angularVelocity <= -Self.prewarmSpeed {
      lastClosingTime = now
    }
  }

  /// Runs only while the lid is closing, so holding it still does not leave
  /// a capture loop running.
  private func updatePrewarm(angle: Double, ceiling: Double) {
    guard angle <= ceiling, recentlyClosing(at: CACurrentMediaTime()) else {
      if isPrewarming { stopCapture() }
      return
    }
    isPrewarming = true
    overlay.warmUp()
    guard preferences.live else {
      streamer.stop()
      overlay.discardLive()
      snapshotter.beginPrewarm(interval: Self.stillPrewarmInterval)
      return
    }
    // Only the stream. Asking ScreenCaptureKit for a screenshot at the
    // same time makes it serve neither quickly.
    snapshotter.endPrewarm()
    streamer.start()
  }

  /// A reading can be a full sensor refresh old, so a fast close works from
  /// where the lid is heading rather than the last reading.
  private func predictedAngle() -> Double {
    guard angularVelocity < -Self.predictionSpeedFloor else { return rawAngle }
    let staleness = min(CACurrentMediaTime() - lastChangeTime, 0.12)
    return rawAngle + angularVelocity * (staleness + Self.predictionLatency)
  }

  // 限速更新设置页上的角度。
  private func publish(angle: Double) {
    let now = CACurrentMediaTime()
    guard now - lastPublishTime > 0.08 else { return }
    lastPublishTime = now
    if currentAngle.map({ abs($0 - angle) > 0.001 }) ?? true { currentAngle = angle }
  }

  // MARK: - Depth effect

  // 动效开始准备画面，结束时先将形变还原。
  private func setActive(_ active: Bool) {
    isActive = active
    guard active else {
      timeoutReferenceAngle = nil
      beginClosingOut()
      return
    }
    beginEffect()
  }

  // 建立本轮的角度基线并启动对应的取画方式。
  private func beginEffect() {
    peakAngle = rawAngle
    lowestRunAngle = rawAngle
    openDwell.reset()
    isClosingOut = false
    startedAt = CACurrentMediaTime()
    if preferences.timeout {
      timeoutReferenceAngle = rawAngle
      timeoutReferenceTime = startedAt
    }
    visualAngle.reset(to: rawAngle)
    snapshotter.endPrewarm()
    if preferences.live { streamer.start() }
    setPollInterval(Self.activePollInterval)
    presentPicture()
  }

  /// Eases the picture back to flat before the overlay fades away. Ending
  /// the effect with the lid still shut would otherwise fade out a warped
  /// picture. `step(_:)` drives the ease and calls `finishClosingOut()`.
  private func beginClosingOut() {
    // Nothing to ease before the picture is up, or with no link to draw it.
    guard overlay.isVisible, displayLink != nil else {
      finishClosingOut()
      return
    }
    isClosingOut = true
    closingOutStartedAt = CACurrentMediaTime()
  }

  // 画面回到平面后淡出，停止捕获。
  private func finishClosingOut() {
    isClosingOut = false
    stopDisplayLink()
    overlay.dismiss(animated: !Style.reduceMotion)
    stopCapture()
  }

  // 先尝试实时流。静态模式直接显示预热画面，或者走一次截取。
  private func presentPicture() {
    guard preferences.enabled, hasScreenAccess, !isSuspended, isActive else { return }
    guard overlay.warmUp() else { return }
    if preferences.live, let screen = NSScreen.lidDepthBuiltIn,
      overlay.showLive(
        on: screen, startAngle: preferences.thresholdAngle, tuning: tuning, fadeIn: fadeIn)
    {
      startDisplayLink()
      if let frame = streamer.newFrame() { overlay.absorb(frame) }
      if !overlay.isPictureReady { requestStillPicture() }
      return
    }
    if let image = snapshotter.latestImage, let screen = snapshotter.latestScreen {
      show(image: image, on: screen)
    } else {
      requestStillPicture()
    }
  }

  // 实时首帧超时或静态预取没完成时，限速补一帧。
  private func requestStillPicture() {
    let now = CACurrentMediaTime()
    guard !isCapturePending, now >= nextStillAttempt else { return }
    nextStillAttempt = now + Self.stillRetryInterval
    isCapturePending = true
    pictureTask = Task { [weak self] in
      guard let self, !Task.isCancelled else { return }
      await snapshotter.captureOnce()
      guard !Task.isCancelled else { return }
      pictureTask = nil
      isCapturePending = false
      guard isActive, let image = snapshotter.latestImage, let screen = snapshotter.latestScreen
      else { return }
      if overlay.isVisible {
        if !overlay.isPictureReady { overlay.seed(image: image) }
      } else {
        show(image: image, on: screen)
      }
    }
  }

  // 显示静态画面，用同一个显示链推动动效。
  private func show(image: CGImage, on screen: NSScreen) {
    overlay.show(
      image: image,
      on: screen,
      startAngle: preferences.thresholdAngle,
      tuning: tuning,
      fadeIn: fadeIn
    )
    // The link belongs to the overlay window.
    startDisplayLink()
  }

  // 把合盖行程换算为模糊和渐暗的进度。
  private func blurProgress(for angle: Double) -> Double {
    let span = max(preferences.blurSpan, 1)
    return min(max((preferences.thresholdAngle - angle) / span, 0), 1)
  }

  // MARK: - Animation

  // 使用效果窗所属屏幕的显示节奏。
  private func startDisplayLink() {
    stopDisplayLink()
    guard let window = overlay.hostWindow else {
      LidDepthLog.lid.notice("display link skipped, no overlay window")
      return
    }
    LidDepthLog.lid.notice("display link started")
    let link = window.displayLink(target: self, selector: #selector(step(_:)))
    link.add(to: .main, forMode: .common)
    lastFrameTime = CACurrentMediaTime()
    displayLink = link
  }

  // 停止逐帧渲染并解除显示链持有。
  private func stopDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
  }

  // 将最新画面和角度插值合成为一帧，收尾时回到平面。
  @objc private func step(_ link: CADisplayLink) {
    let now = CACurrentMediaTime()
    let rawInterval = now - lastFrameTime
    let dt = min(max(rawInterval, 1.0 / 240), 1.0 / 20)
    lastFrameTime = now
    if let frame = streamer.newFrame() {
      overlay.absorb(frame)
    }
    let target = isClosingOut ? preferences.thresholdAngle : rawAngle
    visualAngle.advance(to: target, dt: dt)

    guard isClosingOut else {
      applyVisual(angle: visualAngle.value)
      return
    }
    // At or above the threshold the picture is already flat, so a lid
    // that opened past it finishes at once.
    let settled = visualAngle.value >= target - Self.closingOutSettleEpsilon
    let timedOut = now - closingOutStartedAt > Self.closingOutMaxDuration
    guard settled || timedOut else {
      applyVisual(angle: visualAngle.value)
      return
    }
    // The frame that fades out must match the screen behind it exactly,
    // so land on the threshold itself rather than just short of it.
    visualAngle.reset(to: target)
    applyVisual(angle: target)
    finishClosingOut()
  }

  /// The geometry takes the lid angle itself, so only the blur saturates.
  private func applyVisual(angle: Double) {
    let progress = blurProgress(for: angle)
    overlay.update(progress: progress, currentAngle: angle, tuning: tuning)
  }

  private var fadeIn: TimeInterval { Style.reduceMotion ? 0 : Self.fadeInDuration }

  private var tuning: DepthTuning {
    var result = preferences.tuning
    if Style.reduceMotion { result.recession = 0 }
    return result
  }

  // MARK: - System events

  // 插件开启期间监听显示器、登录会话和授权恢复。
  private func observeSystemEvents() {
    let workspace = NSWorkspace.shared.notificationCenter
    observe(workspace, NSWorkspace.willSleepNotification) { $0.pause(.sleep) }
    observe(workspace, NSWorkspace.didWakeNotification) { $0.unpause(.sleep) }
    observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.pause(.displaysAsleep) }
    observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.unpause(.displaysAsleep) }
    observe(workspace, NSWorkspace.sessionDidResignActiveNotification) {
      $0.pause(.inactiveSession)
    }
    observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) {
      $0.unpause(.inactiveSession)
    }
    observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.layoutChanged() }
    observe(.default, NSApplication.didBecomeActiveNotification) { $0.checkScreenAccess() }
  }

  // 所有系统通知在主线程更新，并与插件的停止操作成对注册和移除。
  private func observe(
    _ center: NotificationCenter, _ name: Notification.Name,
    _ handler: @escaping @MainActor (LidDepthController) -> Void
  ) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.isStarted else { return }
        handler(self)
      }
    }
    observers.append((center, token))
  }

  // 屏幕进入锁定、待机或关闭时马上停止捕获。
  private func pause(_ reason: Pause) {
    pauses.insert(reason)
    stopPolling()
    resetRun()
    source.invalidate()
  }

  // 多个暂停原因结束后才重新读传感器。
  private func unpause(_ reason: Pause) {
    pauses.remove(reason)
    guard !isSuspended else { return }
    builtInLayout = .current
    checkScreenAccess()
    resumePolling()
  }

  // 分辨率、屏幕位置或内建屏幕消失，都会使旧窗口和过滤器失效。
  private func layoutChanged() {
    let layout = Layout.current
    guard layout != builtInLayout else { return }
    builtInLayout = layout
    resetRun()
    source.invalidate()
  }
}
