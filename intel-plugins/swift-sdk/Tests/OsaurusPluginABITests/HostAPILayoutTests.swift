//
//  HostAPILayoutTests.swift
//
//  MANDATORY layout pins. Rejects Swift/C drift in the `OsrHostAPI`
//  mirror. If any assertion fails, a plugin calling through
//  `host->get_active_agent_id` (or any later slot) invokes the WRONG host
//  function — the production `pointer being freed was not allocated`
//  crash class. Offsets from `offsetof` against `osaurus_plugin.h`
//  (arm64 Darwin, LP64) and pinned in `docs/plugins/ABI_VERSIONS.md`.
//

import XCTest

@testable import OsaurusPluginABI

final class HostAPILayoutTests: XCTestCase {

    func testTotalSizeStrideAlignment() {
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.size, 200, "osr_host_api size drifted")
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.stride, 200, "osr_host_api stride drifted")
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.alignment, 8, "osr_host_api alignment drifted")
    }

    func testDocumentedPinnedOffsets() {
        // The four offsets pinned in ABI_VERSIONS.md.
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.version), 0)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.get_active_agent_id), 176)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.log_structured), 184)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.free_string), 192)
    }

    func testEverySlotOffset() {
        // Full field-order pin: every slot, in header order.
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.config_get), 8)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.config_set), 16)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.config_delete), 24)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.db_exec), 32)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.db_query), 40)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.log), 48)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.dispatch), 56)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.task_status), 64)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.dispatch_cancel), 72)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.dispatch_clarify), 80)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.complete), 88)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.complete_stream), 96)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.embed), 104)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.list_models), 112)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.http_request), 120)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.file_read), 128)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.list_active_tasks), 136)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.send_draft), 144)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.dispatch_interrupt), 152)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.dispatch_add_issue), 160)
        XCTAssertEqual(MemoryLayout<OsrHostAPI>.offset(of: \.complete_cancel), 168)
    }

    func testDefaultInitAdvertisesCurrentVersionWithNilSlots() {
        let api = OsrHostAPI()
        XCTAssertEqual(api.version, OsrABIVersion.current)
        XCTAssertNil(api.config_get)
        XCTAssertNil(api.log_structured)
        XCTAssertNil(api.free_string)
    }
}
