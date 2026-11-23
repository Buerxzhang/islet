import AppKit
import SwiftUI

// 弹出面板：数据模型 + SwiftUI 视图。所有指标共用同一套布局（FunFan 风格）：
// 头部（图标 + 标题 + 设置）→ 主数据卡（圆环 + 键值）→ 指标专属内容 → 排行卡 → 底栏（采样耗时 · 诊断 · 退出）。

// MARK: - 数据

struct HeroData {
    var fraction: Double?
    /// 压力等级（CPU、GPU、内存、磁盘、温度）：圆环绿 / 橙 / 红；nil 时用这一项的固定颜色
    var level: StatusIcons.Level?
    var value = "—"
    var unit = ""
    var rows: [(String, String)] = []
}

struct RankRowData: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
    let values: [String]
    let share: Double                // 0...1，名称下方的占比条
    let dim: Bool
    let tooltip: String
    let pids: [Int32]
    let canTerminate: Bool
}

struct FanData {
    var current: Double
    var minimum: Double
    var maximum: Double
}

final class PanelModel: ObservableObject {
    @Published var metric: Metric = .network
    @Published var hero = HeroData()
    @Published var rows: [RankRowData] = []
    @Published var message: String? = "正在采样…"
    @Published var sampleMillis: Int?
    @Published var groups: [Temperatures.Group] = []
    @Published var sensorCount = 0
    @Published var details: [(name: String, readings: [(key: String, celsius: Double)])] = []
    @Published var expanded = false
    @Published var fan: FanData?
    @Published var fixedDraft: Double?           // 拖动固定转速滑块时的预览值
    @Published var footerNote: String?           // “已复制诊断信息”等临时提示
    @Published var strategyError: String?
    var flatRender = false                       // 走查渲染时不用滚动视图（离屏渲染画不出滚动内容）
    // 历史曲线：最近 N 个采样点；网速、磁盘有第二条线（上传 / 写入）
    @Published var history: [Double] = []
    @Published var history2: [Double]?
    @Published var historyCaption = ""
    @Published var historyPeak = ""
    /// 网速面板的连接信息（公网 IP、Wi-Fi、延迟）。
    @Published var connection: NetworkDetails.Info?
    /// 磁盘面板：硬盘健康；功耗面板：笔记本电池（台式机为 nil）。
    @Published var drives: [DriveHealth] = []
    @Published var battery: BatteryInfo?
    /// 走势范围：0 = 5 分钟，1 = 1 小时，2 = 24 小时。
    @Published var historyRange = UserDefaults.standard.integer(forKey: "historyRange")
    var onHistoryRange: () -> Void = {}
    // 结束进程
    @Published var hovered: String?
    @Published var confirming: String?               // 已点 ⊗、等待“确认退出”的行
    /// 鼠标在排行卡片内时冻结列表：每 2 秒重排会让行在鼠标下移动，导致点错程序。
    @Published var frozen = false {
        didSet {
            guard !frozen, let pending = pendingRanking else { return }
            pendingRanking = nil
            setRanking(pending.apps, format: pending.format)
        }
    }
    private var pendingRanking: (apps: [RankedApp], format: (Double) -> String)?
    @Published var quitting: Set<String> = []        // 已请求退出、等待确认的行
    @Published var forceable: Set<String> = []       // 请求退出后仍在运行，可强制结束
    // 网速：今日 / 本月流量；磁盘：外接卷
    @Published var traffic: TrafficLedger.Totals?
    @Published var volumes: [ExternalVolume] = []
    @Published var ejecting: Set<String> = []

    var onSettings: () -> Void = {}
    var onDiagnostics: () -> Void = {}
    var onQuit: () -> Void = {}
    var onSelectStrategy: (FanStrategy) -> Void = { _ in }
    var onFixedCommit: (Double) -> Void = { _ in }
    var onSelectPreset: (CurvePreset) -> Void = { _ in }
    var onToggleExpanded: () -> Void = {}
    var onQuitApp: (RankRowData) -> Void = { _ in }
    var onForceQuit: (RankRowData) -> Void = { _ in }
    var onEject: (ExternalVolume) -> Void = { _ in }

    func group(_ name: String) -> Temperatures.Group? { groups.first { $0.name == name } }

