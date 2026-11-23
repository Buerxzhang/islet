import AppKit
import IOKit.ps
import CoreWLAN
import Network
import UserNotifications

// MARK: - 单位

/// 温度（℃ / ℉）和网速（字节 / 比特）的显示单位。磁盘读写始终用字节。
enum Units {
    static var fahrenheit: Bool { UserDefaults.standard.bool(forKey: "unitFahrenheit") }
    static var bits: Bool { UserDefaults.standard.bool(forKey: "unitBits") }

    /// 摄氏度换成当前单位的数值。
    static func temperature(_ celsius: Double) -> Double { fahrenheit ? celsius * 9 / 5 + 32 : celsius }
    static func degrees(_ celsius: Double) -> String { "\(Int(temperature(celsius).rounded()))°" }
    static var temperatureUnit: String { fahrenheit ? "℉" : "℃" }

    /// 网速：字节时 1.2MB，比特时 9.6Mb。
    static func networkRate(_ bytesPerSecond: Double) -> String {
        guard bits else { return AppDelegate.compactRate(bytesPerSecond) }
        let value = bytesPerSecond * 8
        switch value {
        case 99_950_000...: return String(format: "%.0fMb", value / 1_000_000)
        case 999_500...: return String(format: "%.1fMb", value / 1_000_000)
        case 9_950...: return String(format: "%.0fKb", value / 1_000)
        case 50...: return String(format: "%.1fKb", value / 1_000)
        default: return "0Kb"
        }
    }
}

// MARK: - 提醒

/// 一条提醒规则：某个指标持续若干分钟高于阈值时通知一次，回落后才会再次提醒。
struct AlertRule: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case cpu, gpu, temperature, power, memory
        var title: String { ["CPU", "GPU", "温度", "功耗", "内存"][Self.allCases.firstIndex(of: self)!] }
        /// 阈值单位（温度按当前显示单位）。
        var unit: String {
            switch self {
            case .cpu, .gpu: return "%"
            case .temperature: return Units.temperatureUnit
            case .power: return "W"
            case .memory: return "GB"
            }
        }
        var metric: Metric {
            switch self {
            case .cpu: return .cpu
            case .gpu: return .gpu
            case .temperature: return .temperature
            case .power: return .power
            case .memory: return .memory
            }
        }
        var defaultThreshold: Double { [90, 90, 95, 60, 14][Self.allCases.firstIndex(of: self)!] }
    }
    var id = UUID()
    var kind: Kind
    var threshold: Double     // 温度一律按 ℃ 存
    var minutes: Int
    var enabled = true

    var summary: String {
        let value = kind == .temperature ? Units.degrees(threshold) : "\(Int(threshold))\(kind.unit)"
        return "\(kind.title) ≥ \(value)，持续 \(minutes) 分钟"
    }
}

