import AppKit
import SwiftUI

/// 세대별 포켓몬 도감(지금은 3세대까지). 클릭하면 가끔 지금 정복 중인 세대의 포켓몬이 튀어나오고(1/64 로 이로치),
/// 포켓몬마다 만난 횟수를 남긴다. 한 세대를 다 만나면 다음 세대가 열린다.
/// 그림·이름은 PokéAPI 에서 처음 한 번 받아 ~/Library/Caches/Pokey 과 UserDefaults 에만 둔다(저장소엔 안 올라간다).
final class Pokedex: ObservableObject {
    static let shared = Pokedex()
    static let didChange = Notification.Name("PokeyPokedexDidChange")

    struct Generation: Hashable {
        let number: Int
        let region: (en: String, ko: String)
        let range: ClosedRange<Int>
        var title: String { L("Gen \(number) \(region.en)", "\(number)세대 \(region.ko)") }
        static func == (a: Generation, b: Generation) -> Bool { a.number == b.number }
        func hash(into hasher: inout Hasher) { hasher.combine(number) }
    }

    static let generations = [
        Generation(number: 1, region: ("Kanto", "관동"), range: 1...151),
        Generation(number: 2, region: ("Johto", "성도"), range: 152...251),
        Generation(number: 3, region: ("Hoenn", "호연"), range: 252...386),
    ]

    /// 도감 번호 → 만난 횟수 / 이로치로 만난 횟수
    @Published private(set) var counts: [Int: Int] = [:]
    @Published private(set) var shinyCounts: [Int: Int] = [:]
    /// 도감 번호 → 이름(한국어 / 영어)
    @Published private(set) var names: [Int: String] = [:]
    @Published private(set) var englishNames: [Int: String] = [:]
    @Published private(set) var sprites: [Int: NSImage] = [:]
    @Published private(set) var last: (id: Int, shiny: Bool)?
    /// 처음 만났는데 아직 도감에서 확인 안 한 것 — 도감 창을 열면 지운다(그 창에서는 빨간 점으로 남는다).
    @Published private(set) var newIDs = Set<Int>()
    @Published private(set) var newShinyIDs = Set<Int>()

    @Published private(set) var shinySprites: [Int: NSImage] = [:]
    private var day = ""
    private var poppedToday = false
    private let popper = PokemonPopper()
    private let defaults = UserDefaults.standard

    private init() {
        counts = Self.decode(defaults.dictionary(forKey: "dexCounts"))
        shinyCounts = Self.decode(defaults.dictionary(forKey: "dexShinyCounts"))
        newIDs = Set(defaults.array(forKey: "dexNew") as? [Int] ?? [])
        newShinyIDs = Set(defaults.array(forKey: "dexNewShiny") as? [Int] ?? [])
        for id in 1...Self.generations.last!.range.upperBound {
            if let name = defaults.string(forKey: "pokemonName-\(id)") { names[id] = name }
            if let name = defaults.string(forKey: "pokemonNameEn-\(id)") { englishNames[id] = name }
            if let image = NSImage(contentsOf: Self.spriteFile(id, shiny: false)) { sprites[id] = image }
            if let image = NSImage(contentsOf: Self.spriteFile(id, shiny: true)) { shinySprites[id] = image }
        }
        preload()
    }

    /// 지금 정복 중인 세대 — 다 못 만난 첫 세대. 다 만났으면 nil.
    var conquering: Generation? {
        Self.generations.first { gen in gen.range.contains { counts[$0] == nil } }
    }

    /// 열린 세대(정복 중인 세대까지).
    var unlocked: [Generation] {
        guard let current = conquering else { return Self.generations }
        return Self.generations.filter { $0.number <= current.number }
    }

    func seen(in gen: Generation, shiny: Bool = false) -> Int {
        gen.range.filter { (shiny ? shinyCounts[$0] : counts[$0]) != nil }.count
    }

    var progressTitle: String {
        guard let gen = conquering else { return L("Gen 1–3 complete", "3세대까지 정복 완료") }
        return "\(gen.title) \(seen(in: gen))/\(gen.range.count)"
    }
    func name(_ id: Int) -> String {
        (Language.shared.code == .ko ? names[id] ?? englishNames[id] : englishNames[id] ?? names[id]) ?? "No.\(id)"
    }

    var lastTitle: String {
        guard let last else { return L("No Pokémon met yet", "아직 만난 포켓몬이 없어요") }
        return L("Just met: ", "방금 만난 포켓몬: ") + name(last.id) + (last.shiny ? " ✨" : "")
    }

    var lastSprite: NSImage? {
        guard let last else { return nil }
        return last.shiny ? (shinySprites[last.id] ?? sprites[last.id]) : sprites[last.id]
    }

    // MARK: 튀어나오기

