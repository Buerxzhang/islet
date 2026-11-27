import AppKit
import Combine
import IOKit.graphics

/// 显示器：列出每块屏的可用分辨率，切换分辨率、为外接屏添加 HiDPI 档位。
/// 真正改系统设置的操作都交给辅助程序 islet-display（见 Helpers/display-helper.swift）。
final class DisplayManager: ObservableObject {
    static let shared = DisplayManager()

    struct Mode: Identifiable, Equatable {
        let id: Int32
        let width: Int
        let height: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let hz: Double
        let native: Bool
        let preferred: Bool
        let stretched: Bool

        init(_ mode: CGDisplayMode) {
            id = mode.ioDisplayModeID
            width = mode.width
            height = mode.height
            pixelWidth = mode.pixelWidth
            pixelHeight = mode.pixelHeight
            hz = mode.refreshRate
            native = mode.ioFlags & UInt32(kDisplayModeNativeFlag) != 0
            preferred = mode.ioFlags & UInt32(kDisplayModeDefaultFlag) != 0
            stretched = mode.ioFlags & UInt32(kDisplayModeStretchedFlag) != 0
        }

        static let placeholder = Mode(id: 0, width: 0, height: 0, pixelWidth: 0, pixelHeight: 0, hz: 0, native: false, preferred: false, stretched: false)

        init(id: Int32, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, hz: Double, native: Bool, preferred: Bool, stretched: Bool) {
            self.id = id
            self.width = width
            self.height = height
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.hz = hz
            self.native = native
            self.preferred = preferred
            self.stretched = stretched
        }

        var hiDPI: Bool { pixelWidth >= width * 2 && pixelHeight >= height * 2 }
        var size: String { "\(width)×\(height)" }
        var renderingSize: String { "\(pixelWidth)×\(pixelHeight)" }
        /// 同一尺寸、同一清晰度算一档（不同刷新率合并）。
        var group: String { "\(size):\(hiDPI)" }
        var rate: String { hz > 0 ? String(format: "%g Hz", (hz * 100).rounded() / 100) : "" }
    }

    struct Display: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        let builtIn: Bool
        let current: Mode
        let modes: [Mode]
        let native: Mode?
        let isMain: Bool
        let mirrored: Bool
        let active: Bool
        /// 屏幕在桌面坐标系中的位置与逻辑尺寸，用于绘制排列状态。
        let bounds: CGRect
        /// 屏幕物理宽度（毫米），读不到时为 0。
        let widthMM: Double

        var canSwitch: Bool { active && !mirrored }

