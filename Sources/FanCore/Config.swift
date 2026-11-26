import Foundation

public struct DaemonConfig: Codable, Equatable, Sendable {
    public var profile: FanProfile = .smart
    public var quietFirst: Bool = false

    public init(profile: FanProfile = .smart, quietFirst: Bool = false) {
        self.profile = profile
        self.quietFirst = quietFirst
    }

    public static let defaultPath = "/Library/Application Support/FansCtrl/config.json"

    /// 配置损坏或缺失时回落到默认值，绝不因配置问题让守护进程起不来。
    public static func load(from path: String) -> DaemonConfig {
        guard let data = FileManager.default.contents(atPath: path),
              let cfg = try? JSONDecoder().decode(DaemonConfig.self, from: data) else { return DaemonConfig() }
        return cfg
    }

    public func save(to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}