/// 系统通知：蓝牙设备低电量，以及“提醒规则”里的各项。每种情况提醒一次，恢复正常后才会再次提醒。
final class AlertCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AlertCenter()

    static var lowBatteryEnabled: Bool { UserDefaults.standard.object(forKey: "alertLowBattery") as? Bool ?? true }
    /// 低电量阈值（%），设置里可选。
    static var lowBatteryThreshold: Int { UserDefaults.standard.object(forKey: "alertLowBatteryThreshold") as? Int ?? 20 }
    static let lowBatteryChoices = [(10, "10%"), (15, "15%"), (20, "20%"), (30, "30%")]
    /// 通知是否带提示音。
    static var alertSound: Bool { UserDefaults.standard.object(forKey: "alertSound") as? Bool ?? true }

    /// 设备图标 → 用户认得的类型名（通知标题里用：“键盘 BKB02_1 电量低”）。
    static func kindName(symbol: String) -> String? {
        switch symbol {
        case "keyboard": return "键盘"
        case "computermouse": return "鼠标"
        case "hand.point.up.left": return "触控板"
        case _ where BluetoothSystem.isHeadphone(symbol): return "耳机"
        case "hifispeaker": return "音箱"
        case "gamecontroller": return "手柄"
        default: return nil
        }
    }

    /// 提醒规则（存为 JSON）；首次使用时按旧版开关生成默认规则。
    static var rules: [AlertRule] {
        get {
            if let data = UserDefaults.standard.data(forKey: "alertRules"),
               let rules = try? JSONDecoder().decode([AlertRule].self, from: data) { return rules }
            let defaults = UserDefaults.standard
            return [
                AlertRule(kind: .temperature, threshold: Double(defaults.object(forKey: "alertHeatThreshold") as? Int ?? 95), minutes: 1,
                          enabled: defaults.object(forKey: "alertHeat") as? Bool ?? true),
                AlertRule(kind: .cpu, threshold: 90, minutes: 3, enabled: defaults.object(forKey: "alertLoad") as? Bool ?? false),
            ]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: "alertRules") }
            shared.states = [:]
            shared.prepare()
        }
    }

    private struct State { var since: Date?; var notified = false }
    private var states: [UUID: State] = [:]
    private var lowBatteryNotified: Set<String> = []

    /// 有任何提醒打开时请求通知权限（只会问一次）。
    func prepare() {
        guard Self.lowBatteryEnabled || Self.rules.contains(where: \.enabled) else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func post(_ id: String, title: String, body: String, image: NSImage? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = Self.alertSound ? .default : nil
        // 通知右侧的图：写成临时 PNG 交给系统（系统会把文件移走保管）
        if let image, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("islet-\(UUID().uuidString).png")
            if (try? png.write(to: url)) != nil, let attachment = try? UNNotificationAttachment(identifier: "image", url: url) {
                content.attachments = [attachment]
            }
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id + UUID().uuidString, content: content, trigger: nil))
    }

    /// 菜单栏程序不在前台：通知也照常弹出横幅。
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// 蓝牙设备电量低于阈值时提醒一次；充到阈值 + 10% 以上再重新计。
    func checkBatteries(_ devices: [(id: String, name: String, symbol: String, level: Int)]) {
        guard Self.lowBatteryEnabled else { return }
        let threshold = Self.lowBatteryThreshold
        for device in devices {
            if device.level <= threshold, !lowBatteryNotified.contains(device.id) {
                lowBatteryNotified.insert(device.id)
                notifyLowBattery(name: device.name, symbol: device.symbol, level: device.level)
            } else if device.level >= threshold + 10 {
                lowBatteryNotified.remove(device.id)
            }
        }
    }

    /// 低电量通知：标题带设备类型，右侧是电量环。
    func notifyLowBattery(name: String, symbol: String, level: Int) {
        let kind = Self.kindName(symbol: symbol).map { "\($0) " } ?? ""
        post("battery", title: "\(kind)\(name) 电量低", body: "剩余 \(level)%，记得充电。",
             image: StatusIcons.batteryBadge(symbol: symbol, level: level))
    }

    /// 设置里的“测试”：用一台已连接的设备（没有就用示例键盘）按当前设置发一条。
    func sendTest(device: (name: String, symbol: String, level: Int)?) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard granted else {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                    return
                }
                let sample = device ?? (name: "示例键盘", symbol: "keyboard", level: Self.lowBatteryThreshold)
                self?.notifyLowBattery(name: sample.name, symbol: sample.symbol, level: min(sample.level, Self.lowBatteryThreshold))
            }
        }
    }

    private var cachedRules: [AlertRule]?
    private var cachedAt = Date.distantPast

    /// 每次记录指标时调用：值为该指标的原始读数（CPU / GPU 百分比、温度 ℃、功耗 W、内存 GB）。
    func check(_ metric: Metric, _ value: Double) {
        if Date().timeIntervalSince(cachedAt) > 5 { cachedRules = Self.rules; cachedAt = Date() }
        for rule in cachedRules ?? [] where rule.enabled && rule.kind.metric == metric {
            var state = states[rule.id] ?? State()
            if value >= rule.threshold {
                if state.since == nil { state.since = Date() }
                if !state.notified, let since = state.since, Date().timeIntervalSince(since) >= Double(rule.minutes) * 60 {
                    state.notified = true
                    let current = rule.kind == .temperature ? Units.degrees(value) : String(format: "%.0f%@", value, rule.kind.unit)
                    post(rule.id.uuidString, title: "\(rule.kind.title)持续过高", body: "\(rule.summary)。当前 \(current)。")
                }
            } else {
                state.since = nil
                // 回落一定幅度才重新计，避免在阈值附近反复提醒
                if value < rule.threshold * 0.95 { state.notified = false }
            }
            states[rule.id] = state
        }
    }
}