        /// 下拉里的档位：与屏幕同宽高比、不拉伸的分辨率，每档取最接近当前刷新率的那个；当前模式总在里面。
        var choices: [Mode] {
            guard let native, native.height > 0 else { return [current] }
            let ratio = Double(native.width) / Double(native.height)
            var best: [String: Mode] = [:]
            for mode in modes where !mode.stretched && mode.height > 0
                && abs(Double(mode.width) / Double(mode.height) / ratio - 1) <= 0.01
                && (mode.native || (mode.hiDPI && mode.pixelWidth >= native.width - 8 && mode.pixelWidth <= native.width * 3 / 2 + 8)) {
                // 只列原生分辨率和清晰的 HiDPI 档位：绘制尺寸不小于屏幕像素的。
                // 普通低分辨率档位、绘制尺寸比屏幕小的 HiDPI 档位（如带鱼屏 1290×540 按 2580×1080 绘制）都要放大显示，发虚，不列。
                // 绘制尺寸超过屏幕 1.5 倍的也不列：切过去显示器要重新建立连接、黑屏重启，接上第二块屏后系统还会直接丢掉这类档位
                if let existing = best[mode.group], abs(existing.hz - current.hz) <= abs(mode.hz - current.hz) { continue }
                best[mode.group] = mode
            }
            // 字比推荐大很多的 HiDPI 档位不列（宽度不到推荐宽度的 70%）：如 34 寸带鱼屏的 1720×720，
            // 东西大到没法用。4K 屏的 1920×1080 离推荐不远，照常列出
            if widthMM > 0 {
                let target = widthMM / 25.4 * 90
                best = best.filter { !$0.value.hiDPI || Double($0.value.width) >= target * 0.7 }
            }
            best[current.group] = current
            // 宽度只差 2% 以内的 HiDPI 档位看起来一样（如 2580×1080 和 2560×1072），只留更宽的；当前在用的总留着
            var result: [Mode] = []
            for mode in best.values.sorted(by: { ($0.width, $0.hiDPI ? 1 : 0) > ($1.width, $1.hiDPI ? 1 : 0) }) {
                if mode.hiDPI, mode.group != current.group, let last = result.last, last.hiDPI,
                   Double(last.width) <= Double(mode.width) * 1.02 { continue }
                result.append(mode)
            }
            // 有实用的 HiDPI 档位（比原生一半大的）时不列原生普通档位：字太小、也不如 HiDPI 清晰，
            // 切过去还会黑屏重连。想用原生就关掉 islet 的 HiDPI（正在用时照常列出）。
            // 但原生的字大小本来就最合适时（如 24 寸 1080P，见 recommended）照常列出：它就是推荐的大小，不能选了别的就回不去
            let practical = result.filter { $0.hiDPI && $0.width > native.width / 2 + 8 }
            let nativeFits = widthMM > 0 && practical.allSatisfy {
                let target = widthMM / 25.4 * 90
                return abs(Double(native.width) - target) <= abs(Double($0.width) - target)
            }
            if !practical.isEmpty, !nativeFits {
                result.removeAll { $0.native && !$0.hiDPI && $0.group != current.group }
            }
            return result
        }

        /// 有没有实用的 HiDPI 档位：比原生一半更大的那些。
        /// 2K、带鱼屏通常只有“原生的一半”这一档 HiDPI（东西大得没法用），这种算没有，可以添加。
        var hasHiDPIChoices: Bool {
            guard let native else { return choices.contains(where: \.hiDPI) }
            return choices.contains { $0.hiDPI && $0.width > native.width / 2 + 8 }
        }

        /// 推荐的大小，规则固定：
        /// 1. 系统给某个 HiDPI 档位标了默认（Mac 内建屏、多数 4K 屏），就用它；
        /// 2. 否则按屏幕物理宽度，选最接近每英寸 90 点的 HiDPI 档位（约等于 24 寸 1080p 屏原生的文字大小，桌面距离下读起来舒服）；
        ///    原生分辨率也参与比较：1080P 这类屏原生就最接近，推荐原生，不为了 HiDPI 把字放大；
        /// 3. 读不到物理尺寸时，取最宽的 HiDPI 档位。
        var recommended: Mode? {
            let hiDPI = choices.filter(\.hiDPI)
            if let preferred = hiDPI.first(where: \.preferred) { return preferred }
            guard widthMM > 0 else { return hiDPI.max { $0.width < $1.width } }
            let target = widthMM / 25.4 * 90
            let candidates = hiDPI + choices.filter { $0.native && !$0.hiDPI }
            return candidates.min { abs(Double($0.width) - target) < abs(Double($1.width) - target) }
        }

        /// 默认展示的核心档位，最多 5 个：原生、推荐、当前必留，其余挑紧挨着推荐的。
        var sizeOptions: [Mode] {
            let all = choices.sorted { ($0.width, $0.hiDPI ? 0 : 1) > ($1.width, $1.hiDPI ? 0 : 1) }
            let limit = 5
            guard all.count > limit else { return all }
            var keep = Set<Int>()
            for mode in [native, recommended, current].compactMap({ $0 }) {
                if let index = all.firstIndex(where: { $0.group == mode.group }) { keep.insert(index) }
            }
            let center = all.firstIndex { $0.group == recommended?.group } ?? all.count / 2
            // 放大不超过 200% 的优先（再小就是把画面拉大显示，发虚），其次离推荐最近，距离相同先取“更多空间”一侧
            let half = (native?.width ?? 0) / 2 - 8
            let key = { (i: Int) in (all[i].width < half ? 1 : 0, abs(i - center), i) }
            let near = all.indices.sorted { key($0) < key($1) }
            for index in near where keep.count < limit { keep.insert(index) }
            return keep.sorted().map { all[$0] }
        }

