import AppKit
import Combine
import SwiftUI

/// 更新弹窗：发现新版本 → 下载 → 重启，都在这一个窗口里完成，底栏随下载进度切换。
/// 下载中关掉窗口会在后台继续，下好后再弹出来请用户重启。
final class UpdateWindow {
    static let shared = UpdateWindow()

    /// 跳过这个版本时调用（设置页回到“软件更新”状态）。
    var onSkip: (() -> Void)?
    private var window: NSWindow?
    private var release: UpdateChecker.Release?
    private var watch: AnyCancellable?

    private init() {
        // 后台下载好了而窗口已关：再弹一次
        watch = Updater.shared.$phase.receive(on: DispatchQueue.main).sink { [weak self] phase in
            guard case .ready = phase, let self, let release = self.release, self.window?.isVisible != true else { return }
            self.show(release)
        }
    }

    func show(_ release: UpdateChecker.Release) {
        self.release = release
        if let window, window.isVisible, self.release == release {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        window?.close()
        let view = UpdateDialogHost(release: release, close: { [weak self] in self?.window?.close() },
                                    skip: { [weak self] in
                                        UserDefaults.standard.set(release.version, forKey: "skippedUpdateVersion")
                                        self?.onSkip?()
                                        self?.window?.close()
                                    })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "软件更新"
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.appearance = NSAppearance(named: .aqua)   // 和设置页一样固定浅色
        window.backgroundColor = .white
        window.contentViewController = NSHostingController(rootView: view)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // 先按内容定好尺寸再摆位置，否则之后长高会把窗口顶偏
        window.setContentSize(window.contentViewController!.view.fittingSize)
        // 设置窗口开着（从“查看”打开）就对准它居中，否则在屏幕中间
        if let parent = NSApp.windows.first(where: { $0.isVisible && $0.frameAutosaveName == "islet.settings" }) {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - size.width / 2, y: parent.frame.midY - size.height / 2))
        } else {
            window.center()
        }
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

/// 跟着 Updater 的进度刷新弹窗。
private struct UpdateDialogHost: View {
    let release: UpdateChecker.Release
    let close: () -> Void
    let skip: () -> Void
    @ObservedObject var updater = Updater.shared

    var body: some View {
        UpdateDialog(release: release, phase: updater.phase, close: close, skip: skip)
    }
}

struct UpdateDialog: View {
    let release: UpdateChecker.Release
    let phase: Updater.Phase
    var close: () -> Void = {}
    var skip: () -> Void = {}

    var body: some View {
        Themed { p in
            VStack(spacing: 0) {
                header(p)
                notes(p)
                Rectangle().fill(p.separator).frame(height: 1)
                bottomBar(p)
                    .frame(height: 52)
                    .padding(.horizontal, 18)
                    .background(p.text.opacity(0.025))
            }
            .frame(width: 460)
            .background(Color.white)
        }
    }

    private var subtitle: String { release.summary }

    private func header(_ p: Palette) -> some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("islet 有新版本 \(release.version)").font(.system(size: 16, weight: .semibold)).foregroundStyle(p.text)
                if !subtitle.isEmpty { Text(subtitle).font(Typo.settingsCaption).foregroundStyle(p.text3) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    @ViewBuilder private func notes(_ p: Palette) -> some View {
        let sections = Updater.noteSections(release.notes)
        if !sections.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sections.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 5) {
                            if !sections[i].title.isEmpty {
                                Text(sections[i].title).font(Typo.settingsCaption).foregroundStyle(p.text3)
                            }
                            ForEach(sections[i].items.indices, id: \.self) { j in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Circle().fill(p.accentFill).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                                    Text(sections[i].items[j]).font(Typo.settingsBody).foregroundStyle(p.text2)
                                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 10).fill(p.text.opacity(0.04)))
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
        }
    }

    @ViewBuilder private func bottomBar(_ p: Palette) -> some View {
        switch phase {
        case .idle:
            HStack(spacing: 8) {
                LinkButton(title: "跳过这个版本", muted: true, action: skip)
                Spacer()
                PlainButton(title: "稍后", action: close)
                FilledButton(title: release.download == nil ? "打开下载页" : "更新") { Updater.shared.start(release) }
            }
        case .downloading(let fraction, let text):
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(fraction >= 1 ? "正在核对…" : "正在下载…")
                        Spacer()
                        Text(fraction >= 1 ? "" : text).monospacedDigit()
                    }
                    .font(Typo.settingsCaption).foregroundStyle(p.text3)
                    ProgressView(value: fraction).progressViewStyle(.linear).tint(p.accentFill)
                }
                PlainButton(title: "取消") { Updater.shared.cancel() }
            }
        case .ready:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(Color(hex: 0x34C759))
                Text("已准备好，重启 islet 后生效").font(Typo.settingsBody).foregroundStyle(p.text)
                Spacer()
                PlainButton(title: "稍后", action: close)
                FilledButton(title: "重启") { Updater.shared.relaunch() }
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 16)).foregroundStyle(p.hot)
                Text(message).font(Typo.settingsCaption).foregroundStyle(p.hot).lineLimit(2)
                Spacer(minLength: 8)
                LinkButton(title: "打开下载页", muted: true) { NSWorkspace.shared.open(release.url) }
                FilledButton(title: "重试") { Updater.shared.start(release) }
            }
        }
    }
}

/// 弹窗里唯一的主按钮：实心强调色。
private struct FilledButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Themed { p in
            Button(action: action) {
                Text(title).font(Typo.bodyMedium).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(p.accentFill))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }
}

extension UpdateChecker.Release {
    /// “11 月 23 日发布 · 4.4 MB”：弹窗标题下面和设置页那一行共用，拿不到时为空。
    var summary: String {
        var parts: [String] = []
        if let date {
            let formatter = DateFormatter()
            formatter.dateFormat = "M 月 d 日发布"
            parts.append(formatter.string(from: date))
        }
        if let size { parts.append(String(format: "%.1f MB", Double(size) / 1_048_576)) }
        return parts.joined(separator: " · ")
    }
}
