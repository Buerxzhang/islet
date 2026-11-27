import AppKit
import Combine
import CoreAudio
import SwiftUI

/// 正在发声的程序（不是音乐播放器时，菜单栏和面板显示它）。
struct SoundSource: Equatable {
    var pid: pid_t
    var bundle: String?      // 能打开的应用；转译游戏等可能没有
    var name: String
    var icon: NSImage?

    static func == (a: SoundSource, b: SoundSource) -> Bool { a.pid == b.pid && a.name == b.name && (a.icon == nil) == (b.icon == nil) }

    /// 当前在输出声音的程序（CoreAudio 进程列表），排除本程序。
    static func current() -> [SoundSource] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        let me = getpid()
        return ids.compactMap { id -> SoundSource? in
            var running: UInt32 = 0
            guard property(id, kAudioProcessPropertyIsRunningOutput, &running), running != 0 else { return nil }
            var pid: pid_t = 0
            guard property(id, kAudioProcessPropertyPID, &pid), pid > 0, pid != me else { return nil }
            let audioBundle = stringProperty(id, kAudioProcessPropertyBundleID)
            return resolve(pid: pid, audioBundle: audioBundle)
        }
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var ref: Unmanaged<CFString>?
        let status = withUnsafeMutableBytes(of: &ref) { buffer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer.baseAddress!)
        }
        return status == noErr ? (ref?.takeRetainedValue() as String? ?? "") : ""
    }

    private static func property<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutableBytes(of: &value) { buffer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer.baseAddress!) == noErr
        }
    }

    /// 进程 → 用户认得的程序：本身是应用；或沿父进程找到应用（浏览器、剪辑软件的辅助进程）；
    /// 都不是（转译游戏）就用它的窗口标题，图标取能找到的启动器应用。
    private static func resolve(pid: pid_t, audioBundle: String) -> SoundSource? {
        // Safari 等的声音由系统的 XPC 服务（WebKit.GPU）发出：找“负责”它的应用。
        // 只对系统服务这样做：转译游戏的负责应用是 CrossOver，换过去就丢了游戏名
        var current = audioBundle.hasPrefix("com.apple.") ? responsiblePID(pid) ?? pid : pid
        for _ in 0..<6 {
            let parent = parentPID(current)
            // 普通应用；或由系统直接启动的菜单栏应用（辅助进程由主程序启动，会继续往上找到主程序）
            if let app = NSRunningApplication(processIdentifier: current), let id = app.bundleIdentifier,
               app.activationPolicy == .regular || app.activationPolicy == .accessory && parent <= 1 {
                return SoundSource(pid: current, bundle: id, name: app.localizedName ?? id, icon: app.icon)
            }
            if parent <= 1 { break }
            current = parent
        }
        // 系统声音（通知音等）不当作“其他程序”
        if audioBundle.hasPrefix("com.apple.") { return nil }
        let title = windowTitle(pid: pid)
        // bundle 编号往上截，找能打开的应用（如 com.codeweavers.CrossOver.wineloader → CrossOver）
        var launcher: String?
        var parts = audioBundle.split(separator: ".").map(String.init)
        while parts.count >= 2, launcher == nil {
            let id = parts.joined(separator: ".")
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil { launcher = id }
            parts.removeLast()
        }
        // Windows 程序（wine 转译）：从 exe 里取图标和产品名
        let argv0 = launchName(pid)
        let exe = argv0.flatMap(macPath(windowsPath:)).map { WindowsExecutable.info(path: $0) }
        let icon = exe?.icon ?? launcher.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.map { NSWorkspace.shared.icon(forFile: $0.path) }
        let fallback = launcher.flatMap { id in NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        guard let name = title ?? exe?.name ?? argv0.flatMap(displayName(argv0:)) ?? fallback else { return nil }
        return SoundSource(pid: pid, bundle: launcher, name: name, icon: icon)
    }

    /// 负责这个进程的应用（XPC 服务 → 拉起它的应用）；查不到返回 nil。
    private static func responsiblePID(_ pid: pid_t) -> pid_t? {
        typealias Fn = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        let owner = unsafeBitCast(symbol, to: Fn.self)(pid)
        return owner > 1 && owner != pid ? owner : nil
    }

    /// 进程的启动名：转译程序常把 Windows 路径写在这里（Z:\\...\\YuanShen.exe → YuanShen）。
    private static func launchName(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // 结构：argc（4 字节）、可执行文件路径、若干 \0、argv[0]……
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        guard index > start else { return nil }
        return String(bytes: buffer[start..<index], encoding: .utf8)
    }

    /// 启动名 → 显示名：取文件名、去掉 .exe；wine 自身不算。
    private static func displayName(argv0: String) -> String? {
        var name = argv0.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? argv0
        if name.lowercased().hasSuffix(".exe") { name = String(name.dropLast(4)) }
        return ["wine", "wine64", "wineloader", "wine64-preloader"].contains(name.lowercased()) || name.isEmpty ? nil : name
    }

    /// wine 的 Windows 路径转成 macOS 路径（Z: 盘是根目录）；本来就是 macOS 路径的 .exe 直接用。
    private static func macPath(windowsPath path: String) -> String? {
        guard path.lowercased().hasSuffix(".exe") else { return nil }
        if path.hasPrefix("/") { return path }
        guard path.uppercased().hasPrefix("Z:\\") else { return nil }
        return "/" + path.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
    }

    private static func parentPID(_ pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    private static func windowTitle(pid: pid_t) -> String? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
            && !(($0[kCGWindowName as String] as? String) ?? "").isEmpty }?[kCGWindowName as String] as? String
    }

    /// 切到这个程序：有窗口的进程直接激活，否则打开启动器应用。
    func activate() {
        if let app = NSRunningApplication(processIdentifier: pid), app.activate() { return }
        if let bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// 菜单栏用的圆形图标位图；没有图标时画一个通用的“声音”标志。
    var cgIcon: CGImage? {
        let symbol = NSImage(systemSymbolName: "speaker.wave.2.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white, NSColor(white: 0.35, alpha: 1)])))
        let image = icon ?? symbol
        guard let image else { return nil }
        return SpectrumController.rasterizedIcon(image, inset: icon == nil ? 0 : 0.12)
    }
}
/// Windows 程序（.exe）里的图标和产品名：转译游戏没有 macOS 图标，从 exe 的资源里取。
/// 只读文件头和资源段，不会把整个（可能几百 MB 的）exe 读进内存。
enum WindowsExecutable {
    private static var cache: [String: (name: String?, icon: NSImage?)] = [:]

    static func info(path: String) -> (name: String?, icon: NSImage?) {
        if let cached = cache[path] { return cached }
        let result = (try? read(path)) ?? (nil, nil)
        cache[path] = result
        return result
    }

    private struct Section { var rva: UInt32, size: UInt32, offset: UInt32 }

    private static func read(_ path: String) throws -> (String?, NSImage?) {
        guard let file = FileHandle(forReadingAtPath: path) else { return (nil, nil) }
        defer { try? file.close() }
        func bytes(_ offset: UInt64, _ count: Int) -> Data? {
            guard count > 0, count < 64 << 20 else { return nil }
            try? file.seek(toOffset: offset)
            let data = try? file.read(upToCount: count)
            return data?.count == count ? data : nil
        }
        guard let dos = bytes(0, 64), dos.u16(0) == 0x5A4D else { return (nil, nil) }
        let pe = UInt64(dos.u32(0x3C))
        guard let header = bytes(pe, 24), header.u32(0) == 0x4550 else { return (nil, nil) }
        let sectionCount = Int(header.u16(6)), optionalSize = Int(header.u16(20))
        guard let optional = bytes(pe + 24, optionalSize) else { return (nil, nil) }
        let directories = optional.u16(0) == 0x20B ? 112 : 96   // PE32+ / PE32
        guard optionalSize >= directories + 24 else { return (nil, nil) }
        let resourceRVA = optional.u32(directories + 16), resourceSize = optional.u32(directories + 20)
        guard resourceRVA > 0, let table = bytes(pe + 24 + UInt64(optionalSize), sectionCount * 40) else { return (nil, nil) }
        let sections = (0..<sectionCount).map { i in
            Section(rva: table.u32(i * 40 + 12), size: max(table.u32(i * 40 + 8), table.u32(i * 40 + 16)), offset: table.u32(i * 40 + 20))
        }
        guard let section = sections.first(where: { resourceRVA >= $0.rva && UInt64(resourceRVA) < UInt64($0.rva) + UInt64($0.size) }) else { return (nil, nil) }
        let base = UInt64(section.offset) + UInt64(resourceRVA - section.rva)
        guard let res = bytes(base, Int(resourceSize)) else { return (nil, nil) }

        /// 资源目录的子项：(编号, 偏移, 是否子目录)
        func entries(_ offset: Int) -> [(id: UInt32, offset: Int, isDir: Bool)] {
            guard offset >= 0, offset + 16 <= res.count else { return [] }
            let count = Int(res.u16(offset + 12)) + Int(res.u16(offset + 14))
            return (0..<count).compactMap { i in
                let at = offset + 16 + i * 8
                guard at + 8 <= res.count else { return nil }
                let target = res.u32(at + 4)
                return (res.u32(at), Int(target & 0x7FFF_FFFF), target & 0x8000_0000 != 0)
            }
        }
        /// 某类资源下指定编号（nil 取第一个）的数据。
        func resource(type: UInt32, id: UInt32?) -> Data? {
            guard let typeDir = entries(0).first(where: { $0.id == type && $0.isDir }) else { return nil }
            let names = entries(typeDir.offset)
            guard var node = (id.map { want in names.first { $0.id == want } } ?? names.first) else { return nil }
            // 正常的资源树只有三层；损坏的文件里目录可能互相指向，限定层数免得死循环
            for _ in 0..<8 where node.isDir { guard let next = entries(node.offset).first else { return nil }; node = next }
            guard !node.isDir else { return nil }
            guard node.offset + 8 <= res.count else { return nil }
            let rva = res.u32(node.offset), size = Int(res.u32(node.offset + 4))
            let start = Int(rva) - Int(resourceRVA)
            guard size >= 0, start >= 0, size <= res.count - start else { return nil }
            return res.subdata(in: start..<start + size)
        }

        // 图标：RT_GROUP_ICON(14) 里挑最大的一张，按 RT_ICON(3) 编号取出，拼成 .ico
        var icon: NSImage?
        if let group = resource(type: 14, id: nil), group.count >= 6 {
            let count = Int(group.u16(4))
            func side(_ at: Int) -> Int { group[at] == 0 ? 256 : Int(group[at]) }
            let offsets: [Int] = (0..<count).map { 6 + $0 * 14 }.filter { $0 + 14 <= group.count }
            let best = offsets.max { side($0) < side($1) }
            if let best, let image = resource(type: 3, id: UInt32(group.u16(best + 12))) {
                var ico = Data([0, 0, 1, 0, 1, 0])
                ico.append(group.subdata(in: best..<best + 12))
                ico.append(contentsOf: withUnsafeBytes(of: UInt32(22).littleEndian, Array.init))
                ico.append(image)
                icon = NSImage(data: ico)
            }
        }
        // 名称：版本信息（RT_VERSION 16）里的 ProductName，没有就用 FileDescription
        var name: String?
        if let version = resource(type: 16, id: nil) {
            name = versionString(version, key: "ProductName") ?? versionString(version, key: "FileDescription")
        }
        return (name, icon)
    }

    /// 在版本信息（UTF-16）里找 key，读出紧随其后的字符串值。
    private static func versionString(_ data: Data, key: String) -> String? {
        let pattern = Data((key + "\0").utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        guard let range = data.range(of: pattern) else { return nil }
        var index = range.upperBound
        while index % 4 != 0 { index += 1 }   // 值按 4 字节对齐
        var units: [UInt16] = []
        while index + 1 < data.count {
            let unit = data.u16(index)
            if unit == 0 { break }
            units.append(unit)
            index += 2
        }
        let value = String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
}