        /// 档位的文字说明：原生、推荐（系统默认时叫“默认”），其余按比推荐大还是小。
        func label(_ mode: Mode) -> String {
            if mode.group == recommended?.group { return mode.preferred ? "默认" : "推荐" }
            if mode.native && !mode.hiDPI { return "原生" }
            if !mode.hiDPI { return "普通" }
            guard let recommended else { return "" }
            return mode.width > recommended.width ? "更多空间" : "更大文字"
        }

        /// 界面相对原生放大多少，例如 “125%”。
        func scale(_ mode: Mode) -> String {
            guard let native, mode.width > 0 else { return "" }
            return String(format: "%g%%", (Double(native.width) / Double(mode.width) * 1000).rounded() / 10)
        }
    }

    @Published private(set) var displays: [Display] = []
    /// 各块屏的覆盖配置状态（来自辅助程序）。
    @Published private(set) var overrides: [CGDirectDisplayID: OverrideStatus] = [:]
    @Published private(set) var busy = false
    /// 开关 HiDPI 后没能用软件重连、要手动插拔的屏（值为 true = 刚开启，false = 刚关闭）。
    /// 重连前系统里的档位还是旧的：刚关闭的屏还留着那几档 HiDPI，看起来像系统自带的，开关要照常显示为关
    @Published private(set) var awaitingReconnect: [CGDirectDisplayID: Bool] = [:]
    @Published private(set) var message: String?

    struct OverrideStatus: Decodable {
        let external: Bool
        let installed: Bool
        let owned: Bool
        let sizes: [String]
    }

    private var helper: URL? { Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("islet-display") }

    private init() {}

    // MARK: 屏幕增减后恢复分辨率
    // 系统按“当前接着哪几块屏”分别记分辨率：关掉 / 接上另一块屏后，会套用那种组合下记的（往往是原生分辨率）。
    // 这里记住每块屏最近稳定在用的档位，屏幕组合一变就切回去；切回去用 permanently，系统也会把它记进新组合。

    private var remembered: [CGDirectDisplayID: (group: String, hz: Double)] = [:]
    /// 记的档位在当前组合下没有、临时改用推荐档位的屏：这时的档位不是用户选的，不记，换回能用的组合时还恢复原来选的
    private var fallback: [CGDirectDisplayID: String] = [:]
    private var cachedNames: [CGDirectDisplayID: String] = [:]
    private var cachedBounds: [CGDirectDisplayID: CGRect] = [:]
    private var disabledDisplays: [CGDirectDisplayID: Display] = [:]
    private var activeSet: Set<CGDirectDisplayID> = []
    private var pendingCheck: DispatchWorkItem?

    func startRestoring() {
        refresh()
        rememberCurrent()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            // 组合变化时通知会连着来好几次，系统也要过一会儿才套完它记的设置：等安静下来再看
            self?.pendingCheck?.cancel()
            let check = DispatchWorkItem { self?.screensChanged() }
            self?.pendingCheck = check
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: check)
        }
    }

    /// chosen：用户刚在 islet 里选的，临时档位也算数
    private func rememberCurrent(chosen: Bool = false) {
        let active = displays.filter(\.canSwitch)
        activeSet = Set(active.map(\.id))
        for display in active where chosen || fallback[display.id] != display.current.group {
            remembered[display.id] = (display.current.group, display.current.hz)
            fallback[display.id] = nil
        }
    }

    private func screensChanged() {
        refresh()
        guard !busy else { return }   // 正在试用新分辨率：等确认结束再记
        let active = displays.filter(\.canSwitch)
        guard Set(active.map(\.id)) != activeSet else { rememberCurrent(); return }   // 组合没变：是用户自己改的，记下来
        activeSet = Set(active.map(\.id))
        var restored = false
        for display in active {
            let want = remembered[display.id]
            let pick = { (group: String, hz: Double) in
                display.modes.filter { $0.group == group }.min { abs($0.hz - hz) < abs($1.hz - hz) }
            }
            var mode = want.flatMap { pick($0.group, $0.hz) }
            // 记的档位这个组合下没有：系统给的档位先不当成用户选的
            fallback[display.id] = want != nil && mode == nil ? display.current.group : nil
            // 记的档位这个组合下没有，或这块屏是第一次见：开着 islet 的 HiDPI 却落在原生普通档位上，就切到推荐档位
            if mode == nil, display.current.native, !display.current.hiDPI, overrides[display.id]?.owned == true,
               let recommended = display.recommended, recommended.hiDPI {
                mode = pick(recommended.group, display.current.hz)
                if let mode, want != nil { fallback[display.id] = mode.group }
            }
            guard let mode, mode.group != display.current.group, apply(mode, on: display.id) else {
                if want == nil { remembered[display.id] = (display.current.group, display.current.hz) }
                continue
            }
            restored = true
            if want == nil { remembered[display.id] = (mode.group, mode.hz) }
        }
        if restored { refresh() }
    }

    func refresh() {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return }
        let names = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen.localizedName)
        })
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        let online: [Display] = ids.prefix(Int(count)).compactMap { id in
            let active = CGDisplayIsActive(id) != 0
            let currentMode = CGDisplayCopyDisplayMode(id).map(Mode.init)
            if active && currentMode == nil { return nil }
            if let screenName = names[id] { cachedNames[id] = screenName }
            let rawBounds = CGDisplayBounds(id)
            if active && rawBounds.width > 0 && rawBounds.height > 0 { cachedBounds[id] = rawBounds }
            let bounds = (active && rawBounds.width > 0 && rawBounds.height > 0) ? rawBounds : (cachedBounds[id] ?? rawBounds)
            let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? [])
                .filter { $0.isUsableForDesktopGUI() }.map(Mode.init)
            let native = modes.filter { $0.native && !$0.hiDPI }.max { $0.width * $0.height < $1.width * $1.height }
                ?? modes.filter { !$0.hiDPI }.max { $0.width * $0.height < $1.width * $1.height }
            let fallbackMode = currentMode ?? native ?? modes.first ?? .placeholder
            return Display(id: id, name: names[id] ?? cachedNames[id] ?? "显示器", builtIn: CGDisplayIsBuiltin(id) != 0,
                           current: fallbackMode, modes: modes, native: native,
                           isMain: CGDisplayIsMain(id) != 0, mirrored: CGDisplayIsInMirrorSet(id) != 0,
                           active: active, bounds: bounds, widthMM: Double(CGDisplayScreenSize(id).width))
        }
        let onlineIDs = Set(online.map(\.id))
        for id in onlineIDs { disabledDisplays.removeValue(forKey: id) }
        displays = (online + disabledDisplays.values.filter { !onlineIDs.contains($0.id) }).sorted {
            if $0.isMain != $1.isMain { return $0.isMain }
            if $0.active != $1.active { return $0.active }
            return $0.id < $1.id
        }
        // 重连后档位变了（开启的出现了、关闭的消失了），或屏幕拔掉了，就不再等
        let pending = awaitingReconnect.filter { id, adding in displays.contains { $0.id == id && $0.hasHiDPIChoices != adding } }
        if pending != awaitingReconnect { awaitingReconnect = pending }
        refreshOverrides()
    }

    /// 读外接屏的覆盖配置状态（辅助程序很快，放后台读）。
    private func refreshOverrides() {
        guard let helper else { return }
        let ids = displays.filter { $0.active && !$0.builtIn }.map(\.id)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result: [CGDirectDisplayID: OverrideStatus] = [:]
            for id in ids {
                let (code, data) = Self.run(helper, ["status", String(id)])
                if code == 0, let status = try? JSONDecoder().decode(OverrideStatus.self, from: data) { result[id] = status }
            }
            DispatchQueue.main.async { self?.overrides = result }
        }
    }

    private static func run(_ helper: URL, _ arguments: [String]) -> (Int32, Data) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = helper
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (1, Data(error.localizedDescription.utf8)) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    // MARK: 添加 / 移除 HiDPI 档位

    /// 添加后需要重新连接这块屏，新档位才会出现：用软件断开再接上（只有一块屏时也行），接不回来才提示手动插拔。
    /// 新档位出现后自动切到推荐的大小。
    func addHiDPI(_ display: Display) {
        pendingRecommend = display.id
        perform(["install"], then: ["reconnect"], on: display)
    }
    func removeHiDPI(_ display: Display) {
        pendingRecommend = nil
        perform(["remove"], then: ["reconnect"], on: display)
    }

    /// 开启或关闭显示器；至少保留一块开启的显示器。
    func setEnabled(_ enabled: Bool, on display: Display) {
        guard !busy, let helper else { return }
        if !enabled && displays.filter(\.active).count <= 1 { return }
        busy = true
        message = nil
        let id = String(display.id)
        let command = enabled ? "enable" : "disable"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (code, data) = Self.run(helper, [command, id])
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if code == 0 {
                    if enabled {
                        self.disabledDisplays.removeValue(forKey: display.id)
                    } else {
                        self.disabledDisplays[display.id] = Display(
                            id: display.id, name: display.name, builtIn: display.builtIn,
                            current: display.current, modes: display.modes, native: display.native,
                            isMain: false, mirrored: false, active: false,
                            bounds: display.bounds, widthMM: display.widthMM
                        )
                    }
                    self.message = nil
                } else {
                    self.message = text.isEmpty ? nil : text
                }
                self.refresh()
            }
        }
    }

    /// 开启 HiDPI 后等新档位出现，切到推荐大小。重连要一两秒，最多等几秒；要手动插拔的情况就不自动切了。
    private var pendingRecommend: CGDirectDisplayID?

    private func applyRecommendation(attempts: Int) {
        guard let id = pendingRecommend, !busy else { return }
        if let display = displays.first(where: { $0.id == id }), display.hasHiDPIChoices, let mode = display.recommended {
            pendingRecommend = nil
            if mode.group != display.current.group { choose(mode, on: display) }
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.refresh()
                self?.applyRecommendation(attempts: attempts - 1)
            }
        } else {
            pendingRecommend = nil
        }
    }

    private func perform(_ command: [String], then follow: [String], on display: Display) {
        guard !busy, let helper else { return }
        busy = true
        message = nil
        let id = String(display.id)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var (code, data) = Self.run(helper, command + [id])
            var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let succeeded = code == 0
            if code == 0 {
                (code, data) = Self.run(helper, follow + [id])
                let follow = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                text = code == 0 ? text : "\(text)。\(follow)"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                // 配置写好了但没能重连：在这块屏的说明里提示手动插拔，不再显示助手的原话
                self.awaitingReconnect[display.id] = succeeded && code != 0 ? command == ["install"] : nil
                // 成功不提示（开关状态已经说明了），只留失败的说明
                self.message = succeeded || text.isEmpty ? nil : text
                self.refresh()
                if succeeded { self.applyRecommendation(attempts: 6) } else { self.pendingRecommend = nil }
            }
        }
    }

    // MARK: 切换分辨率
    // 列表里只有系统支持、切过去能正常显示的档位，和系统设置一样直接切换保存，不再弹确认

    func choose(_ mode: Mode, on display: Display) {
        guard !busy, display.canSwitch, mode.id != display.current.id else { return }
        message = apply(mode, on: display.id) ? nil : "系统没有接受这个显示模式"
        refresh()
        rememberCurrent(chosen: true)
    }

    /// 切到这个模式并保存（系统也会把它记进当前的屏幕组合）。
    private func apply(_ mode: Mode, on id: CGDirectDisplayID) -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let target = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode])?
                .first(where: { $0.ioDisplayModeID == mode.id }) else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, id, target, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }
}
