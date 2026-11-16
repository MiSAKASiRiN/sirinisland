import AppKit
import IOBluetooth
import IOKit.ps

struct BatteryPart: Equatable {
    let id: String
    let percent: Int?
    let charging: Bool
    let onAC: Bool

    var label: String {
        switch id {
        case "Left": return "左"
        case "Right": return "右"
        case "Case": return "盒"
        default: return ""
        }
    }
    var order: Int { ["Left", "Right", "Case"].firstIndex(of: id) ?? 3 }
}

struct BatteryDevice: Equatable {
    let id: String
    let name: String
    var parts: [BatteryPart]
    var category: String? = nil
    var transport: String? = nil

    func symbol(for part: BatteryPart?) -> String {
        let model = name.lowercased()
        let pro = model.contains("pro")
        switch part?.id {
        case "Case": return pro ? "airpodspro.chargingcase.wireless" : "airpods.chargingcase"
        case "Left": return pro ? "airpodpro.left" : "airpod.left"
        case "Right": return pro ? "airpodpro.right" : "airpod.right"
        default: break
        }
        if id == "mac" || model.contains("macbook") { return "laptopcomputer" }
        if model.contains("airpods max") { return "airpodsmax" }
        if model.contains("airpods") { return pro ? "airpodspro" : "airpods" }
        if model.contains("iphone") { return "iphone" }
        if model.contains("ipad") { return "ipad" }
        if model.contains("watch") { return "applewatch" }
        if model.contains("pencil") { return "applepencil" }
        if model.contains("keyboard") { return "keyboard" }
        if model.contains("mouse") { return "magicmouse" }
        if model.contains("trackpad") { return "rectangle.roundedtop" }
        switch category {
        case "Keyboard": return "keyboard"
        case "Mouse": return "magicmouse"
        case "Trackpad": return "rectangle.roundedtop"
        case "Headphone", "Headset", "HearingAid": return "headphones"
        case "Speaker": return "hifispeaker"
        case "Game Controller": return "gamecontroller"
        case "Watch": return "applewatch"
        case "Pencil": return "applepencil"
        default: return transport == "USB" ? "cable.connector" : "dot.radiowaves.left.and.right"
        }
    }
}

struct BatteryNotice: Equatable {
    enum Kind: String { case connected = "已连接", charging = "充电中", plugged = "接入电源", low = "低电量" }
    let kind: Kind
    let device: BatteryDevice
    let parts: [BatteryPart]

    var status: String {
        if kind == .connected, let transport = device.transport {
            return transport + " " + kind.rawValue
        }
        return kind.rawValue
    }
}

struct BatteryTransitions {
    private var previous: [String: BatteryDevice]?
    private var lowParts: [String: Set<String>] = [:]

    mutating func update(_ devices: [BatteryDevice], newConnections: Set<String> = []) -> [BatteryNotice] {
        var notices: [BatteryNotice] = []
        var next: [String: BatteryDevice] = [:]
        for device in devices {
            let oldDevice = previous?[device.id]
            let connected = previous != nil && (oldDevice == nil || newConnections.contains(device.id)) && device.id != "mac"
            var low: [BatteryPart] = [], charging: [BatteryPart] = [], plugged: [BatteryPart] = []
            var latched = lowParts[device.id, default: []]
            for part in device.parts {
                let old = oldDevice?.parts.first { $0.id == part.id }
                if let percent = part.percent {
                    if percent > 22 { latched.remove(part.id) }
                    if percent <= 20 && !part.charging && !part.onAC && latched.insert(part.id).inserted {
                        low.append(part)
                    }
                }
                if part.charging && old?.charging != true { charging.append(part) }
                else if device.id == "mac", part.onAC, old?.onAC == false { plugged.append(part) }
            }
            // A closed case or an out-of-range earbud can disappear from a partial report.
            var remembered = device
            remembered.parts += (oldDevice?.parts ?? []).filter { old in !device.parts.contains { $0.id == old.id } }
            next[device.id] = remembered
            lowParts[device.id] = latched
            if connected { notices.append(.init(kind: .connected, device: device, parts: device.parts)) }
            for (kind, parts) in [(BatteryNotice.Kind.charging, charging), (.plugged, plugged), (.low, low)] where !parts.isEmpty {
                notices.append(.init(kind: kind, device: device, parts: parts))
            }
        }
        previous = next
        lowParts = lowParts.filter { previous?[$0.key] != nil }
        return notices
    }
}

