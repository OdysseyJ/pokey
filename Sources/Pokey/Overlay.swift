import AppKit

/// 오버레이가 그릴 것. 좌표는 모두 CG(주 화면 왼쪽 위 원점).
final class OverlayModel {
    var hints: [(label: String, rect: CGRect)] = []
    var gridCells: [(label: String, rect: CGRect)] = []
    var typed = ""
    /// 원을 그릴 커서 위치(자유 이동).
    var cursor: CGPoint?
    /// 테두리를 그릴 영역 — 스크롤 모드는 스크롤될 곳, 자유 이동·격자는 지금 클릭하면 눌릴 요소.
    var area: CGRect?
    /// 영역 안을 옅게 칠할지 — 클릭될 요소만. 스크롤 영역은 가장자리만.
    var fillArea = false
    /// 드래그 중이면 원을 점선으로.
    var dragging = false

    func clear() {
        hints = []
        gridCells = []
        typed = ""
        cursor = nil
        area = nil
        fillArea = false
        dragging = false
    }
}

/// 힌트 라벨 자리. 라벨이 요소를 덮지 않게 — 메뉴바는 메뉴바 아래로, 작은 것은 왼쪽 위 모서리에 걸치게,
/// 넓은 것(줄·입력칸)은 왼쪽 끝 안쪽(보통 여백·아이콘 자리)에. centered 가 아니면 anchor 는 라벨의 왼쪽 끝.
enum HintPlacement {
    static func anchor(for r: CGRect, screenTop: CGFloat) -> (anchor: CGPoint, centered: Bool) {
        if r.minY <= screenTop + 2, r.height <= 34 { return (CGPoint(x: r.midX, y: r.maxY + 9), true) }
        if r.width <= 60, r.height <= 60 { return (CGPoint(x: r.minX + 2, y: r.minY + 2), true) }
        return (CGPoint(x: r.minX + 2, y: r.midY), false)
    }

    /// 라벨 가운데쯤(CG 좌표) — 포켓몬이 여기서 튀어나온다.
    static func center(for r: CGRect) -> CGPoint {
        let top = Screens.frame(containing: CGPoint(x: r.midX, y: r.midY)).minY
        let (anchor, centered) = anchor(for: r, screenTop: top)
        return centered ? anchor : CGPoint(x: anchor.x + 12, y: anchor.y)
    }
}

/// 화면마다 하나씩, 메뉴바보다 위에 뜨는 투명 창. 마우스는 통과시키고 포커스도 가져가지 않는다.
final class Overlay {
    let model = OverlayModel()
    private var windows: [NSWindow] = []

    init() {
        rebuild()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() }
    }

    private func rebuild() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(
                contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            // 창이 나타날 때 시스템 기본 애니메이션(옆에서 미끄러지듯 나옴) 없이 바로.
            window.animationBehavior = .none
            window.contentView = OverlayView(model: model, size: screen.frame.size) { Screens.cgFrame(screen) }
            return window
        }
    }

    func show() {
        for window in windows {
            window.contentView?.needsDisplay = true
            window.orderFrontRegardless()
        }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
    }
}

