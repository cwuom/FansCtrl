import Foundation

public struct FanSpec: Equatable, Sendable, Codable {
    public let index: Int
    public let minRPM: Double
    public let maxRPM: Double

    public init(index: Int, minRPM: Double, maxRPM: Double) {
        self.index = index
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }
}

/// 不同代 Mac 切换手动模式的方式不同，按探测到的 key 选择。
public enum FanModeStrategy: Equatable, Sendable {
    /// Apple Silicon（`F0md`）或较新 Intel（`F0Md`）：每个风扇独立的模式 key。
    case perFan(keyFormat: String)
    /// 较老 Intel：`FS! ` 位掩码，第 i 位置 1 表示风扇 i 强制手动。
    case forceBitmask
    case unsupported
}

public struct TemperatureReading: Equatable, Sendable {
    public var cpu: Double?
    public var gpu: Double?

    public init(cpu: Double?, gpu: Double?) {
        self.cpu = cpu
        self.gpu = gpu
    }

    /// 控制用温度取 CPU/GPU 中的最高值，保证任一热源过热都能拉高转速。
    public var control: Double? {
        switch (cpu, gpu) {
        case let (c?, g?): return max(c, g)
        case let (c?, nil): return c
        case let (nil, g?): return g
        default: return nil
        }
    }
}

public enum SensorCatalog {
    /// 合理温度范围之外的读数视为传感器异常（未上电的核心常读到 0）。
    public static let plausible: ClosedRange<Double> = 5...130

    public struct Selection: Equatable, Sendable {
        public var cpu: [FourCC]
        public var gpu: [FourCC]
        public var appleSilicon: Bool
    }

    /// 根据 key 名分类。存在 Tp/Te 视为 Apple Silicon，否则按 Intel 命名规则。
    public static func select(from keys: [FourCC]) -> Selection {
        let names = keys.map(\.description)
        let appleSilicon = names.contains { $0.hasPrefix("Tp") || $0.hasPrefix("Te") }
        var cpu: [FourCC] = []
        var gpu: [FourCC] = []
        for (key, name) in zip(keys, names) {
            if appleSilicon {
                if name.hasPrefix("Tp") || name.hasPrefix("Te") { cpu.append(key) }
                else if name.hasPrefix("Tg") { gpu.append(key) }
            } else {
                if ["TC0P", "TC0D", "TC0E", "TC0F", "TC0H", "TCXC", "TCSA"].contains(name)
                    || (name.hasPrefix("TC") && name.hasSuffix("C") && name.dropFirst(2).first?.isNumber == true) {
                    cpu.append(key)
                } else if ["TG0P", "TG0D", "TG0H", "TGDD"].contains(name) {
                    gpu.append(key)
                }
            }
        }
        return Selection(cpu: cpu, gpu: gpu, appleSilicon: appleSilicon)
    }
}

public struct FanReading: Equatable, Sendable, Codable {
    public let index: Int
    public let actualRPM: Double?
    public let targetRPM: Double?
    public let manual: Bool?

    public init(index: Int, actualRPM: Double?, targetRPM: Double?, manual: Bool?) {
        self.index = index
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.manual = manual
    }
}

/// 风扇与温度硬件访问。所有方法须在同一串行队列调用。
public final class FanHardware {
    public let smc: SMCAccess
    public let fans: [FanSpec]
    public let strategy: FanModeStrategy
    public let sensors: SensorCatalog.Selection
    /// 部分 Apple Silicon 固件需要先写 `Ftst=1` 才接受手动模式。
    private let hasUnlockKey: Bool
    private var unlocked = false

    public init(smc: SMCAccess) throws {
        self.smc = smc
        let count = Int((try? smc.readDouble("FNum")) ?? 0)
        var specs: [FanSpec] = []
        for i in 0..<count {
            guard let mn = try? smc.readDouble(FourCC("F\(i)Mn")),
                  let mx = try? smc.readDouble(FourCC("F\(i)Mx")),
                  mx > mn, mn >= 0 else { continue }
            specs.append(FanSpec(index: i, minRPM: mn, maxRPM: mx))
        }
        fans = specs

        if smc.exists("F0md") { strategy = .perFan(keyFormat: "F%dmd") }
        else if smc.exists("F0Md") { strategy = .perFan(keyFormat: "F%dMd") }
        else if smc.exists("FS! ") { strategy = .forceBitmask }
        else { strategy = .unsupported }
        hasUnlockKey = smc.exists("Ftst")

        sensors = SensorCatalog.select(from: (try? smc.allKeys()) ?? [])
    }

    public var canControl: Bool { !fans.isEmpty && strategy != .unsupported }

    public func readTemperatures() -> TemperatureReading {
        TemperatureReading(cpu: maxValid(sensors.cpu), gpu: maxValid(sensors.gpu))
    }

    private func maxValid(_ keys: [FourCC]) -> Double? {
        var best: Double?
        for k in keys {
            guard let v = try? smc.readDouble(k), SensorCatalog.plausible.contains(v) else { continue }
            best = max(best ?? v, v)
        }
        return best
    }

    public func readFans() -> [FanReading] {
        fans.map { f in
            FanReading(
                index: f.index,
                actualRPM: try? smc.readDouble(FourCC("F\(f.index)Ac")),
                targetRPM: try? smc.readDouble(FourCC("F\(f.index)Tg")),
                manual: try? isManual(f.index)
            )
        }
    }

    public func isManual(_ index: Int) throws -> Bool {
        switch strategy {
        case .perFan(let fmt):
            return try smc.readDouble(FourCC(String(format: fmt, index))) != 0
        case .forceBitmask:
            return (Int(try smc.readDouble("FS! ")) >> index) & 1 == 1
        case .unsupported:
            return false
        }
    }

    /// 设定手动转速并回读校验。转速会被夹到 [min, max]，越界值永远不会写入硬件。
    public func setManual(_ index: Int, rpm: Double) throws {
        guard let spec = fans.first(where: { $0.index == index }) else { throw SMCError.keyNotFound(FourCC("F\(index)Tg")) }
        let clamped = min(max(rpm, spec.minRPM), spec.maxRPM)
        if hasUnlockKey && !unlocked {
            try smc.writeDouble("Ftst", 1)
            unlocked = true
        }
        if try !isManual(index) {
            switch strategy {
            case .perFan(let fmt):
                try smc.writeDouble(FourCC(String(format: fmt, index)), 1)
            case .forceBitmask:
                let mask = Int(try smc.readDouble("FS! ")) | (1 << index)
                try smc.writeDouble("FS! ", Double(mask))
            case .unsupported:
                throw SMCError.keyNotFound("F0md")
            }
            guard try isManual(index) else { throw SMCError.verifyFailed(FourCC("F\(index)md")) }
        }
        try smc.writeDouble(FourCC("F\(index)Tg"), clamped)
    }

    /// 把全部风扇交还系统。逐个尝试，单个失败不影响其余风扇恢复。
    @discardableResult
    public func setAutomatic() -> [Error] {
        var errors: [Error] = []
        switch strategy {
        case .perFan(let fmt):
            for f in fans {
                do { try smc.writeDouble(FourCC(String(format: fmt, f.index)), 0) } catch { errors.append(error) }
            }
        case .forceBitmask:
            do { try smc.writeDouble("FS! ", 0) } catch { errors.append(error) }
        case .unsupported:
            break
        }
        if hasUnlockKey {
            do { try smc.writeDouble("Ftst", 0); unlocked = false } catch { errors.append(error) }
        }
        return errors
    }
}
