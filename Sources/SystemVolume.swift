import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio

struct OutputVolume: Equatable {
    let level: Float32
    let muted: Bool
    var percent: Int { Int((level * 100).rounded()) }
}

private struct AudioProperty {
    let object: AudioObjectID
    var address: AudioObjectPropertyAddress

    init(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput, element: UInt32 = 0) {
        self.object = object
        address = AudioObjectPropertyAddress(mSelector:selector,mScope:scope,mElement:element)
    }

    func read<T: Numeric>(_ type: T.Type) -> T? {
        var key = address, value: T = 0, size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of:&value) {
            AudioObjectGetPropertyData(object,&key,0,nil,&size,$0.baseAddress!)
        }
        return status == noErr ? value : nil
    }

    func write<T: Numeric>(_ new: T) -> Bool {
        var key = address, value = new, writable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(object,&key,&writable) == noErr, writable.boolValue else { return false }
        return withUnsafeBytes(of:&value) {
            AudioObjectSetPropertyData(object,&key,0,nil,UInt32($0.count),$0.baseAddress!) == noErr
        }
    }

    func observe(_ block: @escaping AudioObjectPropertyListenerBlock) -> (() -> Void)? {
        var key = address
        guard AudioObjectHasProperty(object,&key),
              AudioObjectAddPropertyListenerBlock(object,&key,.main,block) == noErr else { return nil }
        return { var key = self.address; AudioObjectRemovePropertyListenerBlock(self.object,&key,.main,block) }
    }
}

