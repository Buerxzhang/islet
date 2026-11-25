import AppKit
import IOKit.pwr_mgt

// 面板里的操作型功能：结束进程、保持唤醒、流量统计、外接磁盘。

// MARK: - 结束进程

/// 结束排行里某一行对应的进程。按采样时记下的进程号操作（Wine 程序、命令行工具也能处理），
/// 只结束当前用户自己的进程；系统目录里的程序和本程序自身不允许结束。
enum ProcessControl {
    enum Outcome {
        case requested      // 已请求退出（应用可能会先询问是否保存）
        case notAllowed     // 系统进程或本程序
        case notFound       // 已经不在运行
        case denied         // 别的用户或系统的进程，没有权限
    }

    /// 系统程序与本程序：不显示结束按钮。
    static func isSystem(_ identity: String) -> Bool {
        let system = ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/sbin/", "/bin/", "/Library/Apple/"]
        if system.contains(where: { identity.hasPrefix($0) }) { return true }
        return false
    }

    static func isProtected(_ identity: String) -> Bool {
        if isSystem(identity) { return true }
        return identity == Bundle.main.bundlePath || identity.hasPrefix(Bundle.main.bundlePath + "/")
    }

    /// 仍在运行、归当前用户所有、而且还是同一个程序的进程号。
    /// 核对程序路径：原进程退出后进程号可能被别的程序复用，不能只看进程号和用户。
    static func owned(_ identity: String, _ pids: [Int32]) -> [Int32] {
        let uid = getuid()
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.filter { pid in
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard pid > 0, proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_uid == uid,
                  proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
            return AppIdentityResolver.identity(forPath: String(cString: path)) == identity
        }
    }

    /// 排行里是否显示“结束”按钮。
    static func canTerminate(_ identity: String, pids: [Int32]) -> Bool {
        !isProtected(identity) && !owned(identity, pids).isEmpty
    }

    static func isRunning(_ identity: String, pids: [Int32]) -> Bool { !owned(identity, pids).isEmpty }

    /// 优雅退出：.app 走正常退出流程（可能弹出“是否保存”），其他进程发 SIGTERM。
    static func quit(_ identity: String, pids: [Int32]) -> Outcome {
        guard !isProtected(identity) else { return .notAllowed }
        let mine = owned(identity, pids)
        guard !mine.isEmpty else { return pids.contains { kill($0, 0) == 0 || errno == EPERM } ? .denied : .notFound }
        if identity.hasSuffix(".app") {
            let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == identity }
            if !apps.isEmpty {
                apps.forEach { $0.terminate() }
                return .requested
            }
        }
        mine.forEach { kill($0, SIGTERM) }
        return .requested
    }

    /// 强制结束：立即终止，未保存的内容会丢失。
    static func forceQuit(_ identity: String, pids: [Int32]) -> Outcome {
        guard !isProtected(identity) else { return .notAllowed }
        let mine = owned(identity, pids)
        guard !mine.isEmpty else { return .notFound }
        if identity.hasSuffix(".app") {
            NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == identity }.forEach { $0.forceTerminate() }
        }
        mine.forEach { kill($0, SIGKILL) }
        return .requested
    }
}

// MARK: - 保持唤醒

/// 阻止电脑因闲置而睡眠（可选屏幕也保持常亮），到时自动解除。程序退出时系统会自动释放。
final class KeepAwake: ObservableObject {
    enum Duration: Int, CaseIterable {
        case off, halfHour, twoHours, always

        var label: String { ["关闭", "30 分钟", "2 小时", "一直"][rawValue] }
        var seconds: TimeInterval? { [nil, 1800, 7200, nil][rawValue] }
    }

    static let shared = KeepAwake()

    @Published private(set) var duration: Duration = .off
    @Published private(set) var until: Date?
    @Published private(set) var keepDisplayOn = UserDefaults.standard.bool(forKey: "keepAwakeDisplay")
    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    var isActive: Bool { duration != .off }

    /// 剩余时间，如“剩余 1:23:45”；“一直”时为 nil。
    var remainingText: String? {
        guard let until else { return nil }
        let remaining = max(0, Int(until.timeIntervalSinceNow))
        return String(format: "剩余 %d:%02d:%02d", remaining / 3600, remaining / 60 % 60, remaining % 60)
    }

