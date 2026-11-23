import CoreGraphics
import Darwin
import Foundation

// islet 的显示器辅助程序（打包为 islet.app/Contents/MacOS/islet-display，由设置页调用）。
// 单独成进程：写系统配置、重连屏幕都在这里做，出问题不会拖垮 islet 本身。
//
//   status <屏幕 ID>            输出 JSON：是否外接、是否已有覆盖配置、是否 islet 添加的
//   install <屏幕 ID>           按这块屏的原生分辨率生成 HiDPI 档位，写入系统覆盖配置（需要管理员密码）
//   remove <屏幕 ID>            删除 islet 添加的覆盖配置（需要管理员密码；别的工具写的不碰）
//   reconnect <屏幕 ID>         用软件断开再接上这块屏，让新档位生效（需要另一块屏在用）

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success else { fail("无法读取在线显示器") }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { fail("无法读取在线显示器") }
    return Array(displays.prefix(Int(count)))
}

func display(_ text: String?) -> CGDirectDisplayID {
    guard let text, let id = UInt32(text), onlineDisplays().contains(id) else { fail("找不到这块显示器，请刷新后重试") }
    return id
}

func allModes(_ display: CGDirectDisplayID) -> [CGDisplayMode] {
    let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    return CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []
}

// MARK: 覆盖配置

let overridesRoot = "/Library/Displays/Contents/Resources/Overrides"
/// islet 生成的配置里多写一个键作为记号：移除时只删带记号的，别的工具写的不碰。
let markerKey = "isletGenerated"

func overridePath(_ display: CGDirectDisplayID) -> String {
    String(format: "%@/DisplayVendorID-%x/DisplayProductID-%x", overridesRoot, CGDisplayVendorNumber(display), CGDisplayModelNumber(display))
}

/// 这块屏的原生像素尺寸：不带 HiDPI 的原生模式里最大的那个。
func nativeSize(_ display: CGDirectDisplayID) -> (width: Int, height: Int)? {
    let modes = allModes(display).filter { $0.pixelWidth == $0.width }
    let native = modes.filter { $0.ioFlags & UInt32(0x02000000) != 0 }   // kDisplayModeNativeFlag
    let pick = (native.isEmpty ? modes : native).max { $0.width * $0.height < $1.width * $1.height }
    return pick.map { ($0.width, $0.height) }
}

/// HiDPI 档位：UI 放大 200%、153.8%、142.9%、133.3%（相对原生），绘制尺寸最多是屏幕的 1.5 倍。
/// 尽量取与原生严格等比例的尺寸（宽高都是偶数），不会有黑边或变形；凑不出来时按宽度取最接近的偶数。
func scaledSizes(native: (width: Int, height: Int)) -> [(width: Int, height: Int)] {
    func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
    let g = max(gcd(native.width, native.height), 1)
    let unitW = native.width / g, unitH = native.height / g
    let step = unitW % 2 == 0 && unitH % 2 == 0 ? 1 : 2   // 单位尺寸有奇数时，倍数取偶数，宽高才都是偶数
    var seen = Set<String>()
    // 不加 125%、114.3%、111.1%：绘制尺寸超过屏幕 1.5 倍，切过去显示器会黑屏重启，设置里也不列
    let sizes: [(width: Int, height: Int)] = [2.0, 20.0 / 13.0, 10.0 / 7.0, 4.0 / 3.0].compactMap { factor in
        let target = Double(native.width) / factor
        let k = Int((target / Double(unitW * step)).rounded()) * step
        var width = unitW * k, height = unitH * k
        if k <= 0 || abs(Double(width) / target - 1) > 0.02 {
            width = Int((target / 2).rounded()) * 2
            height = Int((Double(width) * Double(native.height) / Double(native.width) / 2).rounded()) * 2
        }
        // 渲染尺寸（逻辑尺寸的 2 倍）太大会拖慢显卡：超过 8K 的不加
        guard width * 2 <= 7680, height * 2 <= 4320, seen.insert("\(width)x\(height)").inserted else { return nil }
        return (width, height)
    }
    return sizes.sorted { $0.width < $1.width }
}

/// 每个档位三条：2 倍渲染尺寸（带缩放标记）、2 倍渲染尺寸、逻辑尺寸。与常见的 HiDPI 覆盖配置写法一致。
func overrideData(vendor: UInt32, product: UInt32, sizes: [(width: Int, height: Int)], marker: Bool) throws -> Data {
    func entry(_ values: [Int]) -> Data {
        Data(values.flatMap { withUnsafeBytes(of: UInt32($0).bigEndian) { Array($0) } })
    }
    var plist: [String: Any] = [
        "DisplayVendorID": vendor,
        "DisplayProductID": product,
        "scale-resolutions": sizes.flatMap { size in
            [entry([size.width * 2, size.height * 2, 9, 0x200000]), entry([size.width * 2, size.height * 2]), entry([size.width, size.height])]
        },
    ]
    if marker { plist[markerKey] = true }
    return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
}

