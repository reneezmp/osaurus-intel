import Foundation
import Testing

@testable import osaurus_xlsx

// MARK: - Zip Fixture Builder

/// Builds zip archives byte-by-byte (central directory + EOCD) so tests can
/// craft malicious metadata that real zip tools refuse to produce.
enum ZipFixture {
  struct Entry {
    var name: String
    var compressedSize: UInt32 = 100
    var uncompressedSize: UInt32 = 100
    // Unix regular file 0644 in the upper 16 bits.
    var externalAttributes: UInt32 = 0x81A4 << 16
    // Upper byte 3 = Unix host.
    var versionMadeBy: UInt16 = 0x031E
  }

  static func make(entries: [Entry]) -> Data {
    var cd = Data()
    for entry in entries {
      append32(&cd, 0x0201_4B50)
      append16(&cd, entry.versionMadeBy)
      append16(&cd, 20)  // version needed
      append16(&cd, 0)  // flags
      append16(&cd, 0)  // method
      append16(&cd, 0)  // mod time
      append16(&cd, 0)  // mod date
      append32(&cd, 0)  // crc32
      append32(&cd, entry.compressedSize)
      append32(&cd, entry.uncompressedSize)
      let nameBytes = Array(entry.name.utf8)
      append16(&cd, UInt16(nameBytes.count))
      append16(&cd, 0)  // extra length
      append16(&cd, 0)  // comment length
      append16(&cd, 0)  // disk number
      append16(&cd, 0)  // internal attributes
      append32(&cd, entry.externalAttributes)
      append32(&cd, 0)  // local header offset
      cd.append(contentsOf: nameBytes)
    }

    var out = cd
    append32(&out, 0x0605_4B50)
    append16(&out, 0)  // disk number
    append16(&out, 0)  // cd start disk
    let count = UInt16(min(entries.count, 0xFFFF))
    append16(&out, count)
    append16(&out, count)
    append32(&out, UInt32(cd.count))
    append32(&out, 0)  // cd offset (cd is at file start)
    append16(&out, 0)  // comment length
    return out
  }

  static func write(entries: [Entry], suffix: String) throws -> String {
    let path = NSTemporaryDirectory() + "zip_fixture_\(suffix)_\(UUID().uuidString).xlsx"
    try make(entries: entries).write(to: URL(fileURLWithPath: path))
    return path
  }

  private static func append16(_ data: inout Data, _ value: UInt16) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
  }

  private static func append32(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 24) & 0xFF))
  }
}

// MARK: - Shell helpers for tamper tests

private func runZipTool(_ executable: String, _ arguments: [String], cwd: String? = nil) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  if let cwd = cwd {
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
  }
  process.standardOutput = Pipe()
  process.standardError = Pipe()
  try process.run()
  process.waitUntilExit()
}

// MARK: - Archive Safety

@Suite("Archive Safety")
struct ArchiveSafetyTests {

