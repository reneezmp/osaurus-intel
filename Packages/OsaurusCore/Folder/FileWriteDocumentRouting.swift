//
//  FileWriteDocumentRouting.swift
//  osaurus
//
//  Intel: the workbook-building half of upstream's FileWriteDocumentRouting,
//  used by `db_export` for `.xlsx`. The rest of the upstream file (the
//  file_write route that renders .xlsx/.docx/.pdf/.pptx from content) needs
//  WorkbookWorkflowService, the rich-text renderers and PPTXEmitter, which
//  arrive with the rich folder formats port (#91). Replace this file with
//  upstream's whole file at that point.
//

import Foundation

enum FileWriteDocumentRouting {
    enum RoutingError: LocalizedError {
        case noRows
        case tooManySheets(Int, max: Int)
        case tooManyRows(Int, max: Int)
        case tooManyColumns(Int, max: Int)

        var errorDescription: String? {
            switch self {
            case .noRows:
                return "The workbook has no rows."
            case .tooManySheets(let count, let max):
                return "The workbook has \(count) sheets; the limit is \(max)."
            case .tooManyRows(let count, let max):
                return "A sheet has \(count) rows; the limit is \(max)."
            case .tooManyColumns(let count, let max):
                return "A row has \(count) columns; the limit is \(max)."
            }
        }
    }

    static let maxSheets = 20
    static let maxRowsPerSheet = 100_000
    static let maxColumns = 1_024

    /// Build a typed `Workbook` from raw rows (`String` / numeric / `Bool` /
    /// `nil` cells) — shared by the `.xlsx` write route and `db_export`.
    static func workbook(sheets: [(String, [[Any]])]) throws -> Workbook {
        guard !sheets.isEmpty else { throw RoutingError.noRows }
        if sheets.count > maxSheets { throw RoutingError.tooManySheets(sheets.count, max: maxSheets) }
        var built: [Workbook.Sheet] = []
        var usedNames: Set<String> = []
        for (index, entry) in sheets.enumerated() {
            var name = sanitizeSheetName(entry.0)
            if usedNames.contains(name.lowercased()) { name = "\(name.prefix(27))_\(index + 1)" }
            usedNames.insert(name.lowercased())
            let rows = trimTrailingEmptyRows(entry.1)
            if rows.count > maxRowsPerSheet { throw RoutingError.tooManyRows(rows.count, max: maxRowsPerSheet) }
            var sheetRows: [Workbook.Row] = []
            for (rowOffset, rawRow) in rows.enumerated() {
                if rawRow.count > maxColumns { throw RoutingError.tooManyColumns(rawRow.count, max: maxColumns) }
                let rowNumber = rowOffset + 1
                var cells: [Workbook.Cell] = []
                for (columnOffset, rawValue) in rawRow.enumerated() {
                    let value = cellValue(rawValue)
                    if case .empty = value { continue }
                    let columnNumber = columnOffset + 1
                    let reference = "\(columnLetters(columnNumber))\(rowNumber)"
                    cells.append(
                        Workbook.Cell(
                            reference: reference,
                            rowNumber: rowNumber,
                            columnNumber: columnNumber,
                            value: value,
                            formula: nil,
                            anchor: DocumentAnchor(
                                kind: .cell,
                                path: [
                                    .init(kind: .document),
                                    .init(kind: .sheet, identifier: name, index: index),
                                    .init(kind: .cell, identifier: reference),
                                ],
                                sourceRange: DocumentSourceRange(
                                    start: .cell(
                                        sheetName: name,
                                        rowIndex: rowNumber - 1,
                                        columnIndex: columnNumber - 1
                                    )
                                ),
                                label: "\(name)!\(reference)"
                            )
                        )
                    )
                }
                guard !cells.isEmpty else { continue }
                sheetRows.append(
                    Workbook.Row(
                        number: rowNumber,
                        cells: cells,
                        anchor: DocumentAnchor(
                            kind: .row,
                            path: [
                                .init(kind: .document),
                                .init(kind: .sheet, identifier: name, index: index),
                                .init(kind: .row, index: rowNumber - 1),
                            ],
                            sourceRange: DocumentSourceRange(
                                start: DocumentSourceLocation(
                                    sheetIndex: index,
                                    sheetName: name,
                                    rowIndex: rowNumber - 1
                                )
                            ),
                            label: "\(name) row \(rowNumber)"
                        )
                    )
                )
            }
            built.append(
                Workbook.Sheet(
                    name: name,
                    index: index,
                    rows: sheetRows,
                    anchor: DocumentAnchor(
                        kind: .sheet,
                        path: [
                            .init(kind: .document),
                            .init(kind: .sheet, identifier: name, index: index),
                        ],
                        sourceRange: DocumentSourceRange(
                            start: DocumentSourceLocation(sheetIndex: index, sheetName: name)
                        ),
                        label: name,
                        metadata: ["sheetIndex": "\(index)"]
                    )
                )
            )
        }
        guard built.contains(where: { !$0.rows.isEmpty }) else { throw RoutingError.noRows }
        return Workbook(sheets: built)
    }

    // MARK: - Cell typing

    /// Numbers and booleans are typed; everything else stays text. Quoted
    /// CSV fields are kept as text by the caller so "00123" survives.
    static func typed(_ text: String) -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        switch trimmed.lowercased() {
        case "true": return true
        case "false": return false
        default: break
        }
        // Only plain decimal numbers (optional sign) become numeric cells. Exponent
        // notation, thousands separators, and leading-zero codes stay text.
        if let number = Double(trimmed),
            trimmed.range(of: #"^[-+]?(\d+\.?\d*|\.\d+)$"#, options: .regularExpression) != nil,
            !(trimmed.count > 1 && trimmed.hasPrefix("0") && !trimmed.hasPrefix("0."))
        {
            return number
        }
        return text
    }

    private static func cellValue(_ raw: Any) -> Workbook.CellValue {
        switch raw {
        case let bool as Bool:
            return .bool(bool)
        case let number as NSNumber:
            // JSONSerialization booleans are NSNumber-backed; distinguish them.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        case let double as Double:
            return .number(double)
        case let int as Int:
            return .number(Double(int))
        case let int64 as Int64:
            return .number(Double(int64))
        case let string as String:
            return string.isEmpty ? .empty : .string(string)
        case is NSNull:
            return .empty
        case let array as [Any]:
            return .string(array.map { "\($0)" }.joined(separator: ", "))
        default:
            return .string(String(describing: raw))
        }
    }

    private static func trimTrailingEmptyRows(_ rows: [[Any]]) -> [[Any]] {
        var out = rows
        while let last = out.last, isEmptyRow(last) { out.removeLast() }
        return out
    }

    private static func isEmptyRow(_ row: [Any]) -> Bool {
        row.allSatisfy { value in
            if let string = value as? String { return string.trimmingCharacters(in: .whitespaces).isEmpty }
            return value is NSNull
        }
    }

    private static func sanitizeSheetName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: #"[\\/\?\*\[\]:]"#, with: "_", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { cleaned = "Sheet" }
        if cleaned.count > 31 { cleaned = String(cleaned.prefix(31)) }
        return cleaned
    }

    static func columnLetters(_ column: Int) -> String {
        var n = column
        var letters = ""
        while n > 0 {
            let rem = (n - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + rem))) + letters
            n = (n - 1) / 26
        }
        return letters
    }
}