/// 早期版本只为 0x61a9 / 0x34b1 这一块屏写过 2580×1080 的配置（没有记号）：内容完全一致时也算 islet 添加的。
func isLegacyOverride(_ data: Data, _ display: CGDirectDisplayID) -> Bool {
    let vendor = CGDisplayVendorNumber(display), product = CGDisplayModelNumber(display)
    guard vendor == 0x61a9, product == 0x34b1,
          let legacy = try? overrideData(vendor: vendor, product: product, sizes: [(2580, 1080)], marker: false) else { return false }
    return data == legacy
}

func isOwned(_ display: CGDirectDisplayID) -> Bool {
    let path = overridePath(display)
    guard let data = FileManager.default.contents(atPath: path) else { return false }
    if isLegacyOverride(data, display) { return true }
    let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    return plist?[markerKey] as? Bool == true
}

/// 已有配置文件里的 HiDPI 档位（逻辑尺寸）：每档都有“逻辑尺寸”和“2 倍渲染尺寸”两条，取前者。
func sizesInOverride(_ display: CGDirectDisplayID) -> [(width: Int, height: Int)] {
    guard let data = FileManager.default.contents(atPath: overridePath(display)),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let entries = plist["scale-resolutions"] as? [Data] else { return [] }
    let pairs = entries.filter { $0.count == 8 }.map { entry -> (width: Int, height: Int) in
        let values = stride(from: 0, to: 8, by: 4).map { offset in
            entry[entry.startIndex + offset ..< entry.startIndex + offset + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        return (values[0], values[1])
    }
    return pairs.filter { size in pairs.contains { $0.width == size.width * 2 && $0.height == size.height * 2 } }
}

func runAsAdmin(_ shell: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", "on run argv", "-e", "do shell script (item 1 of argv) with administrator privileges",
                         "-e", "end run", "--", shell]
    do { try process.run() } catch { fail("无法请求管理员授权：\(error.localizedDescription)") }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("已取消，或系统没有完成操作") }
}

func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// MARK: 显示配置

func configure(_ display: CGDirectDisplayID, mode: CGDisplayMode, option: CGConfigureOption) -> Bool {
    var transaction: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&transaction) == .success, let transaction else { return false }
    guard CGConfigureDisplayWithDisplayMode(transaction, display, mode, nil) == .success else {
        CGCancelDisplayConfiguration(transaction)
        return false
    }
    return CGCompleteDisplayConfiguration(transaction, option) == .success
}

switch arguments.first {
case "status":
    let id = display(arguments.dropFirst().first)
    let path = overridePath(id)
    let payload: [String: Any] = [
        "external": CGDisplayIsBuiltin(id) == 0,
        "installed": FileManager.default.fileExists(atPath: path),
        "owned": isOwned(id),
        // 已有 islet 的配置：列出文件里实际的档位；还没有：列出将要添加的档位
        "sizes": (isOwned(id) ? sizesInOverride(id) : nativeSize(id).map(scaledSizes) ?? []).map { "\($0.width)×\($0.height)" },
    ]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: payload))

case "install":
    let id = display(arguments.dropFirst().first)
    guard CGDisplayIsBuiltin(id) == 0 else { fail("内建屏幕已经有系统提供的缩放档位") }
    let path = overridePath(id)
    guard let native = nativeSize(id) else { fail("读不到这块屏的原生分辨率") }
    // 系统是否已有实用的 HiDPI 档位由设置页判断（DisplayManager.Display.hasHiDPIChoices，会按屏幕物理尺寸排除字太大的档位），
    // 只有判断为没有时才会显示开关，这里不再重复判断，免得两边口径不一（如 24 寸 1080P 屏自带的 1024×576 HiDPI）。
    // islet 自己以前写的配置直接换成新档位；别的工具写的不动
    let replacing = FileManager.default.fileExists(atPath: path)
    guard !replacing || isOwned(id) else { fail("这块屏已有其他工具写入的配置，没有改动") }
    let sizes = scaledSizes(native: native)
    guard !sizes.isEmpty else { fail("这块屏的分辨率不适合添加 HiDPI 档位") }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("islet-display-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("override.plist")
        try overrideData(vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id), sizes: sizes, marker: true).write(to: file)
        let target = quoted(path)
        let folder = quoted((path as NSString).deletingLastPathComponent)
        runAsAdmin("/bin/mkdir -p \(folder) && test ! -L \(target) && \(replacing ? "/bin/rm -f \(target) && " : "")/usr/bin/install -o root -g wheel -m 644 \(quoted(file.path)) \(target)")
    } catch { fail("生成配置失败：\(error.localizedDescription)") }
    print("已添加 \(sizes.map { "\($0.width)×\($0.height)" }.joined(separator: "、"))")

