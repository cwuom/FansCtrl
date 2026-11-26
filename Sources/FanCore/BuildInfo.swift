public enum BuildInfo {
    /// App 版本，必须与 Support/Info.plist 的 CFBundleShortVersionString 一致（scripts/build-app.sh 会校验）
    public static let version = "1.3.0"
    /// 后台服务版本：只有 fanctld 的行为变化时才递增。
    /// App 发现已安装服务的版本与此不同就提示更新，只改界面时不会打扰用户重新授权。
    public static let serviceVersion = "1.2.1"
}
