import AppKit
import Combine
import CoreAudio
import SwiftUI

/// 频谱面板的数据（面板打开时每帧更新）。
final class SpectrumPanelModel: ObservableObject {
    @Published var levels = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    @Published var audible = false
    @Published var look = SpectrumLook.current
    @Published var error: String?
    @Published var nowPlaying: NowPlayingInfo?
    @Published var source: SoundSource?
    @Published var accentTint: NSColor?

    var onCommand: (NowPlayingMonitor.Command) -> Void = { _ in }
    var onLook: (SpectrumLook) -> Void = { _ in }
    var onPrivacy: () -> Void = {}
    var onSettings: () -> Void = {}
    var onQuit: () -> Void = {}
    var onFullscreen: () -> Void = {}
}

/// 点开频谱时的面板：与其他指标的面板同一套卡片式设计。
struct SpectrumPanelView: View {
    @ObservedObject var model: SpectrumPanelModel

    var body: some View {
        Themed { p in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xFF375F)).frame(width: 20)   // 和设置里“音乐”同一个图标
                    Text(model.source == nil ? "音乐频谱" : "频谱").font(Typo.title).foregroundStyle(p.text)
                    Spacer()
                    Button(action: model.onSettings) {
                        Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(p.text2)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("设置")
                }

                if let source = model.source { sourceHero(p, source) } else { hero(p) }

                SoundControls(model: SoundController.shared.panel)

