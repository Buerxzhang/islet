import AppKit
import ServiceManagement
import SwiftUI

// 独立窗口：设置、温度曲线、规则。风格与弹出面板一致（FunFan 设计令牌）。

// MARK: - 窗口管理

final class WindowManager {
    private var windows: [String: NSWindow] = [:]

    /// 打开（或前置）一个 SwiftUI 窗口。
    func show<Content: View>(_ id: String, title: String, size: NSSize, resizable: Bool = false,
                             onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        if let window = windows[id] {
            bringToFront(window)   // 宽度不在这里改：设置窗口由预览里的岛决定宽度，两处都改会来回闪
            return
        }
        // 不用 fullSizeContentView：内容从标题栏下方开始，滚动时不会从红黄绿按钮下面穿过
        var style: NSWindow.StyleMask = [.titled, .closable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden          // 页面里已有大标题
        // 不设 titlebarAppearsTransparent：macOS 27 上透明标题栏的窗口拖向另一块屏时会被拽回原屏
        window.backgroundColor = Self.panelColor
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.contentViewController = NSHostingController(rootView: content())
        window.setContentSize(size)
        window.appearance = NSAppearance(named: .aqua)   // 统一浅色
        // 普通层级：切到别的程序时正常退到后面，再从灵动岛打开设置即可前置
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        // 记住窗口位置：第一次居中，之后在上次拖到的地方打开
        if resizable { window.minSize = NSSize(width: 640, height: 480) }
        // 记住窗口位置和高度：第一次按设计尺寸居中，之后沿用上次的位置和高度。
        // 可调大小的窗口宽度用这次算好的设计宽度（设置窗口 = 预览里岛的宽度），不用上次的：否则打开后预览再改宽度，会跳一下
        let restored = window.setFrameUsingName("islet.\(id)")
        window.setFrameAutosaveName("islet.\(id)")   // 这一步也会套用上次保存的尺寸，所以宽度放在它后面改
        if !restored { window.center() }
        if restored, resizable {
            var frame = window.frame
            frame.size.width = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).width
            window.setFrame(frame, display: false)
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            onClose?()
        }
        windows[id] = window
        bringToFront(window)
    }

    private func bringToFront(_ window: NSWindow) {
        // 不切换成 .regular（程序坞图标）：切回 .accessory 时系统会重建整条菜单栏，关窗时菜单栏会闪一下
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()  // 即使系统没批准激活，也先显示在最前
    }

    /// 与 Palette.panel 一致的窗口底色。
    private static let panelColor = NSColor(srgbRed: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF5 / 255, alpha: 1)

    func close(_ id: String) { windows[id]?.close() }

    func isOpen(_ id: String) -> Bool { windows[id]?.isVisible == true }
}

// MARK: - 设置

