@testable import FanCore

/// 内存版 SMC，用于验证硬件层的写入顺序与校验逻辑。
final class FakeSMC: SMCAccess {
    var store: [FourCC: (info: SMCKeyInfo, bytes: [UInt8])] = [:]
    var writes: [(FourCC, Double)] = []
    /// 写入这些 key 时固件“假装接受”但值不变，模拟拒绝手动控制的机型
    var ignoredWrites: Set<FourCC> = []

    func set(_ key: FourCC, _ type: FourCC, _ size: UInt32, _ value: Double, attributes: UInt8 = 0xC0) {
        store[key] = (SMCKeyInfo(size: size, type: type, attributes: attributes),
                      SMCCodec.encode(value, type: type, size: size) ?? [UInt8](repeating: 0, count: Int(size)))
    }

    /// 只读类型（如 sp78）没有编码器，直接写原始字节
    func setRaw(_ key: FourCC, _ type: FourCC, _ bytes: [UInt8]) {
        store[key] = (SMCKeyInfo(size: UInt32(bytes.count), type: type, attributes: 0x80), bytes)
    }

    func keyInfo(_ key: FourCC) throws -> SMCKeyInfo {
        guard let e = store[key] else { throw SMCError.keyNotFound(key) }
        return e.info
    }

    func readBytes(_ key: FourCC, info: SMCKeyInfo) throws -> [UInt8] {
        guard let e = store[key] else { throw SMCError.keyNotFound(key) }
        return e.bytes
    }

    func writeBytes(_ key: FourCC, _ bytes: [UInt8]) throws {
        guard let e = store[key] else { throw SMCError.keyNotFound(key) }
        guard bytes.count == Int(e.info.size) else { throw SMCError.callFailed(key, -2) }
        writes.append((key, SMCCodec.decode(type: e.info.type, bytes: bytes) ?? .nan))
        if ignoredWrites.contains(key) { return }
        store[key] = (e.info, bytes)
    }

    func allKeys() throws -> [FourCC] { Array(store.keys) }

    /// 模拟本机实测的 Mac17,2（M5 MacBook Pro，单风扇）
    static func appleSiliconSingleFan() -> FakeSMC {
        let smc = FakeSMC()
        smc.set("FNum", "ui8 ", 1, 1)
        smc.set("F0Mn", "flt ", 4, 2317)
        smc.set("F0Mx", "flt ", 4, 6550)
        smc.set("F0Ac", "flt ", 4, 0)
        smc.set("F0Tg", "flt ", 4, 0)
        smc.set("F0md", "ui8 ", 1, 0)
        smc.set("Tp01", "flt ", 4, 55)
        smc.set("Te05", "flt ", 4, 48)
        smc.set("Tp09", "flt ", 4, 0)      // 未上电核心读到 0，应被过滤
        smc.set("Tg0C", "flt ", 4, 62)
        smc.set("TCMb", "flt ", 4, 120)    // 非 CPU 传感器，Apple Silicon 下不应计入
        return smc
    }

    /// 模拟老款 Intel 双风扇机型（FS! 位掩码 + fpe2 定点数）
    static func intelDualFan() -> FakeSMC {
        let smc = FakeSMC()
        smc.set("FNum", "ui8 ", 1, 2)
        for i in 0..<2 {
            smc.set(FourCC("F\(i)Mn"), "fpe2", 2, 1200)
            smc.set(FourCC("F\(i)Mx"), "fpe2", 2, 6000)
            smc.set(FourCC("F\(i)Ac"), "fpe2", 2, 1800)
            smc.set(FourCC("F\(i)Tg"), "fpe2", 2, 1800)
        }
        smc.set("FS! ", "ui16", 2, 0)
        smc.setRaw("TC0P", "sp78", [0x46, 0x00])   // 70°C
        smc.setRaw("TG0P", "sp78", [0x40, 0x00])   // 64°C
        return smc
    }
}
