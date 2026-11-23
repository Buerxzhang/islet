import SwiftUI

// 设计令牌与基础组件，风格参照 FunFan（MIT）的设计稿：
// 深色为主、冷青强调色、卡片分层、温度三态（< 60℃ 冷 / 60–75℃ 暖 / > 75℃ 热）。
// 视图里只用 palette 取色，不写裸色值；浅色一套单独调校，保证文字对比度 ≥ 4.5:1。

struct Palette {
    let panel: Color        // 面板 / 窗口底
    let card: Color         // 卡片底
    let cardStroke: Color   // 卡片描边（浅色下靠它分层）
    let inset: Color        // 内嵌区（分段控件槽、输入框）
    let hover: Color
    let text: Color
    let text2: Color
    let text3: Color
    let separator: Color
    let accentText: Color   // 可点击文字、选中文字
    let accentFill: Color   // 圆环、曲线、选中底、开关
    let cool: Color         // 温度三态 / 负载三态
    let warm: Color
    let hot: Color

    static let light = Palette(
        panel: Color(hex: 0xF2F2F5), card: .white, cardStroke: .black.opacity(0.08),
        inset: Color(hex: 0xE4E4EA), hover: .black.opacity(0.05),
        text: Color(hex: 0x1D1D1F), text2: Color(hex: 0x55555B), text3: Color(hex: 0x6E6E73),
        separator: .black.opacity(0.10),
        // 主题色 #0096D6：和应用图标的底色一致（取自官网背景渐变），文字用再深一点的同色
        accentText: Color(hex: 0x006E9E), accentFill: Color(hex: 0x0096D6),
        cool: Color(hex: 0x1B8A3E), warm: Color(hex: 0xA65C00), hot: Color(hex: 0xC4000E))


    /// 温度着色（传感器列表、曲线编辑器）：和岛、面板圆环同一套阈值（Metric.level），< 80° 绿，80–95° 橙，≥ 95° 红。
    func temperature(_ celsius: Double?) -> Color {
        guard let celsius else { return text3 }
        switch Metric.temperature.level(celsius) {
        case .normal: return cool
        case .warning: return warm
        case .critical: return hot
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: 1)
    }
}

/// 字号收敛为 15 / 12 / 11 三档，外加数值等宽档；最小 11pt。
enum Typo {
    static let title = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 12)
    static let bodyMedium = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11)
    static let captionMedium = Font.system(size: 11, weight: .medium)
    /// 设置窗口是独立窗口，正文用 macOS 标准的 13pt，说明 12pt（面板仍是 12 / 11）
    static let settingsBody = Font.system(size: 13)
    static let settingsCaption = Font.system(size: 12)
    static let settingsBodyMedium = Font.system(size: 13, weight: .medium)   // 侧栏选中项：和正文同字号，只加粗
    /// 数值：和岛上一样用窄体 + 等宽数字，从胶囊点开面板时字形连贯。
    static func number(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.condensed).monospacedDigit()
    }
}

/// 设置页右侧控件（分段选择、下拉菜单）统一宽度：一列对齐，左右边都齐
enum SettingsLayout {
    static let control: CGFloat = 200
}

/// 面板和窗口统一用浅色（不再有主题设置）。
struct Themed<Content: View>: View {
    let content: (Palette) -> Content

    init(@ViewBuilder content: @escaping (Palette) -> Content) {
        self.content = content
    }

    var body: some View { content(.light) }
}

// MARK: - 卡片

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder let content: Content

    var body: some View {
        Themed { p in
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(p.card))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.cardStroke))
        }
    }
}

/// 卡片上方的小节标题：左标题，右侧辅助说明。
struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        Themed { p in
            HStack {
                Text(title).font(Typo.bodyMedium).foregroundStyle(p.text2)
                Spacer()
                if let trailing { Text(trailing).font(Typo.caption).foregroundStyle(p.text3) }
            }
        }
    }
}

// MARK: - 圆环

/// 进度环：中间大数字 + 单位。fraction 为 nil 时只画底环。
struct Ring: View {
    let fraction: Double?
    let value: String
    let unit: String
    var color: Color?
    var size: CGFloat = 92

