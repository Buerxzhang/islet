import AppKit
import AudioToolbox
import Combine
import CoreAudio
import CoreBluetooth
import GameController
import IOBluetooth
import SwiftUI

// 声音：菜单栏显示当前音量（VOL 31%），点开面板控制蓝牙设备、音量和输出设备。

// MARK: - 输出设备与音量（CoreAudio）

struct AudioOutput: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32
    let volume: Float?

    /// 本机的图标：Mac mini、MacBook、iMac、Mac Studio 各自的样子。
    static let macSymbol: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        let model = String(cString: buffer)
        if model.hasPrefix("Macmini") { return "macmini" }
        if model.hasPrefix("MacBook") { return "laptopcomputer" }
        if model.hasPrefix("iMac") { return "desktopcomputer" }
        if model.hasPrefix("MacStudio") || model.hasPrefix("Mac1") { return "macstudio" }
        return "hifispeaker"
    }()

    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return Self.macSymbol
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        default: return "hifispeaker.fill"
        }
    }
}

enum AudioSystem {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: inout T) -> Bool {
        var addr = address(selector, scope)
        guard AudioObjectHasProperty(object, &addr) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
    }

    private static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: T) {
        var addr = address(selector, scope)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(object, &addr), AudioObjectIsPropertySettable(object, &addr, &settable) == noErr,
              settable.boolValue else { return }
        var value = value
        AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }

    static var defaultOutput: AudioDeviceID {
        get {
            var id = AudioDeviceID(0)
            _ = get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, &id)
            return id
        }
        set {
            set(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, newValue)
            // 系统提示音也跟着切
            set(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioObjectPropertyScopeGlobal, newValue)
        }
    }

    static func outputs() -> [AudioOutput] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var hidden: UInt32 = 0
            if get(id, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, &hidden), hidden != 0 { return nil }
            // 只列系统允许作为默认输出的设备（排除虚拟麦克风、频谱功能自建的私有设备等）
            var canBeDefault: UInt32 = 0
            guard get(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput, &canBeDefault),
                  canBeDefault != 0 else { return nil }
            var name: Unmanaged<CFString>?
            guard get(id, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &name), let name else { return nil }
            var transport: UInt32 = 0
            _ = get(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport)
            let deviceName = name.takeRetainedValue() as String
            if transport == kAudioDeviceTransportTypeAggregate,
               deviceName.lowercased().hasPrefix("islet") || deviceName.hasPrefix("系统监控") {
                return nil
            }
            return AudioOutput(id: id, name: deviceName, transport: transport, volume: volume(of: id))
        }
        // 内置扬声器排第一，其余按名称
        .sorted { ($0.transport == kAudioDeviceTransportTypeBuiltIn ? 0 : 1, $0.name) < ($1.transport == kAudioDeviceTransportTypeBuiltIn ? 0 : 1, $1.name) }
    }

    static func volume(of id: AudioDeviceID) -> Float? {
        var value: Float32 = 0
        return get(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput, &value) ? value : nil
    }

    static func setVolume(_ value: Float, of id: AudioDeviceID) {
        set(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput, Float32(min(max(value, 0), 1)))
        if value > 0, isMuted(id) { setMuted(false, id) }
    }

    static func isMuted(_ id: AudioDeviceID) -> Bool {
        var value: UInt32 = 0
        return get(id, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, &value) && value != 0
    }

    static func setMuted(_ muted: Bool, _ id: AudioDeviceID) {
        set(id, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, UInt32(muted ? 1 : 0))
    }

    /// 监听：默认输出设备 / 设备列表变化，以及当前设备的音量、静音变化。
    static func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
                       _ block: @escaping AudioObjectPropertyListenerBlock) {
        var addr = address(selector, scope)
        AudioObjectAddPropertyListenerBlock(object, &addr, DispatchQueue.main, block)
    }

    static func unlisten(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
                         _ block: @escaping AudioObjectPropertyListenerBlock) {
        var addr = address(selector, scope)
        AudioObjectRemovePropertyListenerBlock(object, &addr, DispatchQueue.main, block)
    }
}

// MARK: - 蓝牙（IOBluetooth）

struct BluetoothDevice: Identifiable, Equatable {
    let id: String          // 地址
    let name: String
    let connected: Bool
    let battery: String?    // 如 55%、L80 R75 盒60
    let symbol: String
}

/// 电量文字（如 55%、L80 R75 盒60）拆开：耳机分左 / 右 / 充电盒，其他设备只有一个值。
struct BatteryParts {
    var left: Int?
    var right: Int?
    var box: Int?
    var main: Int?

    init?(_ text: String?) {
        guard let text else { return nil }
        for part in text.split(separator: " ") {
            if part.hasPrefix("L") { left = Int(part.dropFirst()) }
            else if part.hasPrefix("R") { right = Int(part.dropFirst()) }
            else if part.hasPrefix("盒") { box = Int(part.dropFirst()) }
            else { main = Int(part.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) }
        }
        if left == nil, right == nil, box == nil, main == nil { return nil }
    }

    /// 是不是分左右耳的耳机（AirPods 等）。
    var isEarbuds: Bool { left != nil || right != nil }
    /// 设备本身的电量：耳机取左右耳较低的一边，其他取唯一的值（只有充电盒电量时算没有）。
    var level: Int? { [left, right].compactMap { $0 }.min() ?? main }
    /// 左右耳那一行，如 “L80 R75”。
    var earsText: String { [left.map { "L\($0)" }, right.map { "R\($0)" }].compactMap { $0 }.joined(separator: " ") }
}

