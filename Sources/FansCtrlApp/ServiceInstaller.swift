import Foundation

enum ServiceInstallerError: Error, CustomStringConvertible {
    case scriptMissing(String)
    case failed(String)
    case cancelled

    var description: String {
        switch self {
        case .scriptMissing(let n): return "找不到 \(n).sh，请使用打包好的 FansCtrl.app"
        case .failed(let m): return "执行失败：\(m)"
        case .cancelled: return "已取消授权"
        }
    }
}

/// 通过系统原生的管理员授权对话框执行 App 包内的安装/卸载脚本。
enum ServiceInstaller {
    @MainActor
    static func run(script name: String) throws {
        guard let url = Bundle.main.url(forResource: name, withExtension: "sh") else {
            throw ServiceInstallerError.scriptMissing(name)
        }
        // 路径放进 AppleScript 字符串前转义，再交给 quoted form 生成 shell 安全的参数
        let escaped = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"/bin/bash \" & quoted form of \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw ServiceInstallerError.cancelled }
            throw ServiceInstallerError.failed(error[NSAppleScript.errorMessage] as? String ?? "未知错误")
        }
    }
}