    /// 클릭할 때마다 부른다 — 그날 첫 클릭엔 꼭, 그 뒤로는 3번에 1번꼴로 p 에서 랜덤한 포켓몬이 튀어나온다.
    func clicked(at p: CGPoint) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        if today != day {
            day = today
            poppedToday = false
        }
        // 테스트: `defaults write com.seongwoon.hintclick forceShinyNext -bool true` 면 다음 클릭에 꼭 이로치.
        // 도감에는 남기지 않는다.
        let forced = defaults.bool(forKey: "forceShinyNext")
        if forced { defaults.removeObject(forKey: "forceShinyNext") }
        if !forced, poppedToday, Int.random(in: 0..<3) != 0 { return }
        // 이로치(1/64)는 열린 세대 전체에서, 보통은 정복 중인 세대에서만(다 정복했으면 전체에서).
        // 보통일 때 10번 중 3번은 아직 못 만난 포켓몬 중에서.
        let opened = 1...(conquering ?? Self.generations.last!).range.upperBound
        let shiny = forced || Int.random(in: 0..<64) == 0
        let range = shiny ? opened : (conquering?.range ?? opened)
        let ready = range.filter { sprites[$0] != nil }
        let unmet = ready.filter { counts[$0] == nil }
        let pick = !shiny && !unmet.isEmpty && Int.random(in: 0..<10) < 3 ? unmet.randomElement() : ready.randomElement()
        guard let id = pick else { return }
        poppedToday = true

        if shiny {
            if forced {
                Self.download(Self.spriteURL(id, shiny: true), to: Self.spriteFile(id, shiny: true)) { [weak self] image in
                    guard let self, let image else { return }
                    self.popper.pop(Self.outlined(image), near: p, tag: "TEST")
                }
            } else if let image = shinySprites[id] {
                show(id, shiny: true, image: image, at: p)
            } else {
                // 이로치 그림은 그때 받는다 — 받는 대로 띄운다.
                Self.download(Self.spriteURL(id, shiny: true), to: Self.spriteFile(id, shiny: true)) { [weak self] image in
                    guard let self else { return }
                    self.shinySprites[id] = image
                    self.show(id, shiny: image != nil, image: image ?? self.sprites[id]!, at: p)
                }
            }
        } else if let image = sprites[id] {
            show(id, shiny: false, image: image, at: p)
        }
    }

    private func show(_ id: Int, shiny: Bool, image: NSImage, at p: CGPoint) {
        let isNew = shiny ? shinyCounts[id] == nil : counts[id] == nil
        let before = conquering
        if counts[id] == nil { newIDs.insert(id) }
        if shiny, shinyCounts[id] == nil { newShinyIDs.insert(id) }
        counts[id, default: 0] += 1
        if shiny { shinyCounts[id, default: 0] += 1 }

        // 이 한 마리로 세대를 다 채웠으면 다음 세대를 연다.
        var tag: String? = isNew ? "NEW!" : nil
        if let before, conquering?.number != before.number {
            tag = conquering.map { "Gen \($0.number) Unlocked!" } ?? "All Clear!"
            preload()
        }
        // 이로치는 글자 대신 금색 외곽선으로.
        popper.pop(shiny ? Self.outlined(image) : image, near: p, tag: tag)
        last = (id, shiny)
        save()
    }


    var hasUnseen: Bool { !newIDs.isEmpty || !newShinyIDs.isEmpty }

    /// 도감 창을 열었다 — 새 포켓몬 표시를 지우고, 이번에 열린 창에서 빨간 점으로 보일 것을 돌려준다.
    func takeNew() -> (normal: Set<Int>, shiny: Set<Int>) {
        let taken = (newIDs, newShinyIDs)
        newIDs = []
        newShinyIDs = []
        save()
        return taken
    }

    private func save() {
        defaults.set(Self.encode(counts), forKey: "dexCounts")
        defaults.set(Self.encode(shinyCounts), forKey: "dexShinyCounts")
        defaults.set(Array(newIDs), forKey: "dexNew")
        defaults.set(Array(newShinyIDs), forKey: "dexNewShiny")
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: 받기

    /// 없는 그림·이름을 하나씩 받아 둔다(처음 한 번).
    private func preload() {
        // 열린 세대까지만 받는다.
        let upper = (conquering ?? Self.generations.last!).range.upperBound
        let missingSprites = (1...upper).filter { sprites[$0] == nil }
        let missingNames = (1...upper).filter { names[$0] == nil || englishNames[$0] == nil }
        guard !missingSprites.isEmpty || !missingNames.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for id in missingSprites {
                guard let data = try? Data(contentsOf: Self.spriteURL(id, shiny: false)), let image = NSImage(data: data)
                else { continue }
                try? data.write(to: Self.spriteFile(id, shiny: false))
                DispatchQueue.main.async { self.sprites[id] = image }
            }
            for id in missingNames {
                guard let url = URL(string: "https://pokeapi.co/api/v2/pokemon-species/\(id)"),
                    let data = try? Data(contentsOf: url),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let list = json["names"] as? [[String: Any]]
                else { continue }
                func named(_ lang: String) -> String? {
                    list.first { ($0["language"] as? [String: Any])?["name"] as? String == lang }?["name"] as? String
                }
                let korean = named("ko")
                let english = named("en")
                DispatchQueue.main.async {
                    if let korean {
                        self.defaults.set(korean, forKey: "pokemonName-\(id)")
                        self.names[id] = korean
                    }
                    if let english {
                        self.defaults.set(english, forKey: "pokemonNameEn-\(id)")
                        self.englishNames[id] = english
                    }
                    NotificationCenter.default.post(name: Self.didChange, object: nil)
                }
            }
        }
    }

    /// 그림 둘레에 금색 외곽선 — 실루엣을 금색으로 칠해 사방으로 조금씩 밀어 깔고 그 위에 원래 그림.
    static func outlined(_ image: NSImage) -> NSImage {
        let gold = NSColor(srgbRed: 1.0, green: 0.78, blue: 0.2, alpha: 1)
        let size = image.size
        let silhouette = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            gold.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .none
            let width = size.width / 64  // 96 짜리 그림이면 1.5
            for step in 0..<12 {
                let angle = CGFloat(step) / 12 * 2 * .pi
                silhouette.draw(in: rect.offsetBy(dx: cos(angle) * width, dy: sin(angle) * width))
            }
            image.draw(in: rect)
            return true
        }
    }

    private static func download(_ url: URL, to file: URL, completion: @escaping (NSImage?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let image = data.flatMap { NSImage(data: $0) }
            if let data, image != nil { try? data.write(to: file) }
            DispatchQueue.main.async { completion(image) }
        }.resume()
    }

    private static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pokey", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func spriteFile(_ id: Int, shiny: Bool) -> URL {
        cacheDir.appendingPathComponent("\(shiny ? "shiny-" : "")\(id).png")
    }

    private static func spriteURL(_ id: Int, shiny: Bool) -> URL {
        URL(string: "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/\(shiny ? "shiny/" : "")\(id).png")!
    }

    private static func decode(_ raw: [String: Any]?) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for (key, value) in raw ?? [:] { if let id = Int(key), let n = value as? Int { out[id] = n } }
        return out
    }

    private static func encode(_ counts: [Int: Int]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: counts.map { (String($0.key), $0.value) })
    }
}