extension Overlay {
    /// 화면에 띄우지 않고 region(CG 좌표) 영역의 오버레이만 그림으로 — README 스크린샷용.
    static func render(_ model: OverlayModel, region: CGRect, pixelsWide: Int, pixelsHigh: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = region.size
        let view = OverlayView(model: model, size: region.size) { region }
        NSGraphicsContext.saveGraphicsState()
        // rep.size 를 region 크기로 두었으니 컨텍스트는 이미 점 단위다 — 뒤집기만 한다.
        let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        cg.translateBy(x: 0, y: region.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

private final class OverlayView: NSView {
    private let model: OverlayModel
    /// 이 뷰가 덮는 영역(CG 좌표) — 화면이면 그 화면, 스크린샷이면 그 창.
    private let region: () -> CGRect

    init(model: OverlayModel, size: CGSize, region: @escaping () -> CGRect) {
        self.model = model
        self.region = region
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static let hintFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
    private static let gridFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
    private static let hintFill = NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.3, alpha: 0.97)
    private static let hintStroke = NSColor(calibratedRed: 0.72, green: 0.55, blue: 0.05, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        let origin = region().origin
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - origin.x, y: p.y - origin.y) }
        func local(_ r: CGRect) -> CGRect { CGRect(origin: local(r.origin), size: r.size) }

        drawGrid(local)
        drawHints(local)
        // 색은 하나 — 시스템 강조색(시스템 설정 → 모양)을 따른다.
        if let area = model.area { drawArea(local(area), color: .controlAccentColor) }
        if let cursor = model.cursor { drawRing(at: local(cursor), color: .controlAccentColor) }
    }

    private func drawHints(_ local: (CGRect) -> CGRect) {
        let typed = model.typed
        for hint in model.hints where hint.label.hasPrefix(typed) {
            let r = local(hint.rect)
            guard bounds.intersects(r) else { continue }
            let (anchor, centered) = HintPlacement.anchor(for: r, screenTop: bounds.minY)
            drawTag(
                hint.label.uppercased(), typedCount: typed.count, anchor: anchor, centered: centered,
                font: Self.hintFont, fill: Self.hintFill, stroke: Self.hintStroke)
        }
    }

    private func drawGrid(_ local: (CGRect) -> CGRect) {
        let cells = model.gridCells.map { (label: $0.label, rect: local($0.rect)) }.filter { bounds.intersects($0.rect) }
        guard !cells.isEmpty else { return }

        NSColor.black.withAlphaComponent(0.08).setFill()
        bounds.fill()
        let lines = NSBezierPath()
        for cell in cells { lines.appendRect(cell.rect) }
        // 다른 모드와 같은 시스템 강조색.
        let accent = NSColor.controlAccentColor
        lines.lineWidth = 0.5
        accent.withAlphaComponent(0.45).setStroke()
        lines.stroke()

        let typed = model.typed
        for cell in cells where cell.label.hasPrefix(typed) {
            drawTag(
                cell.label.uppercased(), typedCount: typed.count, anchor: CGPoint(x: cell.rect.midX, y: cell.rect.midY),
                centered: true, font: Self.gridFont, fill: accent.withAlphaComponent(0.85),
                stroke: nil, text: .white)
        }
    }

    /// 커서 둘레의 원. 드래그 중이면 점선.
    private func drawRing(at p: CGPoint, color: NSColor) {
        guard bounds.contains(p) else { return }
        let ring = NSBezierPath(ovalIn: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22))
        ring.lineWidth = 2.5
        if model.dragging { ring.setLineDash([4, 3], count: 2, phase: 0) }
        color.setStroke()
        ring.stroke()
    }

    /// 스크롤될 영역 테두리.
    private func drawArea(_ r: CGRect, color: NSColor) {
        guard bounds.intersects(r) else { return }
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
        if model.fillArea {
            color.withAlphaComponent(0.06).setFill()
            path.fill()
        }
        path.lineWidth = 2.5
        color.setStroke()
        path.stroke()
    }

    private func drawTag(
        _ text: String, typedCount: Int, anchor: CGPoint, centered: Bool, font: NSFont, fill: NSColor,
        stroke: NSColor?, text textColor: NSColor = .black
    ) {
        let attributed = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: textColor])
        if typedCount > 0 {
            attributed.addAttribute(
                .foregroundColor, value: textColor.withAlphaComponent(0.35),
                range: NSRange(location: 0, length: min(typedCount, text.count)))
        }
        let size = attributed.size()
        var box = CGRect(x: 0, y: 0, width: size.width + 8, height: size.height + 2)
        box.origin = centered
            ? CGPoint(x: anchor.x - box.width / 2, y: anchor.y - box.height / 2)
            : CGPoint(x: anchor.x, y: anchor.y - box.height / 2)
        box.origin.x = min(max(box.minX, bounds.minX + 1), bounds.maxX - box.width - 1)
        box.origin.y = min(max(box.minY, bounds.minY + 1), bounds.maxY - box.height - 1)

        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        fill.setFill()
        path.fill()
        if let stroke {
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        attributed.draw(at: CGPoint(x: box.minX + 4, y: box.minY + 1))
    }
}
