import Darwin
import FanCore
import Foundation
import SystemConfiguration

/// 本地 Unix socket 服务。socket 文件对所有用户可连，但每个连接都用 getpeereid 校验身份。
final class IPCServer: @unchecked Sendable {
    private let path: String
    private let authorize: @Sendable (uid_t) -> Bool
    private let handler: @Sendable (IPCCommand) -> IPCResponse
    private let ioQueue = DispatchQueue(label: "com.fansctrl.ipc", qos: .utility)
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, authorize: @escaping @Sendable (uid_t) -> Bool, handler: @escaping @Sendable (IPCCommand) -> IPCResponse) {
        self.path = path
        self.authorize = authorize
        self.handler = handler
    }

    func start() throws {
        var st = stat()
        if lstat(path, &st) == 0 {
            // 只清理残留的 socket，路径被其他类型文件占用（包括符号链接）时拒绝启动
            guard (st.st_mode & S_IFMT) == S_IFSOCK else { throw IPCError.io("\(path) 已存在且不是 socket") }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.io("socket: \(errno)") }
        var addr = try UnixSocketAddress.make(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(fd); throw IPCError.io("bind \(path): \(errno)") }
        chmod(path, 0o666)
        guard listen(fd, 8) == 0 else { close(fd); throw IPCError.io("listen: \(errno)") }
        listenFD = fd

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var uid: uid_t = 0, gid: gid_t = 0
        let response: IPCResponse
        if getpeereid(client, &uid, &gid) != 0 || !authorize(uid) {
            response = IPCResponse(ok: false, error: IPCError.permissionDenied.description)
        } else {
            do {
                let line = try SocketIO.readLine(client, limit: IPC.maxMessageBytes)
                response = handler(try IPCCommand.parse(line))
            } catch {
                response = IPCResponse(ok: false, error: "\(error)")
            }
        }
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        try? SocketIO.writeAll(client, data)
    }

    /// 当前登录在图形界面的用户 uid；没人登录时返回 nil。
    static func consoleUID() -> uid_t? {
        var uid: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?, name != "loginwindow" else { return nil }
        return uid
    }
}
