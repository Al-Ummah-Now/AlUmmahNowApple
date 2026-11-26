import Foundation

public struct QuranCaptionCredit: Equatable, Sendable {
    public enum Language: String, Sendable {
        case en, ar

        public var label: String {
            switch self {
            case .en: "Source: Quran Foundation"
            case .ar: "المصدر: مؤسسة القرآن"
            }
        }
    }

    public static let url = URL(string: "https://quran.foundation/")!

    public let text: String
    public let language: Language?
    public var credited: Bool { language != nil }

    public static func splitQuranCredit(_ cueText: String) -> Self {
        let lines = cueText.components(separatedBy: "\n")
        guard lines.count > 1, let last = lines.last else { return Self(text: cueText, language: nil) }
        let lastLine = last.drop(while: { $0 == "\u{200E}" || $0 == "\u{200F}" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let credit =
            lastLine
            .replacingOccurrences(of: "Quran\u{00A0}Foundation\u{00A0}(", with: "Quran Foundation (")
            .replacingOccurrences(of: "مؤسسة\u{00A0}القرآن\u{00A0}(", with: "مؤسسة القرآن (")

        let language: Language
        switch credit {
        case Language.en.label, "Quran data provided by Quran Foundation (https://quran.foundation/)":
            language = .en
        case Language.ar.label, "بيانات القرآن مقدَّمة من مؤسسة القرآن (https://quran.foundation/\u{200E})":
            language = .ar
        default:
            return Self(text: cueText, language: nil)
        }
        return Self(text: lines.dropLast().joined(separator: "\n"), language: language)
    }
}