/// 设置窗口的分页（左侧导航）。
enum SettingsPage: String, CaseIterable, Identifiable {
    case menuBar, music, metrics, fan, bluetooth, extensions, general, about
    /// 左侧导航分组：灵动岛和它的各个模块 / 其他功能 / 关于，组间画分隔线
    static let groups: [[SettingsPage]] = [[.menuBar, .music, .metrics, .fan, .bluetooth], [.extensions, .general], [.about]]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .menuBar: return "灵动岛"
        case .music: return "音乐"
        case .metrics: return "系统指标"
        case .fan: return "风扇"
        case .bluetooth: return "蓝牙电量"
        case .extensions: return "扩展功能"
        case .general: return "通用"
        case .about: return "关于"
        }
    }
    var symbol: String {
        switch self {
        case .menuBar: return "capsule"
        case .music: return "waveform"
        case .metrics: return "gauge.with.dots.needle.33percent"
        case .fan: return "fan"
        case .bluetooth: return BluetoothGlyph.name
        case .extensions: return "puzzlepiece.extension"
        case .general: return "gearshape"
        case .about: return "info.circle"
        }
    }
    var tint: Color {
        switch self {
        case .menuBar: return Color(hex: 0x5E5CE6)
        case .music: return Color(hex: 0xFF375F)
        case .metrics: return Color(hex: 0x30D158)
        case .fan: return Color(hex: 0x30B0C7)
        case .bluetooth: return Color(hex: 0x0A84FF)
        case .extensions: return Color(hex: 0xBF5AF2)
        case .general: return Color(hex: 0x8E8E93)
        case .about: return Color(hex: 0xFF9F0A)
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published private(set) var revision = 0      // 设置变化时递增，触发界面刷新
    @Published var page: SettingsPage = .menuBar
    @Published var controlTemperatures: (average: Double, peak: Double)?
    @Published var diagnosticsNote: String?

    var onChange: (SpeedSetting) -> Void = { _ in }
    var onMetricOrder: () -> Void = {}
    var onFullScreenFloatingIsland: (Bool) -> Void = { _ in }
    var onFreeFloatingIsland: (Bool) -> Void = { _ in }
    var onIslandScreen: (String) -> Void = { _ in }
    var onFloatingIsland: (Bool) -> Void = { _ in }
    var onKeepLeftmost: () -> Void = {}
    var onUnits: () -> Void = {}
    @Published var alertRules = AlertCenter.rules
    @Published var stars: Int?
    @Published var update: UpdateChecker.State = .idle
    @Published var showDonate = false
    /// 风扇页里展开的编辑器（fanCurve、fanRules）。
    @Published var expanded: Set<String> = []
    var onResetAll: () -> Void = {}
    /// 灵动岛各项的顺序；拖动时实时变化，松手后才保存并应用到菜单栏。
    @Published var islandOrder = IslandOrder.items
    /// 正在拖动的项、手指相对按下时的位移、当前位置（列表坐标）、是否还在列表范围内。
    @Published var dragging: String?
    @Published var dragOffset: CGFloat = 0
    @Published var dragY: CGFloat = 0
    @Published var dragInside = true
    /// 各行（以及整个列表）在列表坐标里的位置，用来算落点。
    var rowFrames: [String: CGRect] = [:]
    static let listMarker = "__list__"

    /// 某项当前是否显示在岛上。
    func isVisible(_ id: String) -> Bool {
        switch id {
        case "music": return SpectrumController.isEnabled
        case "metrics": return Metric.groupShown
        case "bluetooth": return SoundController.showsBluetoothItem
        case "network": return SpeedSetting.direction.selection != 2
        default: return Self.metricSetting(id).map { $0.selection == 0 } ?? false
        }
    }

    /// 能不能关掉这一项：岛上至少留一项（音乐、蓝牙、任一指标都算），全关胶囊会整个消失。
    /// 指标整组关掉时，单项指标不算在岛上。
    func canTurnOff(_ id: String) -> Bool {
        let shown = islandOrder.filter { isVisible($0) && (Self.modules.contains($0) || Metric.groupShown) }
        if id == "metrics" { return shown.contains { $0 == "music" || $0 == "bluetooth" } }
        return shown.contains { $0 != id }
    }

    /// 显示 / 隐藏某项。
    func setVisible(_ id: String, _ on: Bool) {
        switch id {
        case "music": SpectrumController.shared.setEnabled(on)
        case "metrics": setMetricsShown(on); return
        case "bluetooth":
            UserDefaults.standard.set(on, forKey: "bluetoothItem")
            SoundController.shared.startBluetoothItem()
        case "network":
            select(.direction, on ? (UserDefaults.standard.object(forKey: "networkLastMode") as? Int ?? 0) : 2)
        default:
            if let setting = Self.metricSetting(id) { select(setting, on ? 0 : 1) }
            // 帧率需要屏幕录制权限：打开时向系统申请（已授权则不弹）
            if id == "fps", on, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        }
        refresh()
    }

    /// 只恢复“显示在岛上”这一块：各项显示 / 隐藏、顺序（重新按机型套用默认），其他设置不动。
    func resetIslandItems() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "islandOrder")
        defaults.removeObject(forKey: "metricOrder")
        for setting in Metric.allCases.map(\.setting) where setting != .direction { defaults.removeObject(forKey: setting.key) }
        islandOrder = IslandOrder.items
        // 音乐、蓝牙、网速默认都显示；网速沿用原来的显示方式
        for id in ["music", "bluetooth", "network"] where !isVisible(id) { setVisible(id, true) }
        onChange(.cpuItem)
        onMetricOrder()
        refresh()
    }

    static func metricSetting(_ id: String) -> SpeedSetting? {
        Metric.allCases.first { "\($0)" == id }?.setting
    }
    /// 模块（各成一个小胶囊）和“系统指标”里的指标，各自排序。
    static let modules = ["music", "metrics", "bluetooth"]
    var moduleOrder: [String] { IslandOrder.modules(islandOrder) }
    var metricOrder: [String] { islandOrder.filter { !Self.modules.contains($0) } }
    /// 被拖动项所在的组。分体时模块只和模块换位置、指标只和指标换；合体时所有项一起任意排。
    func group(of id: String) -> [String] {
        guard MetricsIslandView.splits else { return islandOrder }
        return Self.modules.contains(id) ? moduleOrder : metricOrder
    }

    /// 松手时会落到的位置：同组其他项里，中线在手指上方的个数。
    var dropIndex: Int? {
        guard let dragging else { return nil }
        return group(of: dragging).filter { $0 != dragging && (rowFrames[$0]?.midY ?? .infinity) < dragY }.count
    }

    /// 松手：在列表范围内就按落点调整顺序；拖出列表外则取消。显示 / 隐藏只由开关管。
    /// 分体时排过顺序，合体时穿插的位置会理顺（音乐、蓝牙回到指标两侧）。
    func endDrag() {
        defer {
            dragging = nil
            dragOffset = 0
        }
        guard let id = dragging, dragInside, let index = dropIndex else { return }
        var list = group(of: id).filter { $0 != id }
        list.insert(id, at: min(index, list.count))
        let order = !MetricsIslandView.splits ? list
            : Self.modules.contains(id) ? IslandOrder.flatten(modules: list, metrics: metricOrder)
            : IslandOrder.flatten(modules: moduleOrder, metrics: list)
        guard order != islandOrder else { return }
        IslandOrder.save(order)
        islandOrder = IslandOrder.items
        onMetricOrder()
    }

    var onInstallFan: () -> Void = {}
    var onUninstallFan: () -> Void = {}
    /// 风扇详情里内嵌的曲线编辑器、规则列表用到的数据（没有风扇时为 nil）。
    var curveModel: CurveEditorModel?
    var fanData: FanData?
    var onActivateRules: () -> Void = {}
    var onCopyDiagnostics: () -> Void = {}

    func selection(_ setting: SpeedSetting) -> Int { setting.selection }

    /// 修改设置。允许把指标全部隐藏：胶囊消失后再次打开 islet 会弹出设置。
    func select(_ setting: SpeedSetting, _ index: Int) {
        setting.select(index)
        onChange(setting)
        revision += 1
    }

    var launchAtLogin: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else {
                try service.unregister()
            }
        } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "无法更改登录时启动"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        revision += 1
    }

    func refresh() { revision += 1 }

    /// 分体 / 合体胶囊。
    func setSplit(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: MetricsIslandView.splitKey)
        onMetricOrder()   // 重排灵动岛
        refresh()
    }

    /// 整组显示 / 隐藏系统指标（各项自己的显示设置保留）。
    func setMetricsShown(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Metric.groupKey)
        onChange(.cpuItem)   // 和单项开关走同一条路：重排灵动岛、按需开停采样
        refresh()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var fanClient = FanHelperClient.shared
    @ObservedObject var smoothScroll = SmoothScrollController.shared
    @ObservedObject var displays = DisplayManager.shared
    @ObservedObject var updater = Updater.shared
    /// 走查用：不包 ScrollView（离屏渲染画不出滚动视图的内容）。
    var flat = false

    var body: some View {
        Themed { p in
            HStack(spacing: 0) {
                sidebar(p)
                Rectangle().fill(p.separator).frame(width: 1)
                VStack(spacing: 0) {
                    // 不显示滚动条：接了鼠标时系统用常驻滚动条，占 17 点宽，而且刚打开时系统先报“悬浮”、过一会儿才改成常驻，
                    // 窗口宽度（跟着预览里的岛走）会因此跳一下。滚轮、触控板照常滚动
                    if flat { page(p) } else { ScrollView { page(p) }.scrollIndicators(.never) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(minWidth: 640, minHeight: 480)
            .background(p.panel)
        }
    }

    // MARK: 左侧导航

    private func sidebar(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // 分组之间画分隔线；“关于”紧跟在后面，不推到底部，窗口拉高时不会孤零零挂在最下面
            ForEach(Array(SettingsPage.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Rectangle().fill(p.separator).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 6) }
                // 没有风扇的 Mac 不列“风扇”页
                ForEach(group.filter { $0 != .fan || model.fanData != nil }) { page in sidebarItem(p, page) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(p.inset.opacity(0.5))
    }

    private func sidebarItem(_ p: Palette, _ page: SettingsPage) -> some View {
        let selected = model.page == page
        return Button { model.page = page } label: {
            HStack(spacing: 10) {
                IconTile(symbol: page.symbol, tint: page.tint, size: 24)
                Text(page.title).font(selected ? Typo.settingsBodyMedium : Typo.settingsBody).foregroundStyle(p.text)
                Spacer(minLength: 0)
                if page == .about {
                    Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")).font(Typo.settingsCaption).foregroundStyle(p.text3)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? p.accentFill.opacity(0.2) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 分页内容

    /// 页尾说明：行里只放标题和控件，较长的功能解释、注意事项统一放在页面最下面（小号灰字）
    private static let notes: [SettingsPage: [(String, String)]] = [
        .menuBar: [("胶囊", "玻璃样式仅在悬浮模式下生效。"),
                   ("显示内容", "至少要保留一项。想完全不显示灵动岛，可以只保留音乐（不放歌时就不显示），或按 ⌘Q 退出 islet。")],
        .music: [("频谱", "需要授权「系统录音」权限，只读取正在播放的声音来画频谱，不录麦克风。"),
                 ("兼容性", "会自动识别「音乐」类软件；遇到不适配的软件，欢迎在「关于」页反馈。")],
        .metrics: [("帧率", "是前台窗口所在屏幕每秒画面变化的次数，画面静止时会变低。")],
        .fan: [("调速", "通过未公开的接口实现，系统升级后可能失效。转速有安全下限，退出 islet 或电脑睡眠时会交还系统。遇到异常，请把调速策略切回「自动」或卸载组件。")],
        .bluetooth: [("电量", "由系统读取蓝牙设备上报的电量。各设备的协议不同，部分设备可能读不到或不准。")],
        .extensions: [("HiDPI", "需要输入管理员密码写入系统配置，并且要显示器支持。打开后如果显示异常，请关掉它。")],
    ]

    @ViewBuilder private func pageNotes(_ p: Palette, _ notes: [(String, String)]) -> some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(notes, id: \.0) { title, text in
                    (Text("「\(title)」").foregroundStyle(p.text2) + Text(text).foregroundStyle(p.text3))
                        .font(Typo.settingsCaption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 6)
        }
    }

    private func page(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.page.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(p.text)
            switch model.page {
            case .general: generalPage(p)
            case .menuBar: menuBarPage(p)
            case .music: section(p, "频谱") { musicDetail(p) }
            case .metrics:
                section(p, "网速") { networkDetail(p) }
                section(p, "温度") { temperatureDetail(p) }
                section(p, "帧率") { fpsDetail(p) }
            case .fan: section(p, "调速") { fanDetail(p) }
            case .bluetooth: bluetoothPage(p)
            case .extensions: extensionsPage(p)
            case .about: aboutPage(p)
            }
            pageNotes(p, Self.notes[model.page] ?? [])
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(model.revision)
    }

    /// 通用：启动、外观、单位、提醒、数据与流量。
    @ViewBuilder private func generalPage(_ p: Palette) -> some View {
        section(p, "基本") {
            row(p, "登录时启动", nil, icon: "power", tint: Color(hex: 0x30D158)) {
                Toggle2(isOn: model.launchAtLogin, onChange: model.setLaunchAtLogin)
            }
        }
        section(p, "提醒") {
            row(p, "提醒规则", nil, icon: "bell.badge.fill", tint: Color(hex: 0xFF453A)) {
                PlainButton(title: "添加") {
                    model.alertRules.append(AlertRule(kind: .temperature, threshold: AlertRule.Kind.temperature.defaultThreshold, minutes: 1))
                    AlertCenter.rules = model.alertRules
                }
            }
            ForEach($model.alertRules) { $rule in
                divider(p)
                AlertRuleRow(rule: $rule, onChange: { AlertCenter.rules = model.alertRules }) {
                    model.alertRules.removeAll { $0.id == rule.id }
                    AlertCenter.rules = model.alertRules
                }
            }
        }
        section(p, "数据") {
            row(p, "刷新频率", "越快越耗电", icon: "arrow.clockwise", tint: Color(hex: 0x0A84FF)) {
                Segmented(options: [(0, "1 秒"), (1, "2 秒"), (2, "3 秒")],
                          selection: model.selection(.interval)) { model.select(.interval, $0) }
                    .frame(width: SettingsLayout.control)
            }
            divider(p)
            row(p, "排行条数", nil, icon: "list.number", tint: Color(hex: 0x32ADE6)) {
                Segmented(options: [(0, "3"), (1, "5"), (2, "8")],
                          selection: model.selection(.count)) { model.select(.count, $0) }
                    .frame(width: SettingsLayout.control)
            }
        }
        section(p, "重置") {
            row(p, "恢复默认设置", nil, icon: "arrow.uturn.backward.circle.fill", tint: Color(hex: 0x8E8E93)) {
                PlainButton(title: "恢复默认") {
                    guard confirmAlert("恢复 islet 的默认设置？",
                                       "islet 会重新启动。流量统计、macOS 的显示器配置和系统权限会保留。") else { return }
                    model.onResetAll()
                }
            }
        }
    }

    /// 悬浮胶囊显示在哪块屏：主屏（跟着系统的主显示器走），或固定某块扩展屏。
    @ViewBuilder private func islandScreenMenu() -> some View {
        // 主屏 = 跟着系统的主显示器走；扩展屏按 UUID 固定。之前固定选了主屏那块的，也当作“主屏”
        let primary = NSScreen.screens.first.flatMap(AppDelegate.screenUUID)
        let extras = NSScreen.screens.dropFirst().compactMap { screen in AppDelegate.screenUUID(screen).map { ($0, screen.localizedName) } }
        let stored = AppDelegate.islandScreen
        let current = stored == primary ? "main" : stored
        if extras.count == 1, current == "main" || current == extras[0].0 {
            // 两块屏：和其他行一样用分段选择
            Segmented(options: [("main", "主屏"), (extras[0].0, "扩展屏")], selection: current) { model.onIslandScreen($0) }
                .frame(width: SettingsLayout.control)
        } else {
            // 三块屏及以上，或选过的屏没接着：下拉菜单
            let title = current == "main" ? "主屏" : extras.first { $0.0 == current }?.1 ?? "指定的屏幕（未连接）"
            Menu(title) {
                Button("主屏") { model.onIslandScreen("main") }
                Divider()
                ForEach(extras, id: \.0) { uuid, name in
                    Button(name) { model.onIslandScreen(uuid) }
                }
            }
            .fixedSize()
            .frame(width: SettingsLayout.control, alignment: .trailing)   // 下拉菜单按内容宽度画，靠右和其他控件对齐
        }
    }

    /// 灵动岛：位置、底色，以及岛上显示的内容（顺序与岛上一致）。各模块自己的设置在左侧单独的页里。
    @ViewBuilder private func menuBarPage(_ p: Palette) -> some View {
        section(p, "胶囊") {
            // 显示位置二选一：悬浮在刘海 / 菜单栏下方，或放在菜单栏里（和右键菜单的“悬浮显示 / 在菜单栏显示”联动）
            row(p, "显示位置", nil, icon: "rectangle.on.rectangle", tint: Color(hex: 0x0A84FF)) {
                Segmented(options: [(true, "悬浮"), (false, "菜单栏")], selection: AppDelegate.floatsIsland,
                          onSelect: model.onFloatingIsland)
                    .frame(width: SettingsLayout.control)
            }
            divider(p)
            if AppDelegate.floatsIsland {
                row(p, "全屏时保持悬浮", nil, icon: "arrow.up.left.and.arrow.down.right", tint: Color(hex: 0x0A84FF)) {
                    Toggle2(isOn: AppDelegate.fullScreenFloatingIsland, onChange: model.onFullScreenFloatingIsland)
                }
                divider(p)
                row(p, "自由拖动", nil, icon: "hand.draw", tint: Color(hex: 0x0A84FF)) {
                    Toggle2(isOn: AppDelegate.freeFloatingIsland, onChange: model.onFreeFloatingIsland)
                }
                // 自由拖动时拖到哪块屏就在哪块屏；只有一块屏时不用选
                if !AppDelegate.freeFloatingIsland, NSScreen.screens.count > 1 || AppDelegate.islandScreen != "main" {
                    divider(p)
                    row(p, "显示屏幕", nil, icon: "display.2", tint: Color(hex: 0x0A84FF)) {
                        islandScreenMenu()
                    }
                }
            } else {
                row(p, "始终在菜单栏最左侧", "关闭后按住 ⌘ 拖动", icon: "pin.fill", tint: Color(hex: 0x30D158)) {
                    Toggle2(isOn: AppDelegate.keepsLeftmost) { on in
                        UserDefaults.standard.set(on, forKey: "keepLeftmost")
                        if on { model.onKeepLeftmost() }
                        model.refresh()
                    }
                }
            }
            divider(p)
            row(p, "胶囊形态", nil, icon: "square.split.2x1", tint: Color(hex: 0xBF5AF2)) {
                Segmented(options: [(true, "分体"), (false, "合并")], selection: MetricsIslandView.splits, onSelect: model.setSplit)
                    .frame(width: SettingsLayout.control)
            }
            divider(p)
            // 样式：胶囊底色；玻璃只在悬浮时可用（菜单栏里会透出系统的按下高亮），不悬浮时置灰、按黑色画
            row(p, "样式", AppDelegate.floatsIsland ? nil : "「玻璃」仅在悬浮模式生效",
                icon: "paintpalette", tint: Color(hex: 0xFF9F0A)) {
                // 不悬浮时选着“玻璃”就显示成实际在用的“渐变”；保存的仍是玻璃，再悬浮时自动回到玻璃
                let stored = SpectrumLook.current.backdrop
                Segmented(options: SpectrumLook.Backdrop.allCases.map { ($0, $0.label) },
                          selection: !AppDelegate.floatsIsland && stored == .glass ? .gradient : stored,
                          disabled: AppDelegate.floatsIsland ? [] : [.glass]) { value in
                    var look = SpectrumLook.current
                    look.backdrop = value
                    SpectrumController.shared.setLook(look)
                    model.onMetricOrder()   // 重画胶囊（玻璃开关）
                    model.refresh()
                }
                .frame(width: SettingsLayout.control)
            }
        }
        itemList(p)
    }

    /// 岛上显示的内容，形态跟着“分体胶囊”走：
    /// 分体时三张卡片对应三个小胶囊，拖卡片标题换胶囊位置，指标只在自己的卡片里排；
    /// 合体时一个平铺列表，音乐、蓝牙、各项指标任意排序。开关管显示 / 隐藏（关掉的留在原位）。
    /// 拖动时蓝线是松手后的位置，拖出列表外松手则取消。
    private func itemList(_ p: Palette) -> some View {
        let split = MetricsIslandView.splits
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("显示内容").font(Typo.bodyMedium).foregroundStyle(p.text2)
                Spacer()
            }
            if split {
                ForEach(model.moduleOrder, id: \.self) { id in
                    Card(padding: 12) {
                        VStack(alignment: .leading, spacing: 0) {
                            itemRow(p, id).gesture(dragGesture(id))
                            // 系统指标默认收起，点标题行展开；展开状态在关掉设置窗口时清空
                            if id == "metrics", model.expanded.contains("metrics") { metricRows(p) }
                        }
                    }
                    .background(frameReader(id))
                    .opacity(model.dragging == id ? 0.25 : 1)
                }
            } else {
                if !Metric.groupShown {
                    // 分体时整组关掉了系统指标：合体时没有这一行，在这里说明并能直接打开
                    HStack {
                        Text("系统指标已整组隐藏").font(Typo.settingsCaption).foregroundStyle(p.text3)
                        LinkButton(title: "打开") { model.setMetricsShown(true) }
                    }
                }
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.islandOrder.enumerated()), id: \.element) { index, id in
                            let dimmed = !Metric.groupShown && !SettingsModel.modules.contains(id)
                            VStack(alignment: .leading, spacing: 0) {
                                if index > 0 { divider(p) }
                                itemRow(p, id, compact: true)
                            }
                            .background(frameReader(id))
                            .opacity(model.dragging == id ? 0.25 : dimmed ? 0.45 : 1)
                            .disabled(dimmed)
                            .gesture(dragGesture(id))
                        }
                    }
                }
            }
            LinkButton(title: "恢复默认显示和顺序", muted: true) {
                guard confirmAlert("恢复岛上项目的默认显示？",
                                   "显示哪些项目和它们的顺序会按本机重新设置，其他设置不变。") else { return }
                model.resetIslandItems()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 2)
        }
        .background(frameReader(SettingsModel.listMarker))
        .coordinateSpace(name: "islandList")
        .onPreferenceChange(RowFramesKey.self) { model.rowFrames = $0 }
        .overlay(alignment: .topLeading) { dragOverlay(p) }
    }

    /// 分体时“系统指标”卡片里的各项指标，缩进到模块图标右侧；整组关掉时变淡、不能单独开关（各项的勾保留）。
    private func metricRows(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.metricOrder, id: \.self) { id in
                VStack(alignment: .leading, spacing: 0) {
                    divider(p)
                    itemRow(p, id, compact: true)
                }
                .background(frameReader(id))
                .opacity(model.dragging == id ? 0.25 : 1)
                .gesture(dragGesture(id))
                .padding(.leading, 40)
            }
        }
        .opacity(Metric.groupShown ? 1 : 0.45)
        .disabled(!Metric.groupShown)
    }

    private func frameReader(_ id: String) -> some View {
        GeometryReader { geo in Color.clear.preference(key: RowFramesKey.self, value: [id: geo.frame(in: .named("islandList"))]) }
    }

    private func dragGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("islandList"))
            .onChanged { value in
                if model.dragging == nil { model.dragging = id }
                model.dragOffset = value.translation.height
                model.dragY = value.location.y
                let list = model.rowFrames[SettingsModel.listMarker] ?? .infinite
                model.dragInside = list.insetBy(dx: -24, dy: -24).contains(value.location)
            }
            .onEnded { _ in withAnimation(.easeOut(duration: 0.15)) { model.endDrag() } }
    }

    /// 拖动时：跟着手指的那一行 + 落点处的蓝线；拖出列表外时蓝线消失、行变淡，表示松手会取消。
    @ViewBuilder private func dragOverlay(_ p: Palette) -> some View {
        if let id = model.dragging, let frame = model.rowFrames[id] {
            let others = model.group(of: id).filter { $0 != id }
            let index = model.dropIndex ?? 0
            let lineY: CGFloat? = {
                guard model.dragInside else { return nil }
                // 分体时模块是一张张卡片，蓝线画在卡片之间的空隙里
                let gap: CGFloat = MetricsIslandView.splits && SettingsModel.modules.contains(id) ? 4 : 1
                if index < others.count, let next = model.rowFrames[others[index]] { return next.minY - gap }
                return others.last.flatMap { model.rowFrames[$0]?.maxY }.map { $0 + gap }
            }()
            ZStack(alignment: .topLeading) {
                // 浮起的行半透明，蓝线画在它上面，任何时候都看得见落点
                itemRow(p, id, compact: !MetricsIslandView.splits || !SettingsModel.modules.contains(id))
                    .padding(.horizontal, MetricsIslandView.splits && SettingsModel.modules.contains(id) ? 12 : 0)
                    .frame(width: frame.width)
                    .background(RoundedRectangle(cornerRadius: 8).fill(p.card).shadow(color: .black.opacity(0.25), radius: 10, y: 4))
                    .opacity(model.dragInside ? 0.75 : 0.4)
                    .offset(x: frame.minX, y: frame.minY + model.dragOffset)
                if let lineY {
                    Capsule().fill(p.accentFill).frame(width: frame.width, height: 3)
                        .shadow(color: p.accentFill.opacity(0.6), radius: 3)
                        .offset(x: frame.minX, y: lineY - 1.5)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func itemInfo(_ id: String) -> (title: String, subtitle: String?, icon: String, tint: Color) {
        switch id {
        case "music": return ("音乐", nil, "waveform", Color(hex: 0xFF375F))
        case "metrics": return ("系统指标", nil, "gauge.with.dots.needle.33percent", Color(hex: 0x30D158))
        case "bluetooth": return ("蓝牙电量", nil, BluetoothGlyph.name, Color(hex: 0x0A84FF))
        case "network": return ("网速", nil, "arrow.up.arrow.down", Color(hex: 0x0A84FF))
        default:
            let setting = SettingsModel.metricSetting(id)
            let icon = setting.map(Self.metricIcon) ?? ("circle", Color.gray)
            return (setting?.title ?? id, nil, icon.0, icon.1)
        }
    }

    /// 一行：图标、名称，右侧是显示开关和拖动把手。整行都能拖。
    /// compact：指标行、合体时的平铺列表，小图标、不带说明。
    private func itemRow(_ p: Palette, _ id: String, compact: Bool = false) -> some View {
        let info = itemInfo(id)
        let module = !compact
        let on = model.isVisible(id)
        // 分体时“系统指标”卡片可以展开 / 收起各项指标；收起时副标题写正在显示几项
        let expandable = module && id == "metrics"
        let open = model.expanded.contains("metrics")
        let shownCount = Metric.allCases.filter { model.isVisible("\($0)") }.count
        return HStack(spacing: 10) {
            IconTile(symbol: info.icon, tint: info.tint, size: module ? 30 : 22)
                .opacity(on ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.title).font(Typo.settingsBody).foregroundStyle(on ? p.text : p.text3)
                    if expandable {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(p.text3)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                if expandable, !open { Text("显示 \(shownCount) 项").font(Typo.settingsCaption).foregroundStyle(p.text3) }
                else if module, let subtitle = info.subtitle { Text(subtitle).font(Typo.settingsCaption).foregroundStyle(p.text3) }
            }
            Spacer(minLength: 8)
            // 最后一项不能关（开关变灰），免得胶囊整个消失
            let locked = on && !model.canTurnOff(id)
            Toggle2(isOn: on) { value in
                model.setVisible(id, value)
                model.onMetricOrder()
            }
            .disabled(locked)
            .opacity(locked ? 0.45 : 1)
            .help(locked ? "至少留一项" : "")
            Image(systemName: "line.3.horizontal").font(.system(size: 13, weight: .medium)).foregroundStyle(p.text3)
                .frame(width: 28, height: 30)
                .help("按住拖动调整顺序")
        }
        .padding(.vertical, module ? 6 : 3)
        .contentShape(Rectangle())
        .onTapGesture {
            guard expandable else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                if open { model.expanded.remove("metrics") } else { model.expanded.insert("metrics") }
            }
        }
    }

    // MARK: 展开后的设置

    /// 各模块页的一组设置（放在 section 的卡片里）。
    private func detail<Content: View>(_ p: Palette, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
    }

    /// 模块页（音乐、系统指标、蓝牙电量）的一行：和其他页一样带彩色图标
    private func detailRow<Control: View>(_ p: Palette, _ title: String, _ subtitle: String? = nil, icon: String, tint: Color,
                                          @ViewBuilder control: () -> Control) -> some View {
        row(p, title, subtitle, icon: icon, tint: tint, control: control)
    }

    private func musicDetail(_ p: Palette) -> some View {
        detail(p) {
            detailRow(p, "其他程序的声音", icon: "gamecontroller", tint: Color(hex: 0xFF375F)) {
                Toggle2(isOn: SpectrumController.showsOtherSounds) { on in
                    UserDefaults.standard.set(on, forKey: "spectrumOtherSounds")
                    SpectrumController.shared.otherSoundsChanged()
                    model.refresh()
                }
            }
            divider(p)
            detailRow(p, "声音停止后收起", icon: "timer", tint: Color(hex: 0xFF9F0A)) {   // 只管视频、网页、游戏等；音乐软件暂停时一直显示
                Segmented(options: SpectrumController.hideDelayChoices,
                          selection: UserDefaults.standard.object(forKey: "spectrumHideDelay") as? Int ?? 10) { value in
                    UserDefaults.standard.set(value, forKey: "spectrumHideDelay")
                    SpectrumController.shared.hideDelayChanged()
                    model.refresh()
                }
                .frame(width: SettingsLayout.control)
            }
            let look = SpectrumLook.current
            let setLook: (SpectrumLook) -> Void = { SpectrumController.shared.setLook($0); model.refresh() }
            divider(p)
            detailRow(p, "形状", icon: "chart.bar", tint: Color(hex: 0x5E5CE6)) {
                Segmented(options: SpectrumLook.Shape.allCases.map { ($0, $0.label) }, selection: look.shape) { value in
                    var next = look; next.shape = value; setLook(next)
                }
                .frame(width: SettingsLayout.control)
            }
            divider(p)
            detailRow(p, "颜色", icon: "paintpalette", tint: Color(hex: 0xBF5AF2)) {
                Segmented(options: SpectrumLook.Tint.allCases.map { ($0, $0.label) }, selection: look.tint) { value in
                    var next = look; next.tint = value; setLook(next)
                }
                .frame(width: SettingsLayout.control)
            }
            divider(p)
            detailRow(p, "封面旋转", icon: "opticaldisc", tint: Color(hex: 0x8E8E93)) {
                Toggle2(isOn: look.spin) { on in var next = look; next.spin = on; setLook(next) }
            }
            divider(p)
            detailRow(p, "播放按钮", icon: "playpause", tint: Color(hex: 0x30D158)) {
                Toggle2(isOn: look.controls) { on in var next = look; next.controls = on; setLook(next) }
            }
            divider(p)
            detailRow(p, "灵敏度", icon: "slider.horizontal.3", tint: Color(hex: 0x0A84FF)) {
                Segmented(options: SpectrumAnalyzer.sensitivityChoices, selection: SpectrumAnalyzer.sensitivity) { value in
                    SpectrumAnalyzer.sensitivity = value
                    model.refresh()
                }
                .frame(width: SettingsLayout.control)
            }
            divider(p)
            detailRow(p, "系统录音权限", "不录麦克风", icon: "mic.slash", tint: Color(hex: 0x8E8E93)) {
                PlainButton(title: "打开权限设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func networkDetail(_ p: Palette) -> some View {
        detail(p) {
            detailRow(p, "显示方式", "自动：只显示较快的一方", icon: "arrow.up.arrow.down", tint: Color(hex: 0x0A84FF)) {
                Segmented(options: [(0, "自动"), (1, "上传和下载")], selection: min(model.selection(.direction), 1)) { value in
                    UserDefaults.standard.set(value, forKey: "networkLastMode")
                    model.select(.direction, value)
                }
                .frame(width: SettingsLayout.control)
            }
            divider(p)
            detailRow(p, "单位", icon: "ruler", tint: Color(hex: 0x30D158)) {
                Segmented(options: [(false, "MB/s"), (true, "Mb/s")], selection: Units.bits) { value in
                    UserDefaults.standard.set(value, forKey: "unitBits")
                    model.onUnits()
                    model.refresh()
                }
                .frame(width: SettingsLayout.control)
            }
            divider(p)
            detailRow(p, "流量统计每月起始日", "对齐运营商账单", icon: "calendar", tint: Color(hex: 0xFF453A)) {
                Menu("\(TrafficLedger.monthStart) 日") {
                    ForEach(1...28, id: \.self) { day in
                        Button("\(day) 日") {
                            UserDefaults.standard.set(day, forKey: "trafficMonthStart")
                            model.refresh()
                        }
                    }
                }
                .fixedSize()
                .frame(width: SettingsLayout.control, alignment: .trailing)
            }
            divider(p)
            detailRow(p, "清零流量统计", icon: "arrow.counterclockwise", tint: Color(hex: 0x8E8E93)) {
                PlainButton(title: "清零") {
                    guard confirmAlert("清零流量统计？", "今日和本月的上传、下载记录会归零。") else { return }
                    TrafficLedger.shared.reset()
                    model.refresh()
                }
            }
        }
    }

    /// 帧率：测量方式说明和屏幕录制权限。
    private func fpsDetail(_ p: Palette) -> some View {
        let authorized = CGPreflightScreenCaptureAccess()
        return detail(p) {
            detailRow(p, "屏幕录制权限", authorized ? nil : "授权后需重启 islet", icon: "record.circle", tint: Color(hex: 0xFF375F)) {
                PlainButton(title: authorized ? "已授权" : "打开权限设置") {
                    if !authorized { CGRequestScreenCaptureAccess() }
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    /// 温度：单位（影响所有温度显示，所以放在“温度”这一项，不藏在风扇里）。
    private func temperatureDetail(_ p: Palette) -> some View {
        detail(p) {
            detailRow(p, "温度单位", icon: "thermometer.medium", tint: Color(hex: 0xFF9F0A)) {
                Segmented(options: [(false, "℃"), (true, "℉")], selection: Units.fahrenheit) { value in
                    UserDefaults.standard.set(value, forKey: "unitFahrenheit")
                    model.onUnits()
                    model.refresh()
                }
                .frame(width: SettingsLayout.control)
            }
        }
    }

    private func fanDetail(_ p: Palette) -> some View {
        detail(p) {
            row(p, "调速依据温度", basisSubtitle, icon: "thermometer.medium", tint: Color(hex: 0xFF9F0A)) {
                Segmented(options: TemperatureBasis.allCases.reversed().map { ($0, $0.label) },
                          selection: fanClient.config.basis) { basis in
                    fanClient.update { $0.basis = basis }
                }
                .frame(width: SettingsLayout.control)
            }
            divider(p)
            row(p, "温度曲线", fanClient.config.preset.map { "预设：\($0.label)" } ?? "自定义（\(fanClient.config.curve.count) 个控制点）",
                icon: "chart.xyaxis.line", tint: Color(hex: 0x0A84FF)) {
                if let curve = model.curveModel {
                    editToggle("fanCurve") { curve.points = fanClient.config.curve; curve.selected = nil }
                }
            }
            if let curve = model.curveModel, model.expanded.contains("fanCurve") {
                CurveEditorView(model: curve, embedded: true).padding(.bottom, 10)
            }
            divider(p)
            row(p, "规则", "\(fanClient.config.rules.count) 条 · 启用 \(fanClient.config.rules.filter(\.enabled).count) 条",
                icon: "list.bullet.rectangle", tint: Color(hex: 0xBF5AF2)) {
                editToggle("fanRules") {}
            }
            if model.expanded.contains("fanRules") {
                RulesView(fan: model.fanData, embedded: true, onActivate: model.onActivateRules).padding(.bottom, 10)
            }
            divider(p)
            row(p, "控制组件", componentSubtitle, icon: "wrench.and.screwdriver.fill", tint: Color(hex: 0x8E8E93)) {
                if fanClient.isInstalled {
                    HStack(spacing: 6) {
                        if !fanClient.isHelperCurrent {
                            PlainButton(title: "更新", prominent: true, action: model.onInstallFan)
                        }
                        PlainButton(title: "卸载", action: model.onUninstallFan)
                    }
                } else {
                    PlainButton(title: "安装", prominent: true, action: model.onInstallFan)
                }
            }
            divider(p)
            row(p, "退出时交还系统", nil, icon: "arrow.uturn.backward", tint: Color(hex: 0x30D158)) {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                    Text("始终开启").font(Typo.settingsCaption)
                }
                .foregroundStyle(p.text3)
            }
        
        }
    }

    private func bluetoothDetail(_ p: Palette) -> some View {
        let sound = SoundController.shared.panel
        return detail(p) {
            detailRow(p, "低电量提醒", icon: "battery.25percent", tint: Color(hex: 0xFF453A)) {
                toggle("alertLowBattery", default: true) { _ in
                    AlertCenter.shared.prepare()
                    SoundController.shared.startBluetoothItem()   // 岛上不显示蓝牙时，提醒要靠它定时读电量
                }
            }
            if AlertCenter.lowBatteryEnabled {
                divider(p)
                detailRow(p, "提醒电量", icon: "gauge.with.dots.needle.33percent", tint: Color(hex: 0xFF9F0A)) {
                    Segmented(options: AlertCenter.lowBatteryChoices, selection: AlertCenter.lowBatteryThreshold) { value in
                        UserDefaults.standard.set(value, forKey: "alertLowBatteryThreshold")
                        model.refresh()
                    }
                    .frame(width: SettingsLayout.control)
                }
                divider(p)
                detailRow(p, "提示音", icon: "speaker.wave.2", tint: Color(hex: 0x0A84FF)) { toggle("alertSound", default: true) }
                divider(p)
                detailRow(p, "测试通知", icon: "bell", tint: Color(hex: 0x30D158)) {
                    PlainButton(title: "发送测试通知") {
                        let device = sound.allDevices.first { $0.connected && SoundController.batteryLevel($0.battery) != nil }
                        AlertCenter.shared.sendTest(device: device.map { ($0.name, $0.symbol, SoundController.batteryLevel($0.battery) ?? 20) })
                    }
                }
            }
        }
    }

    /// 蓝牙电量页：低电量提醒 + 岛上显示哪些设备。
    private func bluetoothPage(_ p: Palette) -> some View {
        let sound = SoundController.shared.panel
        return VStack(alignment: .leading, spacing: 18) {
            section(p, "提醒") { bluetoothDetail(p) }
            section(p, "显示的设备") { bluetoothDevices(p, sound) }
        }
        .onAppear { if !flat { SoundController.shared.loadDevices() } }
    }

    private func bluetoothDevices(_ p: Palette, _ sound: SoundPanelModel) -> some View {
        detail(p) {
            if sound.allDevices.isEmpty {
                Text("正在读取设备…").font(Typo.settingsCaption).foregroundStyle(p.text3).padding(.vertical, 6)
            }
            ForEach(sound.allDevices) { device in
                Button {
                    sound.setHidden(!sound.hiddenDevices.contains(device.id), device: device.id)
                    model.refresh()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: sound.hiddenDevices.contains(device.id) ? "square" : "checkmark.square.fill")
                            .font(.system(size: 15)).foregroundStyle(sound.hiddenDevices.contains(device.id) ? p.text3 : p.accentFill)
                        Image(systemName: device.symbol).font(.system(size: 13)).foregroundStyle(p.text2).frame(width: 20)
                        Text(device.name).font(Typo.settingsBody).foregroundStyle(p.text)
                        Spacer()
                        if device.connected { Text("已连接").font(Typo.settingsCaption).foregroundStyle(p.text3) }
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 开关行的通用开关：读写一个布尔设置。
    private func toggle(_ key: String, default value: Bool, onChange: @escaping (Bool) -> Void = { _ in }) -> some View {
        Toggle2(isOn: UserDefaults.standard.object(forKey: key) as? Bool ?? value) { on in
            UserDefaults.standard.set(on, forKey: key)
            onChange(on)
            model.refresh()
        }
    }

    private func confirmAlert(_ title: String, _ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func setting(for metric: Metric) -> SpeedSetting? {
        switch metric {
        case .cpu: return .cpuItem
        case .gpu: return .gpuItem
        case .memory: return .memoryItem
        case .disk: return .diskItem
        case .power: return .powerItem
        case .temperature: return .temperatureItem
        case .fan: return .fanItem
        case .fps: return .fpsItem
        case .network: return nil
        }
    }

    /// 指标的图标和颜色：和面板标题共用 Metric.symbol / Metric.tint。
    private static func metricIcon(_ setting: SpeedSetting) -> (String, Color) {
        guard let metric = Metric.allCases.first(where: { $0.setting == setting }) else { return ("circle.fill", Color(hex: 0x8E8E93)) }
        return (metric.symbol, metric.tint)
    }

    @ViewBuilder private func extensionsPage(_ p: Palette) -> some View {
        section(p, "鼠标滚动") {
            // 只在异常时说明（需要权限、被其他工具占用等）
            row(p, "平滑滚动", [.off, .active].contains(smoothScroll.state) ? nil : smoothScroll.state.description, icon: "computermouse.fill", tint: Color(hex: 0x0A84FF)) {
                Toggle2(isOn: smoothScroll.enabled, onChange: smoothScroll.setEnabled)
            }
            if smoothScroll.state == .permissionRequired || smoothScroll.state == .unavailable {
                divider(p)
                row(p, "辅助功能权限", nil, icon: "hand.raised.fill", tint: Color(hex: 0x8E8E93)) {
                    PlainButton(title: "打开权限设置", action: smoothScroll.openPermissionSettings)
                }
            }
            if smoothScroll.enabled {
                divider(p)
                row(p, "滚动距离", nil, icon: "arrow.up.and.down", tint: Color(hex: 0x30D158)) {
                    Segmented(options: SmoothScrollController.Distance.allCases.map { ($0, $0.label) },
                              selection: smoothScroll.options.distance, onSelect: smoothScroll.setDistance)
                        .frame(width: SettingsLayout.control)
                }
                divider(p)
                row(p, "平滑程度", nil, icon: "waveform.path", tint: Color(hex: 0xFF9F0A)) {
                    Segmented(options: SmoothScrollController.Smoothness.allCases.map { ($0, $0.label) },
                              selection: smoothScroll.options.smoothness, onSelect: smoothScroll.setSmoothness)
                        .frame(width: SettingsLayout.control)
                }
                divider(p)
                row(p, "反转滚动方向", "不影响触控板", icon: "arrow.up.arrow.down", tint: Color(hex: 0x5E5CE6)) {
                    Toggle2(isOn: smoothScroll.options.reverse, onChange: smoothScroll.setReverse)
                }
            }
        }
        displaysSection(p)
    }

    // MARK: 显示器

    /// 每块屏一行，下面是“文字大小”选项。没有实用 HiDPI 档位的外接屏有个 HiDPI 开关：
    /// 打开 = 写一份显示配置并切到推荐大小，关掉 = 移除 islet 写的配置。别的工具写的配置不给开关。
    private func displaysSection(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            section(p, "显示器") {
                if displays.displays.isEmpty {
                    Text("没有检测到显示器").font(Typo.settingsCaption).foregroundStyle(p.text3).padding(.vertical, 10)
                }
                ForEach(Array(displays.displays.enumerated()), id: \.element.id) { index, display in
                    if index > 0 { divider(p) }
                    displayRow(p, display)
                }
                if let message = displays.message {
                    divider(p)
                    Text(message).font(Typo.settingsCaption).foregroundStyle(p.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
            }
        }
        .onAppear { displays.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in displays.refresh() }
    }

    private enum HiDPISwitch { case none, off, on }

    private func hiDPISwitch(_ display: DisplayManager.Display) -> HiDPISwitch {
        guard display.canSwitch, let status = displays.overrides[display.id], status.external else { return .none }
        if status.owned { return .on }
        if !status.installed, !display.hasHiDPIChoices, !status.sizes.isEmpty { return .off }
        return .none
    }

    private func displayRow(_ p: Palette, _ display: DisplayManager.Display) -> some View {
        let current = display.current
        let hiDPI = hiDPISwitch(display)
        let options = display.sizeOptions
        let showSizes = display.canSwitch && options.count > 1
        let subtitle: String
        if !display.active {
            subtitle = "未启用"
        } else {
            let mode = "\(current.size) \(current.hiDPI ? "HiDPI" : "普通")"
            let details = [mode, current.rate].filter { !$0.isEmpty }.joined(separator: " · ")
            // 第二行：镜像时说明为什么不能调；没开 HiDPI 时说明开关的作用；用 HiDPI 时给出实际渲染尺寸（普通模式等于分辨率，不重复）
            let note = display.mirrored ? "镜像中，解除镜像后可以单独调整"
                : hiDPI == .off ? "开启 HiDPI 后文字更清晰，大小可调"
                : current.hiDPI ? renderNote(current, display)
                : !current.native ? "普通分辨率，放大显示会发虚" : nil
            subtitle = note.map { "\(details)\n\($0)" } ?? details
        }
        return VStack(alignment: .leading, spacing: 0) {
            row(p, display.isMain ? "\(display.name)（主屏）" : displays.displays.count > 1 ? "\(display.name)（扩展屏）" : display.name, subtitle,
                icon: display.builtIn ? "laptopcomputer" : "display", tint: Color(hex: 0x0A84FF)) {
                if hiDPI != .none {
                    HStack(spacing: 8) {
                        Text("HiDPI 支持").font(Typo.settingsBody).foregroundStyle(p.text2)
                        Toggle2(isOn: hiDPI == .on) { setHiDPI($0, on: display) }
                    }
                    .disabled(displays.busy)
                } else if let note = hiDPINote(display) {
                    // 没有开关的屏幕也说明一下原因，免得让人以为功能缺了
                    Text(note).font(Typo.settingsCaption).foregroundStyle(p.text3)
                }
            }
            if showSizes { sizePicker(p, display, options) }
        }
    }

    /// 没有 HiDPI 开关时，右侧显示的说明。
    private func hiDPINote(_ display: DisplayManager.Display) -> String? {
        guard display.canSwitch else { return nil }
        if display.builtIn || display.hasHiDPIChoices { return "系统已支持 HiDPI" }
        if displays.overrides[display.id]?.installed == true { return "已有其他工具的显示配置" }
        return nil
    }

    /// HiDPI 的渲染说明：渲染尺寸比屏幕像素大时要再缩小显示，提醒会多占 GPU；正好等于屏幕像素时最省也最清晰。
    private func renderNote(_ mode: DisplayManager.Mode, _ display: DisplayManager.Display) -> String {
        guard let native = display.native else { return "" }
        if mode.pixelWidth < native.width - 8 {
            return "按 \(mode.renderingSize) 绘制后放大显示，会发虚"
        }
        guard mode.pixelWidth > native.width + 8 else { return "按屏幕原生像素绘制，最清晰" }
        return "文字更清晰，显卡负担稍高（按 \(mode.renderingSize) 绘制）"
    }

    private func setHiDPI(_ on: Bool, on display: DisplayManager.Display) {
        if on {
            guard confirmAlert("为 \(display.name) 开启 HiDPI？",
                               "需要输入管理员密码，为这块屏写一份显示配置，补上系统没有的 HiDPI 档位（只写入或删除 islet 自己的配置）。开启后屏幕会断开再接上一次，然后切到推荐的大小。随时可以关掉。") else { return }
            displays.addHiDPI(display)
        } else {
            guard confirmAlert("关闭 \(display.name) 的 HiDPI？",
                               "需要输入管理员密码。关闭后这块屏会断开再接上一次，回到系统自带的分辨率。") else { return }
            displays.removeHiDPI(display)
        }
    }

    /// 一排档位卡片：原生在最左，往右文字越来越大。每张卡片依次是分辨率、文字说明、界面放大比例（次要）。
    /// 只列最合适的几档（见 DisplayManager.Display.choices），普通分辨率和不合适的 HiDPI 档位都不列。
    private func sizePicker(_ p: Palette, _ display: DisplayManager.Display, _ options: [DisplayManager.Mode]) -> some View {
        return VStack(alignment: .trailing, spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(options) { mode in
                    let selected = mode.group == display.current.group
                    let label = display.label(mode)
                    let highlight = label == "推荐" || label == "默认"
                    Button { displays.choose(mode, on: display) } label: {
                        VStack(spacing: 3) {
                            Text(mode.size).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(selected ? p.accentText : p.text)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Text(label).font(Typo.settingsCaption)
                                .foregroundStyle(selected || highlight ? p.accentText : p.text2)
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Text(display.scale(mode))
                                .font(.system(size: 10)).monospacedDigit()
                                .foregroundStyle(p.text3.opacity(0.7))
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9).padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? p.accentFill.opacity(0.14) : p.inset))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? p.accentFill.opacity(0.6) : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(mode.size)，\(label)，界面 \(display.scale(mode))")
                }
            }
        }
        .padding(.leading, 42)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .disabled(displays.busy)
    }

    private var updateTitle: String {
        switch model.update {
        case .available(let release): return "有新版本 \(release.version)"
        case .latest: return "已是最新版本"
        default: return "软件更新"
        }
    }

    private var updateSubtitle: String? {
        switch model.update {
        case .checking: return "正在查询 GitHub…"
        case .failed: return "检查失败，请检查网络后再试"
        case .available(let release):
            switch updater.phase {
            case .downloading(let fraction, _): return "正在下载 \(Int(fraction * 100))%"
            case .ready: return "已下载好，重启后生效"
            case .failed: return "更新失败，点“查看”重试"
            case .idle: return release.summary.isEmpty ? nil : release.summary
            }
        case .latest: return nil
        case .idle: return "从 GitHub 查询是否有新版本"
        }
    }

    @ViewBuilder private func aboutPage(_ p: Palette) -> some View {
        // 头部：图标、名称、版本、简介
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(AppInfo.name).font(.system(size: 22, weight: .bold)).foregroundStyle(p.text)
                    Text("v" + AppInfo.version).font(Typo.settingsCaption).foregroundStyle(p.text3)
                }
                Text(AppInfo.summary).font(Typo.settingsBody).foregroundStyle(p.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
        section(p, "项目") {
            row(p, "\(AppInfo.author) / islet", "GitHub 开源项目", icon: "chevron.left.forwardslash.chevron.right", tint: Color(hex: 0x1C1C1E)) {
                HStack(spacing: 8) {
                    PlainButton(title: "官网") { NSWorkspace.shared.open(AppInfo.website) }
                    PlainButton(title: "GitHub") { NSWorkspace.shared.open(AppInfo.homepage) }
                    PlainButton(title: model.stars.map { "⭐ Star · \($0)" } ?? "⭐ Star") { NSWorkspace.shared.open(AppInfo.homepage) }
                    PlainButton(title: model.showDonate ? "☕️ 收起" : "☕️ 打赏", prominent: model.showDonate) {
                        withAnimation(.easeInOut(duration: 0.2)) { model.showDonate.toggle() }
                    }
                }
                .fixedSize()
            }
            // 打赏：点了才展开
            if model.showDonate {
                divider(p)
                VStack(spacing: 8) {
                    Text("如果 islet 对你有帮助，可以请作者喝杯咖啡").font(Typo.settingsCaption).foregroundStyle(p.text3)
                    HStack(spacing: 28) {
                        donateCode(p, "alipay", "支付宝", Color(hex: 0x1677FF))
                        donateCode(p, "wechat", "微信", Color(hex: 0x07C160))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
        .onAppear {
            if !flat { AppInfo.fetchStars { model.stars = $0 } }
            // 打开关于页时悄悄查一次：重启后内存里没有新版本信息（自动检查一天才一次）；发版后改过说明或又发了新版也能跟上
            if model.update != .checking, updater.phase == .idle {
                UpdateChecker.check { state in if state != .checking, state != .failed { model.update = state } }
            }
        }
        section(p, "更新") {
            row(p, updateTitle, updateSubtitle, icon: "arrow.triangle.2.circlepath", tint: Color(hex: 0x0A84FF)) {
                if case .available(let release) = model.update {
                    PlainButton(title: "查看", prominent: true) { UpdateWindow.shared.show(release) }
                } else {
                    PlainButton(title: model.update == .checking ? "检查中…" : model.update == .failed ? "重试" : "检查更新") {
                        UpdateChecker.check { model.update = $0 }
                    }
                    .disabled(model.update == .checking)
                }
            }
            divider(p)
            row(p, "自动检查更新", nil, icon: "bell.badge", tint: Color(hex: 0xFF9F0A)) {
                toggle("autoCheckUpdates", default: true)
            }
        }
        section(p, "诊断") {
            row(p, Diagnostics.summary(), "反馈时自动复制报告，粘贴即可", icon: "stethoscope", tint: Color(hex: 0xFF453A)) {
                HStack(spacing: 8) {
                    PlainButton(title: model.diagnosticsNote ?? "复制报告", systemImage: "doc.on.doc",
                                action: model.onCopyDiagnostics)
                    PlainButton(title: "反馈问题", systemImage: "exclamationmark.bubble") {
                        model.onCopyDiagnostics()
                        NSWorkspace.shared.open(AppInfo.issuesURL)
                    }
                }
                .fixedSize()
            }
        }
    }

    /// 打赏二维码（随程序打包在 Resources 里）：白底圆角卡片，中间是支付方式的图标，下面一行带品牌色圆点的名字。
    @ViewBuilder private func donateCode(_ p: Palette, _ name: String, _ title: String, _ tint: Color) -> some View {
        if let image = Bundle.main.image(forResource: name) {
            VStack(spacing: 8) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 148, height: 148)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(p.separator, lineWidth: 1))
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                    Text(title).font(Typo.settingsCaption).foregroundStyle(p.text2)
                }
            }
        }
    }

    private var basisSubtitle: String {
        let reading = model.controlTemperatures
        switch fanClient.config.basis {
        case .peak:
            return "CPU/GPU 最热点" + (reading.map { " · \(Int($0.peak.rounded()))℃" } ?? "")
        case .average:
            return "CPU/GPU 均温" + (reading.map { " · \(Int($0.average.rounded()))℃" } ?? "")
        }
    }

    private var componentSubtitle: String {
        if !fanClient.isInstalled { return "未安装，调速需要" }
        if !fanClient.isHelperCurrent { return "版本不一致，需要更新" }
        return "已安装，正常"
    }

    private func section<Content: View>(_ p: Palette, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Typo.bodyMedium).foregroundStyle(p.text2)
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 0) { content() }
            }
        }
    }

    private func row<Control: View>(_ p: Palette, _ title: String, _ subtitle: String?, icon: String? = nil, tint: Color = Color(hex: 0x0A84FF),
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon { IconTile(symbol: icon, tint: tint, size: 30) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.settingsBody).foregroundStyle(p.text)
                if let subtitle {
                    Text(subtitle).font(Typo.settingsCaption).foregroundStyle(p.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 6)
    }

    /// 风扇详情里“编辑 / 收起”：就地展开编辑器。
    private func editToggle(_ id: String, onOpen: @escaping () -> Void) -> some View {
        let open = model.expanded.contains(id)
        return PlainButton(title: open ? "收起" : "编辑") {
            if open { model.expanded.remove(id) } else { onOpen(); model.expanded.insert(id) }
        }
    }

    private func divider(_ p: Palette) -> some View {
        Rectangle().fill(p.separator).frame(height: 1)
    }
}

// MARK: - 温度曲线

final class CurveEditorModel: ObservableObject {
    @Published var points: [CurvePoint] = []
    @Published var selected: Int?
    @Published var currentCelsius: Double?
    let minimum: Double
    let maximum: Double

    var onActivate: () -> Void = {}

    init(minimum: Double, maximum: Double) {
        self.minimum = minimum
        self.maximum = maximum
        points = FanHelperClient.shared.config.curve
    }

    /// 保存到配置；若当前就是曲线策略，立即生效。
    func commit(preset: CurvePreset? = nil) {
        let points = self.points
        FanHelperClient.shared.update { config in
            config.curve = points
            config.preset = preset
        }
    }

    func apply(_ preset: CurvePreset) {
        points = preset.points(minimum: minimum, maximum: maximum)
        selected = nil
        commit(preset: preset)
    }

    func addPointAtCurrent() {
        let celsius = (currentCelsius ?? 70).rounded()
        guard !points.contains(where: { abs($0.celsius - celsius) < 2 }) else { return }
        let rpm = FanCurve.rpm(points, at: celsius) ?? minimum
        points.append(CurvePoint(celsius: celsius, rpm: rpm.rounded()))
        points.sort { $0.celsius < $1.celsius }
        selected = points.firstIndex { $0.celsius == celsius }
        commit()
    }

    func deleteSelected() {
        guard let selected, points.count > 2 else { return }
        points.remove(at: selected)
        self.selected = nil
        commit()
    }
}

struct CurveEditorView: View {
    @ObservedObject var model: CurveEditorModel
    /// 内嵌在设置里：不要标题、外边距和固定宽度。
    var embedded = false
    @ObservedObject var fanClient = FanHelperClient.shared
    private let domain: ClosedRange<Double> = 30...100

    var body: some View {
        Themed { p in
            VStack(alignment: .leading, spacing: embedded ? 10 : 14) {
                if !embedded {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("温度曲线").font(.system(size: 20, weight: .semibold)).foregroundStyle(p.text)
                        Text(fanClient.config.preset?.label ?? "自定义")
                            .font(Typo.captionMedium).foregroundStyle(p.accentText)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(p.accentFill.opacity(0.16)))
                        Spacer()
                        if let celsius = model.currentCelsius {
                            Text("\(fanClient.config.basis == .peak ? "最热" : "均温") \(Int(celsius.rounded()))℃")
                                .font(Typo.captionMedium).foregroundStyle(p.temperature(celsius))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(p.inset))
                        }
                    }
                }

                chart(p)
                    .frame(height: embedded ? 220 : 300)
                    .background(RoundedRectangle(cornerRadius: 10).fill(p.card))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.cardStroke))

                HStack(spacing: 8) {
                    if !embedded { Text("预设").font(Typo.settingsCaption).foregroundStyle(p.text3) }
                    ForEach(CurvePreset.allCases, id: \.self) { preset in
                        presetCard(p, preset)
                    }
                }

                HStack(spacing: 8) {
                    PlainButton(title: embedded ? "加点" : "在当前温度加点", systemImage: "plus.circle", action: model.addPointAtCurrent)
                    PlainButton(title: embedded ? "删除" : "删除选中点", systemImage: "minus.circle",
                                disabled: model.selected == nil || model.points.count <= 2, action: model.deleteSelected)
                    Spacer()
                    Text("\(model.points.count) 个控制点").font(Typo.settingsCaption).foregroundStyle(p.text3)
                    if fanClient.config.strategy != .curve {
                        PlainButton(title: embedded ? "启用" : "使用曲线调速", prominent: true, action: model.onActivate)
                    } else {
                        Text("曲线调速中").font(Typo.captionMedium).foregroundStyle(p.accentText)
                    }
                }
            }
            .padding(embedded ? 0 : 22)
            .frame(width: embedded ? nil : 640)
            .background(embedded ? Color.clear : p.panel)
        }
    }

    private func presetCard(_ p: Palette, _ preset: CurvePreset) -> some View {
        let selected = fanClient.config.preset == preset
        return Button { model.apply(preset) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.label).font(Typo.bodyMedium).foregroundStyle(selected ? p.accentText : p.text)
                if !embedded { Text(preset.detail).font(Typo.settingsCaption).foregroundStyle(p.text3).lineLimit(1) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? p.accentFill.opacity(0.14) : p.card))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? p.accentFill.opacity(0.6) : p.cardStroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chart(_ p: Palette) -> some View {
        GeometryReader { geo in
            let inset = EdgeInsets(top: 16, leading: 52, bottom: 28, trailing: 18)
            let plot = CGRect(x: inset.leading, y: inset.top,
                              width: geo.size.width - inset.leading - inset.trailing,
                              height: geo.size.height - inset.top - inset.bottom)
            let x = { (c: Double) -> CGFloat in plot.minX + CGFloat((c - domain.lowerBound) / (domain.upperBound - domain.lowerBound)) * plot.width }
            let y = { (r: Double) -> CGFloat in plot.maxY - CGFloat((r - model.minimum) / max(model.maximum - model.minimum, 1)) * plot.height }
            let celsiusAt = { (px: CGFloat) -> Double in domain.lowerBound + Double((px - plot.minX) / plot.width) * (domain.upperBound - domain.lowerBound) }
            let rpmAt = { (py: CGFloat) -> Double in model.minimum + Double((plot.maxY - py) / plot.height) * (model.maximum - model.minimum) }

            ZStack(alignment: .topLeading) {
                // 网格与坐标
                Path { path in
                    for step in 0...4 {
                        let yy = plot.minY + plot.height * CGFloat(step) / 4
                        path.move(to: CGPoint(x: plot.minX, y: yy)); path.addLine(to: CGPoint(x: plot.maxX, y: yy))
                    }
                    for c in stride(from: 30.0, through: 100, by: 10) {
                        path.move(to: CGPoint(x: x(c), y: plot.minY)); path.addLine(to: CGPoint(x: x(c), y: plot.maxY))
                    }
                }
                .stroke(p.separator, lineWidth: 1)
                ForEach(0...4, id: \.self) { step in
                    let rpm = model.maximum - (model.maximum - model.minimum) * Double(step) / 4
                    Text(String(Int(rpm))).font(Typo.settingsCaption).foregroundStyle(p.text3)
                        .frame(width: 44, alignment: .trailing)
                        .position(x: plot.minX - 28, y: plot.minY + plot.height * CGFloat(step) / 4)
                }
                ForEach(Array(stride(from: 30, through: 100, by: 10)), id: \.self) { c in
                    Text("\(c)°").font(Typo.settingsCaption).foregroundStyle(p.text3)
                        .position(x: x(Double(c)), y: plot.maxY + 14)
                }

                // 安全下限：斜纹带 + 虚线（中性色：表示“画不到的地方”，不是危险区）
                let floorPath = Path { path in
                    path.move(to: CGPoint(x: plot.minX, y: plot.maxY))
                    for c in stride(from: domain.lowerBound, through: domain.upperBound, by: 1) {
                        path.addLine(to: CGPoint(x: x(c), y: y(FanSafety.floor(celsius: c, minimum: model.minimum, maximum: model.maximum))))
                    }
                    path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                    path.closeSubpath()
                }
                Path { path in
                    var offset = -plot.height
                    while offset < plot.width {
                        path.move(to: CGPoint(x: plot.minX + offset, y: plot.maxY))
                        path.addLine(to: CGPoint(x: plot.minX + offset + plot.height, y: plot.minY))
                        offset += 7
                    }
                }
                .stroke(p.text3.opacity(0.35), lineWidth: 1)
                .clipShape(floorPath)
                Path { path in
                    for (index, c) in stride(from: domain.lowerBound, through: domain.upperBound, by: 1).enumerated() {
                        let point = CGPoint(x: x(c), y: y(FanSafety.floor(celsius: c, minimum: model.minimum, maximum: model.maximum)))
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(p.text3, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                // 当前温度
                if let celsius = model.currentCelsius, domain.contains(celsius) {
                    Path { path in
                        path.move(to: CGPoint(x: x(celsius), y: plot.minY)); path.addLine(to: CGPoint(x: x(celsius), y: plot.maxY))
                    }
                    .stroke(p.text2, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }

                // 曲线：区间外取端点值，所以两端延伸到坐标边界
                let curvePoints = [CGPoint(x: plot.minX, y: y(model.points.first?.rpm ?? model.minimum))]
                    + model.points.map { CGPoint(x: x(min(max($0.celsius, domain.lowerBound), domain.upperBound)), y: y($0.rpm)) }
                    + [CGPoint(x: plot.maxX, y: y(model.points.last?.rpm ?? model.maximum))]
                Path { path in
                    path.move(to: CGPoint(x: plot.minX, y: plot.maxY))
                    curvePoints.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                    path.closeSubpath()
                }
                .fill(p.accentFill.opacity(0.12))
                Path { path in
                    path.addLines(curvePoints)
                }
                .stroke(p.accentFill, style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                // 控制点：可拖动；温度限制在相邻点之间，转速不低于该温度的安全下限
                ForEach(model.points.indices, id: \.self) { index in
                    let point = model.points[index]
                    let selected = model.selected == index
                    Circle()
                        .fill(p.card)
                        .overlay(Circle().stroke(p.accentFill, lineWidth: selected ? 3 : 2))
                        .frame(width: selected ? 14 : 11, height: selected ? 14 : 11)
                        .position(x: x(point.celsius), y: y(point.rpm))
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                model.selected = index
                                let lower = index > 0 ? model.points[index - 1].celsius + 1 : domain.lowerBound
                                let upper = index < model.points.count - 1 ? model.points[index + 1].celsius - 1 : domain.upperBound
                                let celsius = min(max(celsiusAt(drag.location.x).rounded(), lower), upper)
                                let floor = FanSafety.floor(celsius: celsius, minimum: model.minimum, maximum: model.maximum)
                                let rpm = min(max((rpmAt(drag.location.y) / 10).rounded() * 10, floor), model.maximum)
                                model.points[index] = CurvePoint(celsius: celsius, rpm: rpm)
                            }
                            .onEnded { _ in model.commit() })
                        .help("\(Int(point.celsius))℃ → \(Int(point.rpm)) 转")
                }
            }
        }
    }
}

// MARK: - 规则

struct RulesView: View {
    @ObservedObject var fanClient = FanHelperClient.shared
    let fan: FanData?
    /// 走查用：不包 ScrollView、不固定高度。
    var flat = false
    /// 内嵌在设置里：不要标题、外边距和固定尺寸。
    var embedded = false
    var onActivate: () -> Void = {}

    var body: some View {
        Themed { p in
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    if !embedded { Text("规则").font(.system(size: 20, weight: .semibold)).foregroundStyle(p.text) }
                }
                if flat || embedded { ruleList(p) } else { ScrollView { ruleList(p) } }
                HStack(spacing: 8) {
                    PlainButton(title: "添加规则", systemImage: "plus", disabled: fanClient.config.rules.count >= 16) {
                        let rpm = fan.map { ($0.minimum + ($0.maximum - $0.minimum) * 0.6).rounded() } ?? 3000
                        fanClient.update { $0.rules.append(FanRule(threshold: 80, rpm: rpm)) }
                    }
                    Spacer()
                    if fanClient.config.strategy != .rules {
                        PlainButton(title: "使用规则调速", prominent: true, action: onActivate)
                    } else {
                        Text("规则调速中").font(Typo.captionMedium).foregroundStyle(p.accentText)
                    }
                }
            }
            .padding(embedded ? 0 : 22)
            .frame(width: embedded ? nil : 580, height: flat || embedded ? nil : 440)
            .background(embedded ? Color.clear : p.panel)
        }
    }

    private func ruleList(_ p: Palette) -> some View {
        VStack(spacing: 8) {
            ForEach(fanClient.config.rules) { rule in
                ruleCard(p, rule)
            }
            if fanClient.config.rules.isEmpty {
                Text("还没有规则").font(Typo.settingsBody).foregroundStyle(p.text3).padding(.vertical, 20)
            }
        }
    }

    private func ruleCard(_ p: Palette, _ rule: FanRule) -> some View {
        let triggered = fanClient.status?.triggered.contains(rule.id) == true
        return Card(padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Toggle2(isOn: rule.enabled) { on in edit(rule) { $0.enabled = on } }
                    Text("当").font(Typo.settingsBody).foregroundStyle(p.text2)
                    Menu(rule.group) {
                        ForEach(Temperatures.groupNames, id: \.self) { name in
                            Button(name) { edit(rule) { $0.group = name } }
                        }
                    }
                    .frame(width: embedded ? 130 : 96)
                    Menu(rule.peak ? "最高" : "平均") {
                        Button("平均") { edit(rule) { $0.peak = false } }
                        Button("最高") { edit(rule) { $0.peak = true } }
                    }
                    .frame(width: embedded ? 72 : 56)
                    if !embedded { valueControls(p, rule) }
                    Spacer(minLength: 0)
                    Button { fanClient.update { $0.rules.removeAll { $0.id == rule.id } } } label: {
                        Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(p.text3)
                    }
                    .buttonStyle(.plain)
                    .help("删除规则")
                }
                if embedded { valueControls(p, rule).padding(.leading, 36) }
                HStack(spacing: 6) {
                    if triggered {
                        Text("已触发").font(Typo.captionMedium).foregroundStyle(p.accentText)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(p.accentFill.opacity(0.16)))
                    }
                    Text("回落到 \(Int(rule.threshold - rule.hysteresis))℃ 以下才解除（迟滞 \(Int(rule.hysteresis))℃）")
                        .font(Typo.settingsCaption).foregroundStyle(p.text3)
                }
                .padding(.leading, 36)
            }
        }
        .opacity(rule.enabled ? 1 : 0.6)
    }

    /// 阈值和目标转速；内嵌在设置里时放到第二行。
    private func valueControls(_ p: Palette, _ rule: FanRule) -> some View {
        HStack(spacing: 6) {
            Text("≥").font(Typo.settingsBody).foregroundStyle(p.text2)
            Stepper2(value: rule.threshold, step: 1, range: 20...120, unit: "℃", width: 30) { value in
                edit(rule) { $0.threshold = value }
            }
            Text("→").font(Typo.settingsBody).foregroundStyle(p.text2)
            Stepper2(value: rule.rpm, step: 100, range: (fan?.minimum ?? 0)...(fan?.maximum ?? 10000), unit: "转", width: 40) { value in
                edit(rule) { $0.rpm = value }
            }
        }
    }

    private func edit(_ rule: FanRule, _ change: @escaping (inout FanRule) -> Void) {
        fanClient.update { config in
            guard let index = config.rules.firstIndex(where: { $0.id == rule.id }) else { return }
            change(&config.rules[index])
        }
    }
}

/// 指标行拖动排序：拖过某一行时实时换位，松手后保存。
/// 收集各行在列表里的位置。
struct RowFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 一条提醒规则的编辑行：开关、指标、阈值、持续时间、删除。
struct AlertRuleRow: View {
    @Binding var rule: AlertRule
    let onChange: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Themed { p in
            HStack(spacing: 8) {
                Toggle2(isOn: rule.enabled) { on in rule.enabled = on; onChange() }
                Menu(rule.kind.title) {
                    ForEach(AlertRule.Kind.allCases, id: \.self) { kind in
                        Button(kind.title) {
                            rule.kind = kind
                            rule.threshold = kind.defaultThreshold
                            onChange()
                        }
                    }
                }
                .frame(width: 72)
                Text("≥").font(Typo.settingsBody).foregroundStyle(p.text2)
                Menu(thresholdText) {
                    ForEach(choices, id: \.self) { value in
                        Button(label(value)) { rule.threshold = value; onChange() }
                    }
                }
                .frame(width: 84)
                Text("持续").font(Typo.settingsBody).foregroundStyle(p.text2)
                Menu("\(rule.minutes) 分钟") {
                    ForEach([1, 3, 5, 10, 30], id: \.self) { minutes in
                        Button("\(minutes) 分钟") { rule.minutes = minutes; onChange() }
                    }
                }
                .frame(width: 84)
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(p.text3)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("删除这条规则")
            }
            .padding(.vertical, 4)
            .opacity(rule.enabled ? 1 : 0.55)
        }
    }

    /// 各指标可选的阈值。
    private var choices: [Double] {
        switch rule.kind {
        case .cpu, .gpu: return [50, 70, 80, 90, 95]
        case .temperature: return [70, 80, 85, 90, 95, 100]
        case .power: return [20, 30, 40, 60, 80, 100]
        case .memory: return [8, 12, 14, 16, 20, 24, 32]
        }
    }

    private func label(_ value: Double) -> String {
        rule.kind == .temperature ? Units.degrees(value) : "\(Int(value)) \(rule.kind.unit)"
    }

    private var thresholdText: String { label(rule.threshold) }
}
