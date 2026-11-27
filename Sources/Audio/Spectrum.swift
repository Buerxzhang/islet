import Accelerate
import AppKit
import Combine
import AudioToolbox
import CoreAudio
import os
import SwiftUI

// 菜单栏音乐频谱：截取系统正在播放的声音（Core Audio 进程音频截取，macOS 14.2+），
// 做 FFT 拆成 24 个频段，在 CPU 左侧画成跳动的竖条。只读取播放出来的声音，不使用麦克风。

/// 系统音频截取 + 频谱分析。
final class SpectrumAnalyzer {
    static let bandCount = 24
    /// 灵敏度：低 / 标准 / 高（dB 补偿）。安静的歌在“高”下也能跳得明显。
    static let sensitivityChoices: [(Int, String)] = [(0, "低"), (1, "标准"), (2, "高")]
    static var sensitivity: Int {
        get { UserDefaults.standard.object(forKey: "spectrumSensitivity") as? Int ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "spectrumSensitivity"); sensitivityBoost = [-5, 0, 7][newValue] }
    }
    static var sensitivityBoost: Float = [-5, 0, 7][UserDefaults.standard.object(forKey: "spectrumSensitivity") as? Int ?? 1]
    private static let fftSize = 2048

    /// 实时音频线程写入、主线程读取的最近 fftSize 个采样（单声道）。
    private let samples = OSAllocatedUnfairLock(initialState: [Float](repeating: 0, count: SpectrumAnalyzer.fftSize))
    private let ioQueue = DispatchQueue(label: "local.codex.islet.spectrum", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var sampleRate: Double = 48_000
    private let fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(SpectrumAnalyzer.fftSize))), radix: .radix2, ofType: DSPSplitComplex.self)!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: SpectrumAnalyzer.fftSize, isHalfWindow: false)
    private var smoothed = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)

    private(set) var error: String?
    var isRunning: Bool { procID != nil }
    /// 截取用作时钟的输出设备（UID）；输出设备换了要重建截取。
    private(set) var deviceUID: String?

    // MARK: 截取

    func start() {
        guard !isRunning else { return }
        guard #available(macOS 14.2, *) else {
            error = "需要 macOS 14.2 或更新版本"
            return
        }
        do {
            try createTap()
            error = nil
        } catch let failure as NSError {
            error = "无法截取系统声音（错误 \(failure.code)）"
            stop()
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        deviceUID = nil
        samples.withLock { $0 = [Float](repeating: 0, count: Self.fftSize) }
        smoothed = [Float](repeating: 0, count: Self.bandCount)
    }

    @available(macOS 14.2, *)
    private func createTap() throws {
        // 1. 全局立体声截取（不排除任何程序），私有、不静音原声
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "islet · 频谱"
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap))
        tapID = tap

        // 2. 截取到的音频格式（采样率、是否交错）
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format))
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        let channels = Int(max(format.mChannelsPerFrame, 1))
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        // 3. 以系统输出设备为时钟，建一个只含这个截取的私有聚合设备
        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "islet 频谱",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device))
        aggregateID = device
        deviceUID = outputUID

        // 4. 实时回调：只取第一个声道，追加到环形缓冲（尽量少做事）
        let store = samples
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, ioQueue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let buffer = buffers.first, let data = buffer.mData else { return }
            let floats = data.assumingMemoryBound(to: Float.self)
            let total = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let stride = interleaved ? channels : 1
            let frames = total / stride
            guard frames > 0 else { return }
            store.withLock { ring in
                let keep = min(frames, ring.count)
                ring.removeFirst(keep)
                for index in (frames - keep)..<frames { ring.append(floats[index * stride]) }
            }
        })
        procID = proc
        try check(AudioDeviceStart(device, proc))
    }

    /// 当前的声音输出设备（不是“提示音”输出设备：两者可以不同，拔掉的那个可能正好是提示音设备）。
    static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device))
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid))
        guard let value = uid?.takeRetainedValue() as String? else { throw NSError(domain: "spectrum", code: -1) }
        return value
    }

    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw NSError(domain: "spectrum", code: Int(status)) }
    }

    private func check(_ status: OSStatus) throws { try Self.check(status) }

    // MARK: 分析

    /// 计算各频段电平（0...1，已平滑）与是否有声音。主线程调用，约 1 毫秒。
    func analyze() -> (levels: [Float], audible: Bool) {
        let input = samples.withLock { $0 }
        let rms = vDSP.rootMeanSquare(input)
        let n = Self.fftSize
        let windowed = vDSP.multiply(input, window)
        var real = [Float](repeating: 0, count: n / 2)
        var imaginary = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &power)
            }
        }
        // 对数分布的频段：50 Hz ~ 12 kHz（更高的频段音乐里能量很少，常年是平的），低音不至于挤在一两根里
        let nyquist = Float(sampleRate / 2)
        let low: Float = 50, high = min(12_000, nyquist * 0.95)
        let binWidth = Float(sampleRate) / Float(n)
        var levels = [Float](repeating: 0, count: Self.bandCount)
        for band in 0..<Self.bandCount {
            let from = low * pow(high / low, Float(band) / Float(Self.bandCount))
            let to = low * pow(high / low, Float(band + 1) / Float(Self.bandCount))
            let first = max(1, Int(from / binWidth)), last = max(first, min(n / 2 - 1, Int(to / binWidth)))
            var peak: Float = 0
            for bin in first...last { peak = max(peak, power[bin]) }
            // 归一化到 0...1：约 -60 dB 为空，-20 dB 为满（人声、音乐多数频段在 -50 ~ -30 dB）；
            // 高频略加补偿（音乐能量集中在低频）
            let db = 10 * log10(max(peak, 1e-12) / Float(n * n)) + Float(band) * 0.55
            levels[band] = min(max((db + 60 + Self.sensitivityBoost) / 40, 0), 1)
        }
        // 平滑：上升快、回落慢，跳动更顺眼
        for band in 0..<Self.bandCount {
            let target = levels[band]
            smoothed[band] = target > smoothed[band] ? smoothed[band] * 0.35 + target * 0.65 : smoothed[band] * 0.82 + target * 0.18
        }
        return (smoothed, rms > 0.0005)
    }
}

