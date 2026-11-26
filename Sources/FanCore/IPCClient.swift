import Darwin
import Foundation

/// 同步的 Unix socket 客户端：一次连接只发一条命令，带超时，不会卡死调用方。
public struct IPCClient: Sendable {
    public let path: String
    public let timeout: TimeInterval

    public init(path: String = IPC.socketPath, timeout: TimeInterval = 2) {
        self.path = path
        self.timeout = timeout
    }

    public func send(_ command: IPCCommand) throws -> StatusSnapshot {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.io("socket: \(errno)") }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = try UnixSocketAddress.make(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            if errno == EACCES { throw IPCError.permissionDenied }
            throw IPCError.notRunning
        }

        var payload = try command.encoded()
        payload.append(0x0A)
        try SocketIO.writeAll(fd, payload)
        let line = try SocketIO.readLine(fd, limit: IPC.maxMessageBytes * 4)
        let response: IPCResponse
        do { response = try JSONDecoder().decode(IPCResponse.self, from: line) } catch { throw IPCError.io("响应解析失败") }
        if !response.ok {
            if response.error == IPCError.permissionDenied.description { throw IPCError.permissionDenied }
            throw IPCError.io(response.error ?? "未知错误")
        }
        guard let status = response.status else { throw IPCError.io("响应缺少状态") }
        return status
    }
}

public enum UnixSocketAddress {
    public static func make(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw IPCError.io("socket 路径过长") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        return addr
    }
}

public enum SocketIO {
    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw IPCError.io("write: \(errno)")
                }
                offset += n
            }
        }
    }

    /// 读到换行为止（不含换行）；超过 limit 视为恶意/异常输入直接报错。
    public static func readLine(_ fd: Int32, limit: Int) throws -> Data {
        var result = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw IPCError.io(errno == EAGAIN ? "超时" : "read: \(errno)")
            }
            if n == 0 { break }
            if let nl = chunk[0..<n].firstIndex(of: 0x0A) {
                result.append(contentsOf: chunk[0..<nl])
                return result
            }
            result.append(contentsOf: chunk[0..<n])
            if result.count > limit { throw IPCError.invalidRequest("消息过大") }
        }
        if result.isEmpty { throw IPCError.io("连接被关闭") }
        return result
    }
}
