import AppKit
import SwiftUI

// MARK: - 全屏频谱

/// 频谱电平单独一个模型：每帧只刷新频谱这一小块，背景和文字不跟着重绘（否则全屏模糊背景每帧重算，会卡死）。
final class VisualizerBars: ObservableObject {
    static let count = 72
    @Published var values = [CGFloat](repeating: 0, count: count)

    /// 24 个频段插值成更多根条，并做平滑：上升快、回落慢。
    func push(_ levels: [Float], audible: Bool) {
        var next = values
        for i in 0..<Self.count {
            let position = Double(i) / Double(Self.count - 1) * Double(levels.count - 1)
            let low = Int(position), high = min(low + 1, levels.count - 1), t = position - Double(low)
            let value = audible ? CGFloat(Double(levels[low]) * (1 - t) + Double(levels[high]) * t) : 0
            next[i] = value > values[i] ? values[i] + (value - values[i]) * 0.6 : values[i] * 0.86 + value * 0.14
        }
        values = next
    }
}

/// 全屏界面的数据（低频变化）：歌曲信息、控件显隐。
final class VisualizerModel: ObservableObject {
    let bars = VisualizerBars()
    @Published var info: NowPlayingInfo?
    @Published var source: SoundSource?
    @Published var accentTint: NSColor?
    @Published var audible = false
    @Published var controlsVisible = true
    /// 已连接的屏幕名称和当前所在的那块（多屏时右上角可切换）。
    @Published var screenNames: [String] = []
    @Published var currentScreen = 0
    var onSelectScreen: (Int) -> Void = { _ in }

    var onCommand: (NowPlayingMonitor.Command) -> Void = { _ in }
    var onClose: () -> Void = {}
    var demo = false

    /// 歌曲信息变化时调用（不是每帧）。
    func setNowPlaying(_ info: NowPlayingInfo?, source: SoundSource?, tint: NSColor? = nil) {
        let music = source == nil ? info : nil
        if self.info?.title != music?.title || self.info?.playing != music?.playing || self.info?.artwork !== music?.artwork
            || self.info?.elapsed != music?.elapsed || self.source != source || self.accentTint != tint {
            self.info = music
            self.source = source
            self.accentTint = tint
        }
    }

    func setAudible(_ value: Bool) { if audible != value { audible = value } }
}

/// 全屏：模糊封面铺满做背景，歌名居中，下面是进度和控制，底部整屏宽的频谱。
struct VisualizerView: View {
    @ObservedObject var model: VisualizerModel