/// 频谱样式。rawValue 持久化，不要随意改顺序。
/// 频谱在菜单栏的外观：形状、颜色、底色、是否显示播放按钮，各自独立设置。
struct SpectrumLook: Equatable {
    enum Shape: Int, CaseIterable {
        case bars, dots
        var label: String { ["竖条", "点阵"][rawValue] }
    }
    enum Tint: Int, CaseIterable {
        case album = 0, white = 1, icon = 2   // rawValue 持久化
        var label: String {
            switch self {
            case .album: return "专辑色"
            case .icon: return "图标色"
            case .white: return "白色"
            }
        }
        static var allCases: [Tint] { [.album, .icon, .white] }
    }
    enum Backdrop: Int, CaseIterable {
        // 存储值沿用旧版（0 渐变、1 黑色、3 玻璃；2 是已去掉的“专辑色”，读到时按渐变）
        case gradient = 0, black = 1, glass = 3
        var label: String { [.gradient: "渐变", .black: "黑色", .glass: "玻璃"][self]! }
        static var allCases: [Backdrop] { [.gradient, .black, .glass] }
    }

    enum Cover: Int, CaseIterable {
        case circle, rounded
        var label: String { ["圆形", "圆角"][rawValue] }
    }

    var shape: Shape = .bars
    var cover: Cover = .circle
    var tint: Tint = .album
    var backdrop: Backdrop = .gradient
    var controls = true
    var spin = true

    static var current: SpectrumLook {
        let defaults = UserDefaults.standard
        var look = SpectrumLook()
        if let raw = defaults.object(forKey: "spectrumShape") as? Int {
            look.shape = Shape(rawValue: raw) ?? .bars
        } else if defaults.integer(forKey: "spectrumStyle") == 3 {
            look.shape = .dots  // 旧版“点阵”样式
        }
        look.cover = .circle  // 封面固定为圆形（不再提供切换）
        look.tint = Tint(rawValue: defaults.integer(forKey: "spectrumTint")) ?? .album
        if let raw = defaults.object(forKey: "spectrumBackdrop") as? Int { look.backdrop = Backdrop(rawValue: raw) ?? .gradient }
        look.controls = defaults.object(forKey: "spectrumControls") as? Bool ?? true
        look.spin = defaults.object(forKey: "spectrumSpin") as? Bool ?? true
        return look
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(shape.rawValue, forKey: "spectrumShape")
        defaults.set(cover.rawValue, forKey: "spectrumCover")
        defaults.set(tint.rawValue, forKey: "spectrumTint")
        defaults.set(backdrop.rawValue, forKey: "spectrumBackdrop")
        defaults.set(controls, forKey: "spectrumControls")
        defaults.set(spin, forKey: "spectrumSpin")
    }

    /// 没有播放音乐时渐变的起点：主题色（图标底色 #0096D6）的深色版，白字在上面清楚。
    static let themeDark = NSColor(srgbRed: 0x00 / 255.0, green: 0x4B / 255.0, blue: 0x6B / 255.0, alpha: 0.97)

    /// 胶囊底色（从左到右的颜色）。渐变：从左往右过渡到黑，起点在播放时是专辑色，没播放时是主题色的深色版；
    /// 黑色：一直纯黑；玻璃只在悬浮时生效，在菜单栏里按默认的渐变画（再悬浮时自动回到玻璃）。
    /// 底色必须不透明：它同时挡住系统在菜单栏项下面画的按下 / 打开底色。
    func backdropColors(tint: NSColor?) -> [NSColor] {
        let black = NSColor(white: 0.06, alpha: 0.97)
        guard backdrop != .black else { return [black] }   // 渐变，以及不悬浮时的玻璃
        guard let tint else { return [Self.themeDark, black] }
        let album = NSColor(hue: tint.hueComponent, saturation: min(tint.saturationComponent, 0.8), brightness: 0.5, alpha: 0.97)
        return [album, black]
    }

    /// 竖条颜色；album 为专辑主色，没有时回落到 base（白 / 黑）。lighten 时把专辑色调浅（用在深色底上）。
    func color(level: CGFloat, album: NSColor?, base: NSColor, lighten: Bool = false) -> NSColor {
        if tint != .white, var album {
            if lighten {
                album = NSColor(hue: album.hueComponent, saturation: album.saturationComponent * 0.55, brightness: 1, alpha: 1)
            }
            return album.withAlphaComponent(0.55 + 0.45 * level)
        }
        return base.withAlphaComponent(base.alphaComponent * (0.55 + 0.45 * level))
    }
}

final class SpectrumBarsView: NSView {
    static let barWidth: CGFloat = 2
    static let gap: CGFloat = 1.5
    static var contentWidth: CGFloat { CGFloat(SpectrumAnalyzer.bandCount) * (barWidth + gap) - gap }
    private static let dotCount = 6
    static let artworkSize: CGFloat = 16
    private static let groupGap: CGFloat = 7          // 各组之间的视觉间距
    private static let controlInset: CGFloat = 2.5    // 按钮框内图标两侧的留白
    private static let controlWidth: CGFloat = 17
    private static let controlHeight: CGFloat = 10   // 三个按钮同高，比封面小一圈
    private static let backdropPadding: CGFloat = 7

    var look = SpectrumLook.current { didSet { refresh(); updateSpin() } }
    /// 专辑封面（左侧小图）与封面主色。
    var artwork: NSImage? {
        didSet {
            if window != nil, oldValue != nil, artwork != nil { Self.crossfade(artworkLayer) }   // 换歌：封面淡入淡出
            artworkLayer.contents = artwork?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            updateSpin()
        }
    }
    var tint: NSColor?
    /// 正在播放 / 发声的程序图标主色：选“图标色”时用它；选“专辑色”但没有封面时也用它。
    var iconTint: NSColor?
    /// 实际使用的颜色。
    var effectiveTint: NSColor? {
        switch look.tint {
        case .white: return nil
        case .icon: return iconTint ?? tint
        case .album: return tint ?? iconTint
        }
    }
    /// 是否有正在播放的媒体（决定播放按钮是否出现）与播放状态。
    var hasMedia = false
    /// 最左边是圆形封面（灵动岛据此让它和胶囊圆头同心）。
    var leadsWithCircle: Bool { artwork != nil && look.cover == .circle }
    /// 正在播放的应用图标（按钮最右侧，点了打开该应用）。
    var appIcon: CGImage? {
        didSet {
            if window != nil, oldValue != nil, appIcon != nil, oldValue !== appIcon { Self.crossfade(controlLayers[3]) }
            controlLayers[3].contents = appIcon
        }
    }

