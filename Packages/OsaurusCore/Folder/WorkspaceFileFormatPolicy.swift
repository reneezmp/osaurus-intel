//
//  WorkspaceFileFormatPolicy.swift
//  osaurus
//
//  Upstream #91 (`65ff7cc4e`): which formats the folder tools read and write.
//  Upstream keeps this enum at the top of WorkspaceWriteSafety.swift; Intel
//  keeps its own WorkspaceWriteSafety, so the policy lives here verbatim.
//

import Foundation

/// Shared source-vs-document routing for workspace tools.
///
/// UTF-8 text is source, even when the extension also names a renderable
/// format (HTML, RTF, SVG). Binary document packages take the parser path and
/// cannot be fabricated by the UTF-8 text writer.
enum WorkspaceFileFormatPolicy {
    /// Coarse document family, used for model-facing labels and for the
    /// per-family pivot hints in envelopes.
    enum DocumentFamily: String, Sendable, Equatable {
        case pdf
        case word
        case presentation
        case spreadsheet
        case appleIWork
        case openDocument

        var label: String {
            switch self {
            case .pdf: return "PDF document"
            case .word: return "Word document"
            case .presentation: return "presentation"
            case .spreadsheet: return "spreadsheet"
            case .appleIWork: return "Apple iWork document"
            case .openDocument: return "OpenDocument file"
            }
        }

        /// Format the built-in extractor DOES handle for this family, so an
        /// unsupported-variant message can name the concrete conversion target.
        var supportedAlternative: String? {
            switch self {
            case .pdf: return nil
            case .word: return ".docx"
            case .presentation: return ".pptx"
            case .spreadsheet: return ".xlsx"
            case .appleIWork: return ".docx / .xlsx / .pdf (File > Export in Pages, Numbers, Keynote)"
            case .openDocument: return ".docx / .xlsx / .pdf"
            }
        }
    }

    /// What `file_read` can do with a file, decided by extension. Raw UTF-8
    /// decoding still wins at runtime for anything not listed here (an
    /// unknown extension is `.rawText` until the byte sniff says otherwise).
    enum ReadSupport: Equatable, Sendable {
        /// Plain UTF-8 read with `N|` line numbers (source, Markdown, CSV, HTML, RTF, SVG, ...).
        case rawText
        /// A registered document adapter extracts the text layer.
        case extractedText(family: DocumentFamily)
        /// `XLSXAdapter` parses it into a bounded, sheet-aware preview.
        case workbook
        /// Pixel image: shown to vision models, OCR'd for text-only models.
        case image
        /// A recognised document family with no built-in adapter. Never
        /// "text only": the message names the supported sibling format.
        case unsupportedDocument(family: DocumentFamily)

        var isDocument: Bool {
            switch self {
            case .extractedText, .workbook, .unsupportedDocument: return true
            case .rawText, .image: return false
            }
        }

        var family: DocumentFamily? {
            switch self {
            case .extractedText(let family), .unsupportedDocument(let family): return family
            case .workbook: return .spreadsheet
            case .rawText, .image: return nil
            }
        }
    }

    /// Single source of truth for extension → read behaviour. Keep in sync
    /// with the adapters registered in `DocumentAdaptersBootstrap`.
    static let readSupportByExtension: [String: ReadSupport] = [
        // Built-in extraction (PDFAdapter / RichDocumentAdapter / PPTXAdapter).
        "pdf": .extractedText(family: .pdf),
        "docx": .extractedText(family: .word),
        "doc": .extractedText(family: .word),
        "rtfd": .extractedText(family: .word),
        "pptx": .extractedText(family: .presentation),
        "potx": .extractedText(family: .presentation),
        // Workbook preview (XLSXAdapter).
        "xlsx": .workbook,
        // Recognised document families without a built-in adapter.
        "docm": .unsupportedDocument(family: .word),
        "dot": .unsupportedDocument(family: .word),
        "dotx": .unsupportedDocument(family: .word),
        "dotm": .unsupportedDocument(family: .word),
        "xls": .unsupportedDocument(family: .spreadsheet),
        "xlsm": .unsupportedDocument(family: .spreadsheet),
        "xlsb": .unsupportedDocument(family: .spreadsheet),
        "xlt": .unsupportedDocument(family: .spreadsheet),
        "xltx": .unsupportedDocument(family: .spreadsheet),
        "xltm": .unsupportedDocument(family: .spreadsheet),
        "ppt": .unsupportedDocument(family: .presentation),
        "pptm": .unsupportedDocument(family: .presentation),
        "pot": .unsupportedDocument(family: .presentation),
        "potm": .unsupportedDocument(family: .presentation),
        "pps": .unsupportedDocument(family: .presentation),
        "ppsx": .unsupportedDocument(family: .presentation),
        "ppsm": .unsupportedDocument(family: .presentation),
        "pages": .unsupportedDocument(family: .appleIWork),
        "numbers": .unsupportedDocument(family: .appleIWork),
        "key": .unsupportedDocument(family: .appleIWork),
        "odt": .unsupportedDocument(family: .openDocument),
        "ods": .unsupportedDocument(family: .openDocument),
        "odp": .unsupportedDocument(family: .openDocument),
        // Pixel images. SVG is XML source and deliberately absent.
        "png": .image, "jpg": .image, "jpeg": .image, "gif": .image, "bmp": .image,
        "tiff": .image, "tif": .image, "webp": .image, "heic": .image, "heif": .image,
    ]

    static func readSupport(for ext: String) -> ReadSupport {
        readSupportByExtension[ext.lowercased()] ?? .rawText
    }

    /// Extensions that take the document-extraction route (including the
    /// families we recognise but cannot parse, so they get an honest
    /// unsupported-format message instead of a UTF-8 decode failure).
    static let parserPreferredExtensions: Set<String> = Set(
        readSupportByExtension.compactMap { ext, support in
            support.isDocument ? ext : nil
        }
    )

    /// Extensions that read through a working adapter today.
    static let extractableDocumentExtensions: Set<String> = Set(
        readSupportByExtension.compactMap { ext, support in
            switch support {
            case .extractedText, .workbook: return ext
            default: return nil
            }
        }
    )

    /// Model-facing summary of what `file_read` opens. Shared by the tool
    /// description, the compact schema, and every unsupported-format message
    /// so the contract the model learns is identical everywhere.
    static let readableFormatsSummary =
        "text/source (any UTF-8 file), PDF, Word (.docx/.doc/.rtfd), "
        + "PowerPoint (.pptx/.potx), Excel (.xlsx), and images (.png/.jpg/.gif/.webp/.heic/...)"

    /// Model-facing summary of what `file_write` produces.
    static let writableFormatsSummary =
        "UTF-8 text/code (any extension), `.xlsx` from CSV/TSV text or JSON rows, "
        + "and `.docx`/`.pdf` from Markdown or HTML"

    /// Files whose successful persistence is not evidence that the delivered
    /// program or interactive artifact actually runs.
    static let runnableArtifactExtensions: Set<String> = [
        "html", "htm",
        "js", "mjs", "cjs", "jsx",
        "ts", "tsx",
        "py", "rb", "php",
        "sh", "bash", "zsh",
        "swift", "c", "cc", "cpp", "cxx", "h", "hpp",
        "java", "kt", "kts", "go", "rs",
    ]

    static func prefersDocumentExtraction(_ ext: String) -> Bool {
        parserPreferredExtensions.contains(ext.lowercased())
    }

    static func isRunnableArtifact(path: String) -> Bool {
        runnableArtifactExtensions.contains(
            URL(fileURLWithPath: path).pathExtension.lowercased()
        )
    }
}