// MARK: 도감 창

/// 일반 도감과 이로치 도감(151칸씩)을 탭으로 오간다.
struct PokedexView: View {
    /// 이번에 창을 열 때 아직 확인 안 했던 것 — 빨간 점.
    var unseen: (normal: Set<Int>, shiny: Set<Int>) = ([], [])
    @ObservedObject var dex = Pokedex.shared
    @ObservedObject var language = Language.shared
    @State private var shinyTab = false
    @State private var genNumber = 1
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text(L("Pokédex", "포켓몬 도감")).font(.title2.bold())
                Picker("", selection: $genNumber) {
                    ForEach(dex.unlocked, id: \.number) { Text($0.title).tag($0.number) }
                }
                .labelsHidden()
                .frame(width: 120)
                Picker("", selection: $shinyTab) {
                    Text(L("Normal", "일반")).tag(false)
                    Text(L("✨ Shiny", "✨ 이로치")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                Spacer()
                Text("\(dex.seen(in: gen, shiny: shinyTab)) / \(gen.range.count)").font(.headline.monospacedDigit())
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(gen.range, id: \.self) { DexCell(id: $0, shiny: shinyTab, unseen: shinyTab ? unseen.shiny : unseen.normal) }
                }
                .padding(12)
            }
        }
        .frame(minWidth: 600, minHeight: 520)
        .onAppear { genNumber = (dex.conquering ?? Pokedex.generations.last!).number }
    }

    private var gen: Pokedex.Generation {
        Pokedex.generations.first { $0.number == genNumber } ?? Pokedex.generations[0]
    }
}

private struct DexCell: View {
    @ObservedObject var dex = Pokedex.shared
    @ObservedObject var language = Language.shared
    let id: Int
    let shiny: Bool
    let unseen: Set<Int>