                // 只在没法截取声音时提示权限
                if let error = model.error {
                    Card(padding: 10) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error).font(Typo.caption).foregroundStyle(p.hot)
                            HStack {
                                Text("需要“系统录音”权限").font(Typo.body).foregroundStyle(p.text)
                                Spacer()
                                PlainButton(title: "打开权限设置", action: model.onPrivacy)
                            }
                        }
                    }
                }

                HStack(spacing: 14) {
                    LinkButton(title: "样式设置", muted: true, action: model.onSettings)
                    Spacer()
                    LinkButton(title: "退出", muted: true, action: model.onQuit)
                }
                .padding(.top, 2)
            }
            .padding(14)
            .frame(width: 320)
            .background(p.panel)
        }
    }

    /// 主卡片：封面 + 歌曲信息 + 频谱 + 进度 + 控制，底色带一点专辑色。
    private func hero(_ p: Palette) -> some View {
        let info = model.nowPlaying
        let tint = (model.accentTint ?? info?.tint).map(Color.init)
        let accent = tint ?? p.accentFill
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Group {
                    if let artwork = info?.artwork {
                        Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            p.inset
                            Image(systemName: info?.isVideo == true ? "play.rectangle.fill" : "waveform")
                                .font(.system(size: 24, weight: .medium)).foregroundStyle(p.text3)
                        }
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.map { $0.title.isEmpty ? "未知" : $0.title } ?? (model.audible ? "正在播放" : "当前没有声音"))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                    Text(info.map { $0.artist.isEmpty ? $0.album : $0.artist } ?? "没有读到播放器信息")
                        .font(Typo.body).foregroundStyle(p.text2).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(model.audible ? p.cool : p.text3).frame(width: 6, height: 6)
                        Text(Self.appName(info?.bundle) ?? (model.audible ? "有声音" : "没有声音")).font(Typo.caption).foregroundStyle(p.text3).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                fullscreenButton(p)
            }

            bigSpectrum(p).frame(height: 54)

            if let info {
                VStack(spacing: 10) {
                    if let duration = info.duration, duration > 0 {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let position = info.position(at: context.date) ?? 0
                            VStack(spacing: 4) {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(p.text.opacity(0.12)).frame(height: 4)
                                        Capsule().fill(accent).frame(width: geo.size.width * min(max(position / duration, 0), 1), height: 4)
                                    }
                                }
                                .frame(height: 4)
                                HStack {
                                    Text(Self.time(position)).font(Typo.number(11, .medium)).foregroundStyle(p.text3)
                                    Spacer()
                                    Text("-" + Self.time(max(duration - position, 0))).font(Typo.number(11, .medium)).foregroundStyle(p.text3)
                                }
                            }
                        }
                    }
                    HStack(spacing: 40) {
                        if info.canSkip { control(p, "backward.end.fill", size: 16) { model.onCommand(.previous) } }
                        control(p, info.playing ? "pause.fill" : "play.fill", size: 24) { model.onCommand(.togglePlayPause) }
                        if info.canSkip { control(p, "forward.end.fill", size: 16) { model.onCommand(.next) } }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                p.card
                if let tint {
                    LinearGradient(colors: [tint.opacity(0.30), tint.opacity(0.04)], startPoint: .topLeading, endPoint: .bottom)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.cardStroke))
    }

    /// 全屏看频谱（可显示歌词）。
    private func fullscreenButton(_ p: Palette) -> some View {
        Button(action: model.onFullscreen) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(p.text2)
                .frame(width: 26, height: 26)
                .background(Circle().fill(p.text.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("全屏")
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 其他程序在发声：程序图标 + 名称 + 频谱，点图标切过去。
    private func sourceHero(_ p: Palette, _ source: SoundSource) -> some View {
        let tint = model.accentTint.map(Color.init)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button { model.onCommand(.openApp) } label: {
                    Group {
                        if let icon = source.icon {
                            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14).fill(p.inset)
                                Image(systemName: "speaker.wave.2.fill").font(.system(size: 24, weight: .medium)).foregroundStyle(p.text3)
                            }
                        }
                    }
                    .frame(width: 64, height: 64)
                }
                .buttonStyle(.plain)
                .help("切换到 \(source.name)")
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(model.audible ? p.cool : p.text3).frame(width: 6, height: 6)
                        Text(model.audible ? "正在发声" : "没有声音").font(Typo.caption).foregroundStyle(p.text3)
                    }
                }
                Spacer(minLength: 0)
                fullscreenButton(p)
            }
            bigSpectrum(p).frame(height: 54)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                p.card
                if let tint {
                    LinearGradient(colors: [tint.opacity(0.30), tint.opacity(0.04)], startPoint: .topLeading, endPoint: .bottom)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.cardStroke))
    }

    private func control(_ p: Palette, _ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).foregroundStyle(p.text)
                .frame(width: 36, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 应用的显示名：优先用正在运行的应用的本地化名称（如“网易云音乐”而不是 NetEaseMusic）。
    static func appName(_ bundle: String?) -> String? {
        guard let bundle else { return nil }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName { return running }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let info = Bundle(url: url)?.localizedInfoDictionary ?? Bundle(url: url)?.infoDictionary
        return (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
            ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 大号频谱：与菜单栏当前样式一致。
    private func bigSpectrum(_ p: Palette) -> some View {
        GeometryReader { geo in
            let count = SpectrumAnalyzer.bandCount
            let spacing: CGFloat = 3
            let width = (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    let level = CGFloat(model.audible ? model.levels[index] : 0)
                    if model.look.shape == .dots {
                        let rows = 12
                        let lit = Int((level * CGFloat(rows)).rounded(.up))
                        VStack(spacing: 2) {
                            ForEach((0..<rows).reversed(), id: \.self) { row in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(row < lit ? barColor(p, index: index, level: 1) : p.text3.opacity(0.25))
                                    .frame(height: (geo.size.height - CGFloat(rows - 1) * 2) / CGFloat(rows))
                            }
                        }
                        .frame(width: width)
                    } else {
                        RoundedRectangle(cornerRadius: width / 2)
                            .fill(barColor(p, index: index, level: level))
                            .frame(width: width, height: max(width, geo.size.height * level))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
    }

    private func barColor(_ p: Palette, index: Int, level: CGFloat) -> Color {
        let base = NSColor(p.text)
        return Color(nsColor: model.look.color(level: level, album: model.accentTint ?? model.nowPlaying?.tint, base: base))
    }
}