    /// Wine 等环境里的 Windows 程序路径，如 Z:\\Users\\…\\Game.exe 或 Z:/Users/…/Game.exe。
    static func isWindowsPath(_ identity: String) -> Bool {
        let chars = Array(identity.prefix(3))
        return chars.count == 3 && chars[0].isLetter && chars[1] == ":" && (chars[2] == "\\" || chars[2] == "/")
    }

    /// 把排行数据转成行：名称、图标、格式化数值、占比条。
    func setRanking(_ apps: [RankedApp], format: @escaping (Double) -> String) {
        if frozen {
            pendingRanking = (apps, format)  // 冻结期间只记下最新数据，鼠标离开后再刷新
            return
        }
        let peak = apps.map { $0.values.reduce(0, +) }.max() ?? 0
        rows = apps.map { app in
            let (name, icon) = AppIcons.shared.info(for: app.identity, metric: metric)
            let total = app.values.reduce(0, +)
            return RankRowData(id: app.identity, name: name, icon: icon, values: app.values.map(format),
                               share: peak > 0 ? total / peak : 0, dim: total < 0.5,
                               tooltip: app.identity.hasPrefix("/") || Self.isWindowsPath(app.identity) ? app.identity : name,
                               pids: app.pids, canTerminate: ProcessControl.canTerminate(app.identity, pids: app.pids))
        }
    }
}

/// 应用名称与图标缓存（.app 用应用图标，其他进程用齿轮）。
final class AppIcons {
    static let shared = AppIcons()
    private var cache: [String: (String, NSImage)] = [:]

    func info(for identity: String, metric: Metric) -> (String, NSImage) {
        if let cached = cache[identity] { return cached }
        let gear = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) ?? NSImage()
        let info: (String, NSImage)
        if identity.hasSuffix(".app") {
            let url = URL(fileURLWithPath: identity)
            let values = try? url.resourceValues(forKeys: [.localizedNameKey])
            let display = values?.localizedName ?? url.lastPathComponent
            info = (display.hasSuffix(".app") ? String(display.dropLast(4)) : display,
                    Self.rasterize(NSWorkspace.shared.icon(forFile: identity)))
        } else if identity.hasPrefix("/") {
            info = (URL(fileURLWithPath: identity).lastPathComponent, gear)
        } else if PanelModel.isWindowsPath(identity) || identity.contains("\\") {
            // Wine 等环境里的 Windows 程序：路径用 \ 或 / 分隔，只显示文件名
            info = (String(identity.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? Substring(identity)), gear)
        } else {
            info = (identity, gear)
        }
        cache[identity] = info
        return info
    }

    /// 系统应用图标是多分辨率的图标表示，SwiftUI 离屏渲染遇到它会整体变暗；
    /// 先画成 32×32 位图（16pt @2x），显示与渲染都更稳定，也更省。
    static func rasterize(_ icon: NSImage) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return icon }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        icon.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }
}

extension Metric {
    var symbol: String {
        switch self {
        // 面板标题、设置里的图标块共用同一套图标
        case .network: return "arrow.up.arrow.down"
        case .cpu: return "cpu"
        case .gpu: return "square.stack.3d.up"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .power: return "bolt"
        case .fan: return "fan"
        case .temperature: return "thermometer.medium"
        case .fps: return "gauge.with.needle"
        }
    }

    /// 变色阈值，岛和面板共用：value 为 CPU / GPU / 磁盘 0...1、温度 ℃、内存压力（1 正常 / 2 偏高 / 4 严重）。
    /// 功耗、风扇、帧率、网速没有压力，总是 normal。
    func level(_ value: Double?) -> StatusIcons.Level {
        guard let value else { return .normal }
        switch self {
        case .cpu, .gpu: return value >= 0.9 ? .critical : value >= 0.7 ? .warning : .normal
        case .temperature: return value >= 95 ? .critical : value >= 80 ? .warning : .normal
        case .memory: return value >= 4 ? .critical : value >= 2 ? .warning : .normal
        case .disk: return value >= 0.95 ? .critical : value >= 0.85 ? .warning : .normal
        default: return .normal
        }
    }