// MARK: - 重新启动

enum SettingsTransfer {
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(Bundle.main.bundlePath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

// MARK: - 长期历史

/// 每分钟一个点（取这一分钟的平均值），保留 24 小时；存到磁盘，重启后接着画。
final class LongHistory {
    static let shared = LongHistory()
    struct Series: Codable { var a: [Double] = []; var b: [Double]? }
    private struct Bucket { var sum = 0.0, sum2 = 0.0, count = 0, hasB = false }

    private(set) var series: [String: Series] = [:]
    private var buckets: [String: Bucket] = [:]
    private var minute = Int(Date().timeIntervalSince1970 / 60)
    private var lastSaved = Date()
    private static let capacity = 1440

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("islet", isDirectory: true)
        // 保留区分大小写的磁盘上旧版存下的历史数据。
        if !FileManager.default.fileExists(atPath: folder.path) {
            for name in ["Islet", "系统监控"] {
                let old = support.appendingPathComponent(name, isDirectory: true)
                if (try? FileManager.default.moveItem(at: old, to: folder)) != nil { break }
            }
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("history.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([String: Series].self, from: data) { series = saved }
    }

    /// 每次刷新调用；跨分钟时把上一分钟的平均值存成一个点。
    func add(_ key: String, _ value: Double, _ value2: Double?) {
        let now = Int(Date().timeIntervalSince1970 / 60)
        if now != minute { flush(); minute = now }
        var bucket = buckets[key] ?? Bucket()
        bucket.sum += value
        if let value2 { bucket.sum2 += value2; bucket.hasB = true }
        bucket.count += 1
        buckets[key] = bucket
    }

    private func flush() {
        for (key, bucket) in buckets where bucket.count > 0 {
            var item = series[key] ?? Series(a: [], b: bucket.hasB ? [] : nil)
            item.a = Array((item.a + [bucket.sum / Double(bucket.count)]).suffix(Self.capacity))
            if bucket.hasB { item.b = Array(((item.b ?? []) + [bucket.sum2 / Double(bucket.count)]).suffix(Self.capacity)) }
            series[key] = item
        }
        buckets = [:]
        if Date().timeIntervalSince(lastSaved) > 600 { save() }
    }

    func save() {
        lastSaved = Date()
        if let data = try? JSONEncoder().encode(series) { try? data.write(to: Self.fileURL, options: .atomic) }
    }

    /// 最近 minutes 分钟的点；点太多时按段取平均，最多 points 个。
    func recent(_ key: String, minutes: Int, points: Int = 240) -> (a: [Double], b: [Double]?) {
        guard let item = series[key] else { return ([], nil) }
        func shrink(_ values: [Double]) -> [Double] {
            let tail = Array(values.suffix(minutes))
            guard tail.count > points else { return tail }
            let step = Double(tail.count) / Double(points)
            return (0..<points).map { i in
                let slice = tail[Int(Double(i) * step)..<min(tail.count, Int(Double(i + 1) * step))]
                return slice.reduce(0, +) / Double(max(slice.count, 1))
            }
        }
        return (shrink(item.a), item.b.map(shrink))
    }
}

// MARK: - 网络详情


/// 网速面板的“连接”信息：公网 IP、Wi-Fi 名称和信号、延迟。打开网速面板时才查询，结果缓存。
final class NetworkDetails {
    static let shared = NetworkDetails()
    struct Info: Equatable {
        var publicIP: String?
        var wifi: String?        // “名称 · -55 dBm”；有线或未连 Wi-Fi 时 nil
        var latency: Int?        // 毫秒
    }
    private(set) var info = Info()
    private var ipFetchedAt = Date.distantPast
    private var latencyAt = Date.distantPast
    var onChange: (Info) -> Void = { _ in }

    /// 打开面板时调用：Wi-Fi 即时读；延迟 10 秒内不重测；公网 IP 10 分钟内不重查。
    func refresh() {
        info.wifi = Self.wifi()
        onChange(info)
        if Date().timeIntervalSince(latencyAt) > 10 {
            latencyAt = Date()
            measureLatency()
        }
        if Date().timeIntervalSince(ipFetchedAt) > 600 {
            ipFetchedAt = Date()
            fetchPublicIP()
        }
    }

    private static func wifi() -> String? {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn(), interface.rssiValue() != 0 else { return nil }
        let rssi = interface.rssiValue()
        let quality = rssi >= -55 ? "强" : rssi >= -70 ? "中" : "弱"
        // 读取 Wi-Fi 名称需要定位权限；没有时只显示信号
        let name = interface.ssid() ?? "Wi-Fi"
        return "\(name) · 信号\(quality)（\(rssi) dBm）"
    }

    /// 延迟：到公共 DNS（223.5.5.5:53）建立 TCP 连接的耗时，不需要特殊权限。
    private func measureLatency() {
        let start = Date()
        let connection = NWConnection(host: "223.5.5.5", port: 53, using: .tcp)
        var finished = false
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard !finished else { return }
                finished = true
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                connection.cancel()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.info.latency = ms
                    self.onChange(self.info)
                }
            case .failed, .waiting:
                finished = true
                connection.cancel()
            default: break
            }
        }
        connection.start(queue: .global(qos: .utility))
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if !finished { finished = true; connection.cancel() } }
    }

    /// 公网 IP：请求 ipify（只返回 IP 本身）。
    private func fetchPublicIP() {
        guard let url = URL(string: "https://api.ipify.org") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data, let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  ip.count <= 45, !ip.isEmpty else {
                DispatchQueue.main.async { self?.ipFetchedAt = .distantPast }   // 失败下次再试
                return
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.info.publicIP = ip
                self.onChange(self.info)
            }
        }.resume()
    }
}