  @Test("Path traversal entry is rejected before extraction")
  func traversalEntryRejected() throws {
    let path = try ZipFixture.write(
      entries: [
        ZipFixture.Entry(name: "xl/workbook.xml"),
        ZipFixture.Entry(name: "../../../../tmp/evil.xml"),
      ], suffix: "traversal")
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
      _ = try XLSXReader.read(from: path)
      Issue.record("Expected traversal archive to be rejected")
    } catch {
      #expect("\(error)".contains("escapes extraction root"))
    }
  }

  @Test("Absolute entry path is rejected")
  func absoluteEntryRejected() throws {
    let path = try ZipFixture.write(
      entries: [ZipFixture.Entry(name: "/etc/evil.xml")], suffix: "absolute")
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
      _ = try XLSXReader.read(from: path)
      Issue.record("Expected absolute-path archive to be rejected")
    } catch {
      #expect("\(error)".contains("escapes extraction root"))
    }
  }

  @Test("High-ratio zip bomb with modest compressed size is rejected")
  func zipBombRejected() throws {
    // 4 entries, each claiming 100 MB uncompressed from 256 KB compressed:
    // ratio 400:1 at a modest ~1 MB archive size.
    let entries = (1...4).map { i in
      ZipFixture.Entry(
        name: "xl/worksheets/sheet\(i).xml",
        compressedSize: 256 * 1024,
        uncompressedSize: 100 * 1024 * 1024)
    }
    let path = try ZipFixture.write(entries: entries, suffix: "bomb")
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
      _ = try XLSXReader.read(from: path)
      Issue.record("Expected zip bomb to be rejected")
    } catch {
      #expect("\(error)".contains("compression ratio"))
    }
  }

  @Test("Total uncompressed size above limit is rejected")
  func totalSizeRejected() throws {
    let entries = (1...80).map { i in
      ZipFixture.Entry(
        name: "xl/big\(i).bin",
        compressedSize: 90 * 1024 * 1024,
        uncompressedSize: 100 * 1024 * 1024)
    }
    let path = try ZipFixture.write(entries: entries, suffix: "toobig")
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
      _ = try XLSXReader.read(from: path)
      Issue.record("Expected oversized archive to be rejected")
    } catch {
      #expect("\(error)".contains("exceeds limit"))
    }
  }

  @Test("Huge entry count is rejected")
  func hugeEntryCountRejected() throws {
    let entries = (1...10_001).map { i in
      ZipFixture.Entry(name: "e\(i)", compressedSize: 1, uncompressedSize: 1)
    }
    let path = try ZipFixture.write(entries: entries, suffix: "manyentries")
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
      _ = try XLSXReader.read(from: path)
      Issue.record("Expected archive with too many entries to be rejected")
    } catch {
      #expect("\(error)".contains("too many entries"))
    }
  }

  @Test("Symlink entry is rejected")
  func symlinkEntryRejected() throws {
    let path = try ZipFixture.write(
      entries: [
        ZipFixture.Entry(name: "xl/link", externalAttributes: 0xA1FF << 16)
      ], suffix: "symlink")
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
      _ = try XLSXReader.read(from: path)
      Issue.record("Expected symlink archive to be rejected")
    } catch {
      #expect("\(error)".contains("symlink"))
    }
  }

  @Test("readSheetNames also validates the archive first")
  func readSheetNamesValidates() throws {
    let path = try ZipFixture.write(
      entries: [ZipFixture.Entry(name: "../escape.xml")], suffix: "listnames")
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
      _ = try XLSXReader.readSheetNames(from: path)
      Issue.record("Expected readSheetNames to reject the archive")
    } catch {
      #expect("\(error)".contains("escapes extraction root"))
    }
  }

  @Test("Valid archive produced by the writer still validates")
  func validArchivePasses() throws {
    let wb = Workbook()
    wb.addSheet(name: "Data").setCell("A1", value: .string("ok"))
    let path = NSTemporaryDirectory() + "valid_\(UUID().uuidString).xlsx"
    defer { try? FileManager.default.removeItem(atPath: path) }
    try XLSXWriter.write(workbook: wb, to: path)

    let entries = try ZipArchiveGuard.validate(archiveAt: path)
    #expect(!entries.isEmpty)
    let read = try XLSXReader.read(from: path)
    #expect(read.sheets.count == 1)
  }
}

// MARK: - Relationship Target Containment

@Suite("Relationship Target Containment")
struct RelationshipTargetTests {

  @Test("Escaping relationship targets are rejected")
  func escapingTargetsRejected() throws {
    let root = NSTemporaryDirectory() + "pkg_\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }

    for target in ["../../../../etc/hosts", "/../outside.xml", "ws/../../../../etc/hosts"] {
      do {
        _ = try XLSXReader.resolveRelationshipTarget(
          target, baseDir: "\(root)/xl", packageRoot: root)
        Issue.record("Expected target to be rejected: \(target)")
      } catch {
        #expect("\(error)".contains("escapes package"))
      }
    }

    // Safe relative and package-absolute targets still resolve.
    let relative = try XLSXReader.resolveRelationshipTarget(
      "worksheets/sheet1.xml", baseDir: "\(root)/xl", packageRoot: root)
    #expect(relative.hasSuffix("/xl/worksheets/sheet1.xml"))
    let absolute = try XLSXReader.resolveRelationshipTarget(
      "/xl/worksheets/sheet1.xml", baseDir: "\(root)/xl", packageRoot: root)
    #expect(absolute.hasSuffix("/xl/worksheets/sheet1.xml"))
  }