    private static func crossfade(_ layer: CALayer) {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = ColorFade.duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "contents")
    }

    // 颜色过渡：目标颜色变了，就从旧颜色在约半秒内过渡过去（nil 表示白色 / 黑底，由各处自行解释）
    private var shownTarget: NSColor??               // 上一次画用的目标颜色；外层 nil 表示还没画过
    private var tintFade: (from: NSColor?, start: Date)?
    private var tintTimer: Timer?

    private var tintProgress: CGFloat? {
        guard let tintFade else { return nil }
        let t = CGFloat(Date().timeIntervalSince(tintFade.start) / ColorFade.duration)
        return t >= 1 ? nil : 1 - pow(1 - t, 3)
    }

    /// 按当前过渡进度取颜色：make 把“某个颜色（可为 nil）”变成实际要画的颜色。
    private func tinted(_ make: (NSColor?) -> NSColor) -> NSColor {
        guard let progress = tintProgress, let from = tintFade?.from as NSColor?? else { return make(effectiveTint) }
        return ColorFade.mix(make(from), make(effectiveTint), progress)
    }

    private func trackTint() {
        let target = effectiveTint
        defer { shownTarget = .some(target) }
        guard let previous = shownTarget, previous != target, window != nil else { return }
        tintFade = (previous, Date())
        tintTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.tintProgress == nil { timer.invalidate(); self.tintFade = nil }
            self.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        tintTimer = timer
    }

    var playing = false { didSet { if oldValue != playing { refresh(); updateSpin() } } }
    /// 视频：网页和视频播放器通常不支持上一首 / 下一首，只显示播放暂停。
    /// 只有播放暂停（应用不支持上一首 / 下一首：语音消息、网页视频等）。
    var playPauseOnly = false { didSet { if oldValue != playPauseOnly { controlImagesKey = ""; refresh() } } }
    private var controlCommands: [NowPlayingMonitor.Command] { playPauseOnly ? [.togglePlayPause] : [.previous, .togglePlayPause, .next] }
    /// 放在指标灵动岛里：底色由灵动岛统一画，这里不画胶囊，但按深色底配色。
    var embedded = false { didSet { appearance = embedded ? NSAppearance(named: .darkAqua) : nil; refresh() } }

    /// 正在播放的是传统音乐软件：只有这时显示暂停 / 切歌按钮，视频、网页、游戏都不显示
    var musicApp = false { didSet { if oldValue != musicApp { controlImagesKey = ""; refresh() } } }
    private var showsControls: Bool { look.controls && hasMedia && musicApp }
    /// 右侧圆形图标：音乐模式跟随播放按钮；其他程序发声时单独显示它的图标。
    private var showsIcon: Bool { appIcon != nil && (showsControls || !hasMedia || !musicApp) }
    /// 最右边是圆形的播放器图标（排在胶囊右端时让它和圆头同心）。
    var trailsWithCircle: Bool { showsIcon }

    /// 菜单栏项需要的宽度。
    var preferredWidth: CGFloat {
        var width = Self.contentWidth
        if artwork != nil { width += Self.artworkSize + (showsControls ? Self.groupGap - Self.controlInset : Self.groupGap) }
        if showsControls {
            width += Self.controlWidth * CGFloat(controlCommands.count) + Self.groupGap - Self.controlInset
        }
        if showsIcon { width += Self.groupGap + Self.artworkSize }
        if !embedded { width += Self.backdropPadding * 2 }
        return ceil(width) + 6
    }

    private let backdropLayer: CAGradientLayer = {
        let layer = CAGradientLayer()
        layer.startPoint = CGPoint(x: 0, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 0.5)
        return layer
    }()
    private let artworkLayer = CALayer()
    private let controlLayers = (0..<4).map { _ in CALayer() }
    private var controlFrames: [(CGRect, NowPlayingMonitor.Command)] = []
    private var controlImagesKey = ""
    private var bars: [CALayer] = []
    private var dots: [[CALayer]] = []       // 点阵样式：每列 6 格
    private var lastLevels: [Float]?
    private var lastAudible = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true   // 动画中变窄时裁掉超出的内容
        backdropLayer.cornerCurve = .continuous
        layer?.addSublayer(backdropLayer)
        for _ in 0..<SpectrumAnalyzer.bandCount {
            let bar = CALayer()
            bar.cornerRadius = Self.barWidth / 2
            layer?.addSublayer(bar)
            bars.append(bar)
            var column: [CALayer] = []
            for _ in 0..<Self.dotCount {
                let dot = CALayer()
                dot.cornerRadius = 0.4
                layer?.addSublayer(dot)
                column.append(dot)
            }
            dots.append(column)
        }
        artworkLayer.cornerRadius = 3.5
        artworkLayer.masksToBounds = true
        artworkLayer.borderWidth = 1
        artworkLayer.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
        artworkLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(artworkLayer)
        for control in controlLayers {
            control.contentsGravity = .center
            layer?.addSublayer(control)
        }
        update([Float](repeating: 0, count: SpectrumAnalyzer.bandCount), audible: false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // 点击交给菜单栏按钮

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? 2
        controlLayers.forEach { $0.contentsScale = scale }
        controlImagesKey = ""
        refresh()
    }

    /// 点在哪个播放按钮上（视图坐标）；不在按钮上返回 nil。
    func command(at point: NSPoint) -> NowPlayingMonitor.Command? {
        controlFrames.first { $0.0.insetBy(dx: -1, dy: -4).contains(point) }?.1
    }

    /// 圆形封面播放时缓慢旋转（像黑胶），暂停时停在当前角度；圆角封面不转。
    private func updateSpin() {
        let layer = artworkLayer
        guard look.cover == .circle, look.spin else {
            layer.removeAnimation(forKey: "spin")
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            return
        }
        if layer.animation(forKey: "spin") == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi   // 顺时针
            spin.duration = 12
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            layer.speed = 0
            layer.timeOffset = 0
            layer.add(spin, forKey: "spin")
        }
        let shouldSpin = playing && artwork != nil
        if shouldSpin, layer.speed == 0 {
            let paused = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
        } else if !shouldSpin, layer.speed != 0 {
            let now = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = now
        }
    }

    /// 离屏渲染（README 截图）：layer.render(in:) 画圆形裁切的封面会错位，
    /// 所以先隐藏封面图层渲染其余部分，再按封面图层的位置手动画出封面和描边。
    func renderSnapshot(in context: CGContext) {
        let showsArtwork = !artworkLayer.isHidden
        artworkLayer.isHidden = true
        layer?.render(in: context)
        artworkLayer.isHidden = !showsArtwork
        guard showsArtwork, let content = artworkLayer.contents else { return }
        let image = content as! CGImage
        let rect = CGRect(x: artworkLayer.position.x - artworkLayer.bounds.width / 2, y: artworkLayer.position.y - artworkLayer.bounds.height / 2,
                          width: artworkLayer.bounds.width, height: artworkLayer.bounds.height)
        let radius = artworkLayer.cornerRadius
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(image, in: rect)
        context.restoreGState()
        context.saveGState()
        let inner = rect.insetBy(dx: 0.5, dy: 0.5)
        context.addPath(CGPath(roundedRect: inner, cornerWidth: max(radius - 0.5, 0), cornerHeight: max(radius - 0.5, 0), transform: nil))
        context.setStrokeColor(artworkLayer.borderColor ?? NSColor.white.withAlphaComponent(0.45).cgColor)
        context.setLineWidth(artworkLayer.borderWidth)
        context.strokePath()
        context.restoreGState()
    }

    func refresh() {
        update(lastLevels ?? [Float](repeating: 0, count: SpectrumAnalyzer.bandCount), audible: lastAudible)
    }

    func update(_ levels: [Float], audible: Bool) {
        lastLevels = levels
        lastAudible = audible
        // 有底色时一律按深色底绘制
        let onBackdrop = true   // 总有深色底色
        let dark = onBackdrop || effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base = dark ? NSColor.white : NSColor.black
        let fg = base.withAlphaComponent(dark ? 1 : 0.85)
        let dim = base.withAlphaComponent(dark ? 0.55 : 0.5)
        let faint = base.withAlphaComponent(dark ? 0.18 : 0.14)
        let height = bounds.height
        let hasArtwork = artwork != nil
        // 出场 / 入场动画时视图比内容窄：胶囊跟着收窄，内容由图层裁掉
        let total = max(min(preferredWidth - 6, bounds.width - 6), 0)
        var x = (bounds.width - total) / 2

        trackTint()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 底色：胶囊形，黑色或专辑色（压暗）
        backdropLayer.isHidden = embedded
        if !embedded {
            let capsule = CGRect(x: x, y: 0.5, width: total, height: height - 1)
            backdropLayer.frame = capsule
            backdropLayer.cornerRadius = min(capsule.height, capsule.width) / 2
            let colors = [0, 1].map { index in tinted { tint in let stops = look.backdropColors(tint: tint); return stops[min(index, stops.count - 1)] } }
            backdropLayer.colors = (colors.count == 1 ? [colors[0], colors[0]] : colors).map(\.cgColor)
            x += Self.backdropPadding
        }

        artworkLayer.isHidden = !hasArtwork
        if hasArtwork {
            // 用 bounds + position 定位：图层在旋转，frame 不可靠
            artworkLayer.bounds = CGRect(x: 0, y: 0, width: Self.artworkSize, height: Self.artworkSize)
            artworkLayer.position = CGPoint(x: x + Self.artworkSize / 2, y: height / 2)
            artworkLayer.cornerRadius = look.cover == .circle ? Self.artworkSize / 2 : 3.5
            x += Self.artworkSize + (showsControls ? Self.groupGap - Self.controlInset : Self.groupGap)
        }

        // 播放按钮：上一首 / 播放暂停 / 下一首
        controlFrames = []
        let commands = controlCommands
        controlLayers.prefix(3).enumerated().forEach { $1.isHidden = !showsControls || $0 >= commands.count }
        if showsControls {
            let symbols = commands.map { command -> String in
                switch command {
                case .previous: return "backward.end.fill"
                case .next: return "forward.end.fill"
                default: return playing ? "pause.fill" : "play.fill"
                }
            }
            // 按钮跟频谱同色（调浅一些，深色底上更清楚）
            let controlColor = tinted { look.color(level: 1, album: $0, base: fg, lighten: true) }.withAlphaComponent(1)
            let key = symbols.joined() + "\(dark)" + controlColor.description
            for (index, control) in controlLayers.prefix(commands.count).enumerated() {
                let frame = CGRect(x: x, y: 0, width: Self.controlWidth, height: height)
                // 图层只占字形高度，按比例缩放；点击范围仍是整列
                control.frame = CGRect(x: x, y: ((height - Self.controlHeight) / 2).rounded(), width: Self.controlWidth, height: Self.controlHeight)
                control.contentsGravity = .resizeAspect
                controlFrames.append((frame, commands[index]))
                if key != controlImagesKey {
                    // 三个按钮同样高度，和封面、频谱的视觉高度协调
                    control.contents = Self.symbolImage(symbols[index], height: Self.controlHeight, color: controlColor)
                }
                x += Self.controlWidth
            }
            controlImagesKey = key
            x += Self.groupGap - Self.controlInset
        }

        let bottom = (height - Self.artworkSize) / 2
        let maxHeight = Self.artworkSize
        for index in bars.indices {
            let level = CGFloat(index < levels.count ? levels[index] : 0)
            let barX = x + CGFloat(index) * (Self.barWidth + Self.gap)
            let main = tinted { look.color(level: 1, album: $0, base: fg, lighten: onBackdrop) }
            if look.shape == .dots {
                bars[index].isHidden = true
                let size = Self.barWidth, spacing = (Self.artworkSize - size * CGFloat(Self.dotCount)) / CGFloat(Self.dotCount - 1)
                let lit = audible ? Int((level * CGFloat(Self.dotCount)).rounded(.up)) : 0
                for (row, dot) in dots[index].enumerated() {
                    dot.isHidden = false
                    dot.frame = CGRect(x: barX, y: bottom + CGFloat(row) * (size + spacing), width: size, height: size)
                    dot.backgroundColor = (row < max(lit, 1) ? (row < lit ? main : dim) : faint).cgColor
                }
                continue
            }
            dots[index].forEach { $0.isHidden = true }
            let bar = bars[index]
            bar.isHidden = false
            let barHeight = audible ? max(2, maxHeight * level) : 2
            bar.frame = CGRect(x: barX, y: bottom, width: Self.barWidth, height: barHeight)
            bar.backgroundColor = tinted { look.color(level: level, album: $0, base: fg, lighten: onBackdrop) }.cgColor
        }
        // 播放器图标：圆形，放在最右侧，与左侧封面对称
        let iconLayer = controlLayers[3]
        iconLayer.isHidden = !showsIcon
        if showsIcon {
            let iconX = x + Self.contentWidth + Self.groupGap
            let frame = CGRect(x: iconX, y: (height - Self.artworkSize) / 2, width: Self.artworkSize, height: Self.artworkSize)
            iconLayer.frame = frame
            iconLayer.contentsGravity = .resizeAspectFill
            iconLayer.cornerRadius = Self.artworkSize / 2
            iconLayer.masksToBounds = true
            iconLayer.borderWidth = 1
            iconLayer.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
            controlFrames.append((frame.insetBy(dx: -2, dy: -(height - Self.artworkSize) / 2), .openApp))
        }
        CATransaction.commit()
    }

    /// 裁掉符号图自带的留白，只留可见字形（图层按固定高度缩放显示，三个按钮高度一致）。
    private static func symbolImage(_ name: String, height: CGFloat, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config),
              let cg = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        // 找不透明像素的范围
        let w = cg.width, h = cg.height, row = cg.bytesPerRow, step = cg.bitsPerPixel / 8
        let alphaOffset = cg.alphaInfo == .premultipliedFirst || cg.alphaInfo == .first ? 0 : step - 1
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where bytes[y * row + x * step + alphaOffset] > 24 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY,
              let cropped = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else { return symbol }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }
}

