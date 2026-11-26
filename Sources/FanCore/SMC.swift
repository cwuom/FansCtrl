import CSMC
import Foundation

public enum SMCError: Error, Equatable, CustomStringConvertible {
    case openFailed(Int32)
    case keyNotFound(FourCC)
    case callFailed(FourCC, Int32)
    case unsupportedType(FourCC, FourCC)
    case verifyFailed(FourCC)

    public var description: String {
        switch self {
        case .openFailed(let c): return "无法打开 AppleSMC (\(c))"
        case .keyNotFound(let k): return "SMC key 不存在: \(k)"
        case .callFailed(let k, let c): return "SMC 调用失败 \(k): 0x\(String(UInt32(bitPattern: c), radix: 16))"
        case .unsupportedType(let k, let t): return "SMC key \(k) 的类型 \(t) 不支持写入"
        case .verifyFailed(let k): return "写入 \(k) 后回读不一致，固件可能拒绝手动控制"
        }
    }
}

/// 抽象出 SMC 访问，便于在单测中用假 SMC 验证控制逻辑。
public protocol SMCAccess: AnyObject {
    func keyInfo(_ key: FourCC) throws -> SMCKeyInfo
    func readBytes(_ key: FourCC, info: SMCKeyInfo) throws -> [UInt8]
    func writeBytes(_ key: FourCC, _ bytes: [UInt8]) throws
    func allKeys() throws -> [FourCC]
}

extension SMCAccess {
    public func exists(_ key: FourCC) -> Bool { (try? keyInfo(key)) != nil }

    public func readDouble(_ key: FourCC) throws -> Double {
        let info = try keyInfo(key)
        guard let v = SMCCodec.decode(type: info.type, bytes: try readBytes(key, info: info)) else {
            throw SMCError.unsupportedType(key, info.type)
        }
        return v
    }

    public func writeDouble(_ key: FourCC, _ value: Double) throws {
        let info = try keyInfo(key)
        guard let bytes = SMCCodec.encode(value, type: info.type, size: info.size) else {
            throw SMCError.unsupportedType(key, info.type)
        }
        try writeBytes(key, bytes)
    }
}

/// 真实 AppleSMC 连接。非线程安全：由调用方保证在单一串行队列上使用。
public final class SMCConnection: SMCAccess {
    private var conn: io_connect_t = 0
    private var infoCache: [FourCC: SMCKeyInfo] = [:]

    public init() throws {
        let kr = csmc_open(&conn)
        guard kr == KERN_SUCCESS else { throw SMCError.openFailed(kr) }
    }

    deinit { csmc_close(conn) }

    public func keyInfo(_ key: FourCC) throws -> SMCKeyInfo {
        if let cached = infoCache[key] { return cached }
        var raw = csmc_key_info_t()
        let r = csmc_key_info(conn, key.raw, &raw)
        guard r == 0 else { throw SMCError.keyNotFound(key) }
        let info = SMCKeyInfo(size: raw.dataSize, type: FourCC(raw: raw.dataType), attributes: raw.attributes)
        infoCache[key] = info
        return info
    }

    public func readBytes(_ key: FourCC, info: SMCKeyInfo) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 32)
        let r = buf.withUnsafeMutableBufferPointer { csmc_read_sized(conn, key.raw, info.size, $0.baseAddress) }
        guard r == 0 else { throw SMCError.callFailed(key, r) }
        return Array(buf.prefix(Int(info.size)))
    }

    public func writeBytes(_ key: FourCC, _ bytes: [UInt8]) throws {
        let r = bytes.withUnsafeBufferPointer { csmc_write(conn, key.raw, $0.baseAddress, UInt32(bytes.count)) }
        guard r == 0 else { throw SMCError.callFailed(key, r) }
    }

    public func allKeys() throws -> [FourCC] {
        let count = Int(try readDouble("#KEY"))
        var keys: [FourCC] = []
        keys.reserveCapacity(count)
        for i in 0..<count {
            var k: UInt32 = 0
            if csmc_key_at_index(conn, UInt32(i), &k) == 0 { keys.append(FourCC(raw: k)) }
        }
        return keys
    }
}
