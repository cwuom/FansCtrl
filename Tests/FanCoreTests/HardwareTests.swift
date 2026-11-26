import Foundation
import Testing
@testable import FanCore

@Suite struct CodecTests {
    @Test func fourCCRoundTrip() {
        #expect(FourCC("F0Tg").description == "F0Tg")
        #expect(FourCC("FS! ").description == "FS! ")
        #expect(FourCC("ui8").description == "ui8 ")
    }

    @Test func decodesKnownTypes() {
        #expect(SMCCodec.decode(type: "fpe2", bytes: [0x1F, 0x40]) == 2000)
        #expect(SMCCodec.decode(type: "sp78", bytes: [0x32, 0x80]) == 50.5)
        #expect(SMCCodec.decode(type: "sp78", bytes: [0xFF, 0x00]) == -1)
        #expect(SMCCodec.decode(type: "ui16", bytes: [0x25, 0x80]) == 9600)
        #expect(SMCCodec.decode(type: "hex_", bytes: [0x00]) == nil)
        #expect(SMCCodec.decode(type: "flt ", bytes: [0x00]) == nil)
    }

    @Test func floatRoundTripIsLittleEndian() throws {
        let bytes = try #require(SMCCodec.encode(2317, type: "flt ", size: 4))
        #expect(bytes == [0x00, 0xD0, 0x10, 0x45])
        #expect(SMCCodec.decode(type: "flt ", bytes: bytes) == 2317)
    }

    @Test func encodeRejectsUnsafeInput() {
        #expect(SMCCodec.encode(-1, type: "flt ", size: 4) == nil)
        #expect(SMCCodec.encode(.nan, type: "flt ", size: 4) == nil)
        #expect(SMCCodec.encode(300, type: "ui8 ", size: 1) == nil)
        #expect(SMCCodec.encode(100, type: "flt ", size: 2) == nil, "尺寸不符必须拒绝")
        #expect(SMCCodec.encode(100, type: "sp78", size: 2) == nil, "未知写入类型必须拒绝")
    }
}

@Suite struct HardwareTests {
    @Test func discoversAppleSilicon() throws {
        let hw = try FanHardware(smc: FakeSMC.appleSiliconSingleFan())
        #expect(hw.fans == [FanSpec(index: 0, minRPM: 2317, maxRPM: 6550)])
        #expect(hw.strategy == .perFan(keyFormat: "F%dmd"))
        #expect(hw.sensors.appleSilicon)
        #expect(Set(hw.sensors.cpu.map(\.description)) == ["Tp01", "Te05", "Tp09"])
        #expect(hw.sensors.gpu.map(\.description) == ["Tg0C"])
        let t = hw.readTemperatures()
        #expect(t.cpu == 55, "0°C 的无效读数和 TCMb 不应影响结果")
        #expect(t.gpu == 62)
        #expect(t.control == 62)
        #expect(hw.canControl)
    }

    @Test func discoversIntelBitmask() throws {
        let hw = try FanHardware(smc: FakeSMC.intelDualFan())
        #expect(hw.fans.count == 2)
        #expect(hw.strategy == .forceBitmask)
        #expect(!hw.sensors.appleSilicon)
        #expect(hw.readTemperatures() == TemperatureReading(cpu: 70, gpu: 64))
    }

    @Test func fanlessMacCannotControl() throws {
        let smc = FakeSMC()
        smc.set("FNum", "ui8 ", 1, 0)
        smc.set("Tp01", "flt ", 4, 40)
        let hw = try FanHardware(smc: smc)
        #expect(hw.fans.isEmpty)
        #expect(!hw.canControl)
    }

    @Test func setManualWritesModeThenClampedTarget() throws {
        let smc = FakeSMC.appleSiliconSingleFan()
        let hw = try FanHardware(smc: smc)
        try hw.setManual(0, rpm: 99_999)
        #expect(smc.writes.map(\.0.description) == ["F0md", "F0Tg"])
        #expect(try smc.readDouble("F0Tg") == 6550, "超过最大转速必须夹到 max")
        try hw.setManual(0, rpm: 10)
        #expect(try smc.readDouble("F0Tg") == 2317, "低于最小转速必须夹到 min")
        #expect(smc.writes.filter { $0.0 == "F0md" }.count == 1, "已是手动模式时不重复写模式")
    }

    @Test func unlockKeyWrittenFirstAndResetOnRelease() throws {
        let smc = FakeSMC.appleSiliconSingleFan()
        smc.set("Ftst", "ui8 ", 1, 0)
        let hw = try FanHardware(smc: smc)
        try hw.setManual(0, rpm: 3000)
        #expect(smc.writes.first?.0 == "Ftst")
        #expect(hw.setAutomatic().isEmpty)
        #expect(try smc.readDouble("Ftst") == 0)
        #expect(try smc.readDouble("F0md") == 0)
    }

    @Test func firmwareRejectingModeThrows() throws {
        let smc = FakeSMC.appleSiliconSingleFan()
        smc.ignoredWrites = ["F0md"]
        let hw = try FanHardware(smc: smc)
        #expect(throws: SMCError.verifyFailed("F0md")) { try hw.setManual(0, rpm: 3000) }
        #expect(!smc.writes.contains { $0.0 == "F0Tg" }, "模式没切成功就不能写目标转速")
    }

    @Test func intelBitmaskSetsAndClearsBits() throws {
        let smc = FakeSMC.intelDualFan()
        let hw = try FanHardware(smc: smc)
        try hw.setManual(1, rpm: 3000)
        #expect(try smc.readDouble("FS! ") == 2)
        try hw.setManual(0, rpm: 3000)
        #expect(try smc.readDouble("FS! ") == 3)
        #expect(try smc.readDouble("F0Tg") == 3000)
        hw.setAutomatic()
        #expect(try smc.readDouble("FS! ") == 0)
    }
}
