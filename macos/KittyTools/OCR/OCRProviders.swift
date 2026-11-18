// OCR 的四个服务（2026-11-17，照 Bob 1.20 的 OCR 服务做的）：Apple 系统（Vision，本机离线）、百度 OCR（aip）、
// 腾讯 OCR（TC3 签名的 GeneralAccurateOCR）、火山 OCR（visual.volcengineapi.com 的多语种文字识别）。
// 接口、参数、错误码都是从 Bob 1.20 的二进制里认出来的（AppleOCR / BaiduOCR / TencentOCR / VolcengineOCR 那几个类），
// 签名沿用 Translate/Providers 里已经有的那套（腾讯 TC3、火山 HMAC-SHA256）。
// 四家都返回一行行文字：Apple 带行框（用 Clipboard/OCR 的段落拼接），三家云的按接口给的顺序接。

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: 本机（Vision）

nonisolated enum AppleOCR {
  /// Vision 的识字在 macOS 15 起都有（本 App 最低 15）
  static var isAvailable: Bool { true }

  static func recognize(_ image: CGImage, language: Lang?) async throws -> OCRResult {
    // 选了语言才给提示；自动时和截图翻译 / 识字一样什么都不给（写死语言会丢混排里的其它文字）
    let codes = language.map { [$0.visionCode] } ?? []
    guard let lines = await OCR.recognizeLines(in: image, languages: codes) else {
      throw TranslateError(message: "本机没能识别这张图")
    }
    let text = OCR.text(lines, joined: true, separator: "\n")
    guard !text.isEmpty else { throw TranslateError.emptyResult }
    return OCRResult(text: text, lines: lines.count, regions: lines)
  }
}

// MARK: 百度

