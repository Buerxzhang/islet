import Foundation
import IOKit
import IOKit.pwr_mgt
import os

/// 日志按子系统归类，诊断报告用 `log show --predicate 'subsystem == "..."'` 取回。
let helperLog = Logger(subsystem: FanControl.label, category: "fan")

// islet 的风扇控制辅助程序：以 root 运行（launchd 守护进程），只做一件事——
// 按菜单栏程序下发的配置（自动 / 固定 / 曲线 / 规则）调速，并在任何异常时把风扇交还系统。
//
// 安全边界：
// - 只接受 /Applications/islet.app 的连接（另按代码签名标识校验）；
// - 配置在这里重新校验和截断；温度、曲线、规则、安全下限都在这里计算，
//   转速始终在系统最低～最高之间、不低于按温度计算的安全下限，绝不为 0——
//   即使有程序冒充菜单栏程序，最坏也只能让风扇更吵，不能让它更慢；
// - 租约 15 秒：菜单栏程序不再续约（退出、崩溃、被杀）就交还系统；
// - 读不到温度、连续写入失败、系统睡眠、收到退出信号：立即交还系统。
//
// 用法：正常由 launchd 启动；`--dry-run <配置 JSON 文件>` 只读演练，打印每秒算出的目标转速，不写入。

final class FanController {
    let queue = DispatchQueue(label: "\(FanControl.label).control")  // 所有 SMC 访问都在这个队列
    private var config = FanConfig()
    private var status = FanStatus()
    private var leaseExpiry: TimeInterval = 0
    private var smoother = FanSmoother()
    private var rules = FanRuleEngine()
    private let temperatures = Temperatures()
    private var recent: [Double] = []  // 最近 5 秒参考温度，做滑动平均
    private var lastTick: TimeInterval?
    private var lastWritten: Double?
    private var lastWriteTime: TimeInterval = 0
    private var failures = 0
    private var timer: DispatchSourceTimer?
    private let dryRun: Bool

    /// 各风扇的系统最低 / 最高转速（只读一次）。
    private lazy var fans: [(minimum: Double, maximum: Double)] = {
        let count = Int(SMC.shared.value("FNum") ?? 0)
        return (0..<min(count, 4)).compactMap { index in
            guard let minimum = SMC.shared.value("F\(index)Mn"), let maximum = SMC.shared.value("F\(index)Mx"),
                  minimum > 0, maximum >= minimum else { return nil }
            return (minimum, maximum)
        }
    }()

