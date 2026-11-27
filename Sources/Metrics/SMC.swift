import Foundation
import IOKit

/// SMC（系统管理控制器）读写。连接只打开一次；非线程安全，需在同一线程 / 队列上使用。
/// 读取任何用户都可以；写入（风扇控制）只有 root 辅助程序能成功。
final class SMC {
    static let shared = SMC()
    private let connection = smc_open()
    private var keyInfo: [String: (length: UInt32, type: String)] = [:]  // 键的长度和类型不会变，缓存后每次只需一次调用
    private var bytes = [UInt8](repeating: 0, count: 32)

    /// 读取数值型键，支持 flt / ui8 / ui16 / ui32 / fpe2 / sp78。键不存在时返回 nil。
    func value(_ key: String) -> Double? {
        guard connection != 0 else { return nil }
        let type: String
        if let info = keyInfo[key] {
            guard key.withCString({ smc_read_known(connection, $0, info.length, &bytes) }) == 0 else { return nil }
            type = info.type
        } else {
            var rawType: UInt32 = 0
            let length = key.withCString { smc_read(connection, $0, &bytes, &rawType) }
            guard length > 0 else { return nil }
            type = Self.code(rawType)
            keyInfo[key] = (UInt32(length), type)
        }
        switch type {
        case "flt ": return Double(Float(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
        case "ui8 ", "flag", "hex_": return Double(bytes[0])  // 新机型上开关类键可能是 flag / hex_
        case "si8 ": return Double(Int8(bitPattern: bytes[0]))
        case "ui16": return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32": return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "fpe2": return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "sp78": return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default: return nil
        }
    }

    /// 枚举全部键名（启动后只在需要时调用一次，约 1400 个键）。
    func allKeys() -> [String] {
        guard connection != 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: 32)
        var type: UInt32 = 0
        guard smc_read(connection, "#KEY", &bytes, &type) == 4 else { return [] }
        let count = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        return (0..<min(count, 5000)).compactMap { index in
            let key = smc_key_at(connection, index)
            return key == 0 ? nil : Self.code(key)
        }
    }

    /// 写入 ui8 键（如风扇模式 F0Md）。
    @discardableResult
    func writeUInt8(_ key: String, _ value: UInt8) -> Bool {
        write(key, [value])
    }

    /// 写入 flt 键（如目标转速 F0Tg）。Apple 芯片上 flt 为小端。
    @discardableResult
    func writeFloat(_ key: String, _ value: Float) -> Bool {
        let bits = value.bitPattern
        return write(key, [0, 8, 16, 24].map { UInt8((bits >> $0) & 0xff) })
    }

    /// 写入风扇目标转速：按 SMC 键实际类型编码（Intel 常见 fpe2，Apple Silicon 为 flt）。
    @discardableResult
    func writeRPM(_ key: String, _ rpm: Double) -> Bool {
        let type: String?
        if let cached = keyInfo[key]?.type {
            type = cached
        } else if let raw = raw(key) {
            keyInfo[key] = (UInt32(raw.bytes.count), raw.type)
            type = raw.type
        } else {
            type = nil
        }
        if type == "fpe2" {
            let encoded = UInt16(clamping: Int((rpm * 4).rounded()))
            return write(key, [UInt8(encoded >> 8), UInt8(encoded & 0xff)])
        }
        return writeFloat(key, Float(rpm))
    }

    /// 最近一次写入失败：键名和错误码，给日志用。
    private(set) var lastWriteFailure: (key: String, code: Int32)?

    private func write(_ key: String, _ data: [UInt8]) -> Bool {
        guard connection != 0 else {
            lastWriteFailure = (key, -1)
            return false
        }
        let code = key.withCString { smc_write(connection, $0, UInt32(data.count), data) }
        if code != 0 { lastWriteFailure = (key, code) }
        return code == 0
    }

    /// 写入错误码的可读说明。
    static func describe(_ code: Int32) -> String {
        let hex = String(format: "0x%X", UInt32(bitPattern: code))
        switch UInt32(bitPattern: code) {
        case 0xFFFF_FFFF: return "SMC 未连接"
        case 0x84: return "\(hex) 键不存在"
        case 0xE000_02C1: return "\(hex) 没有权限"
        case 0xE000_02E2: return "\(hex) 不允许"
        case 0xE000_02C2: return "\(hex) 参数无效"
        default: return hex
        }
    }

    /// 键是否存在（类型不认识也算存在）。
    func exists(_ key: String) -> Bool { raw(key) != nil }

    /// 原始读取：类型码和字节，给诊断报告用（新机型键类型可能变了，先看原样）。
    func raw(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard connection != 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 32)
        var rawType: UInt32 = 0
        let length = key.withCString { smc_read(connection, $0, &buffer, &rawType) }
        guard length >= 0 else { return nil }
        return (Self.code(rawType), Array(buffer.prefix(min(Int(length), 32))))
    }

