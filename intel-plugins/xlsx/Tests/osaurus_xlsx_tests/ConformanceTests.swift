import Foundation
import OsaurusPluginABI
import OsaurusPluginTestSupport
import Testing

@testable import osaurus_xlsx

// MARK: - SDK Conformance

@Suite("SDK Conformance")
struct SDKConformanceTests {

  @Test("Manifest passes registry conformance")
  func manifestConformant() throws {
    try ManifestConformance.assertConformant(xlsxManifestJSON)
  }

  @Test("v2 entry point returns a conformant plugin API table")
  func entryV2Conformant() throws {
    try ABIConformance.assertEntryConformance(
      osaurus_plugin_entry_v2(nil), manifestJSON: xlsxManifestJSON)
  }

  @Test("v1 entry point returns the same conformant table")
  func entryV1Conformant() throws {
    try ABIConformance.assertEntryConformance(
      osaurus_plugin_entry(), manifestJSON: xlsxManifestJSON)
  }

  @Test("Tool failures render the canonical failure envelope")
  func canonicalFailure() throws {
    var workbooks: [String: Workbook] = [:]
    let invalidArgs = CreateXlsxTool().run(args: "{}", workbooks: &workbooks)
    try assertCanonicalFailure(invalidArgs, kind: .invalidArgs)

    let notFound = SaveXlsxTool().run(
      args: "{\"workbook_id\": \"missing\", \"path\": \"out.xlsx\"}", workbooks: &workbooks)
    try assertCanonicalFailure(notFound, kind: .notFound)
  }
}
