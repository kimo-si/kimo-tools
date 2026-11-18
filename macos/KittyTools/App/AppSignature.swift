// 应用内更新、访达右键共用本构建的 Apple 签名团队。Xcode 把 DEVELOPMENT_TEAM 写入签名保护下的 Info.plist。

import Foundation

nonisolated enum AppSignature {
  /// 只接受完整的 Apple Team ID。签名配置缺失时不接受更新包或扩展事件。
  static let team: String? = {
    guard let team = Bundle.main.object(forInfoDictionaryKey: "KittySigningTeam") as? String,
      team.wholeMatch(of: /[A-Z0-9]{10}/) != nil
    else { return nil }
    return team
  }()

  /// 生成对指定 bundle ID、Apple 证书链和本构建团队的校验条件。
  static func requirement(for identifier: String) -> String? {
    guard let team else { return nil }
    return
      "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
  }
}