    var body: some View {
        Themed { p in
            ZStack {
                Circle().stroke(p.inset, lineWidth: 8)
                if let fraction {
                    Circle()
                        .trim(from: 0, to: min(max(fraction, 0.015), 1))   // 0 时也留一点，不像没数据
                        .stroke(color ?? p.accentFill, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                // unit 写成“单位 说明”：单位跟在数字后面（小一号），下面一行只写说明，如 18% / 占用、12.1 GB / 已用。
                // 没有空格的只当说明
                let parts = unit.split(separator: " ", maxSplits: 1).map(String.init)
                let suffix = parts.count == 2 && value != "—" ? parts[0] : ""
                let label = parts.count == 2 ? parts[1] : unit
                let tight = suffix == "%" || suffix.hasPrefix("°")
                let size: CGFloat = value.count > 5 ? 18 : 22
                VStack(spacing: 0) {
                    (Text(value).font(Typo.number(size))
                        + Text(suffix.isEmpty ? "" : (tight ? suffix : " " + suffix)).font(Typo.number(size * 0.6)))
                        .foregroundStyle(p.text)
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Text(label).font(Typo.caption).foregroundStyle(p.text3)
                }
                .padding(.horizontal, 10)
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - 温度指示物（颜色之外还有形态差：实心点 / 点+外环 / 三角）

struct TemperatureIndicator: View {
    let celsius: Double?

    var body: some View {
        Themed { p in
            let color = p.temperature(celsius)
            Group {
                if let celsius, celsius > 75 {
                    Image(systemName: "triangle.fill").resizable().frame(width: 8, height: 7)
                } else if let celsius, celsius >= 60 {
                    ZStack {
                        Circle().stroke(lineWidth: 1).frame(width: 10, height: 10)
                        Circle().frame(width: 5, height: 5)
                    }
                } else {
                    Circle().frame(width: 7, height: 7)
                }
            }
            .foregroundStyle(color)
            .frame(width: 10, height: 10)
        }
    }
}

/// 温度格：指示物 + 名称 + 数值（数值用主文字色，温度体现在指示物上）。
struct TemperatureChip: View {
    let title: String
    let celsius: Double?
    var unsupported = false

    var body: some View {
        Themed { p in
            HStack(spacing: 6) {
                TemperatureIndicator(celsius: unsupported ? nil : celsius)
                Text(title).font(Typo.body).foregroundStyle(p.text2).lineLimit(1)
                Spacer(minLength: 4)
                Text(unsupported ? "无传感器" : celsius.map { "\(Int($0.rounded()))°" } ?? "—")
                    .font(unsupported ? Typo.caption : Typo.number(15))
                    .foregroundStyle(unsupported ? p.text3 : p.text)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(p.card))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.cardStroke))
            .help(unsupported ? "这台 Mac 没有该位置的温度传感器" : "")
        }
    }
}

// MARK: - 分段控件（自绘：高亮色可控，且能离屏渲染）

struct Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    let selection: Value
    var disabled: Set<Value> = []
    let onSelect: (Value) -> Void

    var body: some View {
        Themed { p in
            HStack(spacing: 2) {
                ForEach(options.indices, id: \.self) { index in
                    let (value, label) = options[index]
                    let selected = value == selection
                    let isDisabled = disabled.contains(value)
                    Button { if !isDisabled { onSelect(value) } } label: {
                        Text(label)
                            .font(Typo.bodyMedium)
                            .foregroundStyle(isDisabled ? p.text3.opacity(0.6) : selected ? p.accentText : p.text2)
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(selected ? p.accentFill.opacity(0.18) : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(selected ? p.accentFill.opacity(0.55) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(p.inset))
        }
    }
}

// MARK: - 开关（自绘 26×15 轨道）

struct Toggle2: View {
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Themed { p in
            Button { onChange(!isOn) } label: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? p.accentFill : p.inset).frame(width: 30, height: 17)
                    Circle().fill(.white).frame(width: 13, height: 13).padding(2)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                }
                .animation(.easeOut(duration: 0.15), value: isOn)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isOn ? "已开启" : "已关闭")
        }
    }
}

// MARK: - 按钮

/// 次级按钮：卡片色底 + 描边。
struct PlainButton: View {
    let title: String
    var systemImage: String?
    var prominent = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Themed { p in
            Button(action: action) {
                HStack(spacing: 4) {
                    if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .medium)) }
                    Text(title).font(Typo.bodyMedium)
                }
                .foregroundStyle(disabled ? p.text3 : prominent ? p.accentText : p.text)
                .padding(.horizontal, 10)
                .frame(height: 26)
                // 次级按钮统一成浅灰底、无描边（和下拉菜单同一种样子）
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(prominent ? p.accentFill.opacity(0.16) : p.text.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(prominent ? p.accentFill.opacity(0.5) : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
        }
    }
}

/// 文字链接式按钮（底栏“诊断 / 退出”、“展开…”）。
struct LinkButton: View {
    let title: String
    var systemImage: String?
    var muted = false
    let action: () -> Void

    var body: some View {
        Themed { p in
            Button(action: action) {
                HStack(spacing: 3) {
                    if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)) }
                    Text(title).font(Typo.bodyMedium)
                }
                .foregroundStyle(muted ? p.text2 : p.accentText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 滑块（自绘，拖动结束才回调提交）

struct Slider2: View {
    let value: Double
    let range: ClosedRange<Double>
    var step: Double = 50
    let onChanging: (Double) -> Void
    let onCommit: (Double) -> Void

    var body: some View {
        Themed { p in
            GeometryReader { geo in
                let width = geo.size.width
                let span = max(range.upperBound - range.lowerBound, 1)
                let fraction = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span
                ZStack(alignment: .leading) {
                    Capsule().fill(p.inset).frame(height: 5)
                    Capsule().fill(p.accentFill).frame(width: max(5, width * fraction), height: 5)
                    Circle().fill(.white).frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                        .offset(x: (width - 16) * fraction)
                }
                .frame(height: 18)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in onChanging(snap(drag.location.x, width: width)) }
                    .onEnded { drag in onCommit(snap(drag.location.x, width: width)) })
            }
            .frame(height: 18)
        }
    }

    private func snap(_ x: CGFloat, width: CGFloat) -> Double {
        let fraction = min(max(Double(x / max(width, 1)), 0), 1)
        let raw = range.lowerBound + (range.upperBound - range.lowerBound) * fraction
        return min(max((raw / step).rounded() * step, range.lowerBound), range.upperBound)
    }
}

/// 键值行：左标签（三级文字），右数值。
struct KeyValueRow: View {
    let key: String
    let value: String
    var valueColor: Color?

    var body: some View {
        Themed { p in
            HStack(spacing: 10) {
                Text(key).font(Typo.caption).foregroundStyle(p.text3).frame(width: 34, alignment: .leading)
                Text(value).font(Typo.number(13)).foregroundStyle(valueColor ?? p.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }
}

// MARK: - 步进器（自绘：− 数值 +）

struct Stepper2: View {
    let value: Double
    let step: Double
    let range: ClosedRange<Double>
    let unit: String
    var width: CGFloat = 36
    let onChange: (Double) -> Void

    var body: some View {
        Themed { p in
            HStack(spacing: 0) {
                button(p, "minus", value - step)
                Text(String(Int(value.rounded())))
                    .font(Typo.number(12, .medium)).foregroundStyle(p.text)
                    .frame(width: width)
                button(p, "plus", value + step)
                Text(unit).font(Typo.caption).foregroundStyle(p.text3).padding(.leading, 3)
            }
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(p.inset))
        }
    }

    private func button(_ p: Palette, _ symbol: String, _ next: Double) -> some View {
        let clamped = min(max(next, range.lowerBound), range.upperBound)
        let disabled = clamped == value
        return Button { if !disabled { onChange(clamped) } } label: {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                .foregroundStyle(disabled ? p.text3.opacity(0.5) : p.text2)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 设置窗口导航和行首的彩色图标（和面板标题同样式）。
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    /// 和面板标题一样：只画彩色图标，不带底块
    var body: some View {
        Group {
            if symbol == BluetoothGlyph.name {
                // 竖胶囊里放符文：呼应“灵动岛”的胶囊
                let line = StrokeStyle(lineWidth: size * 0.07, lineCap: .round, lineJoin: .round)
                ZStack {
                    Capsule().stroke(tint, style: line).frame(width: size * 0.46, height: size * 0.66)
                    // 符文比外框细一些，在小尺寸下不糊成一团
                    BluetoothGlyph().stroke(tint, style: StrokeStyle(lineWidth: size * 0.05, lineCap: .round, lineJoin: .round))
                        .frame(width: size * 0.4, height: size * 0.4)
                }
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.6, weight: .semibold)).foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
    }
}

/// 蓝牙标志：SF Symbols 没有公开蓝牙图标，自己画（IconTile 里用 symbol: "bluetooth"）。
struct BluetoothGlyph: Shape {
    static let name = "bluetooth"

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        var path = Path()
        path.move(to: point(0.25, 0.31))
        path.addLine(to: point(0.75, 0.69))
        path.addLine(to: point(0.5, 0.9))
        path.addLine(to: point(0.5, 0.1))
        path.addLine(to: point(0.75, 0.31))
        path.addLine(to: point(0.25, 0.69))
        return path
    }
}

/// 颜色渐变：换歌、换程序时颜色在约半秒内平滑过渡，而不是一帧突变。
/// 颜色组（渐变的各个色标）按位置一一过渡，个数不同时补齐（单色当作两端同色）。
struct ColorFade {
    static let duration: TimeInterval = 0.45
    let from: [NSColor]
    let to: [NSColor]
    let start = Date()
    var timer: Timer?

    /// 进度 0…1，先快后慢。
    var progress: CGFloat {
        let t = CGFloat(min(Date().timeIntervalSince(start) / Self.duration, 1))
        return 1 - pow(1 - t, 3)
    }
    var finished: Bool { Date().timeIntervalSince(start) >= Self.duration }

    var colors: [NSColor] {
        let count = max(from.count, to.count)
        return (0..<count).map { index in
            Self.mix(from[min(index, from.count - 1)], to[min(index, to.count - 1)], progress)
        }
    }

    static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return t < 0.5 ? a : b }
        return a.blended(withFraction: t, of: b) ?? b
    }

    /// 开始（或从当前颜色重新开始）一段过渡，每帧调用 frame，结束后清空。
    static func start(_ fade: inout ColorFade?, from: [NSColor], to: [NSColor], frame: @escaping () -> Void) {
        fade?.timer?.invalidate()
        guard !from.isEmpty, !to.isEmpty else { fade = nil; return }
        var next = ColorFade(from: from, to: to)
        let box = FadeBox()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            frame()
            if box.finished() { timer.invalidate(); box.done() }
        }
        next.timer = timer
        fade = next
        let started = next.start
        box.finished = { Date().timeIntervalSince(started) >= duration }
        box.done = frame
        RunLoop.main.add(timer, forMode: .common)
    }
}

private final class FadeBox {
    var finished: () -> Bool = { true }
    var done: () -> Void = {}
}