enum BluetoothSystem {
    private typealias SetPower = @convention(c) (Int32) -> Void
    private typealias GetPower = @convention(c) () -> Int32
    private static let framework = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW)

    static var powerOn: Bool {
        if let symbol = dlsym(framework, "IOBluetoothPreferenceGetControllerPowerState") {
            return unsafeBitCast(symbol, to: GetPower.self)() != 0
        }
        return IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
    }

    /// 开关蓝牙（系统私有接口，与 blueutil 相同的做法）。
    static func setPower(_ on: Bool) {
        guard let symbol = dlsym(framework, "IOBluetoothPreferenceSetControllerPowerState") else { return }
        unsafeBitCast(symbol, to: SetPower.self)(on ? 1 : 0)
    }

    /// 设备列表与系统“蓝牙”设置一致：读 system_profiler（系统有缓存，约 0.05 秒），
    /// 只保留有设备类型的（键盘、耳机、手柄等）；手机和没有类型的设备（系统给的类型是 “None”）不列。
    static func devices() -> [BluetoothDevice] {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPBluetoothDataType", "-json"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controller = (root["SPBluetoothDataType"] as? [[String: Any]])?.first else { return [] }
        let bleBatteries = BLEBattery.shared.levels
        var result: [BluetoothDevice] = [], usesBLE = false
        for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
            for entry in controller[key] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any], let minor = info["device_minorType"] as? String,
                          minor.lowercased() != "none", let address = info["device_address"] as? String else { continue }
                    let symbol = symbol(minor, vendor: info["device_vendorID"] as? String, product: info["device_productID"] as? String, name: name)
                    guard symbol != "iphone" else { continue }
                    let ble = connected ? bleBatteries[name] : nil
                    if ble != nil { usesBLE = true }
                    let battery = batteryText(info) ?? (connected ? ble.map { "\($0)%" } ?? classicBattery(address) : nil)
                    result.append(BluetoothDevice(id: address, name: name, connected: connected, battery: battery, symbol: symbol))
                }
            }
        }
        // 有设备的电量来自 BLE（要定期重读，否则一直是第一次读到的数），或还没读到电量：重新读一次（BLEBattery 里限频）
        if usesBLE || result.contains(where: { $0.connected && $0.battery == nil }) { BLEBattery.shared.refresh() }
        return result.sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
    }

    /// 系统给的电量字段：AirPods 等有左 / 右 / 盒子，其余只有一个。
    private static func batteryText(_ info: [String: Any]) -> String? {
        func level(_ key: String) -> Int? {
            (info[key] as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
        }
        let left = level("device_batteryLevelLeft"), right = level("device_batteryLevelRight"), box = level("device_batteryLevelCase")
        if left != nil || right != nil {
            return [left.map { "L\($0)" }, right.map { "R\($0)" }, box.map { "盒\($0)" }].compactMap { $0 }.joined(separator: " ")
        }
        if let main = level("device_batteryLevelMain") ?? level("device_batteryLevel") { return "\(main)%" }
        return nil
    }

    /// 经典蓝牙耳机（如索尼）通过免提协议上报的电量：IOBluetoothDevice 的私有属性，0 表示未知。
    private static func classicBattery(_ address: String) -> String? {
        guard let device = IOBluetoothDevice(addressString: address) else { return nil }
        for key in ["batteryPercentSingle", "batteryPercentCombined", "headsetBattery"] {
            if device.responds(to: NSSelectorFromString(key)), let value = device.value(forKey: key) as? NSNumber, value.intValue > 0 {
                return "\(value.intValue)%"
            }
        }
        return nil
    }

    private static func symbol(_ minor: String, vendor: String?, product: String?, name: String) -> String {
        if let headphone = appleHeadphone(vendor: vendor, product: product, name: name) { return headphone }
        switch minor.lowercased() {
        case "keyboard": return "keyboard"
        case "mouse": return "computermouse"
        case "trackpad": return "hand.point.up.left"
        case "headset", "headphones": return "headphones"
        case "speaker", "loudspeaker", "portable audio", "hifi audio": return "hifispeaker"
        case "gamepad", "joystick": return "gamecontroller"
        case "phone", "smartphone", "cellular": return "iphone"
        default: return "dot.radiowaves.left.and.right"
        }
    }

    /// AirPods / Beats 按型号用对应的图标：先看苹果的产品 ID，认不出时看名字；系统没有这个图标时退回普通耳机。
    private static func appleHeadphone(vendor: String?, product: String?, name: String) -> String? {
        let lower = name.lowercased()
        let apple = vendor?.lowercased() == "0x004c"
        guard apple || lower.contains("airpods") || lower.contains("beats") else { return nil }
        let id = Int((product ?? "").replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
        let symbol: String?
        switch id {
        case 0x200A, 0x201F: symbol = "airpodsmax"
        case 0x200E, 0x2014, 0x2024: symbol = "airpodspro"
        case 0x2013, 0x2019, 0x201B: symbol = "airpods.gen3"
        case 0x2002, 0x200F: symbol = "airpods"
        case 0x200B, 0x201D: symbol = "beats.powerbeatspro"
        case 0x2011, 0x2016: symbol = "beats.studiobuds"
        case 0x2012: symbol = "beats.fitpro"
        default:
            symbol = lower.contains("airpods max") ? "airpodsmax"
                : lower.contains("airpods pro") ? "airpodspro"
                : lower.contains("airpods") ? "airpods"
                : lower.contains("powerbeats") ? "beats.powerbeatspro"
                : lower.contains("studio buds") ? "beats.studiobuds"
                : lower.contains("fit pro") ? "beats.fitpro"
                : lower.contains("beats") ? "beats.headphones"
                : nil
        }
        guard let symbol else { return nil }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil ? symbol : "headphones"
    }

    /// 是不是耳机类图标（AirPods、Beats 和普通耳机）。
    static func isHeadphone(_ symbol: String) -> Bool {
        symbol == "headphones" || symbol.hasPrefix("airpods") || symbol.hasPrefix("beats")
    }

    /// 连接 / 断开（同步调用，可能要几秒，放在后台线程）。
    static func setConnected(_ connect: Bool, address: String) {
        guard let device = IOBluetoothDevice(addressString: address) else { return }
        if connect { device.openConnection() } else { device.closeConnection() }
    }
}

/// 蓝牙 LE 设备（很多第三方键盘、鼠标）的电量：标准电池服务 0x180F 的 2A19 特征。
/// 系统已经连着这些设备，这里只是借用连接读一下电量。
final class BLEBattery: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = BLEBattery()
    private static let service = CBUUID(string: "180F")
    private static let level = CBUUID(string: "2A19")

    private let queue = DispatchQueue(label: "local.codex.islet.ble-battery")
    private var manager: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private let lock = NSLock()
    private var storage: [String: Int] = [:]

    var levels: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    private var lastScan = Date.distantPast

    /// 重新读一遍已连接设备的电量；最多每分钟一次（设备列表每 3 / 30 秒刷新一次，不用每次都读）。
    func refresh() {
        queue.async {
            guard Date().timeIntervalSince(self.lastScan) >= 60 else { return }
            guard let manager = self.manager else {
                self.manager = CBCentralManager(delegate: self, queue: self.queue)
                return
            }
            self.scan(manager)
        }
    }

    private func scan(_ manager: CBCentralManager) {
        guard manager.state == .poweredOn else { return }
        lastScan = Date()
        for peripheral in manager.retrieveConnectedPeripherals(withServices: [Self.service]) {
            peripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            if peripheral.state == .connected {
                peripheral.discoverServices([Self.service])
            } else {
                manager.connect(peripheral)
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) { scan(central) }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == Self.service {
            peripheral.discoverCharacteristics([Self.level], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.uuid == Self.level {
            peripheral.readValue(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.level, let byte = characteristic.value?.first, let name = peripheral.name else { return }
        lock.lock()
        storage[name] = Int(byte)
        lock.unlock()
    }
}

// MARK: - 面板数据

final class SoundPanelModel: ObservableObject {
    @Published var bluetoothOn = true
    @Published var bluetoothLoaded = false
    @Published var allDevices: [BluetoothDevice] = []
    /// 面板里显示的设备：去掉在设置里取消勾选的。
    var devices: [BluetoothDevice] { allDevices.filter { !hiddenDevices.contains($0.id) } }
    @Published var hiddenDevices = Set(UserDefaults.standard.stringArray(forKey: "hiddenBluetoothDevices") ?? [])

    func setHidden(_ hidden: Bool, device: String) {
        if hidden { hiddenDevices.insert(device) } else { hiddenDevices.remove(device) }
        UserDefaults.standard.set(Array(hiddenDevices), forKey: "hiddenBluetoothDevices")
        onHiddenChange()
    }
    var onHiddenChange: () -> Void = {}
    @Published var busy: Set<String> = []        // 正在连接 / 断开的设备
    @Published var confirming: String?           // 等待再点一次确认断开的设备

    /// 键盘、鼠标、触控板断开后可能就没法操作了：已连接时先要求再点一次。
    func tap(_ device: BluetoothDevice) {
        let input = ["keyboard", "computermouse", "hand.point.up.left"].contains(device.symbol)
        if device.connected, input, confirming != device.id {
            confirming = device.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if self?.confirming == device.id { self?.confirming = nil }
            }
            return
        }
        confirming = nil
        onDevice(device)
    }
    @Published var volume: Float = 0
    @Published var muted = false
    @Published var volumeAvailable = true
    @Published var outputs: [AudioOutput] = []
    @Published var current: AudioDeviceID = 0
    @Published var hovered: String?              // 鼠标所在的行（SwiftUI 宏在本构建方式下不可用，悬停状态放在模型里）

    var onBluetoothPower: (Bool) -> Void = { _ in }
    var onDevice: (BluetoothDevice) -> Void = { _ in }
    var onVolume: (Float) -> Void = { _ in }
    var onMute: () -> Void = {}
    var onOutput: (AudioOutput) -> Void = { _ in }
    var onBluetoothSettings: () -> Void = {}
    var onSoundSettings: () -> Void = {}
    var onSettings: () -> Void = {}
    var onQuit: () -> Void = {}
}

/// 菜单栏蓝牙面板：与其他指标面板同一套样式。上方是已连接设备（圆环电量，点了断开），下方是其他已配对设备（点了连接）。
struct BluetoothPanelView: View {
    @ObservedObject var model: SoundPanelModel

    var body: some View {
        Themed { p in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    IconTile(symbol: BluetoothGlyph.name, tint: Color(hex: 0x0A84FF), size: 24)
                        .frame(width: 20)   // 和设置里“蓝牙电量”同一个图标
                    Text("蓝牙电量").font(Typo.title).foregroundStyle(p.text)
                    Spacer()
                    // 关蓝牙会断开蓝牙键鼠，不放在这里；只在已关闭时给个打开的开关
                    if !model.bluetoothOn {
                        Toggle2(isOn: false, onChange: model.onBluetoothPower)
                    }
                    Button(action: model.onSettings) {
                        Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(p.text2)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("设置")
                }
                if !model.bluetoothOn {
                    Card { note(p, "蓝牙已关闭") }
                } else if !model.bluetoothLoaded {
                    Card { note(p, "正在读取设备…") }
                } else {
                    connectedCard(p)
                    let others = model.devices.filter { !$0.connected }
                    if !others.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "其他设备")
                            Card(padding: 6) {
                                VStack(spacing: 2) {
                                    ForEach(others) { device in
                                        DeviceRow(model: model, key: "bt" + device.id, symbol: device.symbol, name: device.name, selected: false,
                                                  trailing: "连接", busy: model.busy.contains(device.id)) { model.tap(device) }
                                    }
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 14) {
                    Text("点设备连接 / 断开").font(Typo.caption).foregroundStyle(p.text3)
                    Spacer()
                    LinkButton(title: "蓝牙设置", muted: true, action: model.onBluetoothSettings)
                    LinkButton(title: "退出", muted: true, action: model.onQuit)
                }
                .padding(.top, 2)
            }
            .padding(14)
            .frame(width: 320)
            .background(p.panel)
        }
    }

    /// 已连接设备：每台一个大圆环（电量），下面是名称和电量。
    private func connectedCard(_ p: Palette) -> some View {
        let connected = model.devices.filter(\.connected)
        return Card(padding: 14) {
            if connected.isEmpty {
                note(p, "没有已连接的设备")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 14) {
                    ForEach(connected) { device in
                        Button { model.tap(device) } label: {
                            VStack(spacing: 7) {
                                DeviceRing(symbol: device.symbol, level: SoundController.batteryLevel(device.battery), busy: model.busy.contains(device.id))
                                    .frame(width: 52, height: 52)
                                Text(device.name).font(Typo.caption).foregroundStyle(p.text2).lineLimit(1).truncationMode(.middle)
                                batteryText(p, device)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("点击断开")
                    }
                }
            }
        }
    }

    private func note(_ p: Palette, _ text: String) -> some View {
        Text(text).font(Typo.caption).foregroundStyle(p.text3).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 8)
    }

    /// 圆环下面的电量：AirPods 等分两行，上面左右耳、下面充电盒；其他设备一行百分比。
    @ViewBuilder private func batteryText(_ p: Palette, _ device: BluetoothDevice) -> some View {
        if model.confirming == device.id {
            Text("再点断开").font(Typo.captionMedium).foregroundStyle(p.hot)
        } else if let parts = BatteryParts(device.battery), parts.isEarbuds {
            VStack(spacing: 1) {
                Text(parts.earsText).font(Typo.number(13, .semibold)).foregroundStyle(p.text)
                if let box = parts.box { Text("盒 \(box)%").font(Typo.caption).foregroundStyle(p.text3) }
            }
        } else {
            Text(device.battery ?? "—").font(Typo.number(13, .semibold)).foregroundStyle(p.text)
        }
    }
}

/// 设备圆环：灰色底环 + 按电量着色的弧（绿 > 40%、橙 ≤ 40%、红 ≤ 20%），中间是设备图标。
struct DeviceRing: View {
    let symbol: String
    let level: Int?
    var busy = false

    var body: some View {
        Themed { p in
            ZStack {
                Circle().stroke(p.text.opacity(0.1), lineWidth: 4)
                if let level {
                    Circle().trim(from: 0, to: CGFloat(level) / 100)
                        .stroke(color(level), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(p.text)
                    .opacity(busy ? 0.3 : 1)
            }
            .padding(2)
        }
    }

    private func color(_ level: Int) -> Color {
        level <= 20 ? .red : level <= 40 ? .orange : .green
    }
}

struct SoundControls: View {
    @ObservedObject var model: SoundPanelModel

    var body: some View {
        Themed { p in
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "声音输出", trailing: model.volumeAvailable ? nil : "当前设备不支持调节音量")
                    Card(padding: 6) {
                      VStack(spacing: 2) {
                        HStack(spacing: 10) {
                            Button(action: model.onMute) {
                                Image(systemName: volumeSymbol).font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(model.muted ? p.text3 : p.text).frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(model.muted ? "取消静音" : "静音")
                            Slider2(value: Double(model.muted ? 0 : model.volume * 100), range: 0...100, step: 1,
                                    onChanging: { model.onVolume(Float($0 / 100)) }, onCommit: { model.onVolume(Float($0 / 100)) })
                                .disabled(!model.volumeAvailable)
                                .opacity(model.volumeAvailable ? 1 : 0.4)
                            Text(model.muted ? "静音" : "\(Int((model.volume * 100).rounded()))%")
                                .font(Typo.number(12, .medium)).foregroundStyle(p.text2)
                                .frame(width: 36, alignment: .trailing)
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 6)
                        .frame(height: 34)
                        Rectangle().fill(p.separator).frame(height: 1).padding(.horizontal, 6).padding(.bottom, 4)
                            ForEach(model.outputs) { output in
                                let selected = output.id == model.current
                                DeviceRow(model: model, key: "out\(output.id)", symbol: output.symbol, name: output.name, selected: selected,
                                          trailing: output.volume.map { "\(Int(($0 * 100).rounded()))%" }, busy: false) {
                                    model.onOutput(output)
                                }
                            }
                        }
                    }
                }

            }
        }
    }

    private var volumeSymbol: String {
        if model.muted || model.volume == 0 { return "speaker.slash.fill" }
        return model.volume < 0.34 ? "speaker.wave.1.fill" : model.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

/// 设备行：圆形图标（选中 / 已连接时高亮）+ 名称 + 右侧数值。
private struct DeviceRow: View {
    @ObservedObject var model: SoundPanelModel
    let key: String
    let symbol: String
    let name: String
    let selected: Bool
    let trailing: String?
    var warning = false
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Themed { p in
            Button(action: action) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(selected ? p.accentFill : p.inset)
                        Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(selected ? Color.white : p.text2)
                    }
                    .frame(width: 26, height: 26)
                    Text(name).font(selected ? Typo.bodyMedium : Typo.body).foregroundStyle(p.text).lineLimit(1)
                    Spacer(minLength: 6)
                    if busy {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
                    } else if let trailing {
                        Text(trailing).font(warning ? Typo.captionMedium : Typo.number(11, .medium)).foregroundStyle(warning ? p.hot : p.text3)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(model.hovered == key ? p.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { model.hovered = key } else if model.hovered == key { model.hovered = nil }
            }
        }
    }
}

// MARK: - 控制器

final class SoundController: NSObject, NSPopoverDelegate {
    static let shared = SoundController()
    private var listeningSystem = false

    var openSettings: () -> Void = {}

    let panel = SoundPanelModel()
    private var embedders = 0   // 正在显示声音控件的面板数（音乐频谱面板、蓝牙面板）
    private var refreshTimer: Timer?
    private var watchedDevice: AudioDeviceID = 0
    private let bluetoothQueue = DispatchQueue(label: "local.codex.islet.bluetooth")

    // MARK: 菜单栏蓝牙

    /// 菜单栏显示已连接的蓝牙设备和电量（设置 → 菜单栏）。
    static var showsBluetoothItem: Bool { UserDefaults.standard.object(forKey: "bluetoothItem") as? Bool ?? true }
    private let bluetoothPopover = NSPopover()
    private var bluetoothTimer: Timer?
    private var bluetoothKey = ""
    private var bluetoothClickMonitor: Any?
    /// 菜单栏蓝牙图像变化（nil 表示不显示）。
    var onBluetoothImage: (NSImage?) -> Void = { _ in }
    /// 蓝牙面板打开 / 关闭（灵动岛据此点亮那一段）。
    var onBluetoothPanel: (Bool) -> Void = { _ in }

    /// 启动蓝牙监视（岛上显示蓝牙或开着低电量提醒时）：每 30 秒刷新一次；设备连接 / 断开时立即刷新。
    func startBluetoothItem() {
        bluetoothTimer?.invalidate()
        bluetoothTimer = nil
        bluetoothKey = ""
        if !Self.showsBluetoothItem { onBluetoothImage(nil) }
        guard Self.showsBluetoothItem || AlertCenter.lowBatteryEnabled else { return }
        if !watchingGamepads { watchingGamepads = true; watchGamepads() }
        refreshBluetooth()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refreshBluetooth() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        bluetoothTimer = timer
        if connectNotification == nil {
            connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        }
    }
    private var connectNotification: IOBluetoothUserNotification?

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        watchDisconnect(device)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refreshBluetooth() }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        disconnectWatched.remove(Self.addressKey(device.addressString ?? ""))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshBluetooth() }
    }

    /// 已注册断开通知的设备（地址）：启动前就连着的设备也要注册，断开时才能马上刷新。
    private var disconnectWatched: Set<String> = []
    private static func addressKey(_ address: String) -> String { address.lowercased().replacingOccurrences(of: ":", with: "-") }

    private func watchDisconnect(_ device: IOBluetoothDevice) {
        guard disconnectWatched.insert(Self.addressKey(device.addressString ?? "")).inserted else { return }
        device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
    }

    /// 系统拿不到电量的已连接设备：有索尼控制通道就用它查（结果缓存，过期才重查）。
    private func withSonyBattery(_ devices: [BluetoothDevice]) -> [BluetoothDevice] {
        let maxAge: TimeInterval = bluetoothPopover.isShown ? 60 : 300
        return devices.map { device in
            guard device.connected, device.battery == nil else { return device }
            var level: Int?
            if device.symbol == "gamecontroller" {
                level = Self.gamepadBattery(named: device.name)
            } else if sonyCapable(device.id) {
                level = SonyBattery.shared.level(for: device.id, maxAge: maxAge)
            }
            guard let level else { return device }
            return BluetoothDevice(id: device.id, name: device.name, connected: true, battery: "\(level)%", symbol: device.symbol)
        }
    }

    /// 游戏手柄电量：系统蓝牙信息里没有，游戏控制器框架直接提供（按名称匹配；只有一个手柄时直接用它）。
    private static func gamepadBattery(named name: String) -> Int? {
        let controllers = GCController.controllers().filter { $0.battery != nil }
        let match = controllers.first { $0.vendorName == name } ?? (controllers.count == 1 ? controllers.first : nil)
        guard let battery = match?.battery, battery.batteryState != .unknown || battery.batteryLevel > 0 else { return nil }
        return Int((battery.batteryLevel * 100).rounded())
    }

    /// 后台也接收手柄连接（菜单栏程序不在前台）；手柄连上 / 断开时刷新。
    private func watchGamepads() {
        GCController.shouldMonitorBackgroundEvents = true
        for name in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.refreshBluetooth() }
            }
        }
    }
    private var watchingGamepads = false

    private var sonyChecked: [String: Bool] = [:]
    private func sonyCapable(_ address: String) -> Bool {
        if let known = sonyChecked[address] { return known }
        let capable = IOBluetoothDevice(addressString: address).flatMap(SonyBattery.channelID(of:)) != nil
        sonyChecked[address] = capable
        return capable
    }

    /// 电量文字取数值：耳机取左右耳较低的一边，其他取唯一的百分比。
    static func batteryLevel(_ text: String?) -> Int? { BatteryParts(text)?.level }

    /// 岛上的蓝牙图像 + 低电量提醒。岛上不显示蓝牙时照样检查电量，提醒不受影响。
    private func publishBluetoothImage() {
        let shows = Self.showsBluetoothItem
        let connected = panel.allDevices.filter { $0.connected && !panel.hiddenDevices.contains($0.id) }
        let devices = connected.map { (symbol: $0.symbol, battery: Self.batteryLevel($0.battery)) }
        let key = "\(shows)" + (panel.bluetoothOn ? connected.map { "\($0.symbol)\($0.battery ?? "-")" }.joined(separator: "|") : "off")
        guard key != bluetoothKey else { return }
        bluetoothKey = key
        onBluetoothImage(shows && !devices.isEmpty ? StatusIcons.bluetooth(devices) : nil)
        // 充电盒单独提醒（标题带“充电盒”）
        AlertCenter.shared.checkBatteries(connected.flatMap { device -> [(id: String, name: String, symbol: String, level: Int)] in
            let parts = BatteryParts(device.battery)
            return [parts?.level.map { (device.id, device.name, device.symbol, $0) },
                    parts?.box.map { (device.id + "#case", "\(device.name) 充电盒", device.symbol, $0) }].compactMap { $0 }
        })
    }

    /// 点了菜单栏的蓝牙：打开 / 关闭蓝牙面板。
    func toggleBluetoothPanel(from button: NSView, anchor: NSRect) {
        if bluetoothPopover.isShown {
            bluetoothPopover.performClose(nil)
            return
        }
        if bluetoothPopover.contentViewController == nil {
            let hosting = NSHostingController(rootView: BluetoothPanelView(model: panel))
            hosting.sizingOptions = [.preferredContentSize]
            bluetoothPopover.contentViewController = hosting
            bluetoothPopover.behavior = .transient
            bluetoothPopover.animates = false
            bluetoothPopover.delegate = self
        }
        controlsWillShow()
        bluetoothPopover.appearance = NSAppearance(named: .aqua)   // 面板统一浅色
        bluetoothPopover.showAboveApps(relativeTo: anchor, of: button, preferredEdge: .minY)
        onBluetoothPanel(true)
        bluetoothClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.bluetoothPopover.performClose(nil)
        }
    }

    func closeBluetoothPanel() { bluetoothPopover.performClose(nil) }

    private lazy var systemListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.audioChanged() }
    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.volumeChanged() }

    func start() {
        panel.onBluetoothPower = { [weak self] in self?.setBluetoothPower($0) }
        panel.onHiddenChange = { [weak self] in self?.publishBluetoothImage() }
        SonyBattery.shared.onUpdate = { [weak self] in self?.refreshBluetooth() }
        panel.onDevice = { [weak self] in self?.toggle($0) }
        panel.onVolume = { [weak self] value in
            guard let self else { return }
            AudioSystem.setVolume(value, of: AudioSystem.defaultOutput)
            self.volumeChanged()
        }
        panel.onMute = { [weak self] in
            let id = AudioSystem.defaultOutput
            AudioSystem.setMuted(!AudioSystem.isMuted(id), id)
            self?.volumeChanged()
        }
        panel.onOutput = { [weak self] output in
            AudioSystem.defaultOutput = output.id
            self?.audioChanged()
        }
        panel.onBluetoothSettings = { [weak self] in
            self?.bluetoothPopover.performClose(nil)
            self?.openURL("x-apple.systempreferences:com.apple.BluetoothSettings")
        }
        panel.onSoundSettings = { [weak self] in self?.openURL("x-apple.systempreferences:com.apple.Sound-Settings.extension") }
        panel.onSettings = { [weak self] in
            self?.bluetoothPopover.performClose(nil)
            self?.openSettings()
        }
        panel.onQuit = { NSApp.terminate(nil) }
    }

    /// 输出设备或设备列表变了：重新监听当前设备的音量，刷新面板和菜单栏。
    private func audioChanged() {
        let current = AudioSystem.defaultOutput
        watch(device: current)
        panel.current = current
        panel.outputs = AudioSystem.outputs()
        volumeChanged()
    }

    private func watch(device: AudioDeviceID) {
        guard device != watchedDevice else { return }
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            if watchedDevice != 0 {
                AudioSystem.unlisten(watchedDevice, selector, kAudioObjectPropertyScopeOutput, deviceListener)
            }
            if device != 0 {
                AudioSystem.listen(device, selector, kAudioObjectPropertyScopeOutput, deviceListener)
            }
        }
        watchedDevice = device
    }

    private func volumeChanged() {
        let id = AudioSystem.defaultOutput
        let volume = AudioSystem.volume(of: id)
        let muted = AudioSystem.isMuted(id)
        panel.volumeAvailable = volume != nil
        panel.volume = volume ?? 1
        panel.muted = muted
        if let index = panel.outputs.firstIndex(where: { $0.id == id }), panel.outputs[index].volume != volume {
            let old = panel.outputs[index]
            panel.outputs[index] = AudioOutput(id: old.id, name: old.name, transport: old.transport, volume: volume)
        }
    }

    // MARK: 蓝牙

    private func refreshBluetooth() {
        bluetoothQueue.async { [weak self] in
            let on = BluetoothSystem.powerOn
            let devices = on ? BluetoothSystem.devices() : []
            DispatchQueue.main.async {
                guard let self else { return }
                self.panel.bluetoothOn = on
                for device in devices where device.connected && !self.disconnectWatched.contains(Self.addressKey(device.id)) {
                    IOBluetoothDevice(addressString: device.id).map(self.watchDisconnect)
                }
                self.panel.allDevices = self.withSonyBattery(devices)
                self.panel.bluetoothLoaded = true
                self.publishBluetoothImage()
            }
        }
    }

    private func setBluetoothPower(_ on: Bool) {
        panel.bluetoothOn = on
        bluetoothQueue.async { [weak self] in
            BluetoothSystem.setPower(on)
            Thread.sleep(forTimeInterval: 1)
            self?.refreshBluetooth()
        }
    }

    private func toggle(_ device: BluetoothDevice) {
        guard !panel.busy.contains(device.id) else { return }
        panel.busy.insert(device.id)
        bluetoothQueue.async { [weak self] in
            BluetoothSystem.setConnected(!device.connected, address: device.id)
            Thread.sleep(forTimeInterval: 0.5)
            DispatchQueue.main.async { self?.panel.busy.remove(device.id) }
            self?.refreshBluetooth()
        }
    }

    // MARK: 面板

    /// 设置窗口读取设备列表用。
    func loadDevices() { refreshBluetooth() }

    /// 有面板要显示声音控件：刷新一次，之后每 3 秒刷新蓝牙（连接状态、电量）。
    func controlsWillShow() {
        if !listeningSystem {
            // 监听默认输出设备和设备列表变化（键盘调音量、插拔耳机时面板同步）
            let system = AudioObjectID(kAudioObjectSystemObject)
            AudioSystem.listen(system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, systemListener)
            AudioSystem.listen(system, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, systemListener)
            listeningSystem = true
        }
        audioChanged()
        refreshBluetooth()
        embedders += 1
        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshBluetooth() }
        }
    }

    func controlsDidHide() {
        embedders = max(embedders - 1, 0)
        guard embedders == 0 else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func popoverDidClose(_ notification: Notification) {
        controlsDidHide()
        if (notification.object as? NSPopover) === bluetoothPopover {
            if let bluetoothClickMonitor { NSEvent.removeMonitor(bluetoothClickMonitor) }
            bluetoothClickMonitor = nil
            onBluetoothPanel(false)
        }
    }

    private func openURL(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    static func fillDemo(_ model: SoundPanelModel) {
        model.bluetoothLoaded = true
        model.allDevices = [
            BluetoothDevice(id: "1", name: "BKB02_1", connected: true, battery: "55%", symbol: "keyboard"),
            BluetoothDevice(id: "2", name: "WH-1000XM6", connected: true, battery: "70%", symbol: "headphones"),
            BluetoothDevice(id: "4", name: "AirPods Pro", connected: true, battery: "L80 R75 盒60", symbol: "airpodspro"),
            BluetoothDevice(id: "3", name: "Xbox Wireless Controller", connected: false, battery: nil, symbol: "gamecontroller"),
        ]
        model.busy = ["2"]
        model.volume = 0.31
        model.outputs = [
            AudioOutput(id: 1, name: "Mac mini扬声器", transport: kAudioDeviceTransportTypeBuiltIn, volume: 0.31),
            AudioOutput(id: 2, name: "Mi monitor", transport: kAudioDeviceTransportTypeDisplayPort, volume: nil),
            AudioOutput(id: 3, name: "Realtek USB2.0 Audio", transport: kAudioDeviceTransportTypeUSB, volume: 1),
        ]
        model.current = 1
    }
}

/// 索尼耳机电量：系统拿不到（经典蓝牙耳机不通过系统上报），通过索尼自己的控制通道（RFCOMM，Headphones Connect 用的那条）查询。
/// 报文：3E [类型][序号][长度 4 字节][内容][校验] 3C，3C/3D/3E 需转义。类型 0x0C 为命令，0x01 为确认。
/// 先发初始化（00 00），再查电量：新版协议 22 00（回 23），旧版 10 00（回 11）。
final class SonyBattery: NSObject, IOBluetoothRFCOMMChannelDelegate {
    static let shared = SonyBattery()
    static let serviceUUID = "956C7B26-D49A-4BA8-B03F-B17D393CB6E2"

    /// 按地址缓存，存到设置里：耳机的控制通道被占用（比如手机上开着索尼 App）时，仍显示最近一次读到的电量。
    private(set) var levels: [String: (level: Int, time: Date)] = {
        let saved = UserDefaults.standard.dictionary(forKey: "sonyBatteryLevels") as? [String: [Double]] ?? [:]
        return saved.compactMapValues { $0.count == 2 ? (Int($0[0]), Date(timeIntervalSince1970: $0[1])) : nil }
    }()
    private var channel: IOBluetoothRFCOMMChannel?
    private var address = ""
    private var buffer: [UInt8] = []
    private var sequence: UInt8 = 0
    private var completion: ((Int?) -> Void)?
    private var timeout: DispatchWorkItem?
    var log: ((String) -> Void)?
    private var queue: [String] = []           // 等待查询的地址（一次只开一条通道）
    private var failed: [String: (time: Date, count: Int)] = [:]
    var onUpdate: () -> Void = {}

    /// 有缓存就返回；过期（默认 5 分钟）就排队重新查询，查到后回调 onUpdate。
    func level(for address: String, maxAge: TimeInterval = 300) -> Int? {
        let cached = levels[address]
        // 成功的结果按 maxAge 过期；失败后 30 秒重试（刚连接时通道可能还没准备好），
        // 连续失败就逐次加倍、最长 30 分钟（通道被手机上的索尼 App 占着时，不反复去抢）
        let retry = failed[address].map { min(30 * pow(2, Double($0.count - 1)), 1800) } ?? 0
        let due = Date().timeIntervalSince(cached?.time ?? .distantPast) > maxAge
            && Date().timeIntervalSince(failed[address]?.time ?? .distantPast) > retry
        if due, !queue.contains(address), self.address != address || completion == nil {
            queue.append(address)
            next()
        }
        // 最近 6 小时内读到过就显示（通道暂时被占用时不至于空着）
        guard let cached, Date().timeIntervalSince(cached.time) < 6 * 3600 else { return nil }
        return cached.level
    }

    private func next() {
        guard completion == nil, !queue.isEmpty else { return }
        let address = queue.removeFirst()
        query(address: address) { [weak self] level in
            // 失败记下时间和次数，到期才重试；成功就清掉
            if level == nil { self?.failed[address] = (Date(), (self?.failed[address]?.count ?? 0) + 1) } else { self?.failed[address] = nil }
            self?.onUpdate()
            DispatchQueue.main.async { self?.next() }
        }
    }

    /// 是否是带索尼控制通道的设备（返回 RFCOMM 通道号）。
    static func channelID(of device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        let uuid = UUID(uuidString: serviceUUID)!
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        let sdp: IOBluetoothSDPUUID = IOBluetoothSDPUUID(bytes: bytes, length: 16)
        var channel: BluetoothRFCOMMChannelID = 0
        guard let record = device.getServiceRecord(for: sdp), record.getRFCOMMChannelID(&channel) == kIOReturnSuccess else { return nil }
        return channel
    }

    /// 查询一次（主线程调用）；结果回调在主线程，失败为 nil。
    func query(address: String, completion: @escaping (Int?) -> Void) {
        guard channel == nil, self.completion == nil else { completion(nil); return }
        guard let device = IOBluetoothDevice(addressString: address), device.isConnected(),
              let id = Self.channelID(of: device) else { completion(nil); return }
        self.address = address
        self.completion = completion
        buffer = []
        sequence = 0
        var opened: IOBluetoothRFCOMMChannel?
        let status = device.openRFCOMMChannelAsync(&opened, withChannelID: id, delegate: self)
        log?("open channel \(id) status \(status)")
        guard status == kIOReturnSuccess else { finish(nil); return }
        channel = opened
        let work = DispatchWorkItem { [weak self] in self?.finish(nil) }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func finish(_ level: Int?) {
        log?("finish \(String(describing: level)) channelOpen=\(channel?.isOpen() ?? false)")
        timeout?.cancel()
        timeout = nil
        if let level {
            levels[address] = (level, Date())
            UserDefaults.standard.set(levels.mapValues { [Double($0.level), $0.time.timeIntervalSince1970] }, forKey: "sonyBatteryLevels")
        }
        channel?.setDelegate(nil)
        channel?.close()
        channel = nil
        let done = completion
        completion = nil
        done?(level)
    }

    // MARK: 报文

    private func send(type: UInt8, payload: [UInt8], sequence seq: UInt8) {
        var body: [UInt8] = [type, seq]
        let length = UInt32(payload.count)
        body += [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
        body += payload
        body.append(UInt8(body.reduce(0) { ($0 + Int($1)) } & 0xFF))
        var frame: [UInt8] = [0x3E]
        for byte in body {
            if byte == 0x3C || byte == 0x3D || byte == 0x3E { frame += [0x3D, byte & 0xEF] } else { frame.append(byte) }
        }
        frame.append(0x3C)
        log?("send \(frame.map { String(format: "%02x", $0) }.joined(separator: " "))")
        _ = frame.withUnsafeMutableBytes { channel?.writeSync($0.baseAddress, length: UInt16($0.count)) }
    }

    private func command(_ payload: [UInt8]) {
        send(type: 0x0C, payload: payload, sequence: sequence)
        sequence ^= 1
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        log?("opened \(error)")
        guard error == kIOReturnSuccess else { finish(nil); return }
        command([0x00, 0x00])   // 初始化
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.channel != nil else { return }
            self.command([0x22, 0x00])   // 新版协议：查电量
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.channel != nil else { return }
                self.command([0x10, 0x00])   // 旧版协议
            }
        }
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        log?("recv \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
        buffer += bytes
        while let start = buffer.firstIndex(of: 0x3E), let end = buffer[start...].firstIndex(of: 0x3C) {
            var frame: [UInt8] = []
            var escape = false
            for byte in buffer[(start + 1)..<end] {
                if escape { frame.append(byte | 0x10); escape = false }
                else if byte == 0x3D { escape = true }
                else { frame.append(byte) }
            }
            buffer.removeSubrange(...end)
            handle(frame)
        }
    }

    private func handle(_ frame: [UInt8]) {
        guard frame.count >= 7 else { return }
        let type = frame[0], seq = frame[1]
        let length = Int(frame[2]) << 24 | Int(frame[3]) << 16 | Int(frame[4]) << 8 | Int(frame[5])
        guard frame.count >= 6 + length else { return }
        let payload = Array(frame[6..<(6 + length)])
        if type != 0x01 { send(type: 0x01, payload: [], sequence: seq ^ 1) }   // 确认对方的报文
        guard let code = payload.first else { return }
        // 电量回复 / 通知：[代码][类型][电量][是否充电]
        if [0x23, 0x25, 0x11, 0x13].contains(code), payload.count >= 3 {
            let level = Int(payload[2])
            log?("battery \(level)")
            if (0...100).contains(level) { finish(level) }
        }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        log?("closed")
        if completion != nil { finish(nil) }
    }
}