    /// 选“一直”时记住，下次启动 islet 自动恢复（沿用原来“启动时保持唤醒”的偏好键）。
    func set(_ duration: Duration) {
        self.duration = duration
        UserDefaults.standard.set(duration == .always, forKey: "keepAwakeOnLaunch")
        until = duration.seconds.map { Date(timeIntervalSinceNow: $0) }
        apply()
        timer?.invalidate()
        timer = nil
        guard duration != .off else { return }
        // 每秒刷新剩余时间；到点自动关闭
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let until = self.until, until <= Date() { self.set(.off) } else { self.objectWillChange.send() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setKeepDisplayOn(_ on: Bool) {
        keepDisplayOn = on
        UserDefaults.standard.set(on, forKey: "keepAwakeDisplay")
        apply()
    }

    private func apply() {
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        guard duration != .off else { return }
        // 系统睡眠断言：PreventUserIdleSystemSleep；屏幕常亮：PreventUserIdleDisplaySleep
        let type = (keepDisplayOn ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep") as CFString
        IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "islet：保持唤醒" as CFString, &assertion)
    }
}

// MARK: - 流量统计

/// 按天、按月累计物理网卡的收发字节数，持久化在偏好设置里（跨重启保留）。
/// 只统计本程序运行期间的流量。
final class TrafficLedger {
    struct Totals: Codable {
        var day = ""
        var dayDown: Double = 0
        var dayUp: Double = 0
        var month = ""
        var monthDown: Double = 0
        var monthUp: Double = 0
    }

    static let shared = TrafficLedger()
    private(set) var totals: Totals
    private var unsaved = 0
    private static let key = "trafficLedger"
    private let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private init() {
        totals = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Totals.self, from: $0) } ?? Totals()
    }

    /// 每月统计从几号开始（对齐运营商账单），1~28。
    static var monthStart: Int { max(1, min(28, UserDefaults.standard.integer(forKey: "trafficMonthStart"))) }

    /// 当前统计周期的标识：起始日之前算上个月的周期。
    private func period(_ date: Date) -> String {
        let calendar = Calendar.current
        var start = date
        if calendar.component(.day, from: date) < Self.monthStart {
            start = calendar.date(byAdding: .month, value: -1, to: date) ?? date
        }
        let month = String(dayFormat.string(from: start).prefix(7))
        return Self.monthStart == 1 ? month : month + "|\(Self.monthStart)"   // 1 号起与旧数据格式一致，升级不清零
    }

    /// 清零今日和本月的统计。
    func reset() {
        totals = Totals()
        save()
    }

    func add(down: Double, up: Double) {
        let day = dayFormat.string(from: Date())
        let month = period(Date())
        if totals.day != day { totals.day = day; totals.dayDown = 0; totals.dayUp = 0 }
        if totals.month != month { totals.month = month; totals.monthDown = 0; totals.monthUp = 0 }
        totals.dayDown += down
        totals.dayUp += up
        totals.monthDown += down
        totals.monthUp += up
        unsaved += 1
        if unsaved >= 30 { save() }
    }

    /// 读取当前统计；跨天 / 跨月时先归零再返回。
    func current() -> Totals {
        add(down: 0, up: 0)
        return totals
    }

    func save() {
        unsaved = 0
        if let data = try? JSONEncoder().encode(totals) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

// MARK: - 外接磁盘

struct ExternalVolume: Identifiable {
    let url: URL
    let name: String
    let icon: NSImage
    let available: Int64?
    let total: Int64?
    let isNetwork: Bool
    var id: String { url.path }
}

enum ExternalVolumes {
    /// 已挂载的外接 / 可推出卷（U 盘、移动硬盘、磁盘映像、网络共享），不含启动盘与系统卷。
    static func list() -> [ExternalVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
                                      .volumeIsLocalKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsRootFileSystem != true,
                  !url.path.hasPrefix("/System/Volumes") else { return nil }
            let isNetwork = values.volumeIsLocal == false
            let external = values.volumeIsInternal == false || values.volumeIsEjectable == true || values.volumeIsRemovable == true
            guard external || isNetwork else { return nil }
            return ExternalVolume(url: url, name: values.volumeName ?? url.lastPathComponent,
                                  icon: AppIcons.rasterize(NSWorkspace.shared.icon(forFile: url.path)),
                                  available: values.volumeAvailableCapacity.map(Int64.init),
                                  total: values.volumeTotalCapacity.map(Int64.init), isNetwork: isNetwork)
        }
    }

    /// 推出（可能阻塞，放在后台线程）。completion 在主线程回调，参数为错误信息。
    static func eject(_ volume: ExternalVolume, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var message: String?
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
            } catch {
                message = "无法推出“\(volume.name)”：可能有程序正在使用它。\(error.localizedDescription)"
            }
            DispatchQueue.main.async { completion(message) }
        }
    }
}
