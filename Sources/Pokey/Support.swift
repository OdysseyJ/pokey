import AppKit

/// 키 코드(ANSI 배열 기준). 입력기보다 먼저 가로채므로 한글 입력 상태여도 같은 값이 온다.
enum Key {
    static let returnKey: Int64 = 36
    static let tab: Int64 = 48
    static let space: Int64 = 49
    static let delete: Int64 = 51
    static let escape: Int64 = 53
    static let left: Int64 = 123
    static let right: Int64 = 124
    static let down: Int64 = 125
    static let up: Int64 = 126
    static let rightBracket: Int64 = 30
    static let equal: Int64 = 24

    static let letters: [Int64: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 31: "o", 32: "u",
        34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
    ]

    private static let others: [Int64: String] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`", 42: "\\",
        49: "Space", 36: "↩", 48: "⇥",
    ]

    /// 단축키 표시용 키 이름.
    static func name(_ code: Int64) -> String? {
        if let ch = letters[code] { return String(ch).uppercased() }
        return others[code]
    }
}

enum Labels {
    /// 요소 힌트용 — 홈 줄 글자부터 쓴다.
    static let hintAlphabet = Array("asdfjklghqweruioptyzxcvbnm")
    /// 격자용 — 줄·칸을 알파벳 순서로 읽을 수 있게.
    static let gridAlphabet = Array("abcdefghijklmnopqrstuvwxyz")

    /// 같은 길이의 라벨 n개. 길이가 같아야 한 라벨이 다른 라벨의 앞부분이 되지 않는다.
    static func make(_ n: Int) -> [String] {
        guard n > 0 else { return [] }
        let k = hintAlphabet.count
        var length = 1
        var capacity = k
        while capacity < n {
            length += 1
            capacity *= k
        }
        var out: [String] = []
        out.reserveCapacity(n)
        var digits = Array(repeating: 0, count: length)
        for _ in 0..<n {
            out.append(String(digits.map { hintAlphabet[$0] }))
            var i = length - 1
            while i >= 0 {
                digits[i] += 1
                if digits[i] < k { break }
                digits[i] = 0
                i -= 1
            }
        }
        return out
    }
}

/// 좌표계: AX·CGEvent 는 주 화면 왼쪽 위가 원점(y 아래로), AppKit 은 왼쪽 아래가 원점. 앱 안에서는 전부 CG 좌표로 다룬다.
enum Screens {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func cgFrame(_ screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    static var all: [CGRect] { NSScreen.screens.map(cgFrame) }

    static func index(containing p: CGPoint) -> Int {
        all.firstIndex { $0.contains(p) } ?? 0
    }

    static func frame(containing p: CGPoint) -> CGRect {
        let frames = all
        return frames.first { $0.contains(p) } ?? frames.first ?? .zero
    }

    /// 가장 가까운 화면 안으로 끌어온다.
    static func clamp(_ p: CGPoint) -> CGPoint {
        let frames = all
        if frames.contains(where: { $0.contains(p) }) { return p }
        var best = p
        var bestDistance = CGFloat.infinity
        for f in frames {
            let q = CGPoint(x: min(max(p.x, f.minX), f.maxX - 1), y: min(max(p.y, f.minY), f.maxY - 1))
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < bestDistance {
                bestDistance = d
                best = q
            }
        }
        return best
    }
}

enum Mouse {
    /// 우리가 보낸 이벤트 표시 — 이벤트 탭이 자기 클릭을 사용자 클릭으로 오해하지 않게.
    static let tag: Int64 = 0x4843_4C4B
    private(set) static var dragging = false

    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private static func post(
        _ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton, clicks: Int64 = 1, flags: CGEventFlags = []
    ) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clicks)
        e.setIntegerValueField(.eventSourceUserData, value: tag)
        // 라벨을 치느라 누른 Shift 등이 클릭에 섞이지 않게 항상 명시한다.
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    static func move(_ p: CGPoint) {
        post(dragging ? .leftMouseDragged : .mouseMoved, p, .left)
    }

    /// popAt: 포켓몬이 튀어나올 곳(없으면 클릭한 곳).
    static func click(
        _ p: CGPoint, right: Bool = false, double: Bool = false, flags: CGEventFlags = [], popAt: CGPoint? = nil
    ) {
        move(p)
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        post(down, p, button, clicks: 1, flags: flags)
        post(up, p, button, clicks: 1, flags: flags)
        if double {
            post(down, p, button, clicks: 2, flags: flags)
            post(up, p, button, clicks: 2, flags: flags)
        }
        Pokedex.shared.clicked(at: popAt ?? p)
    }

    static func press(_ p: CGPoint) {
        post(.leftMouseDown, p, .left)
        dragging = true
    }

    static func release(_ p: CGPoint) {
        post(.leftMouseUp, p, .left)
        dragging = false
    }

    /// dy > 0 이면 위로, dx > 0 이면 왼쪽으로(내용이 오른쪽으로) 스크롤.
    static func scroll(dx: Int32, dy: Int32) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        else { return }
        e.setIntegerValueField(.eventSourceUserData, value: tag)
        e.post(tap: .cghidEventTap)
    }
}
