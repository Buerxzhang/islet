import AppKit
import Combine

/// 菜单栏程序一侧的风扇控制：持久化配置、安装 / 卸载 root 辅助程序、下发配置、定时续约。
/// 只在主线程使用。
final class FanHelperClient: ObservableObject {
    static let shared = FanHelperClient()

    /// 用户的完整配置（持久化）。策略不是“自动”时，启动、唤醒后自动恢复。
    @Published private(set) var config: FanConfig
    /// 辅助程序回报的状态；面板或编辑窗口打开时定时刷新。
    @Published private(set) var status: FanStatus?

    private var connection: NSXPCConnection?
    private var heartbeat: Timer?
    private static let key = "fanConfig"

    private init() {
        let stored = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(FanConfig.self, from: $0) }
        var config = stored ?? FanConfig()
        if config.curve.isEmpty, let fan = Fan.readAll().first {
            config.curve = CurvePreset.balanced.points(minimum: fan.minimum, maximum: fan.maximum)
        }
        if config.rules.isEmpty, let fan = Fan.readAll().first {
            // 示例规则（默认关闭）：让第一次打开规则窗口时有个可改的起点
            config.rules = [FanRule(enabled: false, group: "CPU 性能核", threshold: 85,
                                    rpm: (fan.minimum + (fan.maximum - fan.minimum) * 0.6).rounded())]
        }
        self.config = config
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: FanControl.helperPath)
            && FileManager.default.fileExists(atPath: FanControl.plistPath)
    }

    /// 已安装的辅助程序是否与本程序内置的一致（程序更新后需要重新安装组件）。
    var isHelperCurrent: Bool {
        FileManager.default.contentsEqual(atPath: FanControl.helperPath,
                                          andPath: Bundle.main.bundlePath + "/Contents/Library/FanHelper/isletFanHelper")
    }

    /// 只有安装在“应用程序”里的副本才会被辅助程序接受。
    var isRunningFromApplications: Bool {
        Bundle.main.executablePath == FanControl.clientPath
    }

    /// 其他风扇控制程序（如 FunFan）。两个程序同时调速会互相抢夺风扇。返回提示文字，没有冲突时为 nil。
    var conflict: String? {
        let running = NSWorkspace.shared.runningApplications.contains {
            ($0.bundleIdentifier ?? "").lowercased().contains("funfan") || ($0.localizedName ?? "").lowercased() == "funfan"
        }
        let daemons = (try? FileManager.default.contentsOfDirectory(atPath: "/Library/LaunchDaemons")) ?? []
        let helper = daemons.contains { $0.lowercased().contains("funfan") }
        guard running || helper else { return nil }
        return helper
            ? "检测到 FunFan 的调速组件：两个程序同时调速会互相抢夺风扇，请只在其中一个里开启调速。"
            : "FunFan 也在运行：如果在它里面也开启了调速，两边会互相抢夺风扇。"
    }

    /// 能否直接下发（不需要先安装 / 更新组件）。
    var isReady: Bool { isRunningFromApplications && isInstalled && isHelperCurrent }

    // MARK: - 配置

    /// 修改配置并保存；策略不是“自动”时立即下发。completion 的参数为错误信息，成功为 nil。
    func update(_ change: (inout FanConfig) -> Void, completion: ((String?) -> Void)? = nil) {
        var next = config
        change(&next)
        let previous = config
        config = next
        save()
        guard next.strategy != .auto || previous.strategy != .auto else {
            completion?(nil)
            return
        }
        send { [weak self] error in
            guard let self else { return }
            if let error, next.strategy != .auto {
                // 下发失败：如果是切换策略，退回原策略，界面随之复原；只改参数时保留（续约会重试）
                if previous.strategy != next.strategy {
                    self.config.strategy = previous.strategy
                    self.save()
                }
                completion?(error)
                return
            }
            if self.config.strategy == .auto { self.stopHeartbeat() } else { self.startHeartbeat() }
            self.refreshStatus()
            completion?(nil)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// 启动、唤醒后恢复用户选择的策略。
    func resume() {
        guard config.strategy != .auto, isReady else { return }
        send { [weak self] error in
            if let error { NSLog("恢复风扇控制失败：%@", error) } else { self?.startHeartbeat() }
        }
    }

    /// 睡眠前交还系统（不改用户选择，唤醒后 resume 会恢复）。
    func suspend() {
        stopHeartbeat()
        guard config.strategy != .auto, isInstalled else { return }
        var auto = config
        auto.strategy = .auto
        send(auto) { _ in }
    }

    /// 退出前同步交还系统，最多等 1 秒；即使没送达，15 秒租约到期辅助程序也会自行交还。
    func releaseBeforeQuit() {
        stopHeartbeat()
        guard config.strategy != .auto, isInstalled, let data = try? JSONEncoder().encode(FanConfig()) else { return }
        let done = DispatchSemaphore(value: 0)
        let proxy = makeConnection().remoteObjectProxyWithErrorHandler { _ in done.signal() } as? FanHelperProtocol
        proxy?.apply(data) { _ in done.signal() }
        _ = done.wait(timeout: .now() + 1)
    }

    /// 读取辅助程序状态，更新 status。
    func refreshStatus() {
        guard isInstalled, isRunningFromApplications else {
            status = nil
            return
        }
        let proxy = makeConnection().remoteObjectProxyWithErrorHandler { [weak self] _ in
            DispatchQueue.main.async { self?.status = nil }
        } as? FanHelperProtocol
        proxy?.status { [weak self] data in
            let decoded = try? JSONDecoder().decode(FanStatus.self, from: data)
            DispatchQueue.main.async { self?.status = decoded }
        }
    }

    private func send(_ override: FanConfig? = nil, completion: @escaping (String?) -> Void) {
        let payload = override ?? config
        guard payload.strategy == .auto || isRunningFromApplications else {
            completion("请把 islet 放在“应用程序”文件夹里运行，风扇控制组件只接受那里的副本。")
            return
        }
        guard isInstalled else {
            completion(payload.strategy == .auto ? nil : "风扇控制组件尚未安装。")
            return
        }
        guard let data = try? JSONEncoder().encode(payload) else { completion("配置无法编码"); return }
        let proxy = makeConnection().remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async { completion("无法连接风扇控制组件：\(error.localizedDescription)") }
        } as? FanHelperProtocol
        proxy?.apply(data) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    private func makeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: FanControl.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        // 辅助程序重启或被卸载后连接失效，下次重新建立
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.connection = nil }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        let timer = Timer(timeInterval: FanControl.heartbeatSeconds, repeats: true) { [weak self] _ in
            guard let self, self.config.strategy != .auto else { return }
            self.send { error in
                if let error { NSLog("风扇控制续约失败：%@", error) }
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
    }

    // MARK: - 安装 / 卸载（弹出系统密码框，由用户授权）

    /// 安装或更新组件。返回错误信息，用户取消或失败时非 nil。
    func install() -> String? {
        let source = Bundle.main.bundlePath + "/Contents/Library/FanHelper"
        let label = FanControl.label
        let previousLabel = "local.codex.compact-speed-bar.fanhelper"
        let script = """
        set -e
        launchctl bootout system/\(label) 2>/dev/null || true
        mkdir -p /Library/PrivilegedHelperTools
        install -o root -g wheel -m 755 \(shellQuoted("\(source)/isletFanHelper")) \(shellQuoted(FanControl.helperPath))
        install -o root -g wheel -m 644 \(shellQuoted("\(source)/\(label).plist")) \(shellQuoted(FanControl.plistPath))
        if launchctl print system/\(previousLabel) >/dev/null 2>&1; then
            launchctl bootout system/\(previousLabel)
        fi
        launchctl bootstrap system \(shellQuoted(FanControl.plistPath)) || { sleep 1; launchctl bootstrap system \(shellQuoted(FanControl.plistPath)); }
        rm -f \(shellQuoted("/Library/PrivilegedHelperTools/\(previousLabel)")) \(shellQuoted("/Library/LaunchDaemons/\(previousLabel).plist"))
        """
        connection?.invalidate()
        connection = nil
        let error = runAsAdministrator(script, prompt: "islet 要安装风扇控制组件，用于按温度调节风扇转速。")
        objectWillChange.send()
        return error
    }

    /// 卸载组件：先交还系统，再移除。
    func uninstall() -> String? {
        config.strategy = .auto
        save()
        stopHeartbeat()
        let label = FanControl.label
        let script = """
        launchctl bootout system/\(label) 2>/dev/null || true
        rm -f \(shellQuoted(FanControl.helperPath)) \(shellQuoted(FanControl.plistPath))
        """
        connection?.invalidate()
        connection = nil
        let error = runAsAdministrator(script, prompt: "islet 要卸载风扇控制组件。")
        status = nil
        objectWillChange.send()
        return error
    }

    private func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func runAsAdministrator(_ script: String, prompt: String) -> String? {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let source = "do shell script \"\(escape(script))\" with prompt \"\(escape(prompt))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return nil }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "已取消" }
        return error[NSAppleScript.errorMessage] as? String ?? "未知错误"
    }
}
