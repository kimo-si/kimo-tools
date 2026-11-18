// OCR（2026-11-17，照 Bob 1.20）里能纯函数测的那几样：百家返回的段落怎么接、火山三种回包怎么认、
// 各家语言码的映射、服务列表的默认值和「+」里缺哪几个。

import AppKit
import Foundation
import Testing

@testable import KittyTools

@MainActor
struct OCRTests {
  /// 慢识别结束时收掉顶部进度，浮窗随后展示译文时无需再发结果提示。
  @Test func completedRecognitionDismissesProgress() async {
    let island = Island(showing: nil)
    let progress = OCRProgress(island: island)
    await progress.run(preparesLocalModel: false, noticeDelay: .zero) {
      #expect(island.content?.title == "识别中…")
    }
    #expect(island.content == nil)
  }

  /// 上一轮晚返回时新一轮仍能显示进度，取消后也能在底层工作返回前收起。
  @Test func overlappingRecognitionOwnsProgress() async throws {
    let island = Island(showing: nil)
    let progress = OCRProgress(island: island)
    let older = AsyncStream<Void>.makeStream()
    let newer = AsyncStream<Void>.makeStream()
    var firstEntered = false
    var secondEntered = false
    defer {
      older.continuation.finish()
      newer.continuation.finish()
    }
    let first = Task {
      await progress.run(preparesLocalModel: false, noticeDelay: .zero) {
        firstEntered = true
        for await _ in older.stream {}
      }
    }
    try #require(await becomesTrue { firstEntered })
    let underlyingWork = Task { for await _ in newer.stream {} }
    let second = Task {
      await progress.run(preparesLocalModel: false, noticeDelay: .zero) {
        secondEntered = true
        await underlyingWork.value
      }
    }
    try #require(await becomesTrue { secondEntered })
    older.continuation.finish()
    await first.value
    #expect(island.content?.title == "识别中…")
    second.cancel()
    #expect(await becomesTrue { island.content == nil })
    newer.continuation.finish()
    await second.value
  }

  /// 等待调度顺序上的状态变化，测试失败时仍会释放待结束的任务。
  private func becomesTrue(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
      guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return true
  }

  /// 跟随指定服务或列表顺序；关闭的服务、旧的选择不会被偷偷重新启用。
  @Test func screenshotServiceSelection() {
    var apple = OCRService.builtin(.apple)
    var tencent = OCRService.builtin(.tencent)
    tencent.isEnabled = true
    #expect(OCRService.selected(in: [apple, tencent], choice: "tencent") == tencent)
    #expect(OCRService.selected(in: [apple, tencent], choice: "") == apple)
    apple.isEnabled = false
    #expect(OCRService.selected(in: [apple, tencent], choice: "apple") == tencent)
    tencent.isEnabled = false
    #expect(OCRService.selected(in: [apple, tencent], choice: "tencent") == nil)
  }