    /// 每项固定的颜色（和设置里的图标块一致）：面板标题图标；没有“压力”的项（功耗、风扇、帧率、网速）圆环和走势线也用它。
    var tint: Color {
        switch self {
        case .cpu, .network: return Color(hex: 0x0A84FF)
        case .gpu: return Color(hex: 0x5E5CE6)
        case .memory: return Color(hex: 0x30D158)
        case .disk: return Color(hex: 0x8E8E93)
        case .power: return Color(hex: 0xFFB800)
        case .temperature: return Color(hex: 0xFF9F0A)
        case .fan: return Color(hex: 0x30B0C7)
        case .fps: return Color(hex: 0xFF375F)
        }
    }

    var panelTitle: String {
        switch self {
        case .network: return "网速"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "内存"
        case .disk: return "磁盘"
        case .power: return "功耗"
        case .fan: return "风扇"
        case .temperature: return "温度"
        case .fps: return "帧率"
        }
    }

    /// 排行卡标题；温度面板没有应用排行。
    var rankingTitle: String? {
        switch self {
        case .network: return "应用流量"
        case .cpu: return "CPU 占用"
        case .gpu: return "GPU 占用"
        case .memory: return "内存占用"
        case .disk: return "磁盘读写"
        case .power: return "应用功耗"
        case .fan: return "发热来源"
        case .temperature, .fps: return nil
        }
    }
}