final class BatteryMonitor: NSObject {
    var onNotice: ((BatteryNotice) -> Void)?
    private var transitions = BatteryTransitions()
    private var sources: [CFRunLoopSource] = []
    private var connect: IOBluetoothUserNotification?
    private var disconnect: [String: IOBluetoothUserNotification] = [:]
    private let usb = USBDevices()
    private var attachedNames: [String: String] = [:]
    private var lastPowerDevices: [BatteryDevice] = []
    private var groupAliases: [String: String] = [:]
    private var addressAliases: [String: String] = [:]
    private var newAddresses: [String] = []
    private var lastConnection: [String: TimeInterval] = [:]
    private var pending: DispatchWorkItem?
    private var active = false
    // IOPowerSourcesPrivate.h, kIOPSSourceAll. Older systems can still report the Mac battery.
    private typealias CopySources = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    private static let allSources = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOPSCopyPowerSourcesByType")
        .map { unsafeBitCast($0, to: CopySources.self) }

    static func powerDevices() -> [BatteryDevice]? {
        guard let blob = (allSources?(0) ?? IOPSCopyPowerSourcesInfo())?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() else { return nil }
        var groups: [String: BatteryDevice] = [:]
        for handle in list as [CFTypeRef] {
            guard let d = IOPSGetPowerSourceDescription(blob, handle)?.takeUnretainedValue() as? [String: Any],
                  d["Is Present"] as? Bool != false, let name = d["Name"] as? String else { continue }
            let mac = d["Type"] as? String == "InternalBattery"
            let group = mac ? "mac" : "power:" + ((d["Group Identifier"] ?? d["Accessory Identifier"]) as? String ?? name)
            // The case sometimes publishes a different display name than the two earbuds.
            let caseOnly = d["Part Identifier"] as? String == "Case"
            let deviceName = mac ? "Mac" : (caseOnly && name.hasSuffix(" Case") ? String(name.dropLast(5)) : name)
            var device = groups[group] ?? BatteryDevice(id: group, name: deviceName, parts: [])
            if !caseOnly || device.category == nil { device.category = d["Accessory Category"] as? String ?? device.category }
            if let transport = d["Transport Type"] as? String {
                if transport.hasPrefix("Bluetooth") { device.transport = "蓝牙" }
                else if transport == "USB" { device.transport = "USB" }
            }
            let combined = d["Combined Parts"] as? [[String: Any]] ?? []
            for entry in combined.isEmpty ? [d] : combined.map({ d.merging($0) { _, new in new } }) {
                let partID = entry["Part Identifier"] as? String ?? "Single"
                let percent = (entry["Current Capacity"] as? Int).flatMap { current -> Int? in
                    let max = entry["Max Capacity"] as? Int ?? 100
                    guard max > 0, (0...max).contains(current) else { return nil }
                    return Int((100 * Double(current) / Double(max)).rounded())
                }
                let part = BatteryPart(id: partID, percent: percent, charging: entry["Is Charging"] as? Bool == true,
                                       onAC: entry["Power Source State"] as? String == "AC Power")
                device.parts.removeAll { $0.id == part.id }
                device.parts.append(part)
            }
            device.parts.sort { $0.order < $1.order }
            groups[group] = device
        }
        return Array(groups.values)
    }