final class SystemVolume {
    var onChange: ((OutputVolume) -> Void)?
    var onBrightnessKey: ((_ increasing: Bool, _ fine: Bool) -> Bool)?
    var onKeyAccess: ((Bool) -> Void)?
    var islandVisible: () -> Bool = { true }
    private let output = AudioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, scope:kAudioObjectPropertyScopeGlobal)
    private var device: AudioDeviceID = 0
    private var level: AudioProperty?
    private var mute: AudioProperty { AudioProperty(device,kAudioDevicePropertyMute) }
    private var previous: OutputVolume?
    private var removeOutput: (() -> Void)?
    private var removeLevels: [() -> Void] = []
    private var lastDeniedAccess: Bool?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var consumed = Set<Int>()
    private var retry: Timer?
    private lazy var feedback = NSSound(contentsOfFile:"/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff", byReference:true)

    func start() {
        removeOutput = output.observe { [weak self] _,_ in self?.bindOutput() }
        bindOutput()
        refreshKeyAccess()
        let timer = Timer(timeInterval:2,repeats:true) { [weak self] _ in self?.refreshKeyAccess() }
        timer.tolerance = 0.35
        retry = timer
        RunLoop.main.add(timer,forMode:.common)
    }

    private func bindOutput() {
        let next = output.read(UInt32.self) ?? 0
        guard next != device else { return }
        removeLevels.forEach { $0() }
        removeLevels = []
        device = next
        let virtual = AudioProperty(device,kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        let master = AudioProperty(device,kAudioDevicePropertyVolumeScalar)
        level = [virtual,master].first { $0.read(Float32.self) != nil }
        previous = snapshot()
        // Some drivers notify only the physical channels underlying the virtual master.
        let watched = [virtual,master,mute,AudioProperty(device,kAudioDevicePropertyVolumeScalar,element:1),
                       AudioProperty(device,kAudioDevicePropertyVolumeScalar,element:2)]
        removeLevels = watched.compactMap { property in
            property.observe { [weak self] _,_ in
                guard let self, self.device == next else { return }
                self.publish()
            }
        }
    }

    private func snapshot() -> OutputVolume? {
        guard let value = level?.read(Float32.self), value.isFinite else { return nil }
        return OutputVolume(level:min(1,max(0,value)),muted:(mute.read(UInt32.self) ?? 0) != 0)
    }

    private func publish(_ force: Bool = false) {
        guard let volume = snapshot() else { return }
        let changed = volume != previous
        previous = volume
        if changed || force { onChange?(volume) }
    }

    enum Key: Int { case up = 0, down = 1, mute = 7 }

    func adjust(_ key: Key, fine: Bool) -> Bool {
        bindOutput()
        guard let current = snapshot() else { return false }
        switch key {
        case .mute:
            guard mute.write(UInt32(current.muted ? 0 : 1)) else { return false }
        case .up, .down:
            let units: Float32 = fine ? 64 : 16
            let index = current.level * units
            let next = key == .up ? floor(index+0.001)+1 : ceil(index-0.001)-1
            guard level?.write(min(1,max(0,next/units))) == true else { return false }
            if current.muted { _ = mute.write(UInt32(0)) }
        }
        publish(true)
        return true
    }

    // Subscribe only to system-defined media events. Other keys and shortcuts
    // keep their system handling, as do outputs without writable volume controls.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            consumed.removeAll()
            if let tap { CGEvent.tapEnable(tap:tap,enable:true) }
            return pass
        }
        guard type.rawValue == UInt32(NSEvent.EventType.systemDefined.rawValue),
              let media = NSEvent(cgEvent:event), media.subtype.rawValue == 8 else { return pass }
        let code = (media.data1 >> 16) & 0xffff
        let phase = (media.data1 >> 8) & 0xff
        if phase == 0x0b { return consumed.remove(code) != nil ? nil : pass }
        guard phase == 0x0a, islandVisible() else { return pass }
        let flags = media.modifierFlags
        if flags.contains(.command) || flags.contains(.control) || (flags.contains(.option) && !flags.contains(.shift)) { return pass }
        let fine = flags.contains([.option,.shift])
        if code == 2 || code == 3 { // NX_KEYTYPE_BRIGHTNESS_UP / DOWN
            guard onBrightnessKey?(code == 2,fine) == true else { return pass }
            consumed.insert(code)
            return nil
        }
        guard let key = Key(rawValue:code) else { return pass }
        let repeating = media.data1 & 1 != 0
        if key == .mute && repeating { return consumed.contains(key.rawValue) ? nil : pass }
        guard adjust(key,fine:fine) else { return pass }
        consumed.insert(key.rawValue)
        if key != .mute && !fine {
            let sounds = UserDefaults.standard.bool(forKey:"com.apple.sound.beep.feedback")
            if sounds != flags.contains(.shift) { feedback?.stop(); feedback?.play() }
        }
        return nil
    }

    func refreshKeyAccess() {
        if let tap {
            if CGEvent.tapIsEnabled(tap:tap) { return }
            CGEvent.tapEnable(tap:tap,enable:true)
            if CGEvent.tapIsEnabled(tap:tap) { return }
            stopTap()
        }
        // Ask Quartz for this specific media-event tap. The Accessibility
        // preflight alone does not establish whether a tap was installed.
        let trusted = AXIsProcessTrusted() || CGPreflightPostEventAccess()
        if !trusted && lastDeniedAccess == false { return }
        let mask: CGEventMask = 1 << NSEvent.EventType.systemDefined.rawValue
        let handler: CGEventTapCallBack = { _,type,event,context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<SystemVolume>.fromOpaque(context).takeUnretainedValue().handle(type,event)
        }
        // Use the earliest available point in the user's session.
        for location in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            guard let port = CGEvent.tapCreate(tap:location,place:.headInsertEventTap,options:.defaultTap,
                                               eventsOfInterest:mask,callback:handler,userInfo:Unmanaged.passUnretained(self).toOpaque()),
                  let runSource = CFMachPortCreateRunLoopSource(nil,port,0) else { continue }
            tap = port
            source = runSource
            CFRunLoopAddSource(CFRunLoopGetMain(),runSource,.commonModes)
            CGEvent.tapEnable(tap:port,enable:true)
            if CGEvent.tapIsEnabled(tap:port) {
                lastDeniedAccess = nil
                onKeyAccess?(true)
                return
            }
            stopTap()
        }
        lastDeniedAccess = trusted
    }

    static func promptIfNeeded() {
        let defaults = UserDefaults.standard
        guard !AXIsProcessTrusted(), !defaults.bool(forKey:"didPromptForVolumeKeys") else { return }
        defaults.set(true,forKey:"didPromptForVolumeKeys")
        promptForAccess()
    }

    private static func promptForAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccess() {
        promptForAccess()
        if let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func stopTap() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil; source = nil
        consumed.removeAll()
        onKeyAccess?(false)
    }

    func stop() {
        retry?.invalidate(); retry = nil
        stopTap()
        removeOutput?(); removeOutput = nil
        removeLevels.forEach { $0() }; removeLevels = []
        device = 0; level = nil; previous = nil
        lastDeniedAccess = nil
    }
}
