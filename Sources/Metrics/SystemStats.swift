import Foundation
import IOKit

/// 整机 CPU 使用率：两次 host_statistics 采样之间的忙碌占比。
struct CPULoad {
    private var previous: (busy: UInt64, idle: UInt64)?

    mutating func reset() { previous = nil }

    /// 0...1；第一次调用只建立基线，返回 nil。
    mutating func usage() -> Double? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: load) / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { previous = nil; return nil }
        let (user, system, idle, nice) = load.cpu_ticks
        let current = (busy: UInt64(user) + UInt64(system) + UInt64(nice), idle: UInt64(idle))
        defer { previous = current }
        guard let previous, current.busy >= previous.busy, current.idle >= previous.idle else { return nil }
        let busy = current.busy - previous.busy
        let total = busy + current.idle - previous.idle
        return total > 0 ? Double(busy) / Double(total) : nil
    }
}

/// 整机内存。“已用”与活动监视器一致：App 内存 + 联动内存 + 被压缩内存。
struct MemoryStats {
    let used: UInt64
    let total: UInt64
    let pressure: Int32

    static func read() -> MemoryStats? {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(vm.internal_page_count)
        let app = internalPages - min(UInt64(vm.purgeable_count), internalPages)
        let used = (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
        var pressure: Int32 = 0
        var size = MemoryLayout.size(ofValue: pressure)
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) != 0 { pressure = 0 }
        return MemoryStats(used: used, total: ProcessInfo.processInfo.physicalMemory, pressure: pressure)
    }

    var pressureText: String {
        switch pressure {
        case 1: return "正常"
        case 2: return "偏高"
        case 4: return "严重"
        default: return "未知"
        }
    }
}

/// 所有进程的累计 CPU 时间与内存占用。
/// 用 /bin/ps（setuid root）读取，才能看到 root 进程（WindowServer 等）；
/// 自己的进程再用 proc_pid_rusage 取“物理内存占用”（活动监视器“内存”列），其余回退到常驻内存。
struct ProcessSample {
    struct Entry {
        let path: String
        var parentPID: Int32 = 0
        let cpuTime: Double   // 秒
        let memory: UInt64    // 字节
        let disk: (read: UInt64, written: UInt64)?  // 累计磁盘读写字节，仅自己的进程可读
        let energy: UInt64?   // 累计能耗（纳焦），仅自己的进程可读
    }

    let time: TimeInterval
    let entries: [Int32: Entry]