    init(dryRun: Bool) {
        self.dryRun = dryRun
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// 启动时清理：上次若异常退出、风扇还停在手动模式，先交还系统。
    func start() {
        queue.sync { restore(reason: "启动") }
    }

    /// 应用配置并续约。返回错误信息，成功为 nil。
    func apply(_ data: Data) -> String? {
        queue.sync {
            guard let incoming = try? JSONDecoder().decode(FanConfig.self, from: data) else { return "配置格式错误" }
            guard incoming.strategy != .auto else {
                config = incoming
                status.strategy = .auto
                restore(reason: "切回系统自动")
                return nil
            }
            guard let fan0 = fans.first else { return "这台 Mac 没有可控制的风扇" }
            let sanitized = incoming.sanitized(minimum: fan0.minimum, maximum: fan0.maximum)
            if sanitized.strategy != config.strategy || sanitized.basis != config.basis {
                smoother.reset()
                rules.reset()
                recent.removeAll()
            }
            if sanitized.strategy != config.strategy {
                helperLog.notice("切换策略：\(sanitized.strategy.label, privacy: .public)，依据：\(sanitized.basis.label, privacy: .public)")
            }
            config = sanitized
            status.strategy = sanitized.strategy
            status.message = nil
            leaseExpiry = now + FanControl.leaseSeconds
            if timer == nil { startTimer() }
            return nil
        }
    }

    func statusData() -> Data {
        queue.sync { (try? JSONEncoder().encode(status)) ?? Data() }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard config.strategy != .auto else { return }
        if now > leaseExpiry && !dryRun {
            restore(reason: "租约过期（菜单栏程序未续约）")
            return
        }
        guard let fan0 = fans.first else {
            restore(reason: "没有可控制的风扇")
            return
        }
        // 规则可能引用任意分组；其余策略只需要参考分组
        let needed = config.strategy == .rules
            ? Set(FanControl.controlGroups + config.rules.filter(\.enabled).map(\.group))
            : Set(FanControl.controlGroups)
        let groups = temperatures.read(only: needed)
        let reference = groups.filter { FanControl.controlGroups.contains($0.name) }
        guard let celsius = (reference.isEmpty ? groups : reference)
            .map({ config.basis == .peak ? $0.maximum : $0.average }).max() else {
            restore(reason: "读不到温度")
            return
        }
        recent = Array((recent + [celsius]).suffix(5))
        let smoothed = recent.reduce(0, +) / Double(recent.count)
        let elapsed = lastTick.map { now - $0 } ?? 1
        lastTick = now
        status.celsius = smoothed

        let target: Double?
        switch config.strategy {
        case .auto: target = nil
        case .fixed: target = config.fixedRPM
        case .curve: target = FanCurve.rpm(config.curve, at: smoothed)
        case .rules:
            var readings: [String: (average: Double, peak: Double)] = [:]
            for group in groups { readings[group.name] = (group.average, group.maximum) }
            target = rules.evaluate(config.rules, readings: readings)
            status.triggered = config.rules.filter { rules.armed.contains($0.id) }.map(\.id)
        }
        // 规则都未触发：交给系统（不能按安全下限接管——系统此时可能转得比下限更快）
        guard let desired = target else {
            releaseToSystem()
            return
        }
        let rpm = smoother.update(target: desired, celsius: smoothed, minimum: fan0.minimum, maximum: fan0.maximum,
                                  elapsed: elapsed, useHysteresis: config.strategy == .curve)
        status.target = rpm
        if dryRun {
            print(String(format: "%@：参考温度 %.1f℃（平滑 %.1f℃）→ 目标 %.0f 转", config.strategy.label, celsius, smoothed, rpm))
            return
        }
        // 转速变化不足 40 转不写（防抖）；但每 10 秒重新写一次，防止系统收回控制权
        let changed = lastWritten.map { abs($0 - rpm) >= 40 } ?? true
        guard changed || now - lastWriteTime >= 10 else { return }
        let fraction = (rpm - fan0.minimum) / max(fan0.maximum - fan0.minimum, 1)
        var ok = true
        for (index, fan) in fans.enumerated() {
            let value = fan.minimum + (fan.maximum - fan.minimum) * fraction
            ok = enterManual(index) && SMC.shared.writeRPM("F\(index)Tg", value) && ok
        }
        if ok {
            failures = 0
            lastWritten = rpm
            lastWriteTime = now
            status.controlling = true
        } else {
            failures += 1
            let failure = SMC.shared.lastWriteFailure.map { "\($0.key) \(SMC.describe($0.code))" } ?? "未知"
            let mode = SMC.shared.raw("F0Md")
            helperLog.error("写入失败（第 \(self.failures) 次）：目标 \(Int(rpm)) 转；失败的键 \(failure, privacy: .public)；F0Md \(mode.map { "\($0.type) \($0.bytes)" } ?? "不存在", privacy: .public)；Ftst \(SMC.shared.exists("Ftst") ? "存在" : "不存在", privacy: .public)")
            if failures >= 3 { restore(reason: "连续写入失败") }
        }
    }

    /// 切到手动模式；M3/M4 部分机型需先写 Ftst 解锁（本机没有该键时跳过）。
    private func enterManual(_ index: Int) -> Bool {
        let key = "F\(index)Md"
        if SMC.shared.value(key) == 1 { return true }
        if SMC.shared.writeUInt8(key, 1) { return true }
        guard SMC.shared.exists("Ftst") else { return false }
        SMC.shared.writeUInt8("Ftst", 1)
        for _ in 0..<20 {
            if SMC.shared.writeUInt8(key, 1) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// 暂时交给系统（规则未触发）：模式写回 0，但保留策略和租约，继续评估。
    private func releaseToSystem() {
        status.target = 0
        guard status.controlling else { return }
        status.controlling = false
        smoother.reset()
        lastWritten = nil
        guard !dryRun else { return }
        for index in fans.indices where SMC.shared.value("F\(index)Md") != 0 {
            SMC.shared.writeUInt8("F\(index)Md", 0)
        }
    }

    /// 彻底交还系统：停止计时器，只把模式键写回 0，不写目标转速。
    private func restore(reason: String) {
        let wasActive = config.strategy != .auto || status.controlling
        config.strategy = .auto
        status = FanStatus(message: wasActive ? reason : nil)
        timer?.cancel()
        timer = nil
        smoother.reset()
        rules.reset()
        recent.removeAll()
        lastTick = nil
        lastWritten = nil
        failures = 0
        guard !dryRun else { return }
        for index in fans.indices where SMC.shared.value("F\(index)Md") != 0 {
            SMC.shared.writeUInt8("F\(index)Md", 0)
        }
        if SMC.shared.value("Ftst") == 1 { SMC.shared.writeUInt8("Ftst", 0) }
        if wasActive { helperLog.notice("风扇已交还系统：\(reason, privacy: .public)") }
    }

    /// 睡眠 / 退出时调用。
    func restoreNow(reason: String) {
        queue.sync { restore(reason: reason) }
    }
}

// MARK: - XPC

final class HelperService: NSObject, FanHelperProtocol {
    let controller: FanController

    init(controller: FanController) {
        self.controller = controller
    }

    func apply(_ config: Data, reply: @escaping (String?) -> Void) {
        reply(controller.apply(config))
    }

    func status(reply: @escaping (Data) -> Void) {
        reply(controller.statusData())
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: HelperService

    init(service: HelperService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // 只接受安装在“应用程序”里的 islet；系统还会按代码签名标识校验每条消息的发送方
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(connection.processIdentifier, &buffer, UInt32(buffer.count)) > 0,
              String(cString: buffer) == FanControl.clientPath else {
            helperLog.error("拒绝连接：进程 \(connection.processIdentifier) 不是 islet")
            return false
        }
        connection.setCodeSigningRequirement("identifier \"\(FanControl.clientIdentifier)\"")
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

// MARK: - 睡眠

// IOKit 消息宏在 Swift 中不可用：iokit_common_msg(0x280) / (0x270)
private let messageSystemWillSleep: UInt32 = 0xE000_0280
private let messageCanSystemSleep: UInt32 = 0xE000_0270
private var powerPort: io_connect_t = 0
private var notifier: io_object_t = 0

func watchSleep(_ controller: FanController) {
    let context = Unmanaged.passUnretained(controller).toOpaque()
    var port: IONotificationPortRef?
    powerPort = IORegisterForSystemPower(context, &port, { context, _, message, argument in
        switch message {
        case messageSystemWillSleep:
            if let context {
                Unmanaged<FanController>.fromOpaque(context).takeUnretainedValue().restoreNow(reason: "系统睡眠")
            }
            IOAllowPowerChange(powerPort, Int(bitPattern: argument))
        case messageCanSystemSleep:
            IOAllowPowerChange(powerPort, Int(bitPattern: argument))
        default:
            break
        }
    }, &notifier)
    if let port {
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
    }
}

// MARK: - 入口

let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == "--dry-run" {
    guard let data = FileManager.default.contents(atPath: arguments[2]) else {
        print("读不到配置文件：\(arguments[2])")
        exit(2)
    }
    let controller = FanController(dryRun: true)
    if let error = controller.apply(data) { print(error); exit(1) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { exit(0) }
    dispatchMain()
}

let controller = FanController(dryRun: false)
helperLog.notice("辅助程序启动，协议版本 \(FanControl.version)")
controller.start()
watchSleep(controller)

// launchd 停止服务（卸载 / 关机）时先交还系统再退出
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    controller.restoreNow(reason: "辅助程序退出")
    exit(0)
}
termination.resume()

let delegate = ListenerDelegate(service: HelperService(controller: controller))
let listener = NSXPCListener(machServiceName: FanControl.label)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
