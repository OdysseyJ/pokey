import Foundation

/// 화면 언어 — 기본은 영어, 설정에서 한국어로.
final class Language: ObservableObject {
    static let shared = Language()
    static let didChange = Notification.Name("PokeyLanguageDidChange")

    enum Code: String, CaseIterable {
        case en, ko
        var label: String { self == .en ? "English" : "한국어" }
    }

    @Published var code: Code {
        didSet {
            UserDefaults.standard.set(code.rawValue, forKey: "language")
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    private init() {
        code = Code(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .en
    }
}

/// 지금 언어에 맞는 쪽.
func L(_ en: String, _ ko: String) -> String { Language.shared.code == .ko ? ko : en }
