// 触发策略测试改编自 Mac Duo（Copyright 2026 Makito，Apache-2.0）。
import CoreGraphics
import Foundation
import Testing

@testable import KittyTools

@MainActor
struct LidDepthTests {
  private let highThreshold = LidDepthPolicy(threshold: 130, hysteresis: 4)

  @Test
  func testOpeningReleasesWithoutReachingHysteresisAngle() {
    #expect(activeEffect(angle: 129, opening: false))
    #expect(!activeEffect(angle: 130, opening: true, minimumDurationElapsed: false))
    #expect(!activeEffect(angle: 131, opening: true))
    #expect(!activeEffect(angle: 133, opening: true))
  }

  @Test
  func testStationaryLidBelowThresholdKeepsActiveEffect() {
    #expect(activeEffect(angle: 129, opening: false))
  }

  @Test
  func testJitterAroundThresholdUsesOrdinaryHysteresis() {
    #expect(activeEffect(angle: 129.8, opening: false))
    #expect(activeEffect(angle: 130.2, opening: false))
    #expect(activeEffect(angle: 129.9, opening: false))
  }

  @Test
  func testOrdinaryConfigurationStillReleasesAtHysteresisAngle() {
    let policy = LidDepthPolicy(threshold: 90, hysteresis: 4)

    #expect(wantsActiveEffect(policy: policy, angle: 93.9, opening: false))
    #expect(!wantsActiveEffect(policy: policy, angle: 94, opening: false))
  }