case "remove":
    let id = display(arguments.dropFirst().first)
    let path = overridePath(id)
    guard FileManager.default.fileExists(atPath: path) else { fail("这块屏没有覆盖配置") }
    guard isOwned(id) else { fail("这份配置不是 islet 添加的，没有改动") }
    runAsAdmin("test ! -L \(quoted(path)) && /bin/rm \(quoted(path))")
    print("已移除 islet 添加的档位")

case "reconnect":
    let id = display(arguments.dropFirst().first)
    let displays = onlineDisplays()
    guard CGDisplayIsActive(id) != 0, CGDisplayIsInMirrorSet(id) == 0 else { fail("这块屏没在单独使用，请手动重新插拔") }
    // 正在用 HiDPI 档位时先正常切回原生分辨率，再断开：否则档位在重连时凭空消失，分辨率和缩放倍数一下子跳变，
    // 再按旧尺寸恢复排列，窗口拖动会和鼠标对不上。切换后系统会自己重排，下面记录的就是新位置。
    if let current = CGDisplayCopyDisplayMode(id), current.pixelWidth > current.width {
        let natives = allModes(id).filter { $0.pixelWidth == $0.width && $0.isUsableForDesktopGUI() }
        let flagged = natives.filter { $0.ioFlags & UInt32(0x02000000) != 0 }   // kDisplayModeNativeFlag
        let candidates = flagged.isEmpty ? natives : flagged
        let largest = candidates.map { $0.width * $0.height }.max() ?? 0
        if let native = candidates.filter({ $0.width * $0.height == largest })
            .min(by: { abs($0.refreshRate - current.refreshRate) < abs($1.refreshRate - current.refreshRate) }),
           configure(id, mode: native, option: .permanently) {
            Thread.sleep(forTimeInterval: 0.8)
        }
    }
    // 只有这一块屏时也能断开再接上（实测会黑一两秒再亮回来）；万一接不回来，下面会提示手动插拔
    guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY),
          let symbol = dlsym(library, "SLSConfigureDisplayEnabled") else { fail("本机不支持用软件重新连接，请手动重新插拔这块屏") }
    typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> Int32
    let configureEnabled = unsafeBitCast(symbol, to: ConfigureEnabled.self)
    let origins = displays.filter { CGDisplayIsActive($0) != 0 }.map { ($0, CGDisplayBounds($0).origin) }
    func setEnabled(_ enabled: Bool) -> Bool {
        var transaction: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&transaction) == .success, let transaction else { return false }
        guard configureEnabled(transaction, id, enabled) == 0 else { CGCancelDisplayConfiguration(transaction); return false }
        return CGCompleteDisplayConfiguration(transaction, .forSession) == .success
    }
    guard setEnabled(false) else { fail("系统拒绝断开这块屏，请手动重新插拔") }
    Thread.sleep(forTimeInterval: 0.7)
    var enabled = false
    for _ in 0..<6 {
        if setEnabled(true) { enabled = true; break }
        Thread.sleep(forTimeInterval: 0.5)
    }
    guard enabled else { fail("没能自动接回这块屏：请手动重新插拔，或在系统设置 → 显示器里检测显示器") }
    for _ in 0..<25 where !(onlineDisplays().contains(id) && CGDisplayIsActive(id) != 0) { Thread.sleep(forTimeInterval: 0.2) }
    guard CGDisplayIsActive(id) != 0 else { fail("已发出重新连接，但这块屏还没恢复：请手动重新插拔") }
    // 断开再接上后排列可能变了：恢复原来的位置
    var layout: CGDisplayConfigRef?
    if CGBeginDisplayConfiguration(&layout) == .success, let layout {
        let restored = origins.allSatisfy { CGConfigureDisplayOrigin(layout, $0.0, Int32($0.1.x), Int32($0.1.y)) == .success }
        if restored { _ = CGCompleteDisplayConfiguration(layout, .forSession) } else { CGCancelDisplayConfiguration(layout) }
    }
    print("已重新连接")

default:
    fail("用法：islet-display status|install|remove|reconnect <屏幕 ID>")
}