// MARK: - 磁盘健康

/// NVMe 硬盘的 SMART 状态（系统信息里的“已验证 / 失败”）。打开磁盘面板时在后台读取。
struct DriveHealth: Identifiable, Equatable {
    let id: String          // bsd 名称，如 disk0
    let model: String
    let size: String
    let healthy: Bool?      // nil：读不到
    let status: String

    static func read() -> [DriveHealth] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPNVMeDataType", "-json"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPNVMeDataType"] as? [[String: Any]] else { return [] }
        return controllers.flatMap { ($0["_items"] as? [[String: Any]]) ?? [] }.map { item in
            let smart = item["smart_status"] as? String
            let healthy: Bool? = smart.map { $0.lowercased() == "verified" }
            return DriveHealth(id: item["bsd_name"] as? String ?? UUID().uuidString,
                               model: item["device_model"] as? String ?? item["_name"] as? String ?? "硬盘",
                               size: item["size"] as? String ?? "",
                               healthy: healthy,
                               status: healthy == nil ? "未知" : healthy! ? "正常" : "异常")
        }
    }
}

// MARK: - 笔记本电池


/// 内置电池：电量、是否充电、健康度（当前满电容量 / 设计容量）、循环次数。台式机没有电池时为 nil。
struct BatteryInfo: Equatable {
    let level: Int
    let charging: Bool
    let health: Int?
    let cycles: Int?

    static func read() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int, let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            var health: Int?, cycles: Int?
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                func number(_ key: String) -> Int? {
                    (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
                }
                if let raw = number("AppleRawMaxCapacity") ?? number("NominalChargeCapacity"), let design = number("DesignCapacity"), design > 0 {
                    health = min(100, raw * 100 / design)
                }
                cycles = number("CycleCount")
                IOObjectRelease(service)
            }
            return BatteryInfo(level: current * 100 / max, charging: info[kIOPSIsChargingKey] as? Bool ?? false, health: health, cycles: cycles)
        }
        return nil
    }
}

