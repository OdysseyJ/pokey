import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

/// 전역 키 입력을 가로채는 이벤트 탭. 입력기보다 앞에서 보므로 한글 상태에서도 키 코드가 그대로 온다.
final class KeyTap {
    fileprivate var port: CFMachPort?
    fileprivate let handler: (CGEventType, CGEvent) -> Bool

    init(handler: @escaping (CGEventType, CGEvent) -> Bool) {
        self.handler = handler
    }

    func start() -> Bool {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: tapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }
}

private func tapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let port = tap.port { CGEvent.tapEnable(tap: port, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    return tap.handler(type, event) ? nil : Unmanaged.passUnretained(event)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = Controller()
    private var tap: KeyTap?
    private var statusItem: NSStatusItem!
    private var countItem: NSMenuItem!
    private var pokemonItem: NSMenuItem!
    private var dexWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var dexItem: NSMenuItem!
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        // 예전엔 시스템 로그인 항목(경로 지정)으로 켰다 — 이름이 바뀌어 한 번은 SMAppService 로 다시 등록한다.
        if !UserDefaults.standard.bool(forKey: "loginMigrated") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginMigrated")
        }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        startWhenTrusted()

        AXCollector.shared.refreshExtras()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in AXCollector.shared.refreshExtras() }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
            note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                AXCollector.shared.prepare(app)
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication { AXCollector.shared.prepare(front) }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { AXCollector.shared.refreshExtras() }
            }
        }
    }

    // MARK: 권한

    private func startWhenTrusted() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            startTap()
            return
        }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.startTap()
        }
    }

    private func startTap() {
        let tap = KeyTap { [weak self] type, event in self?.controller.handle(type, event) ?? false }
        if tap.start() {
            self.tap = tap
        } else {
            NSLog("Pokey: 이벤트 탭을 만들지 못했다")
        }
    }

    // MARK: 메뉴바

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // 상태 아이콘 수집은 우리 앱을 빼므로 몬스터볼은 직접 넘긴다.
        controller.ownTargets = { [weak self] in
            guard let frame = self?.statusItem.button?.window?.frame, frame.width > 0 else { return [] }
            return [CGRect(x: frame.minX, y: Screens.primaryHeight - frame.maxY, width: frame.width, height: frame.height)]
        }
        statusItem.button?.image = PokeBall.image()
        buildMenu()
        NotificationCenter.default.addObserver(forName: Pokedex.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.updateHeader()
        }
        // 언어·단축키가 바뀌면 메뉴를 새로 짠다.
        for name in [Language.didChange, Shortcuts.didChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.buildMenu()
                self?.dexWindow?.title = L("Pokédex", "포켓몬 도감")
                self?.settingsWindow?.title = L("Pokey Settings", "Pokey 설정")
            }
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        pokemonItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        pokemonItem.isEnabled = false
        menu.addItem(pokemonItem)
        countItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        countItem.isEnabled = false
        menu.addItem(countItem)
        dexItem = NSMenuItem(title: "", action: #selector(showDex), keyEquivalent: "")
        dexItem.target = self
        menu.addItem(dexItem)
        menu.addItem(.separator())
        // 단축키는 제목에 붙이지 않고 키 칸에 — 오른쪽에 정렬된다. 설정에서 바꾼 단축키를 따른다.
        for (mode, _, _) in Shortcuts.modes {
            let shortcut = Shortcuts.shared.shortcut(for: mode)
            let item = NSMenuItem(title: Self.title(of: mode), action: #selector(pickMode(_:)), keyEquivalent: shortcut.menuKey)
            item.keyEquivalentModifierMask = shortcut.menuModifiers
            item.target = self
            item.representedObject = mode
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: L("Settings", "설정"), action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        // terminate: 를 직접 걸면 macOS 26 이 아이콘을 자동으로 붙인다 — 담백하게 글자만.
        let quit = NSMenuItem(title: L("Quit", "종료"), action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        updateHeader()
    }

    static func title(of mode: Controller.Mode) -> String {
        switch mode {
        case .element: return L("Click Element", "요소 클릭")
        case .grid: return L("Grid", "격자")
        case .free: return L("Free Move", "자유 이동")
        case .scroll: return L("Scroll", "스크롤")
        case .idle: return ""
        }
    }

    /// 메뉴 맨 위 — 오늘의 포켓몬(그림·이름)과 오늘 클릭 수.
    private func updateHeader() {
        let dex = Pokedex.shared
        pokemonItem.title = dex.lastTitle
        if let sprite = dex.lastSprite?.copy() as? NSImage {
            sprite.size = NSSize(width: 40, height: 40)
            pokemonItem.image = sprite
        }
        countItem.title = dex.progressTitle
        // 확인 안 한 새 포켓몬이 있으면 "도감" 옆에 빨간 점(메뉴바 아이콘엔 안 찍는다).
        let title = NSMutableAttributedString(string: L("Pokédex", "도감"))
        if dex.hasUnseen {
            title.append(NSAttributedString(string: "  ●", attributes: [.foregroundColor: NSColor.systemRed]))
        }
        dexItem.attributedTitle = title
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showDex() {
        if dexWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 660, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = L("Pokédex", "포켓몬 도감")
            window.isReleasedWhenClosed = false
            window.center()
            dexWindow = window
        }
        // 열 때마다 새로 그린다 — 새 포켓몬 표시는 여기서 지우고, 이번 창에만 빨간 점으로 남긴다.
        dexWindow?.contentView = NSHostingView(rootView: PokedexView(unseen: Pokedex.shared.takeNew()))
        NSApp.activate(ignoringOtherApps: true)
        dexWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 300), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = L("Pokey Settings", "Pokey 설정")
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? Controller.Mode else { return }
        // 메뉴가 닫히고 앞 앱으로 포커스가 돌아간 뒤에.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.controller.enter(mode) }
    }

}