    func start() {
        guard !active else { return }
        active = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue().schedule()
        }
        typealias Subscribe = @convention(c) (IOPowerSourceCallbackType, UnsafeMutableRawPointer?) -> Unmanaged<CFRunLoopSource>?
        let observers = ["IOPSAccCreateAttachNotification", "IOPSAccCreateLimitedPowerNotification",
                         "IOPSAccNotificationCreateRunLoopSource"]
        sources = observers.compactMap { name in
            guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
            return unsafeBitCast(address, to: Subscribe.self)(callback, context)?.takeRetainedValue()
        }
        if let system = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() { sources.append(system) }
        sources.forEach { CFRunLoopAddSource(CFRunLoopGetMain(), $0, .commonModes) }
        usb.onAttach = { [weak self] key, name, initial in
            guard let self, self.attachedNames[key] == nil else { return }
            self.attachedNames[key] = name
            if !initial {
                self.newAddresses.append(key)
                self.schedule()
            }
        }
        usb.onDetach = { [weak self] key in self?.detached(key) }
        usb.start()
        connect = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(didConnect(_:device:)))
        for device in IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [] where device.isConnected() {
            watch(device)
        }
        refresh()
    }

    private func watch(_ device: IOBluetoothDevice) {
        guard let address = device.addressString else { return }
        attachedNames[address] = device.name ?? "蓝牙设备"
        if disconnect[address] == nil {
            disconnect[address] = device.register(forDisconnectNotification: self, selector: #selector(didDisconnect(_:device:)))
        }
    }

    @objc private func didConnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, device.isConnected() else { return }
            if let address = device.addressString, self.attachedNames[address] == nil { self.newAddresses.append(address) }
            self.watch(device)
            self.schedule()
        }
    }

    @objc private func didDisconnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, let address = device.addressString, !device.isConnected() else { return }
            self.disconnect.removeValue(forKey: address)?.unregister()
            self.detached(address)
        }
    }

    private func detached(_ key: String) {
        guard attachedNames.removeValue(forKey: key) != nil else { return }
        newAddresses.removeAll { $0 == key }
        if let id = addressAliases.removeValue(forKey: key) { lastConnection.removeValue(forKey: id) }
        schedule()
    }

    private func schedule() {
        guard active, pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.pending = nil; self?.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func refresh() {
        guard active else { return }
        if let groups = Self.powerDevices() { lastPowerDevices = groups }
        var devices: [String: BatteryDevice] = [:]
        for group in lastPowerDevices {
            let candidates = attachedNames.filter { key, name in
                name == group.name && (group.transport == nil || group.transport == (key.hasPrefix("usb:") ? "USB" : "蓝牙"))
            }
            let address = candidates.count == 1 ? candidates.first?.key : nil
            let id = groupAliases[group.id] ?? address.flatMap { addressAliases[$0] } ?? group.id
            groupAliases[group.id] = id
            if let address { addressAliases[address] = id }
            devices[id] = BatteryDevice(id: id, name: group.name, parts: group.parts, category: group.category, transport: group.transport)
        }
        for (address, name) in attachedNames {
            let id = addressAliases[address] ?? (address.hasPrefix("usb:") ? address : "bt:" + address)
            addressAliases[address] = id
            if devices[id] == nil { devices[id] = .init(id: id, name: name, parts: []) }
            devices[id]?.transport = address.hasPrefix("usb:") ? "USB" : "蓝牙"
        }
        let now = ProcessInfo.processInfo.systemUptime
        lastConnection = lastConnection.filter { now - $0.value < 3 }
        let arrivals = newAddresses.compactMap { addressAliases[$0] }
        let connections = Set(arrivals.filter { lastConnection[$0] == nil })
        newAddresses.removeAll()
        let ordered = devices.values.sorted {
            let lhs = arrivals.firstIndex(of: $0.id) ?? Int.max
            let rhs = arrivals.firstIndex(of: $1.id) ?? Int.max
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
        for notice in transitions.update(ordered, newConnections: connections) {
            if notice.kind == .connected { lastConnection[notice.device.id] = now }
            onNotice?(notice)
        }
    }

    func stop() {
        active = false
        pending?.cancel()
        pending = nil
        sources.forEach { CFRunLoopSourceInvalidate($0) }
        sources.removeAll()
        connect?.unregister()
        connect = nil
        disconnect.values.forEach { $0.unregister() }
        disconnect.removeAll()
        usb.stop()
        attachedNames.removeAll()
        addressAliases.removeAll()
        groupAliases.removeAll()
        newAddresses.removeAll()
        lastConnection.removeAll()
        lastPowerDevices.removeAll()
        transitions = BatteryTransitions()
    }
}
