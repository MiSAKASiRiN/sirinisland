import AppKit
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = IslandModel()
    let updates = SoftwareUpdates()
    private lazy var settings = SettingsWindow(model: model, updates: updates)
    lazy var music = NowPlaying(model)
    let volume = SystemVolume()
    let brightness = SystemBrightness()
    let battery = BatteryMonitor()
    let banners = SystemBannerMonitor(.notifications)
    let systemFocus = SystemBannerMonitor(.focus)
    var island: IslandController?
    var status: NSStatusItem!
    var tick: Timer?
    private var hidden = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = IslandLogo.menuImage
        status.button?.toolTip = "SirinIsland"
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        updates.start()
        updateScreen()
        NotificationCenter.default.addObserver(self, selector: #selector(updateScreen), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        model.onFinish = { [weak self] in
            guard let self else { return }
            NSSound(named: "Glass")?.play()
            guard !self.hidden, let island = self.island else { return }
            self.model.tab = .focus
            island.show(true)
            if !self.model.pinned && !island.panel.frame.contains(NSEvent.mouseLocation) { island.schedule(false, after: 4) }
        }
        volume.onChange = { [weak self] in self?.island?.presentEvent(.volume($0)) }
        volume.islandVisible = { [weak self] in self?.hidden == false }
        volume.onKeyAccess = { [weak self] in self?.model.volumeKeysActive = $0 }
        brightness.onChange = { [weak self] in self?.island?.presentEvent(.brightness($0)) }
        volume.onBrightnessKey = { [weak self] up,fine in self?.brightness.adjust(increasing:up,fine:fine) ?? false }
        battery.onNotice = { [weak self] in self?.island?.presentEvent(.battery($0)) }
        battery.start()
        brightness.start()
        volume.start()
        if !model.volumeKeysActive { SystemVolume.promptIfNeeded() }
        banners.onNotice = { [weak self] in self?.island?.presentEvent($0) }
        systemFocus.onNotice = banners.onNotice
        banners.start()
        systemFocus.start()
        model.codex.onLowQuota = { [weak self] id, text in
            self?.island?.presentEvent(.banner(BannerNotice(id: id, application: "ChatGPT", title: "Codex 额度提醒", preview: text)))
        }
        model.codex.start()
        music.start()
        model.toggleMusic = { [weak self] in self?.music.controller.togglePlayPause() }
        model.tick()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.model.tick()
        }
        tick = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    @objc func updateScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        if let island { island.relocate(screen) } else { island = IslandController(model: model, screen: screen) }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func entry(_ title: String,_ action: Selector,_ key: String = "") {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        let title = menu.addItem(withTitle: "SirinIsland", action: nil, keyEquivalent: "")
        title.isEnabled = false
        entry("正在播放", #selector(openMusic))
        if model.song?.playing == true { entry("重新连接音频频谱", #selector(retryAudio)) }
        let lyrics = menu.addItem(withTitle:"收起时显示歌词", action:#selector(toggleCompactLyrics), keyEquivalent:"")
        lyrics.target = self
        lyrics.state = model.keepsCompactLyrics ? .on : .off
        entry("打开专注计时", #selector(focus))
        entry("打开文件暂存架", #selector(shelf))
        entry("查看 Codex 额度", #selector(openCodex))
        entry("打开岛内终端", #selector(openTerminal))
        menu.addItem(.separator())
        entry("设置…", #selector(openSettings), ",")
        if let controller = updates.controller {
            let title = updates.pendingVersion.map { "查看更新 \($0)…" } ?? "检查更新…"
            menu.addItem(withTitle: title, action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "").target = controller
        }
        entry(hidden ? "显示灵动岛" : "隐藏灵动岛", #selector(toggleVisibility))
        entry("退出SirinIsland", #selector(quit), "q")
    }
    func applicationWillTerminate(_ notification: Notification) { model.terminal.stop(); model.codex.stop(); volume.stop(); brightness.stop(); battery.stop(); banners.stop(); systemFocus.stop(); music.stop() }
    @objc func openSettings() { settings.present() }
    @objc func toggleCompactLyrics() { model.keepsCompactLyrics.toggle() }
    @objc func openMusic() { open(.music) }
    @objc func retryAudio() { music.retryAudio() }
    @objc func focus() { open(.focus) }
    @objc func openTerminal() { open(.terminal) }
    @objc func openCodex() { open(.codex) }
    @objc func shelf() { open(.shelf) }
    private func open(_ tab: IslandTab) {
        hidden = false
        model.selectPage(tab)
        island?.setVisible(true)
        island?.show(true)
        // Give the pointer time to travel from the menu to the island.
        if !model.pinned && tab != .terminal { island?.schedule(false, after: 6) }
    }
    @objc func toggleVisibility() {
        hidden.toggle()
        if hidden { island?.show(false); island?.setVisible(false) }
        else { island?.setVisible(true) }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        open(model.song?.playing == true ? .music : .focus)
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
