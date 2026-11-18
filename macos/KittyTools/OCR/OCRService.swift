// OCR 服务配置（照 设置 › 翻译 的服务列表）：列表里只有加进来的服务——内置四个（Apple 系统、百度、腾讯、火山），
// 可删、在设置「+」里加回来。从没存过列表时默认只有 Apple 系统（本机、离线、不用密钥、不花钱）。
// 非密钥配置以 JSON 存 UserDefaults，密钥存钥匙串（账户名 "ocr.<服务 id>.<字段>"）。
// 识别语言的编码各家不一样（百度 CHN_ENG、腾讯 zh、火山语言码、Vision 的 BCP-47），映射都在这里。

import CoreGraphics
import Foundation
import Observation

/// 一次识别的结果：接好的文字 + 行数（卡片上写「12 行」）
nonisolated struct OCRResult: Equatable, Sendable {
  var text: String
  var lines: Int
  /// 原图中的文字框（归一化、原点左下）；不提供位置的服务留空。
  var regions: [OCR.Line] = []
}

nonisolated struct OCRService: Codable, Identifiable, Hashable, Sendable {
  enum Kind: String, Codable, CaseIterable, Sendable {
    case apple, baidu, tencent, volcengine

    var defaultName: String {
      switch self {
      case .apple: "Apple 系统"
      case .baidu: "百度 OCR"
      case .tencent: "腾讯 OCR"
      case .volcengine: "火山 OCR"
      }
    }

    /// 卡片标题旁边的小字、设置列表里的状态由来
    var subtitle: String {
      switch self {
      case .apple: "本机 · 离线"
      case .baidu: "百度智能云 · 通用文字识别"
      case .tencent: "腾讯云 · 通用印刷体识别"
      case .volcengine: "火山引擎 · 多语种文字识别"
      }
    }

    /// 不花钱、不用自己申请密钥
    var isFree: Bool { self == .apple }

    /// ServiceLogo 里的图片名；nil = 用 SF 符号画（Apple 系统）
    var logo: String? {
      switch self {
      case .apple: nil
      case .baidu: "baidu"
      case .tencent: "tencent"
      case .volcengine: "volcengine"
      }
    }

    var secretFields: [SecretField] {
      switch self {
      case .apple: []
      case .baidu:
        [
          SecretField(
            name: "apiKey", label: "API Key", prompt: "百度智能云 › 文字识别 › 应用列表里的 API Key"),
          SecretField(name: "secretKey", label: "Secret Key"),
        ]
      case .tencent:
        [
          SecretField(name: "secretId", label: "SecretId"),
          SecretField(name: "secretKey", label: "SecretKey", prompt: "要开通「文字识别 OCR」"),
        ]
      case .volcengine:
        [
          SecretField(name: "accessKey", label: "Access Key"),
          SecretField(name: "secretKey", label: "Secret Key", prompt: "要开通「多语种文字识别」"),
        ]
      }
    }
  }

  struct SecretField: Hashable, Sendable {
    let name: String
    let label: String
    var prompt = ""
  }

  /// 内置服务 = kind 原值
  var id: String
  var kind: Kind
  var name: String
  var isEnabled = true
  /// 腾讯云的资源地域（留空按 ap-beijing；开通的是别的地域时填上）
  var region: String?

  /// 核对从设置备份或同步目录读进来的内置服务列表。
  static func sanitized(_ services: [Self]) -> [Self] {
    var ids: Set<String> = []
    return services.prefix(Kind.allCases.count).filter {
      $0.id == $0.kind.rawValue && $0.name.count <= 200
        && ($0.region ?? "").wholeMatch(of: /[A-Za-z0-9-]{0,64}/) != nil
        && ids.insert($0.id).inserted
    }
  }

  static func builtin(_ kind: Kind) -> OCRService {
    OCRService(
      id: kind.rawValue, kind: kind, name: kind.defaultName, isEnabled: kind == .apple)
  }

  var secretFields: [SecretField] { kind.secretFields }

  /// 一个字段在钥匙串里的账户名
  func account(_ field: String) -> String { "ocr.\(id).\(field)" }

  /// 钥匙串里的值（去掉首尾空白，空串当没有）
  func secret(_ field: String = "apiKey") -> String? {
    Keychain.get(account(field)).flatMap {
      let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? nil : value
    }
  }

  func setSecret(_ value: String?, _ field: String = "apiKey") {
    Keychain.set(value, for: account(field))
  }

  /// 密钥填齐了没有（Apple 系统不用密钥）
  var isConfigured: Bool { secretFields.allSatisfy { secret($0.name) != nil } }

  /// 设置列表和详情页头的状态。isProblem = 开着却缺配置（橙色）
  var settingsStatus: (text: String, isProblem: Bool) {
    let missing: Bool
    let text: String
    if kind == .apple {
      (text, missing) = (AppleOCR.isAvailable ? "本机 · 离线，不用密钥" : "要 macOS 15", false)
    } else if isConfigured {
      (text, missing) = ("已填密钥", false)
    } else {
      (text, missing) = ("未填密钥", true)
    }
    return (text, missing && isEnabled)
  }

  /// 服务分发：浮窗的卡片和设置页「测试连接」共用
  func recognize(_ image: CGImage, language: Lang?) async throws -> OCRResult {
    switch kind {
    case .apple: try await AppleOCR.recognize(image, language: language)
    case .baidu: try await BaiduOCR.recognize(image, language: language, service: self)
    case .tencent: try await TencentOCR.recognize(image, language: language, service: self)
    case .volcengine: try await VolcengineOCR.recognize(image, language: language, service: self)
    }
  }

  /// 截图翻译只请求一个服务：遵循 OCR 浮窗的选择；「全部」时用列表中第一个启用的服务。
  static func selected(in services: [OCRService], choice: String) -> OCRService? {
    let enabled = services.filter(\.isEnabled)
    return enabled.first { $0.id == choice } ?? enabled.first
  }

  /// 原图翻译必须有完整的位置；不把没有位置的文字随意盖回图片，也不偷偷切回本机识字。
  func recognizeForTranslation(_ image: CGImage, language: Lang?, requiresLayout: Bool) async throws
    -> OCRResult
  {
    guard !requiresLayout || kind == .apple || kind == .tencent else {
      throw TranslateError.config("原图翻译暂时支持 Apple 系统和腾讯 OCR，请在 OCR 设置中选择")
    }
    let result = try await recognize(image, language: language)
    try Task.checkCancellation()
    guard !requiresLayout || result.regions.count == result.lines else {
      throw TranslateError(message: "OCR 没有返回完整的文字位置，请重新识别")
    }
    return result
  }
}