    static func sample() -> ProcessSample? {
        guard let output = runTool("/bin/ps", ["-axo", "pid=,ppid=,time=,rss=,comm="]) else { return nil }
        let time = ProcessInfo.processInfo.systemUptime
        var entries: [Int32: Entry] = [:]
        var usage = rusage_info_v6()
        for line in output.split(whereSeparator: \.isNewline) {
            var rest = line[...]
            func token() -> Substring? {
                rest = rest.drop { $0 == " " }
                guard let end = rest.firstIndex(of: " ") else { return nil }
                defer { rest = rest[end...] }
                return rest[..<end]
            }
            guard let pidText = token(), let pid = Int32(pidText),
                  let parentText = token(), let parentPID = Int32(parentText),
                  let timeText = token(), let cpuTime = parseCPUTime(timeText),
                  let rssText = token(), let rss = UInt64(rssText) else { continue }
            let path = String(rest.drop { $0 == " " })
            guard !path.isEmpty else { continue }
            let readable = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            } == 0
            entries[pid] = Entry(path: path, parentPID: parentPID, cpuTime: cpuTime,
                                 memory: readable ? usage.ri_phys_footprint : rss * 1024,
                                 disk: readable ? (usage.ri_diskio_bytesread, usage.ri_diskio_byteswritten) : nil,
                                 energy: readable ? usage.ri_energy_nj : nil)
        }
        return entries.isEmpty ? nil : ProcessSample(time: time, entries: entries)
    }

    /// ps 的 time 格式：[天-][时:]分:秒.百分秒
    private static func parseCPUTime(_ text: Substring) -> Double? {
        var days = 0.0
        var clock = text
        if let dash = text.firstIndex(of: "-") {
            guard let value = Double(text[..<dash]) else { return nil }
            days = value
            clock = text[text.index(after: dash)...]
        }
        var seconds = 0.0
        for part in clock.split(separator: ":") {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return days * 86_400 + seconds
    }

    /// 按应用汇总的 CPU 占用，整机口径（全部核心跑满 = 100%），和面板圆环、胶囊上的数字一致。
    /// 不用活动监视器的单核口径：那样一个应用能显示 776%，和圆环的 100% 放在一起看不懂。
    func cpuRanking(since previous: ProcessSample) -> [RankedApp] {
        let elapsed = time - previous.time
        let cores = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
        guard elapsed > 0, elapsed < 70 else { return [] }
        var apps: [String: Double] = [:]
        var pids: [String: [Int32]] = [:]
        for (pid, now) in entries {
            guard let old = previous.entries[pid], old.path == now.path, now.cpuTime > old.cpuTime else { continue }
            let identity = memoryIdentity(for: pid)
            apps[identity, default: 0] += (now.cpuTime - old.cpuTime) / elapsed / cores * 100
            pids[identity, default: []].append(pid)
        }
        return apps.filter { $0.value >= 0.1 }
            .sorted { $0.value > $1.value }
            .map { RankedApp(identity: $0.key, values: [$0.value], pids: pids[$0.key] ?? []) }
    }

    /// 按应用汇总的磁盘读、写速率（字节/秒）。
    func diskRanking(since previous: ProcessSample) -> [RankedApp] {
        let elapsed = time - previous.time
        guard elapsed > 0, elapsed < 70 else { return [] }
        var apps: [String: (read: Double, write: Double)] = [:]
        var pids: [String: [Int32]] = [:]
        for (pid, now) in entries {
            guard let disk = now.disk, let old = previous.entries[pid], old.path == now.path, let oldDisk = old.disk,
                  disk.read >= oldDisk.read, disk.written >= oldDisk.written,
                  disk.read > oldDisk.read || disk.written > oldDisk.written else { continue }
            let identity = memoryIdentity(for: pid)
            apps[identity, default: (0, 0)].read += Double(disk.read - oldDisk.read) / elapsed
            apps[identity, default: (0, 0)].write += Double(disk.written - oldDisk.written) / elapsed
            pids[identity, default: []].append(pid)
        }
        return apps.sorted { $0.value.read + $0.value.write > $1.value.read + $1.value.write }
            .map { RankedApp(identity: $0.key, values: [$0.value.read, $0.value.write], pids: pids[$0.key] ?? []) }
    }

    /// 按应用汇总的功耗（瓦）。系统进程（root）读不到能耗，不计入。
    func powerRanking(since previous: ProcessSample) -> [RankedApp] {
        let elapsed = time - previous.time
        guard elapsed > 0, elapsed < 70 else { return [] }
        var apps: [String: Double] = [:]
        var pids: [String: [Int32]] = [:]
        for (pid, now) in entries {
            guard let energy = now.energy, let old = previous.entries[pid], old.path == now.path,
                  let oldEnergy = old.energy, energy > oldEnergy else { continue }
            let identity = memoryIdentity(for: pid)
            apps[identity, default: 0] += Double(energy - oldEnergy) / 1e9 / elapsed
            pids[identity, default: []].append(pid)
        }
        return apps.filter { $0.value >= 0.05 }
            .sorted { $0.value > $1.value }
            .map { RankedApp(identity: $0.key, values: [$0.value], pids: pids[$0.key] ?? []) }
    }

    /// Application Support 内的内嵌应用通过父进程找到桌面宿主。
    /// 独立启动的 CLI 遇到终端边界即停止，不按名称猜测归属。
    func memoryIdentity(for pid: Int32) -> String {
        guard let entry = entries[pid] else { return "" }
        let own = AppIdentityResolver.identity(forPath: entry.path)
        guard entry.path.contains("/Library/Application Support/") else { return own }
        var cursor = entry.parentPID
        var visited: Set<Int32> = [pid]
        while cursor > 1, visited.insert(cursor).inserted, let parent = entries[cursor] {
            let identity = AppIdentityResolver.identity(forPath: parent.path)
            if identity.hasSuffix(".app"), identity != own {
                if AppIdentityResolver.isTerminal(identity) { return own }
                return identity
            }
            cursor = parent.parentPID
        }
        return own
    }

    /// 按桌面应用汇总，保留可展开的可执行程序分组；每个 PID 只计入一次。
    func memoryRanking() -> [RankedApp] {
        var groups: [String: [String: [Int32]]] = [:]
        for (pid, entry) in entries {
            groups[memoryIdentity(for: pid), default: [:]][entry.path, default: []].append(pid)
        }
        return groups.map { identity, programs in
            let children = programs.map { path, pids in
                RankedApp(identity: path, values: [Double(pids.reduce(UInt64(0)) { $0 + (entries[$1]?.memory ?? 0) })], pids: pids.sorted())
            }.sorted { $0.values[0] > $1.values[0] }
            return RankedApp(identity: identity, values: [children.reduce(0) { $0 + $1.values[0] }],
                             pids: children.flatMap(\.pids), children: children.count > 1 ? children : [])
        }.sorted { $0.values[0] > $1.values[0] }
    }

}

