import AppKit

// DisplayServices exposes the system's native backlight level. Resolve it at
// runtime so a display without native brightness control keeps its usual keys.
final class SystemBrightness {
    typealias DisplayID = CGDirectDisplayID
    private typealias Read = @convention(c) (DisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Write = @convention(c) (DisplayID, Float) -> Int32
    private typealias Observe = @convention(c) (DisplayID, UInt32, CFNotificationCallback) -> Int32
    private typealias Remove = @convention(c) (DisplayID, UInt32) -> Int32
    private static let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static func function<T>(_ name: String, _: T.Type) -> T? {
        guard let framework, let address = dlsym(framework,name) else { return nil }
        return unsafeBitCast(address,to:T.self)
    }
    private static let read = function("DisplayServicesGetBrightness",Read.self)
    private static let write = function("DisplayServicesSetBrightness",Write.self)
    private static let observe = function("DisplayServicesRegisterForBrightnessChangeNotifications",Observe.self)
    private static let remove = function("DisplayServicesUnregisterForBrightnessChangeNotifications",Remove.self)
    private static weak var observer: SystemBrightness?
    private var display: DisplayID?
    private var subscribed = false
    private var lastLevel: Float?
    private var screenChange: NSObjectProtocol?
    var onChange: ((Float) -> Void)?

    func start() {
        Self.observer = self
        bindDisplay()
        screenChange = NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,
                                                             object:nil,queue:.main) { [weak self] _ in self?.bindDisplay() }
    }

    private func level(of id: DisplayID) -> Float? {
        var value: Float = 0
        guard Self.read?(id,&value) == 0, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    private func bindDisplay() {
        let ids = NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
        let target = ids.first { CGDisplayIsBuiltin($0) != 0 && level(of:$0) != nil }
            ?? ids.first { level(of:$0) != nil }
        guard target != display else { return }
        unsubscribe()
        display = target
        lastLevel = target.flatMap(level)
        guard let target, Self.remove != nil else { return }
        subscribed = Self.observe?(target,target,{ _,_,_,_,_ in
            // Read back the current display rather than replaying queued values
            // from a rapid key sequence or a screen that just disconnected.
            DispatchQueue.main.async { SystemBrightness.observer?.publishIfChanged() }
        }) == 0
    }

    private func publishIfChanged() {
        guard let display, let current = level(of:display), current != lastLevel else { return }
        lastLevel = current
        onChange?(current)
    }

    func adjust(increasing: Bool, fine: Bool) -> Bool {
        guard let display, let current = level(of:display) else { return false }
        let steps: Float = fine ? 64 : 16
        let index = increasing ? floor(current*steps+0.001)+1 : ceil(current*steps-0.001)-1
        let target = min(1,max(0,index/steps))
        guard Self.write?(display,target) == 0 else { return false }
        let applied = level(of:display) ?? target
        lastLevel = applied
        onChange?(applied)
        return true
    }

    private func unsubscribe() {
        if subscribed, let display { _ = Self.remove?(display,display) }
        subscribed = false
    }

    func stop() {
        if let screenChange { NotificationCenter.default.removeObserver(screenChange) }
        screenChange = nil
        unsubscribe()
        display = nil
        if Self.observer === self { Self.observer = nil }
    }
}
