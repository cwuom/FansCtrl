import Darwin
import Foundation
import Testing
@testable import FanCore

@Suite(.timeLimit(.minutes(1))) struct ProtocolTests {
    @Test(arguments: [IPCCommand.status, .setProfile(.library), .setProfile(.smart), .setQuietFirst(true)])
    func roundTrip(cmd: IPCCommand) throws {
        #expect(try IPCCommand.parse(cmd.encoded()) == cmd)
    }

    @Test(arguments: [
        #"{"cmd":"setProfile","profile":"turbo"}"#,
        #"{"cmd":"writeKey","key":"F0Tg"}"#,
        #"{"cmd":"setQuietFirst"}"#,
        #"not json"#,
    ])
    func rejectsInvalid(raw: String) {
        #expect(throws: IPCError.self) { try IPCCommand.parse(Data(raw.utf8)) }
    }

    @Test func rejectsOversizedRequest() {
        let big = Data(repeating: 0x20, count: IPC.maxMessageBytes + 1)
        #expect(throws: IPCError.invalidRequest("请求过大")) { try IPCCommand.parse(big) }
    }

    @Test func socketReadLineEnforcesLimit() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        try SocketIO.writeAll(fds[1], Data("hello\nignored".utf8))
        #expect(try SocketIO.readLine(fds[0], limit: 64) == Data("hello".utf8))

        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        // 写入量要小于 socketpair 的内核缓冲区（约 8KB），否则写端会在读端开始读之前阻塞
        try SocketIO.writeAll(pair[1], Data(repeating: 0x41, count: 3000))
        #expect(throws: IPCError.invalidRequest("消息过大")) { try SocketIO.readLine(pair[0], limit: 1024) }
    }

    /// 回归：App 升级而后台服务仍是旧版时，必须能识别出服务过旧，而不是只显示“未知命令”
    @Test func detectsOutdatedDaemon() throws {
        let v1 = #"{"protocolVersion":1,"model":"Mac17,2","selectedProfile":"smart","activeProfile":"quiet","quietFirst":false,"state":"system","onBattery":false,"thermal":0,"fans":[],"controlSupported":true,"dryRun":false}"#
        let old = try JSONDecoder().decode(StatusSnapshot.self, from: Data(v1.utf8))
        #expect(old.isOutdated)
        #expect(old.isVersionMismatch)
        #expect(old.suppressRemaining == nil)

        let current = StatusSnapshot(model: "m", selectedProfile: .smart, activeProfile: .quiet, smartReason: nil,
                                     quietFirst: false, state: .system, cpuTemp: nil, gpuTemp: nil, controlTemp: nil,
                                     cpuLoad: nil, onBattery: false, thermal: .nominal, fans: [], controlSupported: true,
                                     dryRun: false, lastError: nil)
        let roundTrip = try JSONDecoder().decode(StatusSnapshot.self, from: JSONEncoder().encode(current))
        #expect(!roundTrip.isOutdated)
        #expect(!roundTrip.isVersionMismatch)

        // 协议兼容但版本不同（例如只修了服务端行为）也要提示更新
        var older = current
        older.daemonVersion = "0.0.1"
        #expect(!older.isOutdated)
        #expect(older.isVersionMismatch)
    }

    @Test func socketPathLengthChecked() {
        #expect(throws: IPCError.self) { try UnixSocketAddress.make(String(repeating: "a", count: 200)) }
    }
}

@Suite struct ConfigTests {
    private func tempPath() -> String {
        NSTemporaryDirectory() + "fansctrl-test-\(UUID().uuidString)/config.json"
    }

    @Test func missingOrCorruptFallsBackToDefault() throws {
        let path = tempPath()
        #expect(DaemonConfig.load(from: path) == DaemonConfig())
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("{garbage".utf8).write(to: URL(fileURLWithPath: path))
        #expect(DaemonConfig.load(from: path) == DaemonConfig())
        try FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    @Test func saveLoadRoundTrip() throws {
        let path = tempPath()
        let cfg = DaemonConfig(profile: .library, quietFirst: true)
        try cfg.save(to: path)
        #expect(DaemonConfig.load(from: path) == cfg)
        try FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }
}