/// GPU：整体利用率和各进程累计 GPU 时间，均来自 IORegistry 中的 IOAccelerator（无需特权）。
struct GPUSample {
    let time: TimeInterval
    let utilization: Double?               // 0...1
    let clients: [Int32: (name: String, gpuTime: UInt64)]  // 纳秒

    static func read(includeClients: Bool) -> GPUSample {
        var utilization: Double?
        var clients: [Int32: (name: String, gpuTime: UInt64)] = [:]
        forEachService(matching: "IOAccelerator") { service in
            if let stats = property(service, "PerformanceStatistics") as? [String: Any],
               let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                utilization = max(utilization ?? 0, value / 100)
            }
            guard includeClients else { return }
            var children = io_iterator_t()
            guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(children) }
            while case let child = IOIteratorNext(children), child != 0 {
                defer { IOObjectRelease(child) }
                // 形如 "pid 240, WindowServer"
                guard let creator = property(child, "IOUserClientCreator") as? String,
                      creator.hasPrefix("pid "), let comma = creator.firstIndex(of: ","),
                      let pid = Int32(creator[creator.index(creator.startIndex, offsetBy: 4)..<comma]),
                      let usage = property(child, "AppUsage") as? [[String: Any]] else { continue }
                let total = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"]) as? NSNumber)?.uint64Value ?? 0) }
                let name = creator[creator.index(after: comma)...].trimmingCharacters(in: .whitespaces)
                clients[pid, default: (name, 0)].gpuTime += total
            }
        }
        return GPUSample(time: ProcessInfo.processInfo.systemUptime, utilization: utilization, clients: clients)
    }

    /// 按应用汇总的 GPU 占用百分比。
    func ranking(since previous: GPUSample, resolver: AppIdentityResolver) -> [RankedApp] {
        let elapsed = time - previous.time
        guard elapsed > 0, elapsed < 70 else { return [] }
        var apps: [String: Double] = [:]
        var pids: [String: [Int32]] = [:]
        for (pid, now) in clients {
            guard let old = previous.clients[pid], now.gpuTime > old.gpuTime else { continue }
            let identity = resolver.identity(for: "\(now.name).\(pid)")
            apps[identity, default: 0] += Double(now.gpuTime - old.gpuTime) / 1e9 / elapsed * 100
            pids[identity, default: []].append(pid)
        }
        return apps.filter { $0.value >= 0.1 }
            .sorted { $0.value > $1.value }
            .map { RankedApp(identity: $0.key, values: [$0.value], pids: pids[$0.key] ?? []) }
    }
}

/// 启动盘容量与全部物理磁盘的累计读写字节数。
struct DiskStats {
    let time: TimeInterval
    let available: Int64?
    let total: Int64?
    let bytesRead: UInt64
    let bytesWritten: UInt64

    static func read(includeCapacity: Bool) -> DiskStats {
        var available: Int64?
        var total: Int64?
        if includeCapacity {
            let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
            let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys)
            available = values?.volumeAvailableCapacityForImportantUsage
            total = values?.volumeTotalCapacity.map(Int64.init)
        }
        var read: UInt64 = 0
        var written: UInt64 = 0
        forEachService(matching: "IOBlockStorageDriver") { service in
            guard let stats = property(service, "Statistics") as? [String: Any] else { return }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return DiskStats(time: ProcessInfo.processInfo.systemUptime, available: available, total: total,
                         bytesRead: read, bytesWritten: written)
    }

    var usedFraction: Double? {
        guard let available, let total, total > 0 else { return nil }
        return 1 - Double(available) / Double(total)
    }

    /// 与上次采样之间的读、写速率（字节/秒）。
    func rates(since previous: DiskStats) -> (read: Double, write: Double)? {
        let elapsed = time - previous.time
        guard elapsed > 0, elapsed < 30, bytesRead >= previous.bytesRead, bytesWritten >= previous.bytesWritten else { return nil }
        return (Double(bytesRead - previous.bytesRead) / elapsed, Double(bytesWritten - previous.bytesWritten) / elapsed)
    }
}

private func forEachService(matching className: String, _ body: (io_registry_entry_t) -> Void) {
    var iterator = io_iterator_t()
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
    defer { IOObjectRelease(iterator) }
    while case let service = IOIteratorNext(iterator), service != 0 {
        body(service)
        IOObjectRelease(service)
    }
}

private func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}