// MARK: - 视图

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var fanClient = FanHelperClient.shared

    var body: some View {
        Themed { p in
            VStack(alignment: .leading, spacing: 12) {
                header(p)
                heroCard(p)
                switch model.metric {
                case .fan:
                    thermalSection(p, expandable: true)
                    strategySection(p)
                    rankingCard(p, limit: 3)
                case .temperature:
                    thermalSection(p, expandable: false)
                    groupsCard(p)
                case .network:
                    connectionCard(p)
                    rankingCard(p, limit: nil)
                case .disk:
                    drivesCard(p)
                    volumesCard(p)
                    rankingCard(p, limit: nil)
                case .power:
                    batteryCard(p)
                    keepAwakeCard(p)
                    rankingCard(p, limit: nil)
                case .fps:
                    fpsNoteCard(p)
                default:
                    rankingCard(p, limit: nil)
                }
                footer(p)
            }
            .padding(14)
            .frame(width: 320)
            .background(p.panel)
        }
    }

    /// 帧率面板的说明：测的是什么、什么时候数字会低。
    private func fpsNoteCard(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "说明")
            Card(padding: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(["统计前台窗口所在屏幕每秒画面变化的次数，islet 自己的岛和面板不计入。",
                             "屏幕上任何地方在动都会算进去，比如角落里播放的视频。",
                             "画面静止时（暂停、停在菜单）数字会变低，不代表卡顿。",
                             "需要屏幕录制权限；只数画面变化，不保存、不上传画面。"], id: \.self) { line in
                        Text(line).font(Typo.caption).foregroundStyle(p.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 头部

    private func header(_ p: Palette) -> some View {
        HStack(spacing: 8) {
            // 图标和设置里的图标块同一个，这里只画彩色图标、不带底块
            Image(systemName: model.metric.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(model.metric.tint)
                .frame(width: 20)
            Text(model.metric.panelTitle).font(Typo.title).foregroundStyle(p.text)
            Spacer()
            Button(action: model.onSettings) {
                Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(p.text2)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("设置")
        }
    }

    // MARK: 主数据卡

    private func heroCard(_ p: Palette) -> some View {
        let hero = model.hero
        let color: Color? = {
            switch hero.level {
            case nil: return model.metric.tint
            case .normal: return p.cool
            case .warning: return p.warm
            case .critical: return p.hot
            }
        }()
        return Card(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 18) {
                    Ring(fraction: hero.fraction, value: hero.value, unit: hero.unit, color: color)
                    VStack(alignment: .leading, spacing: 9) {
                        if model.metric == .network, let traffic = model.traffic {
                            // 网速：圆环已是下载速率，右边放实时上传和今日 / 本月流量
                            if let upload = hero.rows.first(where: { $0.0 == "上传" }) { KeyValueRow(key: "上传", value: upload.1) }
                            trafficPair(p, "今日", traffic.dayDown, traffic.dayUp)
                            trafficPair(p, TrafficLedger.monthStart == 1 ? "本月" : "本期", traffic.monthDown, traffic.monthUp)
                        } else {
                            ForEach(hero.rows.indices, id: \.self) { index in
                                KeyValueRow(key: hero.rows[index].0, value: hero.rows[index].1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                if model.history.count >= 2 || model.historyRange > 0 { historyChart(p, color: color) }
            }
        }
    }

    /// 最近几分钟的走势（每次刷新一个点）。
    private func historyChart(_ p: Palette, color: Color?) -> some View {
        // 两条线（网速下载 / 上传、磁盘读取 / 写入）固定蓝 / 绿，和岛上的箭头一致；单线跟圆环同色
        let color = model.history2 != nil ? Metric.network.tint : color
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Segmented(options: [(0, "5 分"), (1, "1 时"), (2, "24 时")], selection: model.historyRange) { value in
                    model.historyRange = value
                    UserDefaults.standard.set(value, forKey: "historyRange")
                    model.onHistoryRange()
                }
                .frame(width: 128)
                Spacer(minLength: 0)
                if !model.historyCaption.isEmpty, model.historyRange > 0 {
                    Text(model.historyCaption).font(Typo.caption).foregroundStyle(p.text3).lineLimit(1)
                }
            }
            Sparkline(values: model.history, values2: model.history2, color: color ?? p.accentFill,
                      color2: p.cool, baseline: p.separator)
                .frame(height: 40)
            // 图例和峰值放在曲线下面一行，各自不换行
            HStack(spacing: 10) {
                if model.history2 != nil {
                    legend(p, color ?? p.accentFill, model.metric == .disk ? "读取" : "下载")
                    legend(p, p.cool, model.metric == .disk ? "写入" : "上传")
                }
                Spacer(minLength: 8)
                Text(model.historyPeak).font(Typo.caption).foregroundStyle(p.text3).lineLimit(1).fixedSize()
            }
        }
    }

    private func legend(_ p: Palette, _ color: Color, _ title: String) -> some View {
        HStack(spacing: 3) {
            Capsule().fill(color).frame(width: 8, height: 3)
            Text(title).font(Typo.caption).foregroundStyle(p.text3).lineLimit(1).fixedSize()
        }
    }

    // MARK: 网速：今日 / 本月流量

    /// 连接：网卡、Wi-Fi、公网 IP、延迟。
    @ViewBuilder private func connectionCard(_ p: Palette) -> some View {
        if let info = model.connection {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "连接")
                Card(padding: 10) {
                    VStack(spacing: 6) {
                        connectionRow(p, "公网 IP", info.publicIP ?? "查询中…")
                        Rectangle().fill(p.separator).frame(height: 1)
                        connectionRow(p, "Wi-Fi", info.wifi ?? "未使用")
                        Rectangle().fill(p.separator).frame(height: 1)
                        connectionRow(p, "延迟", info.latency.map { "\($0) ms" } ?? "测量中…",
                                      color: info.latency.map { $0 > 150 ? p.hot : $0 > 60 ? Color.orange : p.text })
                    }
                }
            }
        }
    }

    private func connectionRow(_ p: Palette, _ title: String, _ value: String, color: Color? = nil) -> some View {
        HStack {
            Text(title).font(Typo.body).foregroundStyle(p.text2)
            Spacer()
            Text(value).font(Typo.number(12, .medium)).foregroundStyle(color ?? p.text).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    /// 流量统计（物理网卡，程序运行期间）：显示下载 + 上传合计，和上面的数值一样大；悬停看分项。
    private func trafficPair(_ p: Palette, _ title: String, _ down: Double, _ up: Double) -> some View {
        KeyValueRow(key: title, value: Self.bytes(down + up))
            .help("下载 \(Self.bytes(down))，上传 \(Self.bytes(up))（物理网卡，程序运行期间）")
    }

    static func bytes(_ value: Double) -> String {
        switch value {
        case 1e12...: return String(format: "%.2f TB", value / 1e12)
        case 1e9...: return String(format: "%.2f GB", value / 1e9)
        case 1e6...: return String(format: "%.0f MB", value / 1e6)
        default: return String(format: "%.0f KB", value / 1e3)
        }
    }

    // MARK: 磁盘：外接磁盘

    /// 硬盘健康：每块 NVMe 硬盘的型号、容量、SMART 状态。
    @ViewBuilder private func drivesCard(_ p: Palette) -> some View {
        if !model.drives.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "硬盘健康", trailing: "SMART 自检")
                Card(padding: 10) {
                    VStack(spacing: 6) {
                        ForEach(Array(model.drives.enumerated()), id: \.element.id) { index, drive in
                            if index > 0 { Rectangle().fill(p.separator).frame(height: 1) }
                            HStack(spacing: 8) {
                                Image(systemName: "internaldrive").font(.system(size: 12)).foregroundStyle(p.text2).frame(width: 18)
                                Text(drive.model).font(Typo.body).foregroundStyle(p.text).lineLimit(1).truncationMode(.middle)
                                Text(drive.size).font(Typo.caption).foregroundStyle(p.text3)
                                Spacer()
                                Label(drive.status, systemImage: drive.healthy == false ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                                    .font(Typo.captionMedium)
                                    .foregroundStyle(drive.healthy == false ? p.hot : drive.healthy == true ? Color.green : p.text3)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 笔记本电池：电量、充电状态、健康度、循环次数。
    @ViewBuilder private func batteryCard(_ p: Palette) -> some View {
        if let battery = model.battery {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "电池")
                Card(padding: 10) {
                    VStack(spacing: 6) {
                        batteryRow(p, "电量", "\(battery.level)%" + (battery.charging ? " · 充电中" : ""))
                        Rectangle().fill(p.separator).frame(height: 1)
                        batteryRow(p, "健康度", battery.health.map { "\($0)%" } ?? "—")
                        Rectangle().fill(p.separator).frame(height: 1)
                        batteryRow(p, "循环次数", battery.cycles.map { "\($0) 次" } ?? "—")
                    }
                }
            }
        }
    }

    private func batteryRow(_ p: Palette, _ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(Typo.body).foregroundStyle(p.text2)
            Spacer()
            Text(value).font(Typo.number(12, .medium)).foregroundStyle(p.text)
        }
    }

    private func volumesCard(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "外接磁盘", trailing: model.volumes.isEmpty ? nil : "\(model.volumes.count) 个")
            Card(padding: 10) {
                VStack(spacing: 0) {
                    if model.volumes.isEmpty {
                        Text("没有外接磁盘或网络共享").font(Typo.body).foregroundStyle(p.text3)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }
                    ForEach(model.volumes) { volume in
                        HStack(spacing: 8) {
                            Image(nsImage: volume.icon).resizable().frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(volume.name).font(Typo.body).foregroundStyle(p.text).lineLimit(1)
                                Text(volumeDetail(volume)).font(Typo.caption).foregroundStyle(p.text3)
                            }
                            Spacer()
                            PlainButton(title: model.ejecting.contains(volume.id) ? "推出中…" : "推出", systemImage: "eject",
                                        disabled: model.ejecting.contains(volume.id)) { model.onEject(volume) }
                        }
                        .frame(height: 36)
                    }
                }
            }
        }
    }

    private func volumeDetail(_ volume: ExternalVolume) -> String {
        let kind = volume.isNetwork ? "网络共享" : "外接"
        guard let available = volume.available, let total = volume.total, total > 0 else { return kind }
        return "\(kind) · 可用 \(Self.bytes(Double(available))) / 共 \(Self.bytes(Double(total)))"
    }

    // MARK: 功耗：保持唤醒

    private func keepAwakeCard(_ p: Palette) -> some View {
        KeepAwakeCard()
    }

    // MARK: 温度宫格（风扇、温度面板）

    private func thermalSection(_ p: Palette, expandable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "硬件温度", trailing: model.sensorCount > 0 ? "\(model.sensorCount) 个传感器" : nil)
            let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
            LazyVGrid(columns: columns, spacing: 8) {
                chip("CPU 均温", "CPU 性能核")
                chip("GPU 均温", "GPU")
                chip("SSD", "固态硬盘")
                chip("内存", "内存")
            }
            if expandable {
                LinkButton(title: model.expanded ? "收起分组温度" : "展开分组温度",
                           systemImage: model.expanded ? "chevron.down" : "chevron.right",
                           action: model.onToggleExpanded)
                if model.expanded { groupsCard(p) }
            }
        }
    }

    private func chip(_ title: String, _ group: String) -> some View {
        let value = model.group(group)?.average
        return TemperatureChip(title: title, celsius: value, unsupported: !model.groups.isEmpty && value == nil)
    }

    /// 分组温度：平均 / 最高；温度面板中可逐组展开到每个探测点（展开后限高滚动）。
    @ViewBuilder
    private func groupsCard(_ p: Palette) -> some View {
        if model.metric == .temperature, model.expanded, !model.flatRender {
            ScrollView { groupsContent(p) }.frame(height: 340)
        } else {
            groupsContent(p)
        }
    }

    private func groupsContent(_ p: Palette) -> some View {
        Card(padding: 10) {
            VStack(spacing: 0) {
                HStack {
                    Text("位置").frame(maxWidth: .infinity, alignment: .leading)
                    Text("平均").frame(width: 44, alignment: .trailing)
                    Text("最高").frame(width: 44, alignment: .trailing)
                }
                .font(Typo.caption).foregroundStyle(p.text3)
                .padding(.bottom, 6)
                ForEach(model.groups, id: \.name) { group in
                    HStack(spacing: 8) {
                        TemperatureIndicator(celsius: group.maximum)
                        Text(group.name).font(Typo.body).foregroundStyle(p.text).frame(maxWidth: .infinity, alignment: .leading)
                        Text(Units.degrees(group.average)).font(Typo.number(12)).foregroundStyle(p.text)
                            .frame(width: 44, alignment: .trailing)
                        Text(Units.degrees(group.maximum)).font(Typo.number(12)).foregroundStyle(p.text2)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .frame(height: 24)
                    if model.metric == .temperature, model.expanded,
                       let readings = model.details.first(where: { $0.name == group.name })?.readings, !readings.isEmpty {
                        sensorStrip(p, readings)
                    }
                }
                if model.metric == .temperature {
                    HStack {
                        LinkButton(title: model.expanded ? "收起探测点" : "展开全部探测点",
                                   systemImage: model.expanded ? "chevron.down" : "chevron.right",
                                   action: model.onToggleExpanded)
                        Spacer()
                        if model.expanded {
                            Text("探测点不等于核心数").font(Typo.caption).foregroundStyle(p.text3)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    /// 一组的全部探测点：小格子按温度着色。
    private func sensorStrip(_ p: Palette, _ readings: [(key: String, celsius: Double)]) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 8)
        return LazyVGrid(columns: columns, spacing: 3) {
            ForEach(readings.indices, id: \.self) { index in
                let reading = readings[index]
                Text("\(Int(reading.celsius.rounded()))")
                    .font(Typo.number(10, .medium))
                    .foregroundStyle(p.text)
                    .frame(maxWidth: .infinity, minHeight: 16)
                    .background(RoundedRectangle(cornerRadius: 3).fill(p.temperature(reading.celsius).opacity(0.22)))
                    .help("\(reading.key)  \(String(format: "%.1f", reading.celsius))℃")
            }
        }
        .padding(.leading, 18)
        .padding(.bottom, 6)
    }

    // MARK: 风扇策略

    private func strategySection(_ p: Palette) -> some View {
        let config = fanClient.config
        let status = fanClient.status
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "调速策略", trailing: strategyStatus(config, status))
            Segmented(options: FanStrategy.allCases.map { ($0, $0.label) },
                      selection: config.strategy,
                      disabled: model.fan == nil ? Set(FanStrategy.allCases.filter { $0 != .auto }) : [],
                      onSelect: model.onSelectStrategy)
            Card(padding: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    switch config.strategy {
                    case .auto:
                        Text("风扇由 macOS 控制。选择其他策略时，会安装一个以管理员权限运行的小组件来调速。")
                            .font(Typo.caption).foregroundStyle(p.text2).fixedSize(horizontal: false, vertical: true)
                    case .fixed:
                        let value = model.fixedDraft ?? config.fixedRPM
                        HStack {
                            Text("固定转速").font(Typo.body).foregroundStyle(p.text2)
                            Spacer()
                            Text("\(Int(value)) 转").font(Typo.number(13)).foregroundStyle(p.text)
                        }
                        if let fan = model.fan {
                            Slider2(value: value, range: fan.minimum...fan.maximum,
                                    onChanging: { model.fixedDraft = $0 },
                                    onCommit: { model.fixedDraft = nil; model.onFixedCommit($0) })
                        }
                        Text("温度超过 \(Int(FanSafety.floorStart))℃ 时会按安全下限自动提速").font(Typo.caption).foregroundStyle(p.text3)
                    case .curve:
                        // 弹窗只做快速切换；编辑曲线在设置 → 风扇里
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("曲线预设").font(Typo.bodyMedium).foregroundStyle(p.text)
                                Text(config.preset?.detail ?? "自定义曲线（\(config.curve.count) 个控制点）")
                                    .font(Typo.caption).foregroundStyle(p.text3)
                            }
                            Spacer()
                            Menu(config.preset?.label ?? "自定义") {
                                ForEach(CurvePreset.allCases, id: \.self) { preset in
                                    Button(preset.label) { model.onSelectPreset(preset) }
                                }
                            }
                            .frame(width: 80)
                        }
                    case .rules:
                        let enabled = config.rules.filter(\.enabled).count
                        let triggered = status?.triggered.count ?? 0
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(config.rules.count) 条规则 · 启用 \(enabled) 条").font(Typo.bodyMedium).foregroundStyle(p.text)
                            Text(triggered > 0 ? "已触发 \(triggered) 条，取最高转速" : "都未触发时由系统控制；规则在设置里编辑")
                                .font(Typo.caption).foregroundStyle(triggered > 0 ? p.accentText : p.text3)
                        }
                    }
                    if config.strategy != .auto, let conflict = fanClient.conflict {
                        Label(conflict, systemImage: "exclamationmark.triangle.fill")
                            .font(Typo.caption).foregroundStyle(p.warm).fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = model.strategyError {
                        Text(error).font(Typo.caption).foregroundStyle(p.hot).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func strategyStatus(_ config: FanConfig, _ status: FanStatus?) -> String? {
        if model.fan == nil { return "没有可控制的风扇" }
        guard config.strategy != .auto else { return "系统控制中" }
        if !fanClient.isInstalled { return "尚未安装控制组件" }
        // 程序更新后组件没跟着更新，或不在“应用程序”里运行：选的策略没有生效，别显示成在接管
        if !fanClient.isHelperCurrent { return "控制组件需要更新 · 系统控制中" }
        if !fanClient.isRunningFromApplications { return "需在“应用程序”里运行 · 系统控制中" }
        guard let status else { return "连接组件中…" }
        if status.controlling { return "接管中 · 目标 \(Int(status.target)) 转" }
        if status.strategy == .rules { return "规则未触发 · 系统控制" }
        return status.message.map { "已交还系统：\($0)" } ?? "等待接管…"
    }

    // MARK: 排行卡

    @ViewBuilder
    private func rankingCard(_ p: Palette, limit: Int?) -> some View {
        if let title = model.metric.rankingTitle {
            let columns = model.metric.columns
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: title, trailing: model.metric == .fan ? "按功耗" : nil)
                Card(padding: 10) {
                    VStack(spacing: 0) {
                        HStack {
                            Text("应用").frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(columns, id: \.self) { Text($0).frame(width: 64, alignment: .trailing) }
                        }
                        .font(Typo.caption).foregroundStyle(p.text3)
                        .padding(.bottom, 4)
                        if let message = model.message, model.rows.isEmpty {
                            Text(message).font(Typo.body).foregroundStyle(p.text3)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                        }
                        ForEach(Array(model.rows.prefix(limit ?? model.rows.count))) { row in
                            rankRow(p, row)
                        }
                    }
                }
                .onHover { inside in
                    model.frozen = inside
                    if !inside { model.confirming = nil }
                }
            }
        }
    }

    private func rankRow(_ p: Palette, _ row: RankRowData) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: row.icon).resizable()
                .renderingMode(row.icon.isTemplate ? .template : .original)
                .foregroundStyle(p.text3)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).font(Typo.body).foregroundStyle(p.text).lineLimit(1).truncationMode(.tail)
                GeometryReader { geo in
                    Capsule().fill(model.metric.tint.opacity(0.55))
                        .frame(width: max(2, geo.size.width * row.share), height: 2)
                }
                .frame(height: 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(row.tooltip)
            ForEach(row.values.indices, id: \.self) { index in
                Text(row.values[index]).font(Typo.number(12, .medium))
                    .foregroundStyle(row.dim ? p.text3 : p.text)
                    .frame(width: row.values.count > 1 ? 58 : 64, alignment: .trailing)
            }
            terminateButton(p, row)
        }
        .frame(height: 30)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                model.hovered = row.id
            } else if model.hovered == row.id {
                model.hovered = nil
                if model.confirming == row.id { model.confirming = nil }
            }
        }
    }

    /// 悬停时出现“结束”；请求退出后仍在运行则变为“强制结束”。系统进程不显示。
    @ViewBuilder
    private func terminateButton(_ p: Palette, _ row: RankRowData) -> some View {
        let allowed = row.canTerminate
        if model.forceable.contains(row.id) {
            Button { model.onForceQuit(row) } label: {
                Text("强制").font(Typo.captionMedium).foregroundStyle(p.hot)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(p.hot.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help("仍未退出：强制结束（未保存的内容会丢失）")
        } else if model.quitting.contains(row.id) {
            ProgressView().controlSize(.mini).frame(width: 18)
        } else if allowed, model.confirming == row.id {
            Button {
                model.confirming = nil
                model.onQuitApp(row)
            } label: {
                Text("确认退出").font(Typo.captionMedium).foregroundStyle(p.hot)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(p.hot.opacity(0.14)))
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .help("再点一次退出 \(row.name)；移开鼠标取消")
        } else if allowed, model.hovered == row.id {
            Button { model.confirming = row.id } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(p.text3)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("退出 \(row.name)")
        } else {
            Color.clear.frame(width: 18, height: 18)
        }
    }

    // MARK: 底栏

    private func footer(_ p: Palette) -> some View {
        HStack(spacing: 14) {
            Text(model.footerNote ?? model.sampleMillis.map { "采样 \($0) ms" } ?? "")
                .font(Typo.caption).foregroundStyle(model.footerNote == nil ? p.text3 : p.accentText)
            Spacer()
            LinkButton(title: "诊断", muted: true, action: model.onDiagnostics).help("复制诊断信息")
            LinkButton(title: "反馈", muted: true, action: Diagnostics.openIssue).help("在 GitHub 新建问题，自动附上诊断信息")
            LinkButton(title: "退出", muted: true, action: model.onQuit)
        }
        .padding(.top, 2)
    }
}

/// 迷你走势图：面积 + 折线；可选第二条线（不填充）。纵轴从 0 到两组数据的最大值。
struct Sparkline: View {
    let values: [Double]
    var values2: [Double]?
    let color: Color
    var color2: Color = .green
    var baseline: Color = .gray

    var body: some View {
        GeometryReader { geo in
            let peak = max((values + (values2 ?? [])).max() ?? 0, 1e-9)
            let count = max(values.count, values2?.count ?? 0)
            let step = geo.size.width / CGFloat(max(count - 1, 1))
            let points = { (series: [Double]) -> [CGPoint] in
                let offset = count - series.count  // 两条线右对齐（最新点在最右）
                return series.enumerated().map { index, value in
                    CGPoint(x: CGFloat(index + offset) * step, y: geo.size.height * (1 - CGFloat(max(value, 0) / peak)))
                }
            }
            let main = points(values)
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height - 0.5))
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height - 0.5))
                }
                .stroke(baseline, lineWidth: 1)
                if let first = main.first, let last = main.last {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: geo.size.height))
                        main.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { path in path.addLines(main) }
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
                if let values2 {
                    Path { path in path.addLines(points(values2)) }
                        .stroke(color2, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                }
            }
        }
    }
}

/// 功耗面板的“保持唤醒”。
struct KeepAwakeCard: View {
    @ObservedObject var keepAwake = KeepAwake.shared

    var body: some View {
        Themed { p in
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "保持唤醒", trailing: keepAwake.isActive ? (keepAwake.remainingText ?? "直到手动关闭") : nil)
                Card(padding: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        Segmented(options: KeepAwake.Duration.allCases.map { ($0, $0.label) },
                                  selection: keepAwake.duration) { keepAwake.set($0) }
                        Text(keepAwake.duration == .always ? "电脑不自动睡眠，重启 islet 后也保持" : "电脑不自动睡眠，适合下载、渲染")
                            .font(Typo.caption).foregroundStyle(p.text3)
                        HStack {
                            Text("屏幕常亮").font(Typo.body).foregroundStyle(p.text)
                            Spacer()
                            Toggle2(isOn: keepAwake.keepDisplayOn) { keepAwake.setKeepDisplayOn($0) }
                        }
                    }
                }
            }
        }
    }
}