/// 管理菜单栏频谱项：开关、截取、刷新节奏、点开的面板。
final class SpectrumController: NSObject, NSPopoverDelegate {
    static let shared = SpectrumController()
    static let defaultsKey = "showSpectrum"

    private let analyzer = SpectrumAnalyzer()
    private var item: NSStatusItem?
    private var barsView: SpectrumBarsView?
    /// 合并进指标灵动岛时的宿主；nil 表示自己单独一个菜单栏项。
    private weak var host: SpectrumHost?
    private var embeddedShown = false
    private var embeddedWidth: CGFloat = 0
    /// 频谱是否显示（单独的菜单栏项可见，或在灵动岛里展开）。
    private var shown: Bool {
        get { host != nil ? embeddedShown : item?.isVisible ?? false }
        set {
            if host != nil {
                guard embeddedShown != newValue else { return }
                embeddedShown = newValue
                host?.spectrumLayoutChanged()
            } else if animatingTo ?? (item?.isVisible ?? false) != newValue {
                animateItem(show: newValue)
            }
        }
    }

    private var itemAnimation: Timer?
    private var animatingTo: Bool?   // 动画进行中的目标状态

    /// 单独显示时频谱出现 / 消失：宽度从 0 展开（略带回弹）并淡入；消失时收拢淡出后再隐藏。两侧图标随宽度平滑移动。
    private func animateItem(show: Bool) {
        guard let item, let barsView else { return }
        itemAnimation?.invalidate()
        animatingTo = show
        let target = barsView.preferredWidth
        let from = item.isVisible ? item.length : 0
        if show && !item.isVisible {
            item.length = 0
            barsView.alphaValue = 0
            item.isVisible = true
        }
        let to: CGFloat = show ? target : 0
        let duration = show ? 0.42 : 0.24
        let alphaFrom = barsView.alphaValue, alphaTo: CGFloat = show ? 1 : 0
        let curve: (Double) -> Double = show
            ? { t in let c = 1.3, u = t - 1; return 1 + (c + 1) * u * u * u + c * u * u }   // 回弹
            : { t in t * t }
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(Date().timeIntervalSince(start) / duration, 1)
            item.length = max(0, (from + (to - from) * CGFloat(curve(t))).rounded())
            barsView.alphaValue = alphaFrom + (alphaTo - alphaFrom) * CGFloat(min(t * 1.25, 1))
            barsView.refresh()
            if t >= 1 {
                timer.invalidate()
                self.animatingTo = nil
                if show {
                    item.length = barsView.preferredWidth
                } else {
                    item.isVisible = false
                    item.length = barsView.preferredWidth
                    barsView.alphaValue = 1
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        itemAnimation = timer
    }
    /// 灵动岛里频谱部分：是否展开、宽度、视图。
    var embeddedLayout: (view: SpectrumBarsView, width: CGFloat)? {
        guard host != nil, embeddedShown, let barsView else { return nil }
        return (barsView, barsView.preferredWidth)
    }
    /// 灵动岛整体底色：跟随频谱“底色”设置；专辑色只在频谱展开且有封面颜色时用。
    var islandBackdrop: [NSColor] {
        SpectrumLook.current.backdropColors(tint: embeddedShown ? barsView?.effectiveTint : nil)
    }

    /// 切换单独显示 / 合并进灵动岛。
    func setHost(_ newHost: SpectrumHost?) {
        guard newHost !== host else { return }
        popover.performClose(nil)
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        barsView?.removeFromSuperview()
        barsView = nil
        host?.embed(nil)
        embeddedShown = false
        host?.spectrumLayoutChanged()
        host = newHost
        if Self.isEnabled, started { apply() }
    }

    /// 灵动岛里点了频谱部分。
    func hostClicked(_ sender: NSView, anchor: NSRect) {
        handleClick(sender, anchor: anchor)
    }

    func closePanel() { popover.performClose(nil) }
    /// 合并进灵动岛时的频谱视图（不论当前是否展开）。
    var hostedBars: SpectrumBarsView? { host != nil ? barsView : nil }

    let visualizer = VisualizerWindowController()

    /// 全屏频谱：在面板所在的屏幕上打开。
    func openVisualizer() {
        let screen = popover.contentViewController?.view.window?.screen ?? NSScreen.main
        popover.performClose(nil)
        visualizer.model.setNowPlaying(panel.nowPlaying, source: panel.source)
        visualizer.open(on: screen)
        schedule(fast: true)
    }
    private var started = false
    private var timer: Timer?
    private var quietSince: Date?
    private var fast = false
    private var revealUntil: Date?          // 刚打开开关时先显示一会儿，让人看到它在哪
    private let panel = SpectrumPanelModel()
    private let popover = NSPopover()
    private var clickMonitor: Any?
    private var nowPlayingSubscription: AnyCancellable?
    private var playerBundle: String?
    /// 不是音乐播放器在发声时的来源程序（游戏、剪辑软件、会议等）。
    private var source: SoundSource?
    private var sourceCheckedAt = Date.distantPast

    /// 其他程序（非音乐播放器）的声音是否显示频谱。
    static var showsOtherSounds: Bool { UserDefaults.standard.object(forKey: "spectrumOtherSounds") as? Bool ?? true }

    /// 应用图标栅格化成 CGImage（直接用 NSWorkspace 图标在图层里会发暗）。
    static func appIcon(bundle: String) -> CGImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return rasterizedIcon(NSWorkspace.shared.icon(forFile: url.path), inset: 0.12)
    }

    static func rasterizedIcon(_ icon: NSImage, inset ratio: CGFloat) -> CGImage? {
        let side = 48
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        // 应用图标的底板约占画布 80%：放大绘制，让圆形裁切后正好是底板颜色
        let inset = CGFloat(side) * ratio
        icon.draw(in: NSRect(x: -inset, y: -inset, width: CGFloat(side) + inset * 2, height: CGFloat(side) + inset * 2))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }

    /// 打开（切到）正在播放的应用。
    private func openPlayer() {
        if let source { source.activate(); return }
        guard let playerBundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: playerBundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// 由主程序设置：打开设置窗口。
    var openSettings: () -> Void = {}
    /// 右键菜单（设置、关于、退出），由主程序提供。
    var showContextMenu: (NSView) -> Void = { _ in }

    /// 安静多久后隐藏（秒）；0 表示一直显示。
    static var hideDelay: TimeInterval {
        TimeInterval(UserDefaults.standard.object(forKey: "spectrumHideDelay") as? Int ?? 10)
    }
    static let hideDelayChoices: [(Int, String)] = [(1, "立即"), (10, "10 秒"), (0, "不隐藏")]

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    /// 在所有指标项之后调用：后创建的排在左边，即 CPU 左侧。
    func start() {
        let hosting = NSHostingController(rootView: SpectrumPanelView(model: panel))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        panel.onLook = { [weak self] in self?.setLook($0) }
        panel.onPrivacy = { [weak self] in self?.openPrivacy() }
        panel.onSettings = { [weak self] in
            self?.popover.performClose(nil)
            self?.openSettings()
        }
        panel.onQuit = { NSApp.terminate(nil) }
        panel.onFullscreen = { [weak self] in self?.openVisualizer() }
        visualizer.model.onCommand = { NowPlayingMonitor.shared.send($0) }
        visualizer.onClosed = { [weak self] in self?.schedule(fast: false) }
        panel.onCommand = { [weak self] command in
            if command == .openApp { self?.popover.performClose(nil); self?.openPlayer(); return }
            NowPlayingMonitor.shared.send(command)
        }
        nowPlayingSubscription = NowPlayingMonitor.shared.$info.receive(on: DispatchQueue.main).sink { [weak self] info in
            self?.showNowPlaying(info)
        }
        // 音乐软件打开 / 退出：没上报“正在播放”的（如 QQ 音乐播放前）也先显示它的图标
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshRunningMusicApp() }
        }
        refreshRunningMusicApp()
        started = true
        watchOutputDevice()
        apply()
    }