  @Test("Tampered rels file with escaping worksheet target fails the read")
  func tamperedRelsRejected() throws {
    let wb = Workbook()
    wb.addSheet(name: "Data").setCell("A1", value: .string("x"))
    let originalPath = NSTemporaryDirectory() + "tamper_src_\(UUID().uuidString).xlsx"
    let workDir = NSTemporaryDirectory() + "tamper_work_\(UUID().uuidString)"
    let tamperedPath = NSTemporaryDirectory() + "tampered_\(UUID().uuidString).xlsx"
    defer {
      try? FileManager.default.removeItem(atPath: originalPath)
      try? FileManager.default.removeItem(atPath: workDir)
      try? FileManager.default.removeItem(atPath: tamperedPath)
    }
    try XLSXWriter.write(workbook: wb, to: originalPath)

    try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    try runZipTool("/usr/bin/unzip", ["-q", "-o", originalPath, "-d", workDir])

    let relsPath = "\(workDir)/xl/_rels/workbook.xml.rels"
    var rels = try String(contentsOfFile: relsPath, encoding: .utf8)
    rels = rels.replacingOccurrences(
      of: "worksheets/sheet1.xml", with: "../../../../../../etc/hosts")
    try rels.write(toFile: relsPath, atomically: true, encoding: .utf8)
    try runZipTool("/usr/bin/zip", ["-r", "-q", tamperedPath, "."], cwd: workDir)

    do {
      _ = try XLSXReader.read(from: tamperedPath)
      Issue.record("Expected tampered rels to be rejected")
    } catch {
      #expect("\(error)".contains("escapes package"))
    }
  }
}

// MARK: - Canonical Path Containment

@Suite("Canonical Path Containment")
struct CanonicalPathTests {

  @Test("Symlink inside the working directory cannot escape it")
  func symlinkEscapeBlocked() throws {
    let base = NSTemporaryDirectory() + "canon_\(UUID().uuidString)"
    let workDir = base + "/proj"
    let outside = base + "/outside"
    try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: workDir + "/link", withDestinationPath: outside)
    defer { try? FileManager.default.removeItem(atPath: base) }

    let result = validatePath("link/escape.xlsx", workingDirectory: workDir)
    if case .failure(let msg) = result {
      #expect(msg.contains("outside"))
    } else {
      Issue.record("Symlinked path escaping the working directory must be rejected")
    }
  }

  @Test("Sibling directory sharing the working-directory prefix is rejected")
  func siblingPrefixBlocked() {
    let result = validatePath(
      "/Users/test/project-evil/file.xlsx", workingDirectory: "/Users/test/project")
    if case .failure(let msg) = result {
      #expect(msg.contains("outside"))
    } else {
      Issue.record("Sibling prefix path must be rejected")
    }
  }
}

// MARK: - Atomic Write

@Suite("Atomic Write")
struct AtomicWriteTests {

  @Test("Writing to a path that is an existing directory fails and preserves it")
  func destinationDirectoryPreserved() throws {
    let dir = NSTemporaryDirectory() + "precious_dir_\(UUID().uuidString)"
    let innerFile = dir + "/precious.txt"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try "do not lose me".write(toFile: innerFile, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let wb = Workbook()
    wb.addSheet(name: "Data").setCell("A1", value: .string("x"))

    #expect(throws: (any Error).self) {
      try XLSXWriter.write(workbook: wb, to: dir, overwrite: true)
    }

    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir))
    #expect(isDir.boolValue)
    #expect(try String(contentsOfFile: innerFile, encoding: .utf8) == "do not lose me")
  }

  @Test("A failing write leaves the prior file untouched")
  func failedWritePreservesPriorFile() throws {
    let path = NSTemporaryDirectory() + "atomic_\(UUID().uuidString).xlsx"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let priorBytes = Data("prior xlsx bytes".utf8)
    try priorBytes.write(to: URL(fileURLWithPath: path))

    // An invalid sheet name makes the writer fail before any replacement.
    let wb = Workbook()
    wb.addSheet(name: "Bad[Name]").setCell("A1", value: .string("x"))

    do {
      try XLSXWriter.write(workbook: wb, to: path, overwrite: true)
      Issue.record("Expected write with invalid sheet name to fail")
    } catch {
      #expect("\(error)".contains("Invalid sheet name"))
    }

    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == priorBytes)
  }

  @Test("A successful overwrite atomically replaces the prior file")
  func successfulWriteReplaces() throws {
    let path = NSTemporaryDirectory() + "atomic_ok_\(UUID().uuidString).xlsx"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let first = Workbook()
    first.addSheet(name: "Data").setCell("A1", value: .string("First"))
    try XLSXWriter.write(workbook: first, to: path)

    let second = Workbook()
    second.addSheet(name: "Data").setCell("A1", value: .string("Second"))
    try XLSXWriter.write(workbook: second, to: path, overwrite: true)

    let read = try XLSXReader.read(from: path)
    if case .string(let v) = read.sheets[0].getCell("A1")?.value {
      #expect(v == "Second")
    } else {
      Issue.record("A1 should hold the replacement value")
    }
  }
}