    private static func code(_ type: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((type >> $0) & 0xff) }, encoding: .ascii) ?? ""
    }
}

/// 整机功耗（瓦），来自 SMC 的 PSTR（系统总功耗）。
enum PowerStats {
    static func systemWatts() -> Double? {
        guard let watts = SMC.shared.value("PSTR"), watts.isFinite, watts >= 0 else { return nil }
        return watts
    }
}

/// 风扇转速。没有风扇的机型（如 MacBook Air）返回空数组。
struct Fan {
    let current: Double
    let minimum: Double
    let maximum: Double

    /// 风扇数量与最低 / 最高转速不会变，只读一次；之后每次只读当前转速。
    private static let limits: [(minimum: Double, maximum: Double)] = {
        let count = Int(SMC.shared.value("FNum") ?? 0)
        return (0..<min(count, 4)).map { index in
            (SMC.shared.value("F\(index)Mn") ?? 0, SMC.shared.value("F\(index)Mx") ?? 0)
        }
    }()

    static func readAll() -> [Fan] {
        limits.enumerated().compactMap { index, limit in
            guard let current = SMC.shared.value("F\(index)Ac") else { return nil }
            return Fan(current: max(current, 0), minimum: limit.minimum, maximum: limit.maximum)
        }
    }
}

/// 温度传感器，按 SMC 键名前缀归类（社区整理的对应关系，Apple 芯片各代基本一致）。
final class Temperatures {
    struct Group {
        let name: String
        let average: Double
        let maximum: Double
    }

    /// 全部分组名（规则编辑器的下拉选项）。
    static let groupNames = groups.map(\.name)

    private static let groups: [(name: String, prefix: String)] = [
        ("CPU 性能核", "Tp"), ("CPU 能效核", "Te"), ("GPU", "Tg"), ("芯片其他部分", "Ts"),
        ("内存", "Tm"), ("固态硬盘", "TH"), ("无线网卡", "TW"),
    ]

    /// 分组名 → 该组的键；首次使用时扫描一次 SMC。
    private lazy var sensors: [(name: String, keys: [String])] = {
        let all = SMC.shared.allKeys()
        return Self.groups.compactMap { group in
            let keys = all.filter { $0.hasPrefix(group.prefix) && Self.sane(SMC.shared.value($0)) != nil }
            return keys.isEmpty ? nil : (group.name, keys)
        }
    }()

    /// 读取各组的平均和最高温度（°C），按平均温度从高到低排序。only 为 nil 时读全部分组。
    func read(only names: Set<String>? = nil) -> [Group] {
        Self.summarize(names.map { names in sensors.filter { names.contains($0.name) } } ?? sensors)
    }

    /// 传感器总数（面板“N 个传感器”）。
    var sensorCount: Int { sensors.reduce(0) { $0 + $1.keys.count } }

    /// 逐个传感器读数，按分组列出（面板展开时用，读全部键约 12 毫秒）。
    func details() -> [(name: String, readings: [(key: String, celsius: Double)])] {
        sensors.map { sensor in
            (sensor.name, sensor.keys.compactMap { key in Self.sane(SMC.shared.value(key)).map { (key, $0) } })
        }
    }

    /// 风扇控制用的温度：CPU 性能核与 GPU 中较高者（按平均或最热口径；没有这两组时用全部分组）。
    func controlCelsius(basis: TemperatureBasis = .average) -> Double? {
        let wanted = Set(FanControl.controlGroups)
        let groups = sensors.contains { wanted.contains($0.name) } ? read(only: wanted) : read()
        return groups.map { basis == .peak ? $0.maximum : $0.average }.max()
    }

    /// 只读菜单栏需要的那一组（CPU 性能核，约 40 个键），开销约为全部读取的四分之一。
    func headline() -> Double? {
        let preferred = ["CPU 性能核", "CPU 能效核"]
        let sensor = preferred.lazy.compactMap { name in self.sensors.first { $0.name == name } }.first
        guard let sensor else { return Self.headline(read()) }
        return Self.summarize([sensor]).first?.average
    }

    private static func summarize(_ sensors: [(name: String, keys: [String])]) -> [Group] {
        sensors.compactMap { sensor in
            let values = sensor.keys.compactMap { Self.sane(SMC.shared.value($0)) }
            guard let maximum = values.max() else { return nil }
            return Group(name: sensor.name, average: values.reduce(0, +) / Double(values.count), maximum: maximum)
        }
        .sorted { $0.average > $1.average }
    }

    /// 菜单栏显示的温度：CPU 性能核平均值；没有这一组时用能效核，再没有则取最热的一组。
    static func headline(_ groups: [Group]) -> Double? {
        (groups.first { $0.name == "CPU 性能核" } ?? groups.first { $0.name == "CPU 能效核" } ?? groups.first)?.average
    }

    /// 过滤掉未接入或异常的读数。
    private static func sane(_ value: Double?) -> Double? {
        guard let value, value > 5, value < 130 else { return nil }
        return value
    }
}
