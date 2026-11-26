import Foundation

/// SMC key / 数据类型使用的四字符码，按大端打包成 UInt32。
public struct FourCC: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let raw: UInt32

    public init(raw: UInt32) { self.raw = raw }

    public init(_ string: String) {
        var value: UInt32 = 0
        var bytes = Array(string.utf8.prefix(4))
        while bytes.count < 4 { bytes.append(0x20) }
        for b in bytes { value = (value << 8) | UInt32(b) }
        raw = value
    }

    public init(stringLiteral value: String) { self.init(value) }

    public var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8((raw >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public struct SMCKeyInfo: Equatable, Sendable {
    public let size: UInt32
    public let type: FourCC
    public let attributes: UInt8

    public init(size: UInt32, type: FourCC, attributes: UInt8) {
        self.size = size
        self.type = type
        self.attributes = attributes
    }
}

/// 数值编解码：Apple Silicon 主要用小端 `flt `，Intel 机型用大端定点格式。
public enum SMCCodec {
    public static func decode(type: FourCC, bytes: [UInt8]) -> Double? {
        switch type.description {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let v = Double(Float(bitPattern: bits))
            return v.isFinite ? v : nil
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256.0
        case "ui8 ":
            return bytes.first.map(Double.init)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "si8 ":
            return bytes.first.map { Double(Int8(bitPattern: $0)) }
        case "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
        default:
            return nil
        }
    }

    /// 只支持风扇控制会写的类型；未知类型返回 nil，调用方必须放弃写入。
    public static func encode(_ value: Double, type: FourCC, size: UInt32) -> [UInt8]? {
        guard value.isFinite, value >= 0 else { return nil }
        let bytes: [UInt8]
        switch type.description {
        case "flt ":
            let bits = Float(value).bitPattern
            bytes = [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8(bits >> 24)]
        case "fpe2":
            guard value * 4 <= Double(UInt16.max) else { return nil }
            let v = UInt16((value * 4).rounded())
            bytes = [UInt8(v >> 8), UInt8(v & 0xFF)]
        case "ui8 ":
            guard value <= 255 else { return nil }
            bytes = [UInt8(value.rounded())]
        case "ui16":
            guard value <= Double(UInt16.max) else { return nil }
            let v = UInt16(value.rounded())
            bytes = [UInt8(v >> 8), UInt8(v & 0xFF)]
        default:
            return nil
        }
        return bytes.count == Int(size) ? bytes : nil
    }
}