// MARK: - Sheet Name Validation

@Suite("Sheet Name Validation")
struct SheetNameValidationTests {

  @Test("validateSheetName enforces Excel rules")
  func rules() {
    #expect(validateSheetName("Sales") == nil)
    #expect(validateSheetName("Q4 2025 Report") == nil)
    #expect(validateSheetName("") != nil)
    #expect(validateSheetName("   ") != nil)
    #expect(validateSheetName(String(repeating: "a", count: 32)) != nil)
    #expect(validateSheetName(String(repeating: "a", count: 31)) == nil)
    for bad in ["a[b", "a]b", "a:b", "a*b", "a?b", "a/b", "a\\b"] {
      #expect(validateSheetName(bad) != nil, "Expected rejection of \(bad)")
    }
  }

  @Test("create_xlsx rejects invalid and duplicate sheet names")
  func createXlsxRejects() {
    var workbooks: [String: Workbook] = [:]
    let tool = CreateXlsxTool()

    let tooLong = tool.run(
      args: "{\"sheets\": [{\"name\": \"\(String(repeating: "x", count: 40))\"}]}",
      workbooks: &workbooks)
    #expect(tooLong.contains("\"kind\":\"invalid_args\""))

    let forbidden = tool.run(
      args: "{\"sheets\": [{\"name\": \"Bad[Name]\"}]}", workbooks: &workbooks)
    #expect(forbidden.contains("\"kind\":\"invalid_args\""))

    let blank = tool.run(args: "{\"sheets\": [{\"name\": \" \"}]}", workbooks: &workbooks)
    #expect(blank.contains("\"kind\":\"invalid_args\""))

    let duplicate = tool.run(
      args: "{\"sheets\": [{\"name\": \"Data\"}, {\"name\": \"data\"}]}", workbooks: &workbooks)
    #expect(duplicate.contains("\"kind\":\"invalid_args\""))
    #expect(duplicate.contains("Duplicate"))
    #expect(workbooks.isEmpty)
  }

  @Test("write_cells rejects creating a sheet with an invalid name")
  func writeCellsRejectsBadSheetName() {
    var workbooks: [String: Workbook] = [:]
    let wb = Workbook()
    wb.addSheet(name: "Data")
    workbooks[wb.id] = wb

    let result = WriteCellsTool().run(
      args:
        "{\"workbook_id\": \"\(wb.id)\", \"sheet_name\": \"Bad:Name\", \"cells\": [{\"ref\": \"A1\", \"value\": \"x\"}]}",
      workbooks: &workbooks)
    #expect(result.contains("\"kind\":\"invalid_args\""))
    #expect(wb.sheets.count == 1)
  }

  @Test("modify_xlsx reports invalid add_sheet/rename_sheet as per-op errors")
  func modifyReportsSheetNameErrors() {
    var workbooks: [String: Workbook] = [:]
    let wb = Workbook()
    wb.addSheet(name: "Data")
    wb.addSheet(name: "Summary")
    workbooks[wb.id] = wb

    let result = ModifyXlsxTool().run(
      args: """
        {"workbook_id": "\(wb.id)", "sheet_name": "Data", "operations": [
          {"type": "add_sheet", "name": "Bad*Name"},
          {"type": "add_sheet", "name": "summary"},
          {"type": "rename_sheet", "new_name": "Summary"}
        ]}
        """,
      workbooks: &workbooks)
    #expect(result.contains("\"operations_applied\": 0"))
    #expect(result.contains("forbidden character"))
    #expect(result.contains("Duplicate sheet name"))
    #expect(wb.sheets.count == 2)
  }

  @Test("csv_to_xlsx rejects an invalid sheet name")
  func csvToXlsxRejects() {
    var workbooks: [String: Workbook] = [:]
    let result = CsvToXlsxTool().run(
      args: "{\"csv_data\": \"a,b\", \"sheet_name\": \"Bad/Name\"}", workbooks: &workbooks)
    #expect(result.contains("\"kind\":\"invalid_args\""))
  }
}

// MARK: - Batch Error Reporting

@Suite("Batch Error Reporting")
struct BatchErrorReportingTests {

  private func parse(_ json: String) throws -> [String: Any] {
    let obj = try JSONSerialization.jsonObject(with: Data(json.utf8))
    guard let dict = obj as? [String: Any] else {
      throw NSError(domain: "BatchErrorReportingTests", code: 1)
    }
    return dict
  }