    /// 输出设备换了（插拔耳机、外接声卡、切换输出）：截取以旧设备为时钟，设备拔掉后会停住，重建一次。
    /// 通知会连着来好几次：等 1 秒安静下来再看，设备没变就不动。
    private var outputWork: DispatchWorkItem?
    private lazy var outputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.outputWork?.cancel()
        let work = DispatchWorkItem { self?.restartCaptureIfNeeded() }
        self?.outputWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func watchOutputDevice() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        AudioSystem.listen(system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, outputListener)
        AudioSystem.listen(system, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, outputListener)
    }

    private func restartCaptureIfNeeded() {
        guard Self.isEnabled, timer != nil, analyzer.isRunning,
              let uid = try? SpectrumAnalyzer.defaultOutputUID(), uid != analyzer.deviceUID else { return }
        analyzer.stop()
        startCapture()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
        if !enabled { popover.performClose(nil) }
        apply()
        if enabled {
            // 安静时打开开关：先显示 5 秒，否则菜单栏上看不出任何变化
            revealUntil = Date(timeIntervalSinceNow: 5)
            shown = true
        }
    }

    /// 封面、主色更新到菜单栏和面板；有封面时菜单栏项加宽放下小封面。
    private func showNowPlaying(_ info: NowPlayingInfo?) {
        if info?.playing == true { source = nil; silentChecks = 0 }   // 音乐开始播放：回到音乐模式
        sourceCheckedAt = .distantPast               // 下一帧就重新查是谁在发声
        render()
    }

    /// 按“谁在发声”决定显示：音乐播放中 → 封面、按钮、播放器图标；
    /// 其他程序在发声 → 白色频谱 + 该程序图标；否则沿用（暂停的）播放信息。
    private func render() {
        let info = displayInfo
        panel.source = source
        if let source {
            panel.nowPlaying = nil
            barsView?.tint = nil
            barsView?.artwork = nil
            barsView?.hasMedia = false
            barsView?.musicApp = false
            playerBundle = nil
            sourceIconPID = source.pid
            barsView?.appIcon = source.cgIcon
            currentIconTint = source.icon.flatMap(NowPlayingMonitor.dominantColor(of:))
            barsView?.iconTint = currentIconTint
            barsView?.playing = false
        } else {
            panel.nowPlaying = info?.placeholder == true ? nil : info
            barsView?.tint = info?.tint
            barsView?.artwork = info?.isVideo == true ? nil : info?.artwork
            barsView?.hasMedia = info != nil
            barsView?.musicApp = info?.isMusicApp == true && info?.placeholder != true   // 占位时没有按钮
            // 视图刚建好时图标还没设（信息可能比视图先到）：也要补上
            if info?.bundle != playerBundle || sourceIconPID != nil || barsView?.appIcon == nil || (info?.bundle != nil && currentIconTint == nil) {
                sourceIconPID = nil
                playerBundle = info?.bundle
                barsView?.appIcon = playerBundle.flatMap(Self.appIcon(bundle:))
                currentIconTint = playerBundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                    .map { NSWorkspace.shared.icon(forFile: $0.path) }.flatMap(NowPlayingMonitor.dominantColor(of:))
                barsView?.iconTint = currentIconTint
            }
            barsView?.playing = info?.playing ?? false
            barsView?.playPauseOnly = !(info?.canSkip ?? true)
        }
        let albumTint = source == nil ? info?.tint : nil
        let effectiveTint = SpectrumLook.current.tint == .icon
            ? (currentIconTint ?? albumTint)
            : (albumTint ?? currentIconTint)
        panel.accentTint = effectiveTint
        barsView?.refresh()
        resize()
        if host != nil { host?.spectrumLayoutChanged() }   // 底色可能随封面颜色变化
        visualizer.model.setNowPlaying(panel.nowPlaying, source: panel.source, tint: effectiveTint)
    }
    private var sourceIconPID: pid_t?
    private var currentIconTint: NSColor?

    /// 正在运行的音乐软件（几个都开着时取最近打开的）
    private var runningMusicApp: String?
    private func refreshRunningMusicApp() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier.map(NowPlayingMonitor.isMusicApp) == true
        }
        let next = apps.max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }?.bundleIdentifier
        guard next != runningMusicApp else { return }
        runningMusicApp = next
        render()
    }

    /// 岛上音乐段显示的播放信息：系统“正在播放”是音乐软件就用它；不是（或没有）而有音乐软件开着，
    /// 就显示那个音乐软件（占位：图标和颜色，没有按钮）；视频等正在播放时仍显示视频
    private var displayInfo: NowPlayingInfo? {
        let info = NowPlayingMonitor.shared.info
        if info?.isMusicApp == true || info?.playing == true { return info }
        guard let bundle = runningMusicApp else { return info }
        var placeholder = NowPlayingInfo()
        placeholder.bundle = bundle
        placeholder.playing = false
        placeholder.placeholder = true
        return placeholder
    }

    /// 读屏：岛上音乐部分现在显示的是谁，如“正在播放 网易云音乐 · 晴天”“正在发声 QuickTime Player”。
    var accessibilitySummary: String? {
        if let source { return "正在发声 \(source.name)" }
        guard let info = NowPlayingMonitor.shared.info else { return nil }
        let app = info.bundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? ""
        let title = info.title.isEmpty ? "" : " · \(info.title)"
        return "\(info.playing ? "正在播放" : "已暂停") \(app)\(title)"
    }
    private let sourceQueue = DispatchQueue(label: "local.codex.islet.spectrum.source")

    /// 有声音时每半秒查一次“谁真的在发声”（CoreAudio 的进程输出），以它为准：
    /// - 正在播放的应用确实在出声（或查不到别人）→ 显示它的封面和按钮；
    /// - 它报告“播放中”却没出声、而别的程序在出声（连续两次）→ 显示真正在出声的程序；
    /// - 它已暂停 → 显示其他正在出声的程序（包括另一个音乐播放器，比如暂停视频后还在放的网易云）。
    /// 返回是否应当显示频谱。
    private func updateSource(audible: Bool) -> Bool {
        let info = NowPlayingMonitor.shared.info
        guard audible else {
            // 安静时保持当前显示，交给隐藏逻辑；但发声的程序已经退出，就不再显示它的图标
            if let source, kill(source.pid, 0) != 0, errno == ESRCH {
                self.source = nil
                render()
            }
            return true
        }
        if Date().timeIntervalSince(sourceCheckedAt) > 0.5 {
            sourceCheckedAt = Date()
            // 后台查：第一次读转译游戏的 exe 图标要零点几秒，别卡住菜单栏
            sourceQueue.async { [weak self] in
                let sources = SoundSource.current()
                DispatchQueue.main.async { self?.chooseSource(from: sources) }
            }
        }
        if info?.playing == true, source == nil { return true }
        // 没在播放、也查不到是哪个程序在出声：是通知音等系统声音，不展开（否则会顶着暂停的播放器信息展开）
        guard let source else { return false }
        let isPlayer = source.bundle.map { NowPlayingMonitor.musicPlayers.contains($0) } ?? false
        return isPlayer || Self.showsOtherSounds
    }

    private var silentChecks = 0   // 正在播放的应用连续几次没出声

    private func chooseSource(from sources: [SoundSource]) {
        let info = NowPlayingMonitor.shared.info
        let others = sources.filter { $0.bundle == nil || $0.bundle != info?.bundle }
        var next: SoundSource?
        if info?.playing == true {
            let audible = sources.contains { $0.bundle != nil && $0.bundle == info?.bundle }
            silentChecks = audible || others.isEmpty ? 0 : silentChecks + 1
            next = silentChecks >= 2 ? others.first : nil
        } else {
            silentChecks = 0
            // 暂停后的播放器常常还占着声音输出一阵子：不算它
            next = others.first
        }
        if next != source { source = next; render() }
    }

    func otherSoundsChanged() {
        sourceCheckedAt = .distantPast
    }

    private func apply() {
        guard Self.isEnabled else {
            timer?.invalidate()
            timer = nil
            analyzer.stop()
            NowPlayingMonitor.shared.stop()
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            barsView?.removeFromSuperview()
            barsView = nil
            if host != nil {
                host?.embed(nil)
                embeddedShown = false
                host?.spectrumLayoutChanged()
            }
            return
        }
        if let host, barsView == nil {
            let view = SpectrumBarsView(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
            view.embedded = true
            barsView = view
            host.embed(view)
            embeddedShown = Self.hideDelay == 0
            showNowPlaying(NowPlayingMonitor.shared.info)
            host.spectrumLayoutChanged()
        }
        if host == nil, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: ceil(SpectrumBarsView.contentWidth) + 6)
            item.autosaveName = StatusItemNames.name("spectrum")
            if let button = item.button {
                button.setAccessibilityLabel("音乐频谱")
                button.target = self
                button.action = #selector(togglePanel(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                let view = SpectrumBarsView(frame: button.bounds)
                view.autoresizingMask = [.width, .height]
                button.addSubview(view)
                barsView = view
            }
            item.isVisible = Self.hideDelay == 0  // 安静时隐藏，有声音才出现
            self.item = item
            showNowPlaying(NowPlayingMonitor.shared.info)
            resize()
        }
        startCapture()
        NowPlayingMonitor.shared.start()
        schedule(fast: false)
    }

    /// 在后台线程启动截取：首次会弹出“系统录音”权限请求，系统在用户点选之前不会返回，
    /// 放在主线程会让整个程序（包括菜单栏指标）卡住。
    private let startQueue = DispatchQueue(label: "local.codex.islet.spectrum.start")
    private func startCapture() {
        let analyzer = self.analyzer
        startQueue.async { [weak self] in
            analyzer.start()
            DispatchQueue.main.async { self?.panel.error = analyzer.error }
        }
    }

    // MARK: 面板

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        handleClick(sender, anchor: sender.bounds)
    }

    private func handleClick(_ sender: NSView, anchor: NSRect) {
        // 右键（或按住 Control 点击）：原生菜单
        if let event = NSApp.currentEvent, event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            popover.performClose(nil)
            showContextMenu(sender)
            return
        }
        // 点在菜单栏的播放按钮上：直接控制播放，不打开面板
        if !popover.isShown, let barsView, let window = sender.window {
            let point = barsView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if let command = barsView.command(at: point) {
                if command == .openApp {
                    openPlayer()
                    return
                }
                NowPlayingMonitor.shared.send(command)
                if command == .togglePlayPause { barsView.playing.toggle() }
                return
            }
        }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // 音乐软件还没开始播放（占位）：点了直接打开它
        if source == nil, displayInfo?.placeholder == true {
            openPlayer()
            return
        }
        panel.look = SpectrumLook.current
        panel.error = analyzer.error
        popover.appearance = NSAppearance(named: .aqua)   // 面板统一浅色
        popover.showAboveApps(relativeTo: anchor, of: sender, preferredEdge: .minY)
        schedule(fast: true)  // 面板里的大号频谱需要实时刷新
        SoundController.shared.controlsWillShow()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        SoundController.shared.controlsDidHide()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    func hideDelayChanged() {
        if Self.hideDelay == 0 { shown = true }
    }

    func setLook(_ look: SpectrumLook) {
        look.save()
        panel.look = look
        barsView?.look = look
        resize()
    }

    private func resize() {
        guard let barsView else { return }
        if host != nil {
            if embeddedWidth != barsView.preferredWidth {
                embeddedWidth = barsView.preferredWidth
                host?.spectrumLayoutChanged()
            }
            return
        }
        guard animatingTo == nil, let item, item.length != barsView.preferredWidth else { return }
        item.length = barsView.preferredWidth
    }

    private func openPrivacy() {
        popover.performClose(nil)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 刷新

    /// 有声音（或面板打开）时每秒 30 帧；安静 1.5 秒后降到每秒 4 次，只做检测。
    private func schedule(fast: Bool) {
        guard timer == nil || fast != self.fast else { return }
        self.fast = fast
        timer?.invalidate()
        let timer = Timer(timeInterval: fast ? 1.0 / 30 : 0.25, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = fast ? 0.005 : 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        // 截取没在运行（没权限、出错）也照常走：电平全是 0，靠“正在播放”决定是否显示
        guard let barsView else { return }
        var (levels, audible) = analyzer.analyze()
        // 其他程序的声音设为不显示时：当作没有声音
        if !updateSource(audible: audible) { audible = false }
        let showingPanel = popover.isShown || visualizer.isOpen
        // 只有面板真的开着才推送：面板关着时更新它的数据会让整张卡片每帧重算（全屏时尤其浪费）
        if popover.isShown {
            panel.levels = levels
            panel.audible = audible
        }
        if visualizer.isOpen {
            visualizer.model.bars.push(levels, audible: audible)
            visualizer.model.setAudible(audible)
        }
        if audible {
            quietSince = nil
            if !shown { shown = true }
            if !fast { schedule(fast: true) }
            barsView.update(levels, audible: true)
            return
        }
        if quietSince == nil { quietSince = Date() }
        let quietFor = Date().timeIntervalSince(quietSince ?? Date())
        let quietLong = quietFor > 1.5
        let revealing = revealUntil.map { $0 > Date() } ?? false
        // 播放器还在“播放中”（切歌间隙、安静段落）不隐藏；暂停 / 停止后安静超过设定时间才隐藏
        let playing = NowPlayingMonitor.shared.info?.playing == true
        // 音乐软件暂停了：一直显示（随时能点继续），退出软件、“正在播放”信息消失才收起
        let musicPaused = displayInfo?.isMusicApp == true && source == nil
        if musicPaused, !shown { shown = true }
        // 播放器报告正在播放、却截不到声音（没有“系统录音”权限、系统静音、音量为 0）：照样展开封面和按钮，频谱是平的
        if playing, source == nil, !shown { shown = true }
        let delay = Self.hideDelay
        if delay > 0, quietFor > delay, !playing, !musicPaused, !showingPanel, !revealing {
            if shown { shown = false }
            if fast { schedule(fast: false) }
        } else {
            barsView.update(levels, audible: !quietLong)  // 回落过程继续画，平滑收尾；之后显示安静状态
            // 安静但还显示着：降到每秒 4 次，省得空转
            if quietLong, fast, !showingPanel { schedule(fast: false) }
        }
    }

    /// 睡眠 / 锁屏时停止截取，唤醒后恢复。
    func suspend() {
        timer?.invalidate()
        timer = nil
        analyzer.stop()
    }

    func resume() {
        guard Self.isEnabled, item != nil || host != nil else { return }
        startCapture()
        schedule(fast: false)
    }
}
