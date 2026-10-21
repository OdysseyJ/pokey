import AppKit
import ApplicationServices

/// 누를 수 있는 요소 하나. 입력칸이면 `isInput` — 요소 모드의 Tab(첫 입력칸에 포커스)이 쓴다.
/// `inWebPage` 는 웹 페이지(AXWebArea) 안의 것 — 브라우저 주소창보다 페이지의 입력칸을 먼저 고르려고.
struct Target {
    let rect: CGRect
    let element: AXUIElement?
    let isInput: Bool
    var inWebPage = false
}

/// 앞에 있는 앱의 창 · 그 앱의 메뉴바 · 오른쪽 상태 아이콘에서 누를 수 있는 요소의 위치를 모은다.
final class AXCollector {
    static let shared = AXCollector()

    private let queue = DispatchQueue(label: "pokey.ax", qos: .userInteractive)
    private let lock = NSLock()
    /// 상태 아이콘(AXExtrasMenuBar)을 가진 프로세스. 누를 때마다 모든 프로세스를 묻기엔 느려서 미리 찾아 둔다.
    private var extrasPids: [pid_t] = []
    /// 화면 구조를 켜 준 프로세스. Electron 은 켜도 그 값을 0 으로 읽어 줘서 우리가 기억한다.
    private var enabledPids = Set<pid_t>()

