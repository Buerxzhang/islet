import AppKit
import CryptoKit

/// 应用内更新：在更新弹窗（UpdateDialog）里显示说明和进度 → 下载 Release 里的 islet.zip → 核对 SHA-256、包标识、版本和签名
/// → 退出后替换「应用程序」里的 islet 并重新打开。任何一步失败都不动现有程序，可改为打开下载页。
final class Updater: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle
        case downloading(Double, String)   // 进度 0…1、“1.5 / 3.0 MB”
        case ready(app: URL, folder: URL)  // 已下载、解压并核对，等用户点“重启”
        case failed(String)
    }
    @Published private(set) var phase = Phase.idle
    private var session: URLSession?
    private var release: UpdateChecker.Release?

    /// 更新说明转成纯文字：去掉 Markdown 记号；「升级」一节是给 GitHub 下载页看的（怎么下载、系统要求），不显示。
    static func plainNotes(_ markdown: String) -> String {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        if let start = lines.firstIndex(where: { $0.hasPrefix("#") && $0.contains("升级") }) {
            let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("#") } ?? lines.endIndex
            lines.removeSubrange(start..<end)
        }
        return lines.map { line -> String in
            var line = String(line).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            while line.hasPrefix("#") { line.removeFirst() }
            if line.hasPrefix("- ") { line = "• " + line.dropFirst(2) }
            return line.trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 更新说明分组：「改进」「调整」这类小标题下面跟着若干条，弹窗里按组列出。
    static func noteSections(_ markdown: String) -> [(title: String, items: [String])] {
        var sections: [(title: String, items: [String])] = []
        for line in plainNotes(markdown).split(separator: "\n").map(String.init) where !line.isEmpty {
            if line.hasPrefix("• ") {
                if sections.isEmpty { sections.append(("", [])) }
                sections[sections.count - 1].items.append(String(line.dropFirst(2)))
            } else {
                sections.append((line, []))
            }
        }
        return sections.filter { !$0.items.isEmpty || !$0.title.isEmpty }
    }

    // MARK: 下载

    /// 开始下载；没有安装包的版本直接打开下载页。
    func start(_ release: UpdateChecker.Release) {
        guard session == nil else { return }
        guard let url = release.download else { NSWorkspace.shared.open(release.url); return }
        self.release = release
        phase = .downloading(0, "")
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    func cancel() {
        session?.invalidateAndCancel()
        session = nil
        if case .ready(_, let folder) = phase { try? FileManager.default.removeItem(at: folder) }
        phase = .idle
    }

    private func fail(_ message: String) {
        session?.invalidateAndCancel()
        session = nil
        phase = .failed(message)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let text = String(format: "%.1f / %.1f MB", Double(totalBytesWritten) / 1_048_576, Double(totalBytesExpectedToWrite) / 1_048_576)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session === session else { return }
            self.phase = .downloading(fraction, text)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 临时文件在这个回调返回后就会被删：先挪走
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("islet-update-\(UUID().uuidString).zip")
        let moved = status == 200 && (try? FileManager.default.moveItem(at: location, to: target)) != nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session === session, let release = self.release else {
                if moved { try? FileManager.default.removeItem(at: target) }
                return
            }
            guard status == 200 else { self.fail("下载失败（服务器返回 \(status)）"); return }
            guard moved else { self.fail("保存下载的文件失败"); return }
            self.session = nil
            self.phase = .downloading(1, "正在核对…")
            // 解压、核对签名要一两秒：放到后台，界面不卡
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try Self.prepare(target, release) }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let ready): self.phase = .ready(app: ready.app, folder: ready.folder)
                    case .failure(let error): self.fail((error as? UpdateError)?.message ?? error.localizedDescription)
                    }
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as? URLError)?.code != .cancelled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session === session else { return }
            self.fail("下载失败：\(error.localizedDescription)")
        }
    }

    // MARK: 安装

    private struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// 核对下载的包：完整、是 islet、版本更新、签名完整、能写入现在的位置。返回解压出的新版。
    private static func prepare(_ zip: URL, _ release: UpdateChecker.Release) throws -> (app: URL, folder: URL) {
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: zip) }
        // 1. 文件完整：和 GitHub 记录的 SHA-256 一致
        if let digest = release.digest {
            let data = try Data(contentsOf: zip)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash == digest.lowercased() else { throw UpdateError("下载的文件校验不一致") }
        }
        // 2. 解压，确认是 islet、版本对得上、签名完整
        let folder = fileManager.temporaryDirectory.appendingPathComponent("islet-update-\(UUID().uuidString)")
        var prepared = false
        defer { if !prepared { try? fileManager.removeItem(at: folder) } }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]) else { throw UpdateError("解压失败") }
        try? fileManager.removeItem(at: zip)
        let app = folder.appendingPathComponent("islet.app")
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("下载的不是 islet")
        }
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard UpdateChecker.isNewer(version, than: UpdateChecker.currentVersion) else { throw UpdateError("下载的版本不比当前新") }
        guard Self.run("/usr/bin/codesign", ["--verify", "--strict", app.path]) else { throw UpdateError("下载的程序签名不完整") }
        _ = Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        // 3. 能写入现在的位置（通常是「应用程序」）
        let current = Bundle.main.bundleURL
        guard fileManager.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw UpdateError("没有权限写入 \(current.deletingLastPathComponent().path)")
        }
        prepared = true
        return (app, folder)
    }

    /// 退出 islet，由一个小脚本等它退出后替换并重新打开。
    func relaunch() {
        guard case .ready(let app, let folder) = phase else { return }
        let current = Bundle.main.bundleURL
        // 退出后替换：先把旧版挪到备份，新版放进去；放不进去就把旧版挪回来。最后重新打开
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        backup="$2.update-backup"
        rm -rf "$backup"
        if mv "$2" "$backup"; then
            if mv "$3" "$2"; then rm -rf "$backup"; else mv "$backup" "$2"; fi
        fi
        rm -rf "$4"
        open "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), current.path, app.path, folder.path]
        do { try process.run() } catch { fail("没能重新打开：\(error.localizedDescription)"); return }
        NSApp.terminate(nil)
    }

    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