  /// 腾讯高精度使用 ConfigID，不发送这个接口不支持的 Language 参数。
  @Test func tencentRequestLanguages() throws {
    for language: Lang? in [nil, .zhHans, .en, .ja, .ko, .ru] {
      let body = try TencentOCR.requestBody(image: "sample", language: language)
      let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
      #expect(
        json["ConfigID"] == ([Lang.zhHans, .en].contains(language ?? .ja) ? "OCR" : "MulOCR"))
      #expect(json["Language"] == nil)
    }
  }

  /// 坐标按上传尺寸归一化、翻转 Y；旋转图只接受原图四点，不误用校正后的框。
  @Test func tencentOriginalCoordinates() throws {
    let polygon = [
      ["X": 100, "Y": 40], ["X": 300, "Y": 40], ["X": 300, "Y": 80], ["X": 100, "Y": 80],
    ]
    let object: [String: Any] = [
      "Response": [
        "Angle": 90,
        "TextDetections": [
          ["DetectedText": "Hello", "Polygon": polygon],
          [
            "DetectedText": "World", "Polygon": NSNull(),
            "ItemPolygon": ["X": 10, "Y": 20, "Width": 100, "Height": 30],
          ],
        ],
      ]
    ]
    let result = try TencentOCR.result(from: object, imageSize: CGSize(width: 1000, height: 400))
    #expect(result.text == "Hello\nWorld" && result.lines == 2)
    #expect(
      result.regions == [
        OCR.Line(text: "Hello", box: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.1))
      ])
  }

  /// 越界框夹回图片内，零面积与图外框不允许参与覆盖。
  @Test func tencentInvalidCoordinates() throws {
    let detections: [[String: Any]] = [-20, 1000].map { x in
      ["DetectedText": "text", "ItemPolygon": ["X": x, "Y": 10, "Width": 40, "Height": 20]]
    }
    let result = try TencentOCR.result(
      from: ["Response": ["Angle": 0, "TextDetections": detections]],
      imageSize: CGSize(width: 100, height: 100))
    #expect(result.regions.count == 1)
    #expect(result.regions.first?.box == CGRect(x: 0, y: 0.7, width: 0.2, height: 0.2))
  }

  /// 按需联网探针：只上传屏外合成文字，用 Dev 版已有配置，不读取屏幕、不打印密钥或响应正文。
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_TENCENT_OCR"] == "1"))
  func liveTencentImageTranslation() async throws {
    let service = try #require(OCRServiceStore().enabled.first { $0.kind == .tencent })
    let image = try ScreenshotTests.render(["Hello world", "Image translation test", "中文识别测试"])
    for round in 1...2 {
      let started = ContinuousClock.now
      let result = try await service.recognizeForTranslation(
        image, language: nil, requiresLayout: true)
      let elapsed = ContinuousClock.now - started
      #expect(result.text.contains("Hello") && result.text.contains("中文识别测试"))
      #expect(!result.regions.isEmpty && result.regions.allSatisfy { !$0.box.isEmpty })
      let segments = await ScreenshotOverlay.prepareSegments(of: result.regions, in: image)
      let rendered = await ScreenshotOverlay.render(
        image, segments: segments, translations: segments.map { _ in "翻译结果" }, pixelsPerPoint: 2)
      #expect(rendered.image != nil)
      print("ocr-probe provider=tencent round=\(round) elapsed=\(elapsed) lines=\(result.lines)")
    }
  }

  @Test func serviceStoreDefaultsAndMissing() {
    let store = OCRServiceStore(services: OCRServiceStore.defaults)
    #expect(store.services.map(\.id) == ["apple"])
    #expect(store.enabled.map(\.id) == ["apple"])
    #expect(store.missingBuiltins == [.baidu, .tencent, .volcengine])
    // 删掉 Apple 也能从「+」加回来
    store.remove("apple")
    #expect(store.services.isEmpty)
    #expect(store.missingBuiltins == OCRService.Kind.allCases)
    // 内置服务的钥匙串账户名分开，不和翻译的混
    #expect(OCRService.builtin(.baidu).account("apiKey") == "ocr.baidu.apiKey")
  }

  @Test func baiduParagraphs() {
    let words: [[String: Any]] = [
      ["words": "第一行"], ["words": "第二行"], ["words": "第三段"],
    ]
    #expect(BaiduOCR.text(words: words, paragraphs: nil) == "第一行\n第二行\n第三段")
    let paragraphs: [[String: Any]] = [
      ["words_result_idx": [0, 1]], ["words_result_idx": [2]],
    ]
    #expect(BaiduOCR.text(words: words, paragraphs: paragraphs) == "第一行\n第二行\n\n第三段")
    // 索引越界、空段落都跳过
    #expect(
      BaiduOCR.text(
        words: words, paragraphs: [["words_result_idx": [9]], ["words_result_idx": [0]]])
        == "第一行")
  }

  @Test func volcengineResponseShapes() {
    #expect(VolcengineOCR.lines(in: ["Result": ["line_texts": ["a", "b"]]]) == ["a", "b"])
    #expect(
      VolcengineOCR.lines(in: ["Result": ["data": ["line_texts": ["x"]]]]) == ["x"])
    #expect(
      VolcengineOCR.lines(in: ["ocr_infos": [["text": "一"], ["text": "二"]]]) == ["一", "二"])
    #expect(VolcengineOCR.lines(in: ["line_texts": ["top"]]) == ["top"])
    #expect(VolcengineOCR.lines(in: [:]).isEmpty)
  }

  @Test func languageCodes() {
    #expect(Lang.zhHans.visionCode == "zh-Hans")
    #expect(Lang.zhHant.visionCode == "zh-Hant")
    #expect(Lang.ja.visionCode == "ja-JP")
    #expect(Lang.zhHans.baiduOCRCode == "CHN_ENG")
    #expect(Lang.ko.baiduOCRCode == "KOR")
    #expect(Lang.zhHant.tencentOCRCode == "zh")
    #expect(Lang.fr.tencentOCRCode == nil)
    #expect(Lang.de.volcengineOCRCode == "de")
    #expect(OCRLanguage.title("") == "自动")
    #expect(OCRLanguage.title(Lang.en.rawValue) == "英语")
  }

  @Test func serviceStatus() {
    let apple = OCRService.builtin(.apple)
    #expect(apple.isConfigured && apple.settingsStatus.text.contains("离线"))
    var baidu = OCRService.builtin(.baidu)
    baidu.isEnabled = true
    #expect(!baidu.isConfigured && baidu.settingsStatus.isProblem)
    // 关着的服务缺密钥只写出来、不标橙
    baidu.isEnabled = false
    #expect(!baidu.settingsStatus.isProblem)
  }
}
