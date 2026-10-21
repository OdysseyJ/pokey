import AppKit
import SwiftUI

/// README 스크린샷: `Pokey --shot <bundle id> <out dir>`.
/// 그 앱의 가장 큰 창을 캡처한 그림(<out dir>/base.png, 다른 창에 가려도 상관없다) 위에 각 모드 화면을 합성한다.
/// 화면에 아무것도 띄우지 않고 키도 보내지 않는다. 앱 번들 안의 실행 파일로 돌려야 도감 기록을 읽는다.
enum Shot {
    static func run(bundle: String, outDir: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            print("not running: \(bundle)")
            exit(1)
        }
        // 다른 데스크톱에 있어도 찾는다(캡처는 미리 해 둔 base.png 를 쓴다).
        let windows = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter {
                ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                    && ($0[kCGWindowLayer as String] as? Int) == 0
            }
            .compactMap { w -> (id: Int, bounds: CGRect)? in
                guard let id = w[kCGWindowNumber as String] as? Int,
                    let dict = w[kCGWindowBounds as String] as? NSDictionary,
                    let bounds = CGRect(dictionaryRepresentation: dict)
                else { return nil }
                return (id, bounds)
            }
        guard let window = windows.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        else {
            print("no window")
            exit(1)
        }
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        // 창 캡처는 화면 기록 권한이 있는 쪽(터미널)에서 미리 해 둔다: screencapture -x -o -l<창 번호> <outDir>/base.png
        let basePath = (outDir as NSString).appendingPathComponent("base.png")
        guard let base = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: basePath))) ?? Data())
        else {
            print("window \(window.id) — capture it first: screencapture -x -o -l\(window.id) \(basePath)")
            exit(2)
        }
        let region = window.bounds

        func save(_ name: String, _ model: OverlayModel, crop: CGRect? = nil, extra: ((CGRect) -> Void)? = nil) {
            compose(
                base: base, region: region, model: model, crop: crop, extra: extra,
                path: (outDir as NSString).appendingPathComponent("\(name).png"))
        }

        AXCollector.shared.collect(pid: app.processIdentifier, bundleID: bundle, screens: Screens.all) { targets in
            let inside = targets.filter { region.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
            let model = OverlayModel()

            model.hints = zip(Labels.make(inside.count), inside).map { (label: $0.0, rect: $0.1.rect) }
            save("element", model)

            model.clear()
            model.gridCells = Controller.gridCells(in: region)
            save("grid", model)

            // 자유 이동: 창 가운데쯤의 작은 요소(링크 등)를 가리킨 모습.
            let center = CGPoint(x: region.midX, y: region.midY)
            let small = inside.filter { $0.rect.width < 300 && $0.rect.height < 60 }
            if let target = small.min(by: { distance($0.rect, center) < distance($1.rect, center) }) {
                model.clear()
                model.cursor = CGPoint(x: target.rect.midX, y: target.rect.midY)
                model.area = target.rect
                model.fillArea = true
                let zoom = target.rect.insetBy(dx: -260, dy: -130)
                save("free", model, crop: zoom)

                // 포켓몬: 그 요소의 라벨 자리에서 솟아오른 모습.
                let spot = HintPlacement.center(for: target.rect)
                if let sprite = NSImage(contentsOf: cacheFile(25)) {
                    model.clear()
                    save("pokemon", model, crop: CGRect(x: spot.x - 260, y: spot.y - 170, width: 520, height: 260)) { _ in
                        let p = CGPoint(x: spot.x - region.minX, y: region.height - (spot.y - region.minY))
                        let size: CGFloat = 96
                        NSGraphicsContext.current?.imageInterpolation = .none
                        sprite.draw(in: CGRect(x: p.x - size / 2, y: p.y - 18, width: size, height: size))
                        drawTag("NEW!", above: CGPoint(x: p.x, y: p.y - 18 + size))
                    }
                }
            }

            if let area = largestScrollArea(pid: app.processIdentifier, in: region) {
                model.clear()
                model.area = area
                save("scroll", model)
            }

            MainActor.assumeIsolated { saveDex(to: (outDir as NSString).appendingPathComponent("pokedex.png")) }
            exit(0)
        }
        RunLoop.main.run()
    }

    /// base(region 을 캡처한 그림) 위에 model 의 오버레이를 그려 path 에 저장한다. crop 은 region 안의 일부(CG 좌표).
    private static func compose(
        base: NSBitmapImageRep, region: CGRect, model: OverlayModel, crop: CGRect?, extra: ((CGRect) -> Void)?,
        path: String
    ) {
        let overlay = Overlay.render(model, region: region, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh)
        let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0)!
        out.size = region.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        let rect = CGRect(origin: .zero, size: region.size)
        let cg = NSGraphicsContext.current!.cgContext
        if let image = base.cgImage { cg.draw(image, in: rect) }
        if let image = overlay.cgImage { cg.draw(image, in: rect) }
        extra?(rect)
        NSGraphicsContext.restoreGraphicsState()
        var final = out
        if let crop, let image = out.cgImage {
            let scale = CGFloat(base.pixelsWide) / region.width
            let local = crop.offsetBy(dx: -region.minX, dy: -region.minY).intersection(CGRect(origin: .zero, size: region.size))
            let pixels = CGRect(
                x: local.minX * scale, y: local.minY * scale, width: local.width * scale, height: local.height * scale)
            if let cut = image.cropping(to: pixels.integral) { final = NSBitmapImageRep(cgImage: cut) }
        }
        try? final.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print(path)
    }

    /// 메뉴바 띠: `Pokey --shot-menubar <out dir>` — 앞 앱의 메뉴와 오른쪽 상태 아이콘에 라벨이 붙은 모습.
    /// 처음엔 캡처할 띠(x,y,w,h)를 알려 주고 끝난다: screencapture -x -R<x,y,w,h> <out dir>/menubar-base.png
    static func menuBar(outDir: String) {
        let front = NSWorkspace.shared.frontmostApplication
        AXCollector.shared.refreshExtras()
        Thread.sleep(forTimeInterval: 1.5)
        AXCollector.shared.collect(
            pid: front?.processIdentifier ?? 0, bundleID: front?.bundleIdentifier, screens: Screens.all
        ) { targets in
            let items = targets.filter { t in
                let top = Screens.frame(containing: CGPoint(x: t.rect.midX, y: t.rect.midY)).minY
                return t.rect.minY <= top + 6 && t.rect.height <= 34
            }
            // 메뉴 항목이 가장 많이 걸친 화면(메뉴바가 활성인 화면).
            var screens = Screens.all
            // SCREEN=<번호> 로 화면을 고를 수 있다(상태 아이콘은 주 화면 위치로 잡히곤 한다).
            if let i = Int(ProcessInfo.processInfo.environment["SCREEN"] ?? ""), screens.indices.contains(i) {
                screens = [screens[i]]
            }
            guard
                let screen = screens.max(by: { a, b in
                    items.filter { a.intersects($0.rect) }.count < items.filter { b.intersects($0.rect) }.count
                }), !items.isEmpty
            else {
                print("no menu bar items")
                exit(1)
            }
            let region = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: 58)
            let basePath = (outDir as NSString).appendingPathComponent("menubar-base.png")
            guard let base = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: basePath))) ?? Data())
            else {
                print("strip \(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))")
                exit(2)
            }
            let model = OverlayModel()
            let onScreen = items.filter { region.intersects($0.rect) }
            model.hints = zip(Labels.make(onScreen.count), onScreen).map { (label: $0.0, rect: $0.1.rect) }
            compose(
                base: base, region: region, model: model, crop: nil, extra: nil,
                path: (outDir as NSString).appendingPathComponent("menubar.png"))
            exit(0)
        }
        RunLoop.main.run()
    }

    private static func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat { hypot(r.midX - p.x, r.midY - p.y) }

    private static func cacheFile(_ id: Int) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pokey/\(id).png")
    }

    private static func drawTag(_ text: String, above p: CGPoint) {
        let label = NSAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .heavy), .foregroundColor: NSColor.white])
        let size = label.size()
        let box = CGRect(x: p.x - size.width / 2 - 5, y: p.y - 14, width: size.width + 10, height: 14)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        label.draw(at: CGPoint(x: box.minX + 5, y: box.minY + (14 - size.height) / 2))
    }

    /// 창 안에서 가장 큰 스크롤 영역(웹 페이지 본문 등).
    private static func largestScrollArea(pid: pid_t, in region: CGRect) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        var stack = (windows as? [AXUIElement]) ?? []
        var best: CGRect?
        var visited = 0
        while let element = stack.popLast(), visited < 4000 {
            visited += 1
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if (role as? String) == "AXScrollArea", let f = AXCollector.frame(of: element), region.intersects(f) {
                let visible = f.intersection(region)
                if visible.width * visible.height > (best.map { $0.width * $0.height } ?? 0) { best = visible }
                continue
            }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            stack.append(contentsOf: (children as? [AXUIElement]) ?? [])
        }
        return best
    }

    /// 도감 창 모습 — ImageRenderer 는 스크롤 목록·팝업 메뉴를 못 그려서 같은 칸(DexCell)으로 정적으로 짠다.
    @MainActor private static func saveDex(to path: String) {
        let dex = Pokedex.shared
        let gen = Pokedex.generations[0]
        let ids = Array(gen.range.prefix(40))
        let view = VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Pokédex", "포켓몬 도감")).font(.title2.bold())
                Text(gen.title).foregroundStyle(.secondary)
                Spacer()
                Text("\(dex.seen(in: gen)) / \(gen.range.count)").font(.headline.monospacedDigit())
            }
            .padding(16)
            Divider()
            VStack(spacing: 8) {
                ForEach(0..<5, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(ids[(row * 8)..<(row * 8 + 8)], id: \.self) { id in
                            DexCell(id: id, shiny: false, unseen: []).frame(width: 96)
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 860)
        .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
        print(path)
    }
}