  @Test("write_cells reports skipped cells in the errors array")
  func writeCellsReportsErrors() throws {
    var workbooks: [String: Workbook] = [:]
    let wb = Workbook()
    wb.addSheet(name: "Data")
    workbooks[wb.id] = wb

    let result = WriteCellsTool().run(
      args: """
        {"workbook_id": "\(wb.id)", "sheet_name": "Data", "cells": [
          {"ref": "A1", "value": "ok"},
          {"ref": "NOT_A_REF", "value": "x"},
          {"ref": "B1", "value": "abc", "type": "number"},
          {"ref": "C1", "value": "1", "type": "bogus"}
        ]}
        """,
      workbooks: &workbooks)

    let dict = try parse(result)
    #expect(dict["cells_written"] as? Int == 1)
    let errors = dict["errors"] as? [[String: Any]]
    #expect(errors?.count == 3)
    let indices = Set((errors ?? []).compactMap { $0["index"] as? Int })
    #expect(indices == [1, 2, 3])
    let refs = Set((errors ?? []).compactMap { $0["ref"] as? String })
    #expect(refs.contains("NOT_A_REF"))
  }

  @Test("modify_xlsx reports invalid operations in the errors array")
  func modifyReportsErrors() throws {
    var workbooks: [String: Workbook] = [:]
    let wb = Workbook()
    let sheet = wb.addSheet(name: "Data")
    sheet.setCell("A1", value: .string("keep"))
    workbooks[wb.id] = wb

    let result = ModifyXlsxTool().run(
      args: """
        {"workbook_id": "\(wb.id)", "sheet_name": "Data", "operations": [
          {"type": "set_cell", "ref": "A2", "value": "ok"},
          {"type": "set_cell", "ref": "BADREF!", "value": "x"},
          {"type": "set_cell"},
          {"type": "delete_row", "row": -3},
          {"type": "delete_column", "column": "5"},
          {"type": "explode"}
        ]}
        """,
      workbooks: &workbooks)

    let dict = try parse(result)
    #expect(dict["operations_applied"] as? Int == 1)
    let errors = dict["errors"] as? [[String: Any]]
    #expect(errors?.count == 5)
    let indices = Set((errors ?? []).compactMap { $0["index"] as? Int })
    #expect(indices == [1, 2, 3, 4, 5])
    let messages = (errors ?? []).compactMap { $0["error"] as? String }
    #expect(messages.contains { $0.contains("Unknown operation type") })
  }

  @Test("modify_xlsx warns that deletions do not adjust formulas or merges")
  func deleteWarnsAboutFormulas() throws {
    var workbooks: [String: Workbook] = [:]
    let wb = Workbook()
    let sheet = wb.addSheet(name: "Data")
    sheet.setCell("A1", value: .string("r1"))
    sheet.setCell("A2", value: .string("r2"))
    workbooks[wb.id] = wb

    let result = ModifyXlsxTool().run(
      args:
        "{\"workbook_id\": \"\(wb.id)\", \"sheet_name\": \"Data\", \"operations\": [{\"type\": \"delete_row\", \"row\": 1}]}",
      workbooks: &workbooks)

    let dict = try parse(result)
    #expect(dict["operations_applied"] as? Int == 1)
    let warnings = dict["warnings"] as? [String]
    #expect(warnings?.contains { $0.contains("not adjusted") } == true)

    // No warning when no rows/columns were deleted.
    let noDelete = ModifyXlsxTool().run(
      args:
        "{\"workbook_id\": \"\(wb.id)\", \"sheet_name\": \"Data\", \"operations\": [{\"type\": \"set_cell\", \"ref\": \"B1\", \"value\": \"x\"}]}",
      workbooks: &workbooks)
    let noDeleteDict = try parse(noDelete)
    #expect((noDeleteDict["warnings"] as? [String])?.isEmpty == true)
  }

  @Test("xlsx_to_csv rejects an unknown format")
  func csvFormatValidated() {
    var workbooks: [String: Workbook] = [:]
    let result = XlsxToCsvTool().run(
      args: "{\"path\": \"/tmp/whatever.xlsx\", \"format\": \"bogus\"}", workbooks: &workbooks)
    #expect(result.contains("\"kind\":\"invalid_args\""))
  }
}

// MARK: - Manifest Version

@Suite("Manifest Version")
struct ManifestVersionTests {
  @Test("Embedded manifest version matches the released version")
  func versionMatchesRelease() throws {
    let data = Data(xlsxManifestJSON.utf8)
    let manifest = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(manifest["version"] as? String == "1.2.0")
  }
}
