import AppKit
import ServiceManagement
import SwiftUI

/// 단축키 하나 — 키 코드 + 수식키(⌃⌥⇧⌘, CGEventFlags 와 NSEvent.ModifierFlags 의 비트가 같다).
struct Shortcut: Equatable {
    var keyCode: Int64
    var modifiers: UInt64

    static let modifierMask: UInt64 =
        CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskCommand.rawValue

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    /// ⌃⌥⇧⌘ + 키 이름 — 메뉴·설정 창에 보이는 모양.
    var display: String {
        var s = ""
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        return s + (Key.name(keyCode) ?? "Key \(keyCode)")
    }

    /// 메뉴 항목의 키 칸에 넣을 글자(없으면 메뉴엔 안 보인다).
    var menuKey: String {
        guard let name = Key.name(keyCode) else { return "" }
        return name == "Space" ? " " : name.lowercased()
    }

    var menuModifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: UInt(modifiers)) }
}

/// 모드별 단축키. UserDefaults 에 남고, 바꾸면 메뉴·이벤트 탭이 바로 따른다.
final class Shortcuts: ObservableObject {
    static let shared = Shortcuts()
    static let didChange = Notification.Name("PokeyShortcutsDidChange")

    static let modes: [(mode: Controller.Mode, key: String, unused: String)] = [
        (.element, "element", ""), (.grid, "grid", ""), (.free, "free", ""), (.scroll, "scroll", ""),
    ]

    private static let defaultsTable: [Controller.Mode: Shortcut] = [
        .element: Shortcut(keyCode: 2, modifiers: CGEventFlags.maskControl.rawValue),  // ⌃D
        .grid: Shortcut(keyCode: 5, modifiers: CGEventFlags.maskControl.rawValue),  // ⌃G
        .free: Shortcut(keyCode: 3, modifiers: CGEventFlags.maskControl.rawValue),  // ⌃F
        .scroll: Shortcut(keyCode: 1, modifiers: CGEventFlags.maskControl.rawValue),  // ⌃S
    ]

    @Published private(set) var table: [Controller.Mode: Shortcut] = defaultsTable
    /// 설정 창에서 키를 받는 중 — 그동안 이벤트 탭은 아무것도 가로채지 않는다.
    @Published var isRecording = false

    private init() {
        let saved = UserDefaults.standard.dictionary(forKey: "shortcuts") as? [String: [Int]] ?? [:]
        for (mode, key, _) in Self.modes {
            if let pair = saved[key], pair.count == 2 {
                table[mode] = Shortcut(keyCode: Int64(pair[0]), modifiers: UInt64(pair[1]))
            }
        }
    }

    func shortcut(for mode: Controller.Mode) -> Shortcut { table[mode] ?? Self.defaultsTable[mode]! }

    /// 이 키·수식키에 걸린 모드.
    func mode(code: Int64, flags: CGEventFlags) -> Controller.Mode? {
        let mods = flags.rawValue & Shortcut.modifierMask
        return table.first { $0.value.keyCode == code && $0.value.modifiers == mods }?.key
    }

    /// 다른 모드가 이미 쓰던 단축키면 서로 바꾼다.
    func set(_ shortcut: Shortcut, for mode: Controller.Mode) {
        if let other = table.first(where: { $0.value == shortcut && $0.key != mode })?.key {
            table[other] = table[mode]
        }
        table[mode] = shortcut
        save()
    }

    func reset() {
        table = Self.defaultsTable
        save()
    }

    private func save() {
        var out: [String: [Int]] = [:]
        for (mode, key, _) in Self.modes {
            let s = shortcut(for: mode)
            out[key] = [Int(s.keyCode), Int(s.modifiers)]
        }
        UserDefaults.standard.set(out, forKey: "shortcuts")
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

// MARK: 설정 창

/// 설정 창 — 언어와 모드별 단축키.
struct SettingsView: View {
    @ObservedObject var store = Shortcuts.shared
    @ObservedObject var language = Language.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("Language", "언어")).font(.title3.bold())
                Spacer()
                Picker("", selection: $language.code) {
                    ForEach(Language.Code.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            Toggle(L("Launch at login", "로그인 시 자동 실행"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        NSLog("Pokey: 로그인 항목 변경 실패 \(error)")
                    }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            Divider()
            Text(L("Shortcuts", "단축키")).font(.title3.bold())
            VStack(spacing: 10) {
                ForEach(Shortcuts.modes, id: \.key) { item in
                    HStack {
                        Text(AppDelegate.title(of: item.mode))
                        Spacer()
                        ShortcutRecorder(mode: item.mode)
                    }
                }
            }
            Text(
                L(
                    "Click a button and press the new shortcut. Include ⌃, ⌥ or ⌘. Esc cancels.",
                    "버튼을 누르고 새 단축키를 입력하세요. ⌃ ⌥ ⌘ 중 하나는 같이 눌러야 해요. esc 는 취소."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("Restore Defaults", "기본값으로")) { store.reset() }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

private struct ShortcutRecorder: View {
    @ObservedObject var store = Shortcuts.shared
    let mode: Controller.Mode
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        // 버튼 폭은 안쪽 글자에 주어 버튼 자체가 줄 오른쪽 끝에 붙게(바깥 frame 은 가운데 정렬이 된다).
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? L("Press keys…", "키를 누르세요…") : store.shortcut(for: mode).display)
                .frame(minWidth: 96)
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        store.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // esc
                stop()
                return nil
            }
            let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
            guard !mods.intersection([.control, .option, .command]).isEmpty else {
                NSSound.beep()
                return nil
            }
            store.set(Shortcut(keyCode: Int64(event.keyCode), modifiers: UInt64(mods.rawValue)), for: mode)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        store.isRecording = false
    }
}