  @Test
  func testOpeningReversalInvalidatesClosingMemory() {
    var intent = LidMotionIntent()
    intent.update(angularVelocity: -3, at: 10, closingSpeed: 2, openingSpeed: 2)
    #expect(intent.wasClosingRecently(at: 10.1, memoryDuration: 1.5))

    intent.update(angularVelocity: 3, at: 10.2, closingSpeed: 2, openingSpeed: 2)
    #expect(!intent.wasClosingRecently(at: 10.2, memoryDuration: 1.5))

    // A sub-threshold jitter sample must not restore closing intent.
    intent.update(angularVelocity: -0.4, at: 10.3, closingSpeed: 2, openingSpeed: 2)
    #expect(!intent.wasClosingRecently(at: 10.3, memoryDuration: 1.5))
    #expect(
      !highThreshold.wantsEffect(
        isEnabled: true,
        isActive: false,
        angle: 129.9,
        predictedAngle: 129.9,
        riseSinceLowest: 0,
        hasBeenAboveThreshold: true,
        wasClosingRecently: intent.wasClosingRecently(at: 10.3, memoryDuration: 1.5),
        isClearlyOpening: false,
        hasDwelledOpen: false,
        minimumDurationElapsed: true
      )
    )
  }

  @Test
  func testRestingBelowThresholdDoesNotActivate() {
    #expect(
      !highThreshold.wantsEffect(
        isEnabled: true,
        isActive: false,
        angle: 129,
        predictedAngle: 129,
        riseSinceLowest: 0,
        hasBeenAboveThreshold: true,
        wasClosingRecently: false,
        isClearlyOpening: false,
        hasDwelledOpen: false,
        minimumDurationElapsed: true
      )
    )
  }

  @Test
  func testSlowOpeningReleasesAfterDwell() {
    #expect(activeEffect(angle: 133, opening: false))
    #expect(!activeEffect(angle: 133, opening: false, dwelled: true))
  }

  @Test
  func testDwellAngleIsTheThreshold() {
    // A hinge whose limit rounds to the threshold must still release.
    #expect(highThreshold.dwellAngle == 130)
  }

  @Test
  func testDwellRestartsWhenLidDropsBelowDwellAngle() {
    let dwellAngle = highThreshold.dwellAngle
    var dwell = LidOpenDwell()
    dwell.update(angle: 130, at: 10, dwellAngle: dwellAngle)
    #expect(!dwell.hasDwelled(at: 10.5, duration: 1))
    #expect(dwell.hasDwelled(at: 11, duration: 1))

    // Jitter back below the start angle restarts the wait.
    dwell.update(angle: 129.5, at: 11.1, dwellAngle: dwellAngle)
    dwell.update(angle: 130, at: 11.2, dwellAngle: dwellAngle)
    #expect(!dwell.hasDwelled(at: 12, duration: 1))
  }

  @Test
  func testOneWholeDegreeStepDoesNotReleaseOnOpening() {
    // A whole-degree sensor resting on a half-degree boundary alternates
    // 129/130. The step reads as fast opening, but the rise is only 1°.
    #expect(activeEffect(angle: 130, opening: true, rise: 1))
    #expect(activeEffect(angle: 130, opening: true, rise: 1, minimumDurationElapsed: false))
  }

  @Test
  func testRiseAboveOneStepReleasesOnOpening() {
    #expect(!activeEffect(angle: 130, opening: true, rise: LidDepthPolicy.minimumReleaseRise))
    #expect(!activeEffect(angle: 130.9, opening: true, rise: 70))
  }

  @Test
  func testSmallOpeningStillReleasesThroughDwell() {
    // Too small a rise for the speed release, but held above the threshold.
    #expect(!activeEffect(angle: 130, opening: false, dwelled: true, rise: 1))
  }

  // 运行时校验同步参数，恢复默认时保留插件开关。
  @Test func optionsClampImportedValues() throws {
    let name = "kitty-lid-depth-test-\(UUID().uuidString)"
    let prefs = try #require(UserDefaults(suiteName: name))
    defer { prefs.removePersistentDomain(forName: name) }
    prefs.set(true, forKey: Feature.lidDepth.prefsKey)
    prefs.set(false, forKey: Prefs.lidDepthLive)
    prefs.set(250.0, forKey: Prefs.lidDepthAngle)
    prefs.set(-2.0, forKey: Prefs.lidDepthPerspective)
    let options = LidDepthOptions(prefs)
    #expect(!options.live)
    #expect(options.thresholdAngle == 130)
    #expect(options.tuning.viewingDistance == 6)
    #expect(LidDepthOptions.Setting.blur.clamped(.infinity) == 135)
    #expect(LidDepthOptions.defaults.keys.allSatisfy { SettingsArchive.kinds[$0] != nil })
    LidDepthOptions.reset(prefs)
    #expect(LidDepthOptions(prefs).live)
    #expect(prefs.bool(forKey: Feature.lidDepth.prefsKey))
  }

  // 不打开窗口、不读取屏幕，检验移植的 MSL 可编译并能为静态画面建纹理。
  @Test func metalPipelinePreparesSyntheticPicture() async throws {
    let resources = try #require(await LidDepthRenderer.prepare())
    let renderer = LidDepthRenderer(resources: resources)
    let context = try #require(
      CGContext(
        data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let prepared = try #require(
      await renderer.makePicture(image: image, screenSize: CGSize(width: 32, height: 24), pixelScale: 1))
    renderer.adopt(prepared)
    #expect(renderer.isReady)
    renderer.release()
    #expect(!renderer.isReady)
  }

  private func activeEffect(
    angle: Double,
    opening: Bool,
    dwelled: Bool = false,
    rise: Double = 40,
    minimumDurationElapsed: Bool = true
  ) -> Bool {
    wantsActiveEffect(
      policy: highThreshold,
      angle: angle,
      opening: opening,
      dwelled: dwelled,
      rise: rise,
      minimumDurationElapsed: minimumDurationElapsed
    )
  }

  private func wantsActiveEffect(
    policy: LidDepthPolicy,
    angle: Double,
    opening: Bool,
    dwelled: Bool = false,
    rise: Double = 40,
    minimumDurationElapsed: Bool = true
  ) -> Bool {
    policy.wantsEffect(
      isEnabled: true,
      isActive: true,
      angle: angle,
      predictedAngle: angle,
      riseSinceLowest: rise,
      hasBeenAboveThreshold: true,
      wasClosingRecently: false,
      isClearlyOpening: opening,
      hasDwelledOpen: dwelled,
      minimumDurationElapsed: minimumDurationElapsed
    )
  }
}