    var body: some View {
        let count = (shiny ? dex.shinyCounts[id] : dex.counts[id]) ?? 0
        let shinyCount = dex.shinyCounts[id] ?? 0
        let met = shiny ? dex.shinySprites[id] : dex.sprites[id]
        let isNew = unseen.contains(id)
        VStack(spacing: 2) {
            ZStack {
                if let image = dex.sprites[id] {
                    if count > 0 {
                        // 이로치 탭은 튀어나올 때처럼 금색 외곽선.
                        let shown = met ?? image
                        Image(nsImage: shiny ? Pokedex.outlined(shown) : shown).interpolation(.none).resizable()
                            .scaledToFit()
                    } else {
                        // 아직 못 만난 포켓몬은 검은 실루엣으로.
                        Image(nsImage: image).renderingMode(.template).interpolation(.none).resizable().scaledToFit()
                            .foregroundStyle(Color.black)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 72, height: 72)
            Text(String(format: "No.%03d", id)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Text(count > 0 ? dex.name(id) : "???").font(.caption.weight(.semibold)).lineLimit(1)
            Text(count > 0 ? L("×\(count)", "\(count)번") + (!shiny && shinyCount > 0 ? " · ✨" : "") : " ")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(count > 0 ? Color.primary.opacity(0.05) : Color.clear))
        // 지난번 도감을 연 뒤로 새로 만난 포켓몬은 빨간 점.
        .overlay(alignment: .topTrailing) {
            if isNew { Circle().fill(Color.red).frame(width: 8, height: 8).padding(7) }
        }
    }
}

/// 정한 자리(요소 모드는 노란 라벨 자리, 그 밖은 클릭한 곳)에서 톡 튀어 올랐다가 사라지는 작은 창. 마우스는 통과시킨다.
private final class PokemonPopper {
    private let panel: NSPanel
    private let imageView = NSImageView()
    private let newLabel = NSTextField(labelWithString: "NEW!")
    private var generation = 0
    private static let size: CGFloat = 96

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.magnificationFilter = .nearest  // 픽셀 아트를 또렷하게
        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        imageView.frame = content.bounds
        imageView.autoresizingMask = [.width, .height]
        content.addSubview(imageView)
        // 처음 만난 포켓몬이면 그림 위에 작게.
        newLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        newLabel.textColor = .white
        newLabel.alignment = .center
        newLabel.wantsLayer = true
        newLabel.drawsBackground = true
        newLabel.backgroundColor = .controlAccentColor
        newLabel.layer?.cornerRadius = 4
        newLabel.layer?.masksToBounds = true
        newLabel.frame = NSRect(x: (Self.size - 36) / 2, y: Self.size - 16, width: 36, height: 14)
        content.addSubview(newLabel)
        panel.contentView = content
    }

    /// tag: 그림 위에 작게 띄울 말(NEW! · Gen N Unlocked!). 없으면 그림만.
    func pop(_ image: NSImage, near p: CGPoint, tag: String?) {
        generation += 1
        let gen = generation
        imageView.image = image
        newLabel.isHidden = tag == nil
        if let tag {
            newLabel.stringValue = tag
            let width = newLabel.intrinsicContentSize.width + 10
            newLabel.frame = NSRect(x: (Self.size - width) / 2, y: Self.size - 16, width: width, height: 14)
        }

        let cocoa = CGPoint(x: p.x, y: Screens.primaryHeight - p.y)
        // 그림 아래 가운데가 p 에 오게(스프라이트 아래 여백만큼 조금 더 내린다) — p 에서 솟아오르듯.
        let end = NSRect(x: cocoa.x - Self.size / 2, y: cocoa.y - 18, width: Self.size, height: Self.size)
        let start = end.offsetBy(dx: 0, dy: -24)
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, self.generation == gen else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                self.panel.animator().alphaValue = 0
                self.panel.animator().setFrame(end.offsetBy(dx: 0, dy: 10), display: true)
            }, completionHandler: {
                if self.generation == gen { self.panel.orderOut(nil) }
            })
        }
    }
}

/// 메뉴바 아이콘 — 몬스터볼을 직접 그린다.
enum PokeBall {
    static func image(size: CGFloat = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let ball = rect.insetBy(dx: 1, dy: 1)
            let outline = NSColor(white: 0.12, alpha: 1)
            let circle = NSBezierPath(ovalIn: ball)

            NSGraphicsContext.saveGraphicsState()
            circle.addClip()
            NSColor(srgbRed: 0.93, green: 0.22, blue: 0.2, alpha: 1).setFill()
            NSRect(x: ball.minX, y: ball.midY, width: ball.width, height: ball.height / 2).fill()
            NSColor.white.setFill()
            NSRect(x: ball.minX, y: ball.minY, width: ball.width, height: ball.height / 2).fill()
            outline.setFill()
            NSRect(x: ball.minX, y: ball.midY - 0.75, width: ball.width, height: 1.5).fill()
            NSGraphicsContext.restoreGraphicsState()

            outline.setStroke()
            circle.lineWidth = 1.2
            circle.stroke()

            let r = ball.width * 0.17
            let button = NSBezierPath(
                ovalIn: NSRect(x: ball.midX - r, y: ball.midY - r, width: r * 2, height: r * 2))
            NSColor.white.setFill()
            button.fill()
            button.lineWidth = 1.2
            outline.setStroke()
            button.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
