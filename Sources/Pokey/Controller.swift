import AppKit
import ApplicationServices

/// 모드 전환과 키 처리. 이벤트 탭 콜백이 메인 런루프에서 오므로 전부 메인 스레드에서 돈다.
final class Controller {
    enum Mode { case idle, element, grid, free, scroll }

    private(set) var mode: Mode = .idle
    /// 수집에서 빠지는 우리 앱 자신의 요소(메뉴바 몬스터볼) — CG 좌표.
    var ownTargets: () -> [CGRect] = { [] }
    private let overlay = Overlay()
    /// 누름을 삼킨 키 — 뗌도 삼켜야 앱에 짝 없는 keyUp 이 가지 않는다.
    private var swallowed = Set<Int64>()
    /// ⌃Space(한영 전환)를 누른 뒤 아직 ⌃ 를 떼지 않았다 — 이어 친 d·g·f·s 는 단축키가 아니라 글자다.
    private var controlHeldSinceSpace = false
    private var generation = 0
    private var typed = ""

    // 요소 모드
    private var targets: [(label: String, target: Target)] = []
    private var loading = false
    private var pending: [(Int64, CGEventFlags)] = []

    // 격자 · 자유 이동
    private var cells: [(label: String, rect: CGRect)] = []
    private var cellSize = CGSize(width: 60, height: 60)
    private var gridScreen = 0
    private var cursor = CGPoint.zero

    // 스크롤 모드
    private var scrollArea: CGRect?


    // MARK: 이벤트 입구

