import Foundation
import IOKit

// Match physical devices, not each interface of a composite keyboard or dock.
final class USBDevices {
    var onAttach: ((String, String, Bool) -> Void)?
    var onDetach: ((String) -> Void)?
    private var port: IONotificationPortRef?
    private var attached: io_iterator_t = 0
    private var detached: io_iterator_t = 0

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            Unmanaged<USBDevices>.fromOpaque(context).takeUnretainedValue().drain(iterator)
        }
        for addition in [true, false] {
            var iterator: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(port, addition ? kIOFirstMatchNotification : kIOTerminatedNotification,
                    IOServiceMatching("IOUSBHostDevice"), callback, context, &iterator) == KERN_SUCCESS else {
                stop()
                return
            }
            if addition { attached = iterator } else { detached = iterator }
            // Draining seeds the initial inventory and arms future notifications.
            drain(iterator, initial: true)
        }
    }

    private func drain(_ iterator: io_iterator_t, initial: Bool = false) {
        while true {
            let device = IOIteratorNext(iterator)
            guard device != 0 else { return }
            defer { IOObjectRelease(device) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(device, &id) == KERN_SUCCESS else { continue }
            let key = "usb:" + String(id)
            if iterator == detached {
                onDetach?(key)
                continue
            }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            if property("Built-In") as? Bool == true || property("non-removable") as? String == "yes" { continue }
            let product = property("USB Product Name") as? String
            var registryName = [CChar](repeating: 0, count: 128)
            let fallback = IORegistryEntryGetName(device, &registryName) == KERN_SUCCESS ? String(cString: registryName) : "USB 设备"
            let name = product.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            onAttach?(key, name, initial)
        }
    }

    func stop() {
        if let port { IONotificationPortDestroy(port) }
        port = nil
        for iterator in [attached, detached] where iterator != 0 { IOObjectRelease(iterator) }
        attached = 0
        detached = 0
    }
}
