import AppKit

/// 运行系统命令行工具并返回 stdout；正常 20ms 内结束，卡住超过 3 秒强制结束。
func runTool(_ path: String, _ arguments: [String]) -> String? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    // 菜单栏 App 没有 LANG，ps 会把中文路径转义成 M-e… 形式
    process.environment = ["LC_ALL": "en_US.UTF-8"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: watchdog)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()
    guard process.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self)
}

/// 排行中的一行：identity 是 .app 路径、可执行文件路径或进程名；values 按列排列。
struct RankedApp {
    let identity: String
    let values: [Double]
    /// 这一行包含的进程号（结束进程时直接按它们操作，不靠路径反查）。
    var pids: [Int32] = []
    var children: [RankedApp] = []
}

/// 各进程累计收发字节数（nettop）。
struct AppTraffic {
    let time: TimeInterval
    let counters: [String: (received: UInt64, sent: UInt64)]

    static func sample() -> AppTraffic? {
        guard let output = runTool("/usr/bin/nettop", ["-n", "-P", "-L", "1", "-s", "1", "-J", "bytes_in,bytes_out", "-x"]),
              output.contains("bytes_in,bytes_out") else { return nil }
        let time = ProcessInfo.processInfo.systemUptime
        var counters: [String: (UInt64, UInt64)] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 4,
                  let received = UInt64(fields[fields.count - 3]),
                  let sent = UInt64(fields[fields.count - 2]) else { continue }
            counters[fields.dropLast(3).joined(separator: ",")] = (received, sent)
        }
        return AppTraffic(time: time, counters: counters)
    }

    /// 按应用汇总的下载、上传速率（字节/秒）。
    func ranked(since previous: AppTraffic, resolver: AppIdentityResolver) -> [RankedApp] {
        let elapsed = time - previous.time
        guard elapsed > 0, elapsed < 70 else { return [] }
        var apps: [String: (down: Double, up: Double)] = [:]
        var pids: [String: [Int32]] = [:]
        for (key, now) in counters {
            guard let old = previous.counters[key], now.received >= old.received,
                  now.sent >= old.sent, now.received > old.received || now.sent > old.sent else { continue }
            let name = resolver.identity(for: key)
            if let dot = key.lastIndex(of: "."), let pid = Int32(key[key.index(after: dot)...]) { pids[name, default: []].append(pid) }
            apps[name, default: (0, 0)].down += Double(now.received - old.received) / elapsed
            apps[name, default: (0, 0)].up += Double(now.sent - old.sent) / elapsed
        }
        return apps.sorted { $0.value.down + $0.value.up > $1.value.down + $1.value.up }
            .map { RankedApp(identity: $0.key, values: [$0.value.down, $0.value.up], pids: pids[$0.key] ?? []) }
    }
}

/// 把 nettop 的 "进程名.PID" 解析为稳定身份：
/// - 属于 .app 的进程（含 Helper）归并到最外层 .app 路径
/// - 其他进程用可执行文件路径（nettop 会把名字截断到 15 字节，路径更准确，也能合并同名多进程）
/// 结果按 key 缓存。非线程安全，需在同一队列上使用。
final class AppIdentityResolver {
    private var cache: [String: String] = [:]
    private var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))

    func removeAll() { cache.removeAll(keepingCapacity: true) }

    func identity(for key: String) -> String {
        if let cached = cache[key] { return cached }
        let identity = resolve(key)
        cache[key] = identity
        return identity
    }

    static func identity(forPath path: String) -> String {
        if let end = path.range(of: ".app/") {
            return String(path[..<end.upperBound].dropLast())
        }
        return path
    }

    static func isTerminal(_ identity: String) -> Bool {
        ["Terminal.app", "iTerm.app", "iTerm2.app", "Warp.app", "Alacritty.app", "kitty.app", "Ghostty.app"]
            .contains(URL(fileURLWithPath: identity).lastPathComponent)
    }

    private func resolve(_ key: String) -> String {
        guard let dot = key.lastIndex(of: "."), let pid = Int32(key[key.index(after: dot)...]) else { return key }
        let length = buffer.withUnsafeMutableBufferPointer { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return String(key[..<dot]) }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let own = Self.identity(forPath: path)
        guard path.contains("/Library/Application Support/") else { return own }
        var cursor = pid
        var visited: Set<Int32> = []
        while cursor > 1, visited.insert(cursor).inserted {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(cursor, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { break }
            cursor = Int32(info.pbsi_ppid)
            guard cursor > 1, proc_pidpath(cursor, &buffer, UInt32(buffer.count)) > 0 else { break }
            let parent = Self.identity(forPath: String(cString: buffer))
            if parent.hasSuffix(".app"), parent != own {
                return Self.isTerminal(parent) ? own : parent
            }
        }
        return own
    }
}

/// 菜单栏上每个指标各对应一种排行。
enum Metric: Int, CaseIterable {
    case network, cpu, gpu, memory, disk, power, fan, temperature, fps

    var title: String {
        switch self {
        case .network: return "应用实时流量"
        case .cpu: return "CPU 占用排行"
        case .gpu: return "GPU 占用排行"
        case .memory: return "内存占用排行"
        case .disk: return "磁盘读写排行"
        case .power: return "功耗排行"
        case .fan: return "风扇 · 发热来源"
        case .temperature: return "温度"
        case .fps: return "帧率"
        }
    }

    var columns: [String] {
        switch self {
        case .network: return ["↓ 下载", "↑ 上传"]
        case .cpu: return ["CPU"]
        case .gpu: return ["GPU"]
        case .memory: return ["内存"]
        case .disk: return ["读取", "写入"]
        case .power, .fan: return ["功耗"]
        case .temperature: return ["平均", "最高"]
        case .fps: return []
        }
    }

    var emptyMessage: String {
        switch self {
        case .network: return "当前没有活跃应用流量"
        case .cpu: return "当前没有明显的 CPU 占用"
        case .gpu: return "当前没有明显的 GPU 占用"
        case .memory: return "暂无数据"
        case .disk: return "当前没有明显的磁盘读写"
        case .power, .fan: return "当前没有明显耗电的应用"
        case .temperature: return "读不到温度传感器"
        case .fps: return ""
        }
    }

    /// 排行数据来自 ps 进程快照的指标。
    var usesProcesses: Bool { [.cpu, .memory, .disk, .power, .fan].contains(self) }

    var accessibilityLabel: String {
        switch self {
        case .network: return "实时网速"
        case .cpu: return "CPU 使用率"
        case .gpu: return "GPU 使用率"
        case .memory: return "内存使用率"
        case .disk: return "启动盘已用空间"
        case .power: return "整机功耗"
        case .fan: return "风扇转速"
        case .temperature: return "CPU 温度"
        case .fps: return "屏幕帧率"
        }
    }

}