/// 服务列表（设置页编辑，识别时读）。从没存过时只有 Apple 系统（启用）
@Observable final class OCRServiceStore {
  nonisolated static let key = Prefs.ocrServices

  var services: [OCRService] {
    didSet {
      guard persists, let data = try? JSONEncoder().encode(services) else { return }
      UserDefaults.standard.set(data, forKey: Self.key)
    }
  }

  var enabled: [OCRService] { services.filter(\.isEnabled) }

  /// 从偏好读出来的才写回偏好：单测、设置自检传进来的一份怎么改都不碰用户的列表
  private let persists: Bool

  init(services: [OCRService]? = nil) {
    persists = services == nil
    let saved =
      services
      ?? UserDefaults.standard.data(forKey: Self.key).flatMap {
        try? JSONDecoder().decode([OCRService].self, from: $0)
      }
    self.services = saved ?? Self.defaults
  }

  /// 从没存过列表时的默认：只有 Apple 系统（本机、离线）
  static let defaults = [OCRService.builtin(.apple)]

  /// 同步写入偏好后重新读取这些服务，密钥仍由本版本的钥匙串提供。
  func reloadFromPreferences() {
    guard persists else { return }
    let saved =
      UserDefaults.standard.data(forKey: Self.key).flatMap {
        try? JSONDecoder().decode([OCRService].self, from: $0)
      } ?? Self.defaults
    if saved != services { services = saved }
  }

  /// 还没加进列表的内置服务（设置「+」菜单里列出来；Apple 系统删掉了也能加回来）
  var missingBuiltins: [OCRService.Kind] {
    OCRService.Kind.allCases.filter { kind in
      !services.contains { $0.id == kind.rawValue }
    }
  }

  /// 删一个服务：只拿出列表、密钥留着（从「+」加回来还在）
  func remove(_ id: String) {
    services.removeAll { $0.id == id }
  }
}

// MARK: 识别语言

extension Lang {
  /// Vision 的 BCP-47（不要在自动时给提示：实测写死语言会丢混排里的其它文字，见 Clipboard/OCR.swift）
  nonisolated var visionCode: String {
    switch self {
    case .zhHans: "zh-Hans"
    case .zhHant: "zh-Hant"
    case .en: "en-US"
    case .ja: "ja-JP"
    case .ko: "ko-KR"
    case .fr: "fr-FR"
    case .de: "de-DE"
    case .es: "es-ES"
    case .ru: "ru-RU"
    case .pt: "pt-BR"
    case .it: "it-IT"
    }
  }

  /// 百度 OCR 的 language_type（另一个是自动：auto_detect）
  nonisolated var baiduOCRCode: String {
    switch self {
    case .zhHans, .zhHant: "CHN_ENG"
    case .en: "ENG"
    case .ja: "JAP"
    case .ko: "KOR"
    case .fr: "FRE"
    case .de: "GER"
    case .es: "SPA"
    case .ru: "RUS"
    case .pt: "POR"
    case .it: "ITA"
    }
  }

  /// 腾讯 OCR 的 Language：只认中英日韩，别的语言不给（交给它自动）
  nonisolated var tencentOCRCode: String? {
    switch self {
    case .zhHans, .zhHant: "zh"
    case .en: "en"
    case .ja: "ja"
    case .ko: "ko"
    case .fr, .de, .es, .ru, .pt, .it: nil
    }
  }

  /// 火山多语种 OCR 的 language
  nonisolated var volcengineOCRCode: String {
    switch self {
    case .zhHans, .zhHant: "zh"
    case .en: "en"
    case .ja: "ja"
    case .ko: "ko"
    case .fr: "fr"
    case .de: "de"
    case .es: "es"
    case .ru: "ru"
    case .pt: "pt"
    case .it: "it"
    }
  }
}

/// 设置 › OCR 的语言选择：空串 = 自动
enum OCRLanguage {
  static func lang(_ raw: String) -> Lang? { Lang(rawValue: raw) }

  /// 菜单里显示的名字
  static func title(_ raw: String) -> String { lang(raw)?.title ?? "自动" }
}