// MARK: - 关于

/// 检查更新：查 GitHub 上最新的 Release，和当前版本比较。有新版本时交给 Updater 弹窗、下载并安装。
enum UpdateChecker {
    struct Release: Equatable {
        let version: String
        let url: URL          // Release 网页
        var notes = ""        // 更新说明（Markdown）
        var download: URL?    // islet.zip
        var digest: String?   // islet.zip 的 SHA-256（十六进制）
        var size: Int64?      // islet.zip 的字节数
        var date: Date?       // 发布时间
    }
    enum State: Equatable { case idle, checking, latest, available(Release), failed }

    /// 自动检查（每天最多一次，有新版本时弹出更新窗口，同一版本只弹一次，选过“跳过这个版本”的不再弹）。
    static var autoCheck: Bool { UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true }
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// 版本号按数字逐段比较：1.10.0 > 1.9.2。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }, b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 本地测试更新流程：`defaults write local.codex.islet updateFeedURL http://localhost:8765/release.json`
    /// 指向一个和 GitHub 接口同格式的 JSON（见 test-update.sh），删掉这个键就恢复查 GitHub。
    static var feedURL: URL {
        UserDefaults.standard.string(forKey: "updateFeedURL").flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/Buerxzhang/islet/releases/latest")!
    }

    /// 查询最新版本：成功时回调最新的 Release（可能不比当前新），失败时回调 nil。
    static func fetchLatest(_ completion: @escaping (Release?) -> Void) {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 8
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            var release: Release?
            if (response as? HTTPURLResponse)?.statusCode == 200,
               let object = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
               let tag = object["tag_name"] as? String, let page = (object["html_url"] as? String).flatMap(URL.init(string:)) {
                let zip = (object["assets"] as? [[String: Any]])?.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
                release = Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, url: page,
                                  notes: object["body"] as? String ?? "",
                                  download: (zip?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                                  digest: (zip?["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil },
                                  size: (zip?["size"] as? NSNumber)?.int64Value,
                                  date: (object["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
            }
            DispatchQueue.main.async { completion(release) }
        }.resume()
    }

    /// 自动检查发现新版本时调用（弹出更新窗口）。
    static var onFound: ((Release) -> Void)?

    /// 手动检查（关于页的按钮）。
    static func check(_ completion: @escaping (State) -> Void) {
        completion(.checking)
        fetchLatest { release in
            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
            guard let release else { completion(.failed); return }
            completion(isNewer(release.version, than: currentVersion) ? .available(release) : .latest)
        }
    }

    /// 自动检查：启动后和之后每隔几小时调用；距上次检查不到一天就跳过。新版本只通知一次。
    static func checkInBackground() {
        guard autoCheck else { return }
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        fetchLatest { release in
            guard let release else { return }   // 失败不记时间，下次再试
            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
            guard isNewer(release.version, than: currentVersion),
                  UserDefaults.standard.string(forKey: "skippedUpdateVersion") != release.version else { return }
            onFound?(release)
        }
    }
}

enum AppInfo {
    static let name = "islet"
    static let summary = "菜单栏里的灵动岛"
    static let author = "Buerxzhang"
    static let homepage = URL(string: "https://github.com/Buerxzhang/islet")!
    /// 官网（GitHub Pages）：功能介绍和可交互的演示。
    static let website = URL(string: "https://buerxzhang.github.io/islet/")!
    /// 新建问题页（诊断报告先复制到剪贴板，不放进网址）。
    static let issuesURL = URL(string: "https://github.com/Buerxzhang/islet/issues/new")!
    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "—")（\(info?["CFBundleVersion"] as? String ?? "—")）"
    }

    /// GitHub 标星数：打开关于页时查一次（公开接口，不需要登录），失败时不显示数字。
    static func fetchStars(_ completion: @escaping (Int?) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/Buerxzhang/islet")!)
        request.timeoutInterval = 6
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let stars = (response as? HTTPURLResponse)?.statusCode == 200
                ? ((data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["stargazers_count"] as? Int) : nil
            DispatchQueue.main.async { completion(stars) }
        }.resume()
    }
}
