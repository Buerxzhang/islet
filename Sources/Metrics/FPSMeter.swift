import AppKit
import CoreMedia
import ScreenCaptureKit

/// 帧率：用 ScreenCaptureKit 盯住一整块屏幕，统计每秒画面实际变化了几次（islet 自己的窗口不算）。
/// 只数帧、不看画面：捕获尺寸压到很小，每帧只算一个内容指纹用来比较，算完就丢，不保存、不上传。
/// 需要“屏幕录制”权限。静止时读数会降低，同屏其他动画也会计入。
/// 只统计缩略图内容有变化的帧，足够小的变化可能会漏掉。
final class FPSMeter: NSObject, SCStreamOutput, SCStreamDelegate {
    enum MeterError: Error { case noDisplay }

    /// 每秒回调一次（主线程）：画面变化次数、屏幕名称。
    /// 帧数为 -1 表示捕获意外停止（屏幕断开等），调用方可以重新开始。
    var onSample: (Int, String) -> Void = { _, _ in }
    /// 走查用：启动过程中的每一步。
    var onStep: (String) -> Void = { _ in }
    private(set) var targetName = ""
    /// 被测屏幕的最高刷新率，用作面板参考。
    private(set) var refreshRate = 60
    /// 被测屏幕（前台窗口换到别的屏幕时要换目标）。
    private(set) var targetDisplay: CGDirectDisplayID?

    private var stream: SCStream?
    // 高优先级队列：处理慢了系统会直接丢帧，测出来就偏低
    private let queue = DispatchQueue(label: "islet.fps", qos: .userInteractive)
    /// 测量期间告诉系统别把 islet 降速（App Nap）：菜单栏程序长期在后台，被降速后会漏掉大量帧
    private var activity: NSObjectProtocol?
    private var frames = 0                 // 只在 queue 上读写
    private var lastFingerprint: UInt64?
    private var ticker: DispatchSourceTimer?

    /// 前台程序最大的那个窗口所在的屏幕；前台程序没有窗口（如只有桌面）时用主屏幕。
    static func frontmostDisplay() -> CGDirectDisplayID {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return CGMainDisplayID() }
        let bounds = list.compactMap { info -> CGRect? in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid, let layer = info[kCGWindowLayer as String] as? Int, layer >= 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict), rect.width >= 100, rect.height >= 100 else { return nil }
            return rect
        }
        guard let largest = bounds.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return CGMainDisplayID() }
        let displays = NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        let overlaps = displays.map { id -> (id: CGDirectDisplayID, area: CGFloat) in
            let overlap = CGDisplayBounds(id).intersection(largest)
            return (id, overlap.isNull ? 0 : overlap.width * overlap.height)
        }
        if let best = overlaps.max(by: { $0.area < $1.area }), best.area > 0 { return best.id }
        return CGMainDisplayID()
    }

    func start(display displayID: CGDirectDisplayID) async throws {
        onStep("读取屏幕列表")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        onStep("屏幕 \(content.displays.count) 块")
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw MeterError.noDisplay
        }
        targetDisplay = display.displayID
        // islet 自己的窗口（岛上的频谱一直在动、面板、设置）不算
        let own = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let aspect = CGFloat(display.height) / CGFloat(max(display.width, 1))
        let screenID = display.displayID
        let screen = await MainActor.run {
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == screenID }
                .map { (name: $0.localizedName, fps: $0.maximumFramesPerSecond) }
        }
        targetName = screen?.name ?? "屏幕"
        refreshRate = screen?.fps ?? 60

        let config = SCStreamConfiguration()
        config.width = 128                                         // 只数帧：画面越小越省；整块屏幕留宽一点，小窗口的变化也看得出
        config.height = max(16, Int((128 * aspect).rounded()))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 240)   // 不限速：画面变一次就送一帧
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 4
        config.showsCursor = false                                  // 鼠标移动不算画面变化
        config.capturesAudio = false

        onStep("目标：\(targetName)，开始捕获")
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "测量屏幕帧率")
        onStep("捕获已开始")

        let ticker = DispatchSource.makeTimerSource(queue: queue)
        var previousTick = ProcessInfo.processInfo.systemUptime
        ticker.schedule(deadline: .now() + 1, repeating: 1)
        ticker.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - previousTick
            guard elapsed > 0 else { return }
            let count = Int((Double(self.frames) / elapsed).rounded())
            previousTick = now
            self.frames = 0
            let name = self.targetName
            let onSample = self.onSample
            DispatchQueue.main.async { onSample(count, name) }
        }
        ticker.resume()
        self.ticker = ticker
    }

    func stop() async {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        ticker?.cancel()
        ticker = nil
        try? await stream?.stopCapture()
        stream = nil
    }

    /// 只数内容真的变了的完整帧
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let fingerprint = Self.fingerprint(pixels), fingerprint != lastFingerprint else { return }
        if lastFingerprint != nil { frames += 1 }
        lastFingerprint = fingerprint
    }

    /// 小图的内容指纹（FNV-1a）：画面没变时指纹相同。
    private static func fingerprint(_ buffer: CVPixelBuffer) -> UInt64? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        var hash: UInt64 = 0xcbf29ce484222325
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                // 只比较可见颜色，忽略 alpha 和行末填充。
                hash = (hash ^ UInt64(row[x] & 0x00ff_ffff)) &* 0x100000001b3
            }
        }
        return hash
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onSample(-1, self.targetName) }
    }
}

/// 走查：--fps-probe <输出文件> <秒数>
/// 测前台窗口所在屏幕的帧率，每秒写一行到文件，结束后退出。不创建菜单栏图标。
enum FPSProbe {
    private static var current: FPSMeter?

    static func run(_ arguments: [String]) {
        let output = URL(fileURLWithPath: arguments[2])
        let seconds = Int(arguments[3]) ?? 10
        FileManager.default.createFile(atPath: output.path, contents: nil)
        func write(_ line: String) {
            guard let handle = try? FileHandle(forWritingTo: output) else { return }
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
        let meter = FPSMeter()
        current = meter   // 留住：否则启动完就被释放，每秒的计数也跟着停了
        meter.onStep = { write("STEP\t\($0)") }
        var count = 0
        meter.onSample = { fps, name in
            write("\(fps)\t\(name)\t\(meter.refreshRate)Hz")
            count += 1
            if count >= seconds || fps < 0 { exit(0) }
        }
        Task {
            do { try await meter.start(display: FPSMeter.frontmostDisplay()) }
            catch { write("ERROR\t\(error)"); exit(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds + 15)) { write("TIMEOUT"); exit(2) }
    }
}
