import Foundation
import Testing

@testable import OsaurusCore

/// Source-level guards for Ventura rendering failures that the compiler cannot
/// see: native segmented pickers and bordered buttons render blank or
/// white-on-white on Rosy, and SF Symbols newer than macOS 13 render nothing.
/// See docs/UPSTREAM_SYNC.md → "Ventura themed-control sweep".
@Suite("Intel Ventura control guards")
struct IntelVenturaControlGuardTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Chat
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // OsaurusCore

    /// Swift files that the OsaurusCore target actually compiles: everything
    /// outside `Tests`/`.build` minus `Package.swift`'s `exclude:` list.
    private static func compiledSources() throws -> [(path: String, text: String)] {
        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        guard let start = manifest.range(of: "exclude:"),
            let end = manifest.range(of: "]", range: start.upperBound..<manifest.endIndex)
        else { return [] }
        let excludeBlock = manifest[start.upperBound..<end.lowerBound]
        let regex = try NSRegularExpression(pattern: "\"([^\"]+)\"")
        let block = String(excludeBlock)
        let excludes = regex.matches(in: block, range: NSRange(block.startIndex..., in: block))
            .compactMap { Range($0.range(at: 1), in: block).map { String(block[$0]) } }

        func isExcluded(_ path: String) -> Bool {
            excludes.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }

        var result: [(String, String)] = []
        let rootPath = packageRoot.path + "/"
        let enumerator = FileManager.default.enumerator(
            at: packageRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            let relative = url.path.replacingOccurrences(of: rootPath, with: "")
            if relative.hasPrefix(".build") || relative.hasPrefix("Tests") {
                enumerator?.skipDescendants()
                continue
            }
            guard url.pathExtension == "swift", relative != "Package.swift", !isExcluded(relative)
            else { continue }
            result.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return result
    }

    @Test("Compiled views use themed segmented pickers and bordered buttons")
    func noNativeSegmentedOrBorderedStyles() throws {
        let sources = try Self.compiledSources()
        #expect(sources.count > 500, "source enumeration looks broken")
        // The lookbehind keeps `ThemedBorderedButtonStyle(` from matching.
        let banned = try NSRegularExpression(
            pattern:
                "\\.pickerStyle\\(\\.segmented\\)|(?<![A-Za-z])SegmentedPickerStyle\\(|\\.buttonStyle\\(\\.bordered(Prominent)?\\)|(?<![A-Za-z])Bordered(Prominent)?ButtonStyle\\("
        )
        var offenders: [String] = []
        for (path, text) in sources where !path.hasSuffix("IntelThemedControls.swift") {
            let range = NSRange(text.startIndex..., in: text)
            for match in banned.matches(in: text, range: range) {
                if let r = Range(match.range, in: text) { offenders.append("\(path): \(text[r])") }
            }
        }
        #expect(offenders.isEmpty, "use ThemedSegmentedPicker / ThemedBorderedButtonStyle: \(offenders)")
    }

    @Test("Compiled SF Symbol names exist on macOS 13")
    func symbolsExistOnVentura() throws {
        let tablePath =
            "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
        guard let data = FileManager.default.contents(atPath: tablePath),
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            let symbols = plist["symbols"] as? [String: String],
            let releases = plist["year_to_release"] as? [String: [String: String]]
        else {
            // The table ships with macOS; without it there is nothing to check against.
            return
        }
        func needsNewerThanVentura(_ name: String) -> Bool {
            guard let year = symbols[name], let macOS = releases[year]?["macOS"] else { return false }
            let parts = macOS.split(separator: ".").compactMap { Int($0) }
            return (parts.first ?? 0, parts.dropFirst().first ?? 0) > (13, 0)
        }

        // Dotted literals anywhere (symbol-shaped, rarely ordinary strings),
        // plus single words passed straight to a symbol API.
        let dotted = try NSRegularExpression(pattern: "\"([a-z][a-z0-9]*(?:\\.[a-z0-9]+)+)\"")
        let direct = try NSRegularExpression(
            pattern: "(?:systemName|systemImage|systemSymbolName|icon):\\s*\"([a-z][a-z0-9.]*)\"")
        var offenders: [String] = []
        for (path, text) in try Self.compiledSources() {
            for (lineNumber, line) in text.components(separatedBy: "\n").enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                for regex in [dotted, direct] {
                    for match in regex.matches(in: line, range: range) {
                        guard let r = Range(match.range(at: 1), in: line) else { continue }
                        let name = String(line[r])
                        if needsNewerThanVentura(name) {
                            offenders.append("\(path):\(lineNumber + 1) \(name)")
                        }
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "SF Symbols unavailable on macOS 13 render blank on Rosy: \(offenders)")
    }

    @Test("Document chips use a Ventura symbol for text and Markdown files")
    func documentChipSymbols() {
        let markdown = Attachment.document(filename: "notes.md", content: "# Hi", fileSize: 4)
        #expect(markdown.fileIcon == "doc.text")
        #expect(BusinessDocumentKind.plainText.systemImageName == "doc.text")
    }

    @Test("Codex sends the picker's default effort when none is chosen")
    func codexReasoningEffortDefaults() {
        #expect(ChatEngine.codexReasoningEffort(modelId: "gpt-6-astra", options: nil) == "medium")
        #expect(ChatEngine.codexReasoningEffort(modelId: "gpt-5.6-terra", options: [:]) == "medium")
        #expect(
            ChatEngine.codexReasoningEffort(
                modelId: "gpt-6-astra", options: ["reasoningEffort": .string("XHigh")]) == "xhigh")
        #expect(
            ChatEngine.codexReasoningEffort(
                modelId: "gpt-6-astra", options: ["reasoningEffort": .string("off")]) == nil)
        #expect(ChatEngine.codexReasoningEffort(modelId: "gpt-4.1", options: nil) == nil)
    }

    @Test("Hex field applies only full values while typing")
    func hexTypingCommitRules() {
        #expect(!ThemeHexTextField.isFullHex("#FF0"))
        #expect(!ThemeHexTextField.isFullHex("#FF00"))
        #expect(ThemeHexTextField.isFullHex("#FF0000"))
        #expect(ThemeHexTextField.isFullHex("#FF000080"))
        // Shorthand still commits on Enter / leaving the field.
        #expect(ThemeHexTextField.isCompleteHex("#FF0"))
        #expect(!ThemeHexTextField.isCompleteHex("#FF00"))
    }
}
