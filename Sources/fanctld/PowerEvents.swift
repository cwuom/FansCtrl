import Foundation
import IOKit
import IOKit.pwr_mgt

/// 睡眠前交还系统控制、唤醒后延迟恢复，避免睡眠期间风扇停留在手动转速。
final class PowerEvents: @unchecked Sendable {
    // IOMessage.h 中的 iokit_common_msg 宏无法导入 Swift，按定义 (sys_iokit | sub_iokit_common | code) 展开
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private let onSleep: @Sendable () -> Void
    private let onWake: @Sendable () -> Void

    init(onSleep: @escaping @Sendable () -> Void, onWake: @escaping @Sendable () -> Void) {
        self.onSleep = onSleep
        self.onWake = onWake
    }

    func start(queue: DispatchQueue) -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, argument in
            guard let refcon else { return }
            let me = Unmanaged<PowerEvents>.fromOpaque(refcon).takeUnretainedValue()
            me.handle(messageType, argument)
        }, &notifier)
        guard rootPort != 0, let notifyPort else { return false }
        IONotificationPortSetDispatchQueue(notifyPort, queue)
        return true
    }

    private func handle(_ type: UInt32, _ argument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: argument)
        switch type {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, token)
        case Self.systemWillSleep:
            onSleep()
            IOAllowPowerChange(rootPort, token)
        case Self.systemHasPoweredOn:
            onWake()
        default:
            break
        }
    }
}