    private static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXMenuBarItem", "AXMenuItem", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
        "AXDisclosureTriangle", "AXSlider", "AXIncrementor", "AXTab", "AXRow", "AXDockItem",
    ]
    /// 이 역할 안쪽은 더 들어가지 않는다(버튼 속 글자·아이콘에 힌트가 겹치지 않게).
    private static let leafRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSlider", "AXIncrementor",
        "AXDisclosureTriangle", "AXRow", "AXMenuBarItem",
    ]
    /// 역할만으로는 모르지만 AXPress 동작이 있으면 누를 수 있는 것(웹의 클릭 가능한 div 등).
    private static let inputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
    private static let pressCheckRoles: Set<String> = ["AXGroup", "AXImage", "AXCell"]

    private static let chromiumBundles: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
    ]

    private static let nodeLimit = 8000
    private static let timeBudget: TimeInterval = 1.2

    // MARK: 상태 아이콘 프로세스 캐시

    func refreshExtras() {
        let own = ProcessInfo.processInfo.processIdentifier
        let pids = NSWorkspace.shared.runningApplications.map(\.processIdentifier).filter { $0 != own }
        DispatchQueue.global(qos: .utility).async {
            var found: [pid_t] = []
            let foundLock = NSLock()
            DispatchQueue.concurrentPerform(iterations: pids.count) { i in
                let app = AXUIElementCreateApplication(pids[i])
                AXUIElementSetMessagingTimeout(app, 0.2)
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &value) == .success {
                    foundLock.lock()
                    found.append(pids[i])
                    foundLock.unlock()
                }
            }
            self.lock.lock()
            self.extrasPids = found
            self.lock.unlock()
        }
    }

    // MARK: 수집

    func collect(pid: pid_t, bundleID: String?, screens: [CGRect], completion: @escaping ([Target]) -> Void) {
        lock.lock()
        let extras = extrasPids
        lock.unlock()
        queue.async {
            // 처음 켠 거면 Electron 이 구조를 만드는 동안 잠깐 기다린다(안 그러면 첫 ⌃D 에 거의 안 잡힌다).
            if self.enable(pid: pid, bundleID: bundleID) { Thread.sleep(forTimeInterval: 0.35) }
            let targets = Self.gather(pid: pid, bundleID: bundleID, screens: screens, extrasPids: extras)
            DispatchQueue.main.async { completion(targets) }
        }
    }

    private static func gather(pid: pid_t, bundleID: String?, screens: [CGRect], extrasPids: [pid_t]) -> [Target] {
        let union = screens.reduce(CGRect.null) { $0.union($1) }
        let deadline = Date().addingTimeInterval(timeBudget)
        var out: [Target] = []
        var visited = 0

        // 메뉴가 열려 있으면 그 메뉴 항목만 — 메뉴 밖을 누르면 메뉴가 닫히니 다른 데는 의미가 없다.
        let menuItems = openMenuItems()
        if !menuItems.isEmpty { return menuItems }

        let app = AXUIElementCreateApplication(pid)

        // 창: 앞의 창에 가린 뒤 창의 요소는 뺀다.
        var occluders: [CGRect] = []
        let windows: [AXUIElement] = copy(app, kAXWindowsAttribute) ?? []
        for window in windows {
            if (copy(window, kAXMinimizedAttribute) as Bool?) == true { continue }
            guard let frame = frame(of: window) else { continue }
            let clip = frame.intersection(union)
            guard !clip.isNull, clip.width > 0, clip.height > 0 else { continue }
            walk(window, clip: clip, occluders: occluders, out: &out, visited: &visited, deadline: deadline)
            occluders.append(frame)
        }

        // 앞 앱의 메뉴바(애플 메뉴 · 파일 · 편집 …).
        if let menuBar: AXUIElement = copy(app, kAXMenuBarAttribute) {
            for item in (copy(menuBar, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                if let f = frame(of: item), f.width > 1, f.intersects(union) {
                    out.append(Target(rect: f, element: item, isInput: false))
                }
            }
        }

        // 오른쪽 상태 아이콘(와이파이 · 배터리 · 앱 아이콘 …).
        for extrasPid in extrasPids {
            let owner = AXUIElementCreateApplication(extrasPid)
            AXUIElementSetMessagingTimeout(owner, 0.1)
            guard let bar: AXUIElement = copy(owner, "AXExtrasMenuBar") else { continue }
            for item in (copy(bar, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                if let f = frame(of: item), f.width > 1, f.intersects(union) {
                    out.append(Target(rect: f, element: item, isInput: false))
                }
            }
        }

        return dedupe(out)
    }

    private static func walk(
        _ root: AXUIElement, clip: CGRect, occluders: [CGRect], out: inout [Target], visited: inout Int, deadline: Date
    ) {
        var stack: [(element: AXUIElement, inWeb: Bool)] = [(root, false)]
        let names = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute] as CFArray
        while let (element, inWeb) = stack.popLast() {
            visited += 1
            if visited > nodeLimit || Date() > deadline { return }

            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names, [], &raw) == .success,
                let values = raw as? [AnyObject], values.count == 4
            else { continue }
            let role = values[0] as? String ?? ""
            let frame: CGRect? = {
                guard let p = point(values[1]), let s = size(values[2]) else { return nil }
                return CGRect(origin: p, size: s)
            }()

            // 크기를 아는데 보이는 칸 밖이면 그 아래도 볼 필요 없다(크기 0인 묶음은 자식이 있을 수 있어 둔다).
            if let f = frame, f.width > 0, f.height > 0, !f.intersects(clip) { continue }

            if let f = frame, f.width >= 4, f.height >= 4 {
                let isTarget =
                    clickableRoles.contains(role) || (pressCheckRoles.contains(role) && hasPress(element))
                if isTarget {
                    let visible = f.intersection(clip)
                    let center = CGPoint(x: visible.midX, y: visible.midY)
                    if !visible.isNull, !occluders.contains(where: { $0.contains(center) }) {
                        out.append(
                            Target(
                                rect: visible, element: element, isInput: inputRoles.contains(role), inWebPage: inWeb))
                    }
                }
            }

            if leafRoles.contains(role) { continue }
            var children = values[3] as? [AXUIElement] ?? []
            // 목록·표는 접힌 섹션 줄 안에 줄이 또 들어 있다(슬랙 사이드바의 채널). 줄 안쪽은 안 들어가므로
            // 보이는 줄 전체(AXVisibleRows)를 따로 받아 함께 본다. 겹치는 줄은 dedupe 가 걸러 낸다.
            if role == "AXOutline" || role == "AXTable", let rows: [AXUIElement] = copy(element, kAXVisibleRowsAttribute) {
                children += rows
            }
            let childInWeb = inWeb || role == "AXWebArea"
            stack.append(contentsOf: children.reversed().map { ($0, childInWeb) })
        }
    }

    /// 화면에 떠 있는 메뉴(메뉴바·상태 아이콘·우클릭 메뉴 — 어느 앱 것이든)의 항목. 메뉴 창을 창 목록에서 찾고,
    /// 그 안의 한 점에서 AX 로 메뉴를 집어 항목을 읽는다. 구분선(얇은 항목)과 꺼진 항목은 뺀다.
    private static func openMenuItems() -> [Target] {
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var out: [Target] = []
        for window in windows where (window[kCGWindowLayer as String] as? Int) == menuLevel {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.width > 20, bounds.height > 20
            else { continue }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.3)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(bounds.midX), Float(bounds.midY), &hit) == .success,
                var element = hit
            else { continue }
            var menu: AXUIElement?
            for _ in 0..<6 {
                if (copy(element, kAXRoleAttribute) as String?) == "AXMenu" {
                    menu = element
                    break
                }
                guard let parent: AXUIElement = copy(element, kAXParentAttribute) else { break }
                element = parent
            }
            guard let menu else { continue }
            for item in (copy(menu, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                guard let f = frame(of: item), f.height >= 16, bounds.intersects(f),
                    (copy(item, kAXEnabledAttribute) as Bool?) != false
                else { continue }
                out.append(Target(rect: f, element: item, isInput: false))
            }
        }
        return out
    }

    /// 중심이 거의 같은 것은 하나만(바깥 것이 먼저 들어온다).
    private static func dedupe(_ targets: [Target]) -> [Target] {
        var kept: [Target] = []
        for t in targets {
            let c = CGPoint(x: t.rect.midX, y: t.rect.midY)
            if !kept.contains(where: { abs($0.rect.midX - c.x) < 6 && abs($0.rect.midY - c.y) < 6 }) {
                kept.append(t)
            }
        }
        return kept
    }

    // MARK: Electron · 크로미움

    /// Electron(슬랙 등)·크로미움은 이걸 켜야 화면 구조를 내놓는다. 이번에 처음 켰으면 true.
    @discardableResult
    private func enable(pid: pid_t, bundleID: String?) -> Bool {
        lock.lock()
        let isNew = enabledPids.insert(pid).inserted
        lock.unlock()
        guard isNew else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let bundleID, Self.chromiumBundles.contains(bundleID) {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        return true
    }

    /// 앱이 앞으로 오면 미리 켜 둔다 — 단축키를 누를 때쯤엔 구조가 만들어져 있게.
    func prepare(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier
        queue.async { self.enable(pid: pid, bundleID: bundleID) }
    }

    // MARK: 위치로 찾기

    /// 화면 위치의 요소. 앞 앱 안에서 먼저 찾고(우리 오버레이 창이 맨 위라 시스템 전체로 찾으면 그게 걸린다),
    /// 없으면 시스템 전체에서 — 단 우리 앱 것이면 버린다.
    static func element(at p: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(p.x), Float(p.y), &hit) == .success,
            let hit
        {
            return hit
        }
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success,
            let hit
        else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        return pid == ProcessInfo.processInfo.processIdentifier ? nil : hit
    }

    /// p 의 요소에서 위로 올라가며 처음 만나는, 조건에 맞는 요소의 위치.
    static func ancestorFrame(at p: CGPoint, levels: Int, where match: (AXUIElement, String) -> Bool) -> CGRect? {
        guard var element = element(at: p) else { return nil }
        for _ in 0..<levels {
            let role: String = copy(element, kAXRoleAttribute) ?? ""
            if match(element, role), let frame = frame(of: element) { return frame }
            guard let parent: AXUIElement = copy(element, kAXParentAttribute) else { return nil }
            element = parent
        }
        return nil
    }

    /// 지금 클릭하면 눌릴 요소(버튼·링크 등). 화면을 거의 덮는 것(터미널 본문 등)은 표시할 뜻이 없어 뺀다.
    static func clickTarget(at p: CGPoint) -> CGRect? {
        let frame = ancestorFrame(at: p, levels: 8) { element, role in
            clickableRoles.contains(role) || (pressCheckRoles.contains(role) && hasPress(element))
        }
        guard let frame, frame.width >= 4, frame.height >= 4, !(frame.width > 600 && frame.height > 400) else {
            return nil
        }
        return frame
    }

    /// 스크롤하면 움직일 영역.
    static func scrollArea(at p: CGPoint) -> CGRect? {
        ancestorFrame(at: p, levels: 40) { _, role in role == "AXScrollArea" }
    }

    // MARK: AX 도우미

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var p: CFTypeRef?
        var s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success,
            let origin = point(p), let size = size(s)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func axValue(_ v: AnyObject?, _ type: AXValueType) -> AXValue? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let value = v as! AXValue
        return AXValueGetType(value) == type ? value : nil
    }

    private static func point(_ v: AnyObject?) -> CGPoint? {
        guard let value = axValue(v, .cgPoint) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &p) ? p : nil
    }

    private static func size(_ v: AnyObject?) -> CGSize? {
        guard let value = axValue(v, .cgSize) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(value, .cgSize, &s) ? s : nil
    }

    private static func hasPress(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else {
            return false
        }
        return list.contains(kAXPressAction)
    }
}
