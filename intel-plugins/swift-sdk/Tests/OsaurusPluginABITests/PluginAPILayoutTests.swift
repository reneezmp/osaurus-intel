//
//  PluginAPILayoutTests.swift
//
//  Layout pins for the plugin-side table (`osr_plugin_api`) and its
//  required v1 prefix. The host reads this table through pointer
//  arithmetic — drift here breaks every plugin built on the SDK.
//

import XCTest

@testable import OsaurusPluginABI

final class PluginAPILayoutTests: XCTestCase {

    func testFullPluginAPILayout() {
        // Five required pointers, uint32 version (padded), three optional
        // pointers — per osaurus_plugin.h on arm64 Darwin.
        XCTAssertEqual(MemoryLayout<OsrPluginAPI>.size, 72)
        XCTAssertEqual(MemoryLayout<OsrPluginAPI>.stride, 72)
        XCTAssertEqual(MemoryLayout<OsrPluginAPI>.alignment, 8)

        XCTAssertEqual(MemoryLayout<OsrPluginAPI>.offset(of: \.free_string), 0)
        XCTAssertEqual(MemoryLayout<OsrPluginAPI>.offset(of: \.`init`), 8)
        XCTAssertEqual(MemoryLayout<OsrPluginAPI>.offset(of: \.destroy), 16)
        XCTAssertEqual(MemoryLayout<OsrPluginAPI>.offset(of: \.get_manifest), 24)
        XCTAssertEqual(MemoryLayout<OsrPluginAPI>.offset(of: \.invoke), 32)
        XCTAssertEqual(MemoryLayout<OsrPluginAPI>.offset(of: \.version), 40)
        XCTAssertEqual(MemoryLayout<OsrPluginAPI>.offset(of: \.handle_route), 48)
        XCTAssertEqual(MemoryLayout<OsrPluginAPI>.offset(of: \.on_config_changed), 56)
        XCTAssertEqual(MemoryLayout<OsrPluginAPI>.offset(of: \.on_task_event), 64)
    }

    func testV1PrefixLayout() {
        XCTAssertEqual(MemoryLayout<OsrPluginAPIv1Prefix>.size, 40)
        XCTAssertEqual(MemoryLayout<OsrPluginAPIv1Prefix>.stride, 40)
        XCTAssertEqual(MemoryLayout<OsrPluginAPIv1Prefix>.alignment, 8)

        XCTAssertEqual(MemoryLayout<OsrPluginAPIv1Prefix>.offset(of: \.free_string), 0)
        XCTAssertEqual(MemoryLayout<OsrPluginAPIv1Prefix>.offset(of: \.`init`), 8)
        XCTAssertEqual(MemoryLayout<OsrPluginAPIv1Prefix>.offset(of: \.destroy), 16)
        XCTAssertEqual(MemoryLayout<OsrPluginAPIv1Prefix>.offset(of: \.get_manifest), 24)
        XCTAssertEqual(MemoryLayout<OsrPluginAPIv1Prefix>.offset(of: \.invoke), 32)
    }

    func testPrefixOffsetsMatchFullStructPrefix() {
        // The v1 prefix must be readable through a pointer to the full
        // struct — offsets of the shared fields must be identical.
        XCTAssertEqual(
            MemoryLayout<OsrPluginAPIv1Prefix>.offset(of: \.free_string),
            MemoryLayout<OsrPluginAPI>.offset(of: \.free_string))
        XCTAssertEqual(
            MemoryLayout<OsrPluginAPIv1Prefix>.offset(of: \.`init`),
            MemoryLayout<OsrPluginAPI>.offset(of: \.`init`))
        XCTAssertEqual(
            MemoryLayout<OsrPluginAPIv1Prefix>.offset(of: \.destroy),
            MemoryLayout<OsrPluginAPI>.offset(of: \.destroy))
        XCTAssertEqual(
            MemoryLayout<OsrPluginAPIv1Prefix>.offset(of: \.get_manifest),
            MemoryLayout<OsrPluginAPI>.offset(of: \.get_manifest))
        XCTAssertEqual(
            MemoryLayout<OsrPluginAPIv1Prefix>.offset(of: \.invoke),
            MemoryLayout<OsrPluginAPI>.offset(of: \.invoke))
    }
}