    /// true 를 돌려주면 이벤트를 삼킨다.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .leftMouseDown, .rightMouseDown:
            if event.getIntegerValueField(.eventSourceUserData) != Mouse.tag, mode != .idle { exit() }
            return false
        case _ where Shortcuts.shared.isRecording:
            return false  // 설정 창에서 새 단축키를 받는 중
        case .flagsChanged:
            if !event.flags.contains(.maskControl) { controlHeldSinceSpace = false }
            return false
        case .keyUp:
            return swallowed.remove(event.getIntegerValueField(.keyboardEventKeycode)) != nil
        case .keyDown:
            return keyDown(event)
        default:
            return false
        }
    }

    private func keyDown(_ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection([.maskControl, .maskShift, .maskAlternate, .maskCommand])

        if flags == .maskControl, code == Key.space {
            controlHeldSinceSpace = true
        }

        if let target = Shortcuts.shared.mode(code: code, flags: flags) {
            // 한영 전환하고 ⌃ 를 미처 떼기 전에 친 글자 — ⌃ 를 빼고 그 글자 그대로 보낸다.
            if controlHeldSinceSpace, flags == .maskControl, mode == .idle {
                event.flags.remove(.maskControl)
                return false
            }
            swallowed.insert(code)
            if mode == target { exit() } else { enter(target) }
            return true
        }

        guard mode != .idle else { return false }
        swallowed.insert(code)
        key(code, flags)
        return true
    }

    // MARK: 모드 전환

    func enter(_ target: Mode) {
        reset()
        mode = target
        generation += 1
        switch target {
        case .element:
            startElement()
        case .grid:
            cursor = Mouse.location
            gridScreen = Screens.index(containing: cursor)
            buildGrid()
            render()
        case .free:
            cursor = Mouse.location
            render()
        case .scroll:
            moveIntoFocusedWindow()
            scrollArea = AXCollector.scrollArea(at: Mouse.location)
            render()
        case .idle:
            break
        }
    }

    func exit() {
        reset()
        mode = .idle
        generation += 1
        overlay.hide()
    }

    private func reset() {
        if Mouse.dragging { Mouse.release(Mouse.location) }
        typed = ""
        targets = []
        cells = []
        pending = []
        loading = false
        scrollArea = nil
    }

    private func render() {
        let m = overlay.model
        m.clear()
        switch mode {
        case .idle:
            overlay.hide()
            return
        case .element:
            m.hints = targets.map { (label: $0.label, rect: $0.target.rect) }
            m.typed = typed
        case .grid:
            m.gridCells = cells
            m.typed = typed
        case .free:
            m.cursor = cursor
            m.dragging = Mouse.dragging
            m.area = AXCollector.clickTarget(at: cursor)
            m.fillArea = true
        case .scroll:
            if let scrollArea {
                m.area = scrollArea
            } else {
                m.cursor = Mouse.location  // 영역을 못 찾으면 커서 원으로라도
            }
        }
        overlay.show()
    }

    // MARK: 키

    private func key(_ code: Int64, _ flags: CGEventFlags) {
        if code == Key.escape {
            if mode == .grid, !typed.isEmpty {
                typed = ""
                render()
            } else {
                exit()
            }
            return
        }
        switch mode {
        case .element: elementKey(code, flags)
        case .grid: gridKey(code, flags)
        case .free: _ = pointerKey(code, flags, vim: true)
        case .scroll: scrollKey(code, flags)
        case .idle: break
        }
    }

    // MARK: 요소 모드

    private func startElement() {
        loading = true
        let front = NSWorkspace.shared.frontmostApplication
        let gen = generation
        AXCollector.shared.collect(
            pid: front?.processIdentifier ?? 0, bundleID: front?.bundleIdentifier, screens: Screens.all
        ) { [weak self] found in
            guard let self, self.mode == .element, self.generation == gen else { return }
            self.loading = false
            let found = found + self.ownTargets().map { Target(rect: $0, element: nil, isInput: false) }
            guard !found.isEmpty else {
                NSSound.beep()
                self.exit()
                return
            }
            self.targets = Array(zip(Labels.make(found.count), found)).map { (label: $0.0, target: $0.1) }
            self.render()
            let queued = self.pending
            self.pending = []
            for (code, flags) in queued { self.key(code, flags) }
        }
    }

    private func elementKey(_ code: Int64, _ flags: CGEventFlags) {
        if loading {
            pending.append((code, flags))
            return
        }
        if code == Key.delete {
            if !typed.isEmpty {
                typed.removeLast()
                render()
            }
            return
        }
        if code == Key.tab {
            focusFirstInput()
            return
        }
        guard let ch = Key.letters[code] else { return }
        let next = typed + String(ch)
        let matches = targets.filter { $0.label.hasPrefix(next) }
        guard !matches.isEmpty else {
            NSSound.beep()
            return
        }
        guard matches.count == 1, matches[0].label == next else {
            typed = next
            render()
            return
        }

        let rect = matches[0].target.rect
        let point = CGPoint(x: rect.midX, y: rect.midY)
        let label = HintPlacement.center(for: rect)  // 노란 라벨이 있던 곳에서 포켓몬이 나온다
        exit()
        // ⌥ 옮기기만 · ⇧ 우클릭 · ⌘ ⌘-클릭 · 그 밖은 클릭
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            if flags.contains(.maskAlternate) {
                Mouse.move(point)
            } else if flags.contains(.maskShift) {
                Mouse.click(point, right: true, popAt: label)
            } else {
                Mouse.click(point, flags: flags.contains(.maskCommand) ? .maskCommand : [], popAt: label)
            }
        }
    }

    /// Vimium 의 gi — 가장 위(같은 줄이면 왼쪽)의 입력칸에 포커스. 웹 페이지 안의 입력칸이 있으면 그중에서 고른다
    /// (브라우저 주소창보다 페이지 먼저). AX 로 안 되면 클릭한다.
    private func focusFirstInput() {
        let all = targets.map(\.target).filter(\.isInput)
        let inPage = all.filter(\.inWebPage)
        let inputs = inPage.isEmpty ? all : inPage
        guard let first = inputs.min(by: { a, b in
            abs(a.rect.minY - b.rect.minY) > 4 ? a.rect.minY < b.rect.minY : a.rect.minX < b.rect.minX
        }) else {
            NSSound.beep()
            return
        }
        exit()
        if let element = first.element,
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        {
            return
        }
        Mouse.click(CGPoint(x: first.rect.midX, y: first.rect.midY))
    }

    // MARK: 격자 모드

    /// 커서가 있는 화면을 26×26 이하의 칸으로 — 라벨 = 줄 글자 + 칸 글자.
    private func buildGrid() {
        let screens = Screens.all
        guard !screens.isEmpty else { return }
        gridScreen = min(gridScreen, screens.count - 1)
        let f = screens[gridScreen]
        let alphabet = Labels.gridAlphabet
        let side = max(56, f.width / CGFloat(alphabet.count), f.height / CGFloat(alphabet.count))
        let cols = min(alphabet.count, Int((f.width / side).rounded(.up)))
        let rows = min(alphabet.count, Int((f.height / side).rounded(.up)))
        cellSize = CGSize(width: f.width / CGFloat(cols), height: f.height / CGFloat(rows))
        cells = []
        for r in 0..<rows {
            for c in 0..<cols {
                let rect = CGRect(
                    x: f.minX + CGFloat(c) * cellSize.width, y: f.minY + CGFloat(r) * cellSize.height,
                    width: cellSize.width, height: cellSize.height)
                cells.append((label: String([alphabet[r], alphabet[c]]), rect: rect))
            }
        }
    }

    private func gridKey(_ code: Int64, _ flags: CGEventFlags) {
        if code == Key.delete {
            if !typed.isEmpty {
                typed.removeLast()
                render()
            }
            return
        }
        if code == Key.tab {
            gridScreen = (gridScreen + 1) % max(1, Screens.all.count)
            typed = ""
            buildGrid()
            let f = Screens.all[gridScreen]
            cursor = CGPoint(x: f.midX, y: f.midY)
            Mouse.move(cursor)
            render()
            return
        }
        if let ch = Key.letters[code] {
            let next = typed + String(ch)
            let matches = cells.filter { $0.label.hasPrefix(next) }
            guard !matches.isEmpty else {
                NSSound.beep()
                return
            }
            if matches.count == 1, matches[0].label == next {
                let r = matches[0].rect
                cursor = CGPoint(x: r.midX, y: r.midY)
                // 칸을 고르면 바로 클릭하고 끝낸다. ⇧ 로 마지막 글자를 치면 옮기기만 하고 남아 방향키로 다듬는다.
                if !flags.contains(.maskShift), !Mouse.dragging {
                    let point = cursor
                    exit()
                    Mouse.click(point, flags: flags.contains(.maskCommand) ? .maskCommand : [])
                    return
                }
                Mouse.move(cursor)
                typed = ""
            } else {
                typed = next
            }
            render()
            return
        }
        _ = pointerKey(code, flags, vim: false)
    }

    // MARK: 격자 · 자유 이동 공통

    /// 방향키(자유 이동은 hjkl 도)로 커서 이동 · ⇧ 스크롤 · ⌥ 크게 · ⌘ 화면 끝. ↵ 클릭 · ⇧↵ 더블 · ] 우클릭 · = 드래그.
    private func pointerKey(_ code: Int64, _ flags: CGEventFlags, vim: Bool) -> Bool {
        var dir: CGVector?
        switch code {
        case Key.left: dir = CGVector(dx: -1, dy: 0)
        case Key.right: dir = CGVector(dx: 1, dy: 0)
        case Key.up: dir = CGVector(dx: 0, dy: -1)
        case Key.down: dir = CGVector(dx: 0, dy: 1)
        default:
            if vim {
                switch Key.letters[code] {
                case "h": dir = CGVector(dx: -1, dy: 0)
                case "l": dir = CGVector(dx: 1, dy: 0)
                case "k": dir = CGVector(dx: 0, dy: -1)
                case "j": dir = CGVector(dx: 0, dy: 1)
                default: break
                }
            }
        }

        if let d = dir {
            if flags.contains(.maskShift) {
                Mouse.scroll(dx: Int32(-d.dx * 80), dy: Int32(-d.dy * 80))
                return true
            }
            let screen = Screens.frame(containing: cursor)
            if flags.contains(.maskCommand) {
                if d.dx < 0 { cursor.x = screen.minX + 2 }
                if d.dx > 0 { cursor.x = screen.maxX - 2 }
                if d.dy < 0 { cursor.y = screen.minY + 2 }
                if d.dy > 0 { cursor.y = screen.maxY - 2 }
            } else {
                let big = mode == .grid ? max(cellSize.width, cellSize.height) : 80
                let step: CGFloat = flags.contains(.maskAlternate) ? big : 10
                cursor = CGPoint(x: cursor.x + d.dx * step, y: cursor.y + d.dy * step)
            }
            cursor = Screens.clamp(cursor)
            Mouse.move(cursor)
            render()
            return true
        }

        switch code {
        case Key.returnKey:
            let point = cursor
            if Mouse.dragging {
                Mouse.release(point)
                exit()
                return true
            }
            exit()
            Mouse.click(
                point, double: flags.contains(.maskShift), flags: flags.contains(.maskCommand) ? .maskCommand : [])
            return true
        case Key.rightBracket:
            let point = cursor
            exit()
            Mouse.click(point, right: true)
            return true
        case Key.equal:
            if !Mouse.dragging { Mouse.press(cursor) }
            render()
            return true
        default:
            return false
        }
    }

    // MARK: 스크롤 모드

    /// 커서가 앞 창 밖에 있으면 창 가운데로 — 스크롤은 커서 아래의 뷰로 간다.
    private func moveIntoFocusedWindow() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
            let window = value, CFGetTypeID(window) == AXUIElementGetTypeID(),
            let frame = AXCollector.frame(of: window as! AXUIElement)
        else { return }
        if !frame.contains(Mouse.location) {
            Mouse.move(CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    /// j/k ↓↑ 조금 · d/u 반 쪽 · space 한 쪽(⇧ 위로) · g 맨 위 · ⇧G 맨 아래 · h/l ←→ · ↵ 끝내기
    private func scrollKey(_ code: Int64, _ flags: CGEventFlags) {
        let shift = flags.contains(.maskShift)
        switch (code, Key.letters[code]) {
        case (Key.down, _), (_, "j"): Mouse.scroll(dx: 0, dy: -70)
        case (Key.up, _), (_, "k"): Mouse.scroll(dx: 0, dy: 70)
        case (Key.left, _), (_, "h"): Mouse.scroll(dx: 70, dy: 0)
        case (Key.right, _), (_, "l"): Mouse.scroll(dx: -70, dy: 0)
        case (_, "d"): Mouse.scroll(dx: 0, dy: -400)
        case (_, "u"): Mouse.scroll(dx: 0, dy: 400)
        case (Key.space, _): Mouse.scroll(dx: 0, dy: shift ? 800 : -800)
        case (_, "g"): Mouse.scroll(dx: 0, dy: shift ? -1_000_000 : 1_000_000)
        case (Key.returnKey, _): exit()
        default: break
        }
    }
}
