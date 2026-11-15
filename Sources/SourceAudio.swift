import CoreAudio
import AudioToolbox
import Foundation

@available(macOS 14.2, *)
private enum AudioDiscovery {
    static func address(_ key: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: key, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func scalar(_ id: AudioObjectID, _ key: AudioObjectPropertySelector) -> UInt32 {
        var a = address(key), value: UInt32 = 0, size: UInt32 = 4
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr ? value : 0
    }
    static func string(_ id: AudioObjectID, _ key: AudioObjectPropertySelector) -> String {
        var a = address(key)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }
    static func objects(for source: AudioSource) -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyProcessObjectList), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size >= 4 else { return [] }
        var ids = [UInt32](repeating: 0, count: Int(size) / 4)
        guard ids.withUnsafeMutableBytes({ AudioObjectGetPropertyData(system, &addr, 0, nil, &size, $0.baseAddress!) }) == noErr else { return [] }
        let active = ids.prefix(Int(size)/4).filter { scalar($0, kAudioProcessPropertyIsRunningOutput) != 0 }
        let pidMatch = active.filter { source.pid == Int32(bitPattern: scalar($0, kAudioProcessPropertyPID)) }
        if !pidMatch.isEmpty { return pidMatch.sorted() }
        return active.filter { object in
            let id = string(object, kAudioProcessPropertyBundleID).lowercased()
            return source.bundles.contains { id == $0 || id.hasPrefix($0 + ".") }
        }.sorted()
    }
}

@available(macOS 14.2, *)
private final class PlayerTap {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var proc: AudioDeviceIOProcID?
    private var started = false
    private let io = DispatchQueue(label: "SirinIsland.audio.samples", qos: .userInitiated)

    init(objects: [AudioObjectID], onFrame: @escaping ([CGFloat]) -> Void) throws {
        func check(_ result: OSStatus) throws {
            if result != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        }
        do {
            let desc = CATapDescription(stereoMixdownOfProcesses: objects)
            desc.name = "SirinIsland · 播放器频谱"
            desc.isPrivate = true
            desc.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(desc, &tap))
            let uid = AudioDiscovery.string(tap, kAudioTapPropertyUID)
            guard !uid.isEmpty else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioHardwareBadObjectError)) }
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SirinIsland · 播放器频谱",
                kAudioAggregateDeviceUIDKey: "local.codex.ArcIsland." + UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid,
                                                   kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &device))
            var addr = AudioDiscovery.address(kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)
            var format = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &format))
            guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mSampleRate > 0 else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioFormatUnsupportedDataFormatError))
            }
            let meter = try SpectrumAnalyzer(rate: format.mSampleRate)
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, io) { _, input, _, _, _ in
                if let frame = meter.consume(input) { onFrame(frame) }
            })
            try check(AudioDeviceStart(device, proc))
            started = true
        } catch {
            stop()
            throw error
        }
    }
    private func stop() {
        if let proc {
            if started { AudioDeviceStop(device, proc) }
            AudioDeviceDestroyIOProcID(device, proc)
            self.proc = nil
        }
        if device != 0 { AudioHardwareDestroyAggregateDevice(device); device = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }
    deinit { stop() }
}

final class SourceAudioMonitor {
    var output: ((AudioSource, [CGFloat], String) -> Void)?
    private let queue = DispatchQueue(label: "SirinIsland.audio.setup", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var session: AnyObject?
    private var current = [AudioObjectID]()
    private var outputDevice: AudioObjectID = 0
    private var generation = UUID()

    func select(_ source: AudioSource?) {
        let token = UUID()
        generation = token
        let publish: (AudioSource, [CGFloat], String) -> Void = { [weak self] target, samples, status in
            DispatchQueue.main.async {
                guard self?.generation == token else { return }
                self?.output?(target, samples, status)
            }
        }
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            session = nil
            current = []
            guard let source else { return }
            guard #available(macOS 14.2, *) else {
                publish(source, [], "实时频谱需要 macOS 14.2 或更高版本")
                return
            }
            let poll = DispatchSource.makeTimerSource(queue: queue)
            poll.schedule(deadline: .now(), repeating: 3)
            poll.setEventHandler { [weak self] in
                guard let self else { return }
                let ids = AudioDiscovery.objects(for: source)
                if ids.isEmpty {
                    self.session = nil
                    self.current = []
                    publish(source, [], "等待播放器音频")
                    return
                }
                let output = AudioDiscovery.scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
                guard self.current != ids || self.outputDevice != output else { return }
                self.outputDevice = output
                self.session = nil
                self.current = ids
                do {
                    var lastSignal = ProcessInfo.processInfo.systemUptime
                    self.session = try PlayerTap(objects: ids) { samples in
                        let now = ProcessInfo.processInfo.systemUptime
                        if samples.contains(where: { $0 > 0 }) { lastSignal = now }
                        publish(source, samples, now-lastSignal > 4 ? "暂无音频信号 · 检查音频录制权限" : "")
                    }
                } catch {
                    publish(source, [], "频谱未连接 · 检查系统音频录制权限")
                }
            }
            timer = poll
            poll.resume()
        }
    }
}