    private var info: NowPlayingInfo? { model.info }
    /// 频谱主色：封面主色或软件图标主色；取不到时用白色。
    private var tint: Color { (model.accentTint ?? info?.tint).map(Color.init) ?? .white }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // 沉浸式：封面铺满整屏并强模糊作为背景（原图只有 100×100，模糊后看不出颗粒）
                VisualizerBackground(art: info?.artwork ?? model.source?.icon, tint: tint)
                    .frame(width: w, height: h).clipped()
                VStack(spacing: 0) {
                    titleBlock(size: h * 0.085)
                        .frame(maxWidth: min(w * 0.8, h * 1.8))
                        .frame(maxHeight: .infinity)
                    VisualizerSpectrum(bars: model.bars, tint: tint)
                        .frame(height: h * 0.5)
                        .padding(.horizontal, h * 0.04)
                        .padding(.bottom, h * 0.03)
                }
                .frame(width: w, height: h)
                // 控件浮在频谱上：不占布局高度，鼠标一动出现，静止 2.5 秒隐藏
                VStack {
                    Spacer()
                    controls
                        .opacity(model.controlsVisible ? 1 : 0)
                        .offset(y: model.controlsVisible ? 0 : 16)
                        .padding(.bottom, h * 0.06)
                }
                // 底边一条细进度线，控件隐藏时也能看出播到哪
                VStack {
                    Spacer()
                    edgeProgress
                }
                topBar.opacity(model.controlsVisible ? 1 : 0)
            }
            .frame(width: w, height: h)
            .animation(.easeInOut(duration: 0.35), value: model.controlsVisible)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    /// 歌名居中大字，下面是歌手和播放器；暂停时整体稍微变淡。
    private func titleBlock(size: CGFloat) -> some View {
        VStack(spacing: size * 0.22) {
            Text(title).font(.system(size: size, weight: .bold)).foregroundStyle(.white)
                .lineLimit(2).minimumScaleFactor(0.5).multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.35), radius: 20, y: 6)
            Text(subtitle).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            HStack(spacing: 7) {
                Circle().fill(model.audible ? Color.green : .gray).frame(width: 8, height: 8)
                Text(sourceName).font(.system(size: max(14, size * 0.24), weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }
            .padding(.top, size * 0.05)
        }
        .opacity(info?.playing == false ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.4), value: info?.playing)
    }

    private var title: String {
        if let info, !info.title.isEmpty { return info.title }
        return model.source?.name ?? "正在播放"
    }

    private var subtitle: String {
        if let info { return info.artist.isEmpty ? info.album : info.artist }
        return model.audible ? "正在发声" : "没有声音"
    }

    private var sourceName: String {
        if let source = model.source { return source.name }
        return info?.bundle.flatMap(SpectrumPanelView.appName) ?? (model.audible ? "有声音" : "没有声音")
    }

    // MARK: 控制

    /// 浮动控制条：毛玻璃胶囊，内含上一首 / 播放暂停 / 下一首、时间和进度。
    @ViewBuilder private var controls: some View {
        if let info {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let position = info.position(at: context.date) ?? 0
                let duration = info.duration ?? 0
                HStack(spacing: 22) {
                    Text(Self.time(position)).frame(width: 44, alignment: .trailing)
                    HStack(spacing: 10) {
                        if info.canSkip { button("backward.fill", 20) { model.onCommand(.previous) } }
                        button(info.playing ? "pause.fill" : "play.fill", 28) { model.onCommand(.togglePlayPause) }
                        if info.canSkip { button("forward.fill", 20) { model.onCommand(.next) } }
                    }
                    Text(duration > 0 ? "-" + Self.time(max(duration - position, 0)) : "").frame(width: 44, alignment: .leading)
                }
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 22).padding(.vertical, 8)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
            }
        }
    }

    /// 屏幕底边的细进度线。
    @ViewBuilder private var edgeProgress: some View {
        if let info, let duration = info.duration, duration > 0 {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let position = info.position(at: context.date) ?? 0
                GeometryReader { geo in
                    Rectangle().fill(.white.opacity(0.55))
                        .frame(width: geo.size.width * min(max(position / duration, 0), 1))
                }
                .frame(height: 3)
            }
        }
    }

    private var topBar: some View {
        VStack {
            HStack(spacing: 10) {
                Spacer()
                if model.screenNames.count > 1 {
                    Menu {
                        ForEach(model.screenNames.indices, id: \.self) { index in
                            Button {
                                model.onSelectScreen(index)
                            } label: {
                                if index == model.currentScreen {
                                    Label(model.screenNames[index], systemImage: "checkmark")
                                } else {
                                    Text(model.screenNames[index])
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "display.2").font(.system(size: 12, weight: .semibold))
                            Text(model.screenNames[min(model.currentScreen, model.screenNames.count - 1)])
                                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        }
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(Capsule().fill(.white.opacity(0.14)))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("在哪块屏幕上全屏")
                }
                Button { model.onClose() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.white.opacity(0.14)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("退出全屏（Esc）")
            }
            .padding(22)
            Spacer()
        }
    }

    private func button(_ symbol: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).foregroundStyle(.white)
                .frame(width: 52, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 背景：封面放大、强模糊、提饱和，再压暗。只在封面变化时重绘。
private struct VisualizerBackground: View, Equatable {
    let art: NSImage?
    let tint: Color

    static func == (a: Self, b: Self) -> Bool { a.art === b.art && a.tint == b.tint }

    var body: some View {
        ZStack {
            Color.black
            if let art {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    .scaleEffect(1.15).blur(radius: 60).saturation(1.4)
            } else {
                RadialGradient(colors: [tint.opacity(0.45), .black], center: .center, startRadius: 0, endRadius: 1000)
            }
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.5), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        }
        .drawingGroup()
    }
}

/// 底部频谱：主色到白色的渐变竖条 + 光晕 + 倒影。只观察电平模型，每帧只重绘这一块。
private struct VisualizerSpectrum: View {
    @ObservedObject var bars: VisualizerBars
    let tint: Color

    var body: some View {
        let values = bars.values
        let colors = [tint, tint.opacity(0.9), .white]
        Canvas { context, size in
            let count = values.count
            let gap: CGFloat = max(size.width / CGFloat(count) * 0.32, 2)
            let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            let mid = size.height * 0.78
            for (i, level) in values.enumerated() {
                let x = CGFloat(i) * (width + gap)
                // 提高对比：电平做幂次压缩，安静的频段更矮，起伏更明显
                let h = max(width, mid * pow(min(level, 1), 2.2) * 0.96)
                context.fill(Path(roundedRect: CGRect(x: x, y: mid - h, width: width, height: h), cornerRadius: width / 2),
                             with: .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: 0, y: mid), endPoint: CGPoint(x: 0, y: 0)))
                context.fill(Path(roundedRect: CGRect(x: x, y: mid + 4, width: width, height: h * 0.35), cornerRadius: width / 2),
                             with: .linearGradient(Gradient(colors: [tint.opacity(0.35), .clear]),
                                                   startPoint: CGPoint(x: 0, y: mid), endPoint: CGPoint(x: 0, y: mid + h * 0.35)))
            }
        }
        .drawingGroup()
    }
}

/// 全屏窗口：盖住整块屏幕（含菜单栏和程序坞），Esc 或右上角退出；鼠标静止 2.5 秒后隐藏控件和光标。
final class VisualizerWindowController: NSObject, NSWindowDelegate {
    final class Window: NSWindow {
        var onEscape: () -> Void = {}
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onEscape() } else { super.keyDown(with: event) }
        }
        override func cancelOperation(_ sender: Any?) { onEscape() }
    }

    let model = VisualizerModel()
    private var window: Window?
    private var mouseMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var hideWork: DispatchWorkItem?
    var isOpen: Bool { window != nil }
    var onClosed: () -> Void = {}

    private static let screenKey = "visualizerScreen"

    /// 选过的屏幕（优先按 UUID 匹配，兼容旧版按名称记住）；没接着就用点开面板的那块。
    private static func preferredScreen(fallback: NSScreen?) -> NSScreen? {
        let saved = UserDefaults.standard.string(forKey: screenKey)
        return NSScreen.screens.first { AppDelegate.screenUUID($0) == saved || $0.localizedName == saved }
            ?? fallback ?? NSScreen.main
    }

    private static func screenLabels(for screens: [NSScreen]) -> [String] {
        guard screens.count > 1 else { return screens.map(\.localizedName) }
        return screens.enumerated().map { index, screen in
            if index == 0 { return "\(screen.localizedName)（主屏）" }
            if screens.count == 2 { return "\(screen.localizedName)（扩展屏）" }
            return "\(screen.localizedName)（扩展屏 \(index)）"
        }
    }

    private func updateScreens(current: NSScreen?) {
        let screens = NSScreen.screens
        model.screenNames = Self.screenLabels(for: screens)
        model.currentScreen = current.flatMap { screens.firstIndex(of: $0) } ?? 0
    }

    /// 换到另一块屏幕全屏，并记住下次也用它。
    func move(toScreen index: Int) {
        let screens = NSScreen.screens
        guard let window, screens.indices.contains(index) else { return }
        let screen = screens[index]
        UserDefaults.standard.set(AppDelegate.screenUUID(screen) ?? screen.localizedName, forKey: Self.screenKey)
        window.setFrame(screen.frame, display: true)
        updateScreens(current: screen)
    }

    func open(on screen: NSScreen?) {
        if let window { window.makeKeyAndOrderFront(nil); return }
        guard let screen = Self.preferredScreen(fallback: screen) else { return }
        updateScreens(current: screen)
        model.onSelectScreen = { [weak self] in self?.move(toScreen: $0) }
        let window = Window(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.contentView = NSHostingView(rootView: VisualizerView(model: model))
        window.setFrame(screen.frame, display: true)
        window.onEscape = { [weak self] in self?.close() }
        window.delegate = self
        model.onClose = { [weak self] in self?.close() }
        self.window = window
        model.controlsVisible = true
        NSApp.activate()
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; window.animator().alphaValue = 1 }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .scrollWheel]) { [weak self] event in
            self?.revealControls()
            return event
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateScreens(current: self?.window?.screen)
        }
        revealControls()
    }

    func close() {
        guard let window else { return }
        hideWork?.cancel()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        NSCursor.unhide()
        self.window = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; window.animator().alphaValue = 0 }) {
            window.orderOut(nil)
        }
        onClosed()
    }

    private func revealControls() {
        if !model.controlsVisible { model.controlsVisible = true }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.model.controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
}