nonisolated enum BaiduOCR {
  static let tokenURL = "https://aip.baidubce.com/oauth/2.0/token"

  static func recognize(_ image: CGImage, language: Lang?, service: OCRService) async throws
    -> OCRResult
  {
    guard let apiKey = service.secret("apiKey"), let secretKey = service.secret("secretKey") else {
      throw TranslateError.config("请先在设置里填写百度 OCR 的 API Key 和 Secret Key")
    }
    let token = try await BaiduToken.shared.token(apiKey: apiKey, secretKey: secretKey)
    guard let base64 = OCRImage.base64(image) else {
      throw TranslateError(message: "这张图转不成 JPEG，换一张试试")
    }
    var fields: [(String, String)] = [
      ("image", base64), ("detect_direction", "true"), ("paragraph", "true"),
      ("probability", "true"),
    ]
    if let language { fields.append(("language_type", language.baiduOCRCode)) }
    var components = URLComponents(
      string: "https://aip.baidubce.com/rest/2.0/ocr/v1/accurate_basic")!
    components.queryItems = [URLQueryItem(name: "access_token", value: token)]
    var request = URLRequest(url: components.url!)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Signing.form(fields)
    let object = try await HTTP.send(request)
    if let code = object["error_code"], "\(code)" != "0" {
      let value = "\(code)"
      // Token 过期 / 无效：把缓存清掉，下一次重新取（不然会一直拿着坏 token 到 30 天后）
      if value == "110" || value == "111" { await BaiduToken.shared.invalidate(apiKey: apiKey) }
      throw error(code: value)
    }
    let words = object["words_result"] as? [[String: Any]] ?? []
    let text = Self.text(words: words, paragraphs: object["paragraphs_result"] as? [[String: Any]])
    guard !text.isEmpty else { throw TranslateError.emptyResult }
    return OCRResult(text: text, lines: words.count)
  }

  /// 有段落分组时按段落接（段内的行换行，段间空一行）；没有就一行一行
  static func text(words: [[String: Any]], paragraphs: [[String: Any]]?) -> String {
    let lines = words.compactMap { $0["words"] as? String }
    guard let paragraphs, !paragraphs.isEmpty else {
      return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var result: [String] = []
    for paragraph in paragraphs {
      // JSONSerialization 给的是 NSNumber，直接 as? [Int] 有时转不过去
      let indexes =
        (paragraph["words_result_idx"] as? [Any])?.compactMap {
          ($0 as? NSNumber)?.intValue
        } ?? []
      let picked = indexes.compactMap { lines.indices.contains($0) ? lines[$0] : nil }
      guard !picked.isEmpty else { continue }
      result.append(picked.joined(separator: "\n"))
    }
    return result.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 百度 OCR 的错误码 → 用户看得懂的中文。密钥类是配置错误（橙色、去设置）
  static func error(code: String) -> TranslateError {
    switch code {
    case "110", "111": .config("Access Token 无效或过期，请再试一次")
    case "17", "19": TranslateError(message: "百度 OCR 今天的免费额度用完了")
    case "18": TranslateError(message: "请求太频繁，稍后再试")
    case "216200", "216201", "216202": TranslateError(message: "图片读不出来或太大了")
    case "216203", "216630", "216631": TranslateError(message: "百度没能识别这张图里的文字")
    case "216632", "216633", "216634": TranslateError(message: "百度 OCR 不支持这张图（格式或语言）")
    case "282003", "282004", "282005": TranslateError(message: "请求参数不对，请重试")
    case "282000": TranslateError(message: "百度服务出错，请重试")
    default: TranslateError(message: "百度 OCR 出错（错误码 \(code)）")
    }
  }
}

/// 百度的 access_token 有效期 30 天：按 API Key 缓存在内存里，过期前 1 分钟重取
actor BaiduToken {
  static let shared = BaiduToken()
  private var cache: [String: (token: String, expires: Date)] = [:]

  func token(apiKey: String, secretKey: String) async throws -> String {
    if let entry = cache[apiKey], entry.expires > .now { return entry.token }
    var components = URLComponents(string: BaiduOCR.tokenURL)!
    components.queryItems = [
      URLQueryItem(name: "grant_type", value: "client_credentials"),
      URLQueryItem(name: "client_id", value: apiKey),
      URLQueryItem(name: "client_secret", value: secretKey),
    ]
    var request = URLRequest(url: components.url!)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    // 不走 HTTP.send：它看见 JSON 里的 error 就抛成服务类错误，而这里要按「密钥不对」提示（橙色、去设置）
    let (data, response) = try await HTTP.perform {
      try await URLSession.shared.data(for: request)
    }
    guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
      throw TranslateError.config("百度 OCR 拿 Access Token 失败，请检查密钥和网络")
    }
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    if let error = object["error"] as? String {
      let description = object["error_description"] as? String ?? error
      throw TranslateError.config("百度 OCR 的密钥不对：\(description.prefix(120))")
    }
    guard let token = object["access_token"] as? String, !token.isEmpty else {
      throw TranslateError.config("百度 OCR 没有返回 Access Token，请检查密钥")
    }
    let expires = (object["expires_in"] as? NSNumber)?.doubleValue ?? 2_592_000
    // 提前一分钟过期，免得刚好卡在边界上
    cache[apiKey] = (token, Date.now.addingTimeInterval(max(60, expires - 60)))
    return token
  }

  func invalidate(apiKey: String) {
    cache[apiKey] = nil
  }
}

// MARK: 腾讯

nonisolated enum TencentOCR {
  static let host = "ocr.tencentcloudapi.com"

  /// 按实际上传尺寸还原位置；图片编码在后台执行，不占主线程。
  @concurrent
  static func recognize(_ image: CGImage, language: Lang?, service: OCRService) async throws
    -> OCRResult
  {
    let uploaded = OCRImage.resized(image, maxDimension: OCRImage.maxDimension)
    let request = try makeRequest(uploaded, language: language, service: service)
    // 发起一轮 OCR，同时取文字和原图位置，不再额外运行 Vision。
    let object = try await HTTP.send(request)
    try Task.checkCancellation()
    return try result(
      from: object, imageSize: CGSize(width: uploaded.width, height: uploaded.height))
  }

  /// 高精度接口没有 Language 参数；自动和非中英语种使用其多语种配置。
  static func requestBody(image: String, language: Lang?) throws -> Data {
    struct Body: Encodable {
      enum CodingKeys: String, CodingKey {
        case imageBase64 = "ImageBase64"
        case configID = "ConfigID"
      }

      var imageBase64: String
      var configID: String
    }
    let basic = language.map { [.zhHans, .zhHant, .en].contains($0) } ?? false
    return try JSONEncoder().encode(Body(imageBase64: image, configID: basic ? "OCR" : "MulOCR"))
  }

  /// 生成腾讯签名请求，密钥只用于签名、不写日志。
  private static func makeRequest(_ image: CGImage, language: Lang?, service: OCRService) throws
    -> URLRequest
  {
    guard let secretID = service.secret("secretId"), let secretKey = service.secret("secretKey")
    else {
      throw TranslateError.config("请先在设置里填写腾讯云的 SecretId 和 SecretKey")
    }
    guard let base64 = OCRImage.base64(image) else {
      throw TranslateError(message: "这张图转不成 JPEG，换一张试试")
    }
    let body = try requestBody(image: base64, language: language)
    var request = URLRequest(url: URL(string: "https://\(host)")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.httpBody = body
    let region = (service.region ?? "").trimmingCharacters(in: .whitespaces)
    for (name, value) in Tencent.headers(
      secretID: secretID, secretKey: secretKey, body: body,
      timestamp: Int(Date.now.timeIntervalSince1970),
      host: host, service: "ocr", action: "GeneralAccurateOCR", version: "2018-11-19",
      region: region.isEmpty ? "ap-beijing" : region)
    {
      request.setValue(value, forHTTPHeaderField: name)
    }
    return request
  }

  /// 解码为对象后统一校验；原图 polygon 与旋转校正后的 itemPolygon 不能混用。
  static func result(from object: [String: Any], imageSize: CGSize) throws -> OCRResult {
    let data = try JSONSerialization.data(withJSONObject: object)
    let response = try JSONDecoder().decode(Envelope.self, from: data).response
    if let error = response.error {
      let code = error.code
      let isKey =
        code.hasPrefix("AuthFailure") || code.hasPrefix("Unauthorized")
        || code.hasPrefix("InvalidParameterValue.SecretId")
      throw TranslateError(
        message: "腾讯 OCR 错误：\(error.message.prefix(160))", kind: isKey ? .config : .service)
    }
    let detections = (response.textDetections ?? []).filter { !$0.text.isEmpty }
    let lines = detections.map(\.text)
    let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw TranslateError.emptyResult }
    let regions = detections.compactMap { $0.line(imageSize: imageSize, angle: response.angle) }
    return OCRResult(text: text, lines: lines.count, regions: regions)
  }

  private struct Envelope: Decodable {
    enum CodingKeys: String, CodingKey {
      case response = "Response"
    }

    var response: Response
  }

  private struct Response: Decodable {
    enum CodingKeys: String, CodingKey {
      case textDetections = "TextDetections"
      case angle = "Angle"
      case error = "Error"
    }

    var textDetections: [Detection]?
    var angle: Double?
    var error: ServiceError?
  }

  private struct ServiceError: Decodable {
    enum CodingKeys: String, CodingKey {
      case code = "Code"
      case message = "Message"
    }

    var code: String
    var message: String
  }

  private struct Point: Decodable {
    enum CodingKeys: String, CodingKey {
      case x = "X"
      case y = "Y"
    }

    var x: CGFloat
    var y: CGFloat
  }

  private struct Rectangle: Decodable {
    enum CodingKeys: String, CodingKey {
      case x = "X"
      case y = "Y"
      case width = "Width"
      case height = "Height"
    }

    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
  }

  private struct Detection: Decodable {
    enum CodingKeys: String, CodingKey {
      case detectedText = "DetectedText"
      case polygon = "Polygon"
      case itemPolygon = "ItemPolygon"
    }

    var detectedText: String
    var polygon: [Point]?
    var itemPolygon: Rectangle?

    var text: String { detectedText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 优先用原图四点坐标；只在服务明确说图片没有旋转时才接受矩形退路。
    private func bounds(angle: Double?) -> CGRect? {
      if let points = polygon, points.count >= 3,
        points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
        let left = points.map(\.x).min(), let right = points.map(\.x).max(),
        let top = points.map(\.y).min(), let bottom = points.map(\.y).max()
      {
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
      }
      guard let angle, angle.isFinite,
        abs(angle.truncatingRemainder(dividingBy: 360)) < 0.001,
        let box = itemPolygon, [box.x, box.y, box.width, box.height].allSatisfy(\.isFinite),
        box.width > 0, box.height > 0
      else { return nil }
      return CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
    }

    /// 腾讯左上原点的像素框 → Vision 左下原点的归一化框；归一化后不受上传缩图影响。
    func line(imageSize: CGSize, angle: Double?) -> OCR.Line? {
      guard imageSize.width > 0, imageSize.height > 0, let pixels = bounds(angle: angle) else {
        return nil
      }
      let clipped = pixels.intersection(CGRect(origin: .zero, size: imageSize))
      guard !clipped.isNull, !clipped.isEmpty else { return nil }
      let box = CGRect(
        x: clipped.minX / imageSize.width, y: 1 - clipped.maxY / imageSize.height,
        width: clipped.width / imageSize.width, height: clipped.height / imageSize.height)
      return OCR.Line(text: text, box: box)
    }
  }
}

// MARK: 火山

nonisolated enum VolcengineOCR {
  static let host = "visual.volcengineapi.com"
  static let query = "Action=MultiLanguageOCR&Version=2022-08-31"

  static func recognize(_ image: CGImage, language: Lang?, service: OCRService) async throws
    -> OCRResult
  {
    guard let accessKey = service.secret("accessKey"),
      let secretKey = service.secret("secretKey")
    else {
      throw TranslateError.config("请先在设置里填写火山引擎的 Access Key 和 Secret Key")
    }
    guard let base64 = OCRImage.base64(image) else {
      throw TranslateError(message: "这张图转不成 JPEG，换一张试试")
    }
    var fields: [(String, String)] = [("image_base64", base64)]
    if let language { fields.append(("language", language.volcengineOCRCode)) }
    let body = Signing.form(fields)
    var request = URLRequest(url: URL(string: "https://\(host)/?\(query)")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.httpBody = body
    for (name, value) in Volcengine.headers(
      accessKey: accessKey, secretKey: secretKey, body: body, date: .now, host: host, query: query,
      service: "cv", contentType: "application/x-www-form-urlencoded")
    {
      request.setValue(value, forHTTPHeaderField: name)
    }
    let object = try await HTTP.send(request)
    if let error = (object["ResponseMetadata"] as? [String: Any])?["Error"] as? [String: Any] {
      let code = error["Code"] as? String ?? ""
      let message = error["Message"] as? String ?? "未知"
      let isKey = ["Signature", "AccessKey", "Auth"].contains { code.contains($0) }
      throw TranslateError(
        message: "火山 OCR 错误：\(message.prefix(160))", kind: isKey ? .config : .service)
    }
    let lines = Self.lines(in: object)
    let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw TranslateError.emptyResult }
    return OCRResult(text: text, lines: lines.count)
  }

  /// 火山这个接口不同版本的回包长得不一样（Result.line_texts / Result.data.line_texts / ocr_infos），三种都认
  static func lines(in object: [String: Any]) -> [String] {
    let result = object["Result"] as? [String: Any] ?? object
    if let lines = result["line_texts"] as? [String], !lines.isEmpty { return lines }
    if let data = result["data"] as? [String: Any],
      let lines = data["line_texts"] as? [String], !lines.isEmpty
    {
      return lines
    }
    if let infos = result["ocr_infos"] as? [[String: Any]], !infos.isEmpty {
      return infos.compactMap { $0["text"] as? String }
    }
    if let lines = object["line_texts"] as? [String] { return lines }
    return []
  }
}

// MARK: 图片

nonisolated enum OCRImage {
  /// 最大边长：再大的图各家的接口会拒（百度 4 MB、腾讯 7 MB），先缩到 2600 像素
  static let maxDimension: CGFloat = 2600

  /// JPEG 的 base64（百度 / 腾讯 / 火山都要这个；Apple 直接把 CGImage 交给 Vision）
  static func base64(_ image: CGImage) -> String? {
    jpeg(image)?.base64EncodedString()
  }

  static func jpeg(_ image: CGImage, quality: CGFloat = 0.85) -> Data? {
    let image = resized(image, maxDimension: maxDimension)
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }

  /// 等比缩到最长边不超过 maxDimension；已经够小就原样返回
  static func resized(_ image: CGImage, maxDimension: CGFloat) -> CGImage {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    let longest = max(width, height)
    guard longest > maxDimension else { return image }
    let scale = maxDimension / longest
    let size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
    guard
      let context = CGContext(
        data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return image }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(origin: .zero, size: size))
    return context.makeImage() ?? image
  }
}

/// 设置 › OCR 详情页「测试连接」用的图：白底黑字「Hello, world」
nonisolated enum OCRTestImage {
  static func make() -> CGImage? {
    let width = 360
    let height = 110
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: "Hello, world",
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): font,
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
            gray: 0, alpha: 1),
        ]))
    context.textPosition = CGPoint(x: 24, y: 38)
    CTLineDraw(line, context)
    return context.makeImage()
  }
}
