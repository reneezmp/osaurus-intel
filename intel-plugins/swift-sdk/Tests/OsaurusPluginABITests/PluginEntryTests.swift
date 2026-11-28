//
//  PluginEntryTests.swift
//
//  Verifies the entry-point helpers: table assembly defaults, and that
//  `enterV2` installs the host into `HostBridge.shared` and returns the
//  plugin API pointer unchanged.
//

import XCTest

@testable import OsaurusPluginABI

private let dummyInit: OsrInitFn = { OsrPluginCtx(bitPattern: 0x1) }
private let dummyDestroy: OsrDestroyFn = { _ in }
private let dummyGetManifest: OsrGetManifestFn = { _ in osrMakeCString("{}") }
private let dummyInvoke: OsrInvokeFn = { _, _, _, _ in osrMakeCString("{\"ok\":true}") }

// Stable storage, as a real plugin would declare.
private var testPluginAPI = PluginEntry.makeAPI(
    init: dummyInit,
    destroy: dummyDestroy,
    getManifest: dummyGetManifest,
    invoke: dummyInvoke
)

final class PluginEntryTests: XCTestCase {

    override func tearDown() {
        HostBridge.shared.install(nil)
        super.tearDown()
    }

    func testMakeAPIPopulatesRequiredSlotsAndDefaults() {
        let api = PluginEntry.makeAPI(
            init: dummyInit,
            destroy: dummyDestroy,
            getManifest: dummyGetManifest,
            invoke: dummyInvoke
        )
        XCTAssertNotNil(api.free_string, "default free_string must be installed")
        XCTAssertNotNil(api.`init`)
        XCTAssertNotNil(api.destroy)
        XCTAssertNotNil(api.get_manifest)
        XCTAssertNotNil(api.invoke)
        XCTAssertEqual(api.version, OsrABIVersion.v2)
        XCTAssertNil(api.handle_route)
        XCTAssertNil(api.on_config_changed)
        XCTAssertNil(api.on_task_event)
    }

    func testDefaultFreeStringReleasesStrdupString() {
        // Must not crash: strdup + libc free pair.
        PluginEntry.defaultFreeString(osrMakeCString("hello"))
        PluginEntry.defaultFreeString(nil)
    }

    func testEnterV1ReturnsAPIPointer() {
        let result = PluginEntry.enterV1(api: &testPluginAPI)
        XCTAssertNotNil(result)
        withUnsafePointer(to: &testPluginAPI) { expected in
            XCTAssertEqual(result, UnsafeRawPointer(expected))
        }
    }

    func testEnterV2InstallsSharedBridgeAndReturnsAPIPointer() {
        var host = OsrHostAPI(version: 6)
        let result = withUnsafePointer(to: &host) { hostPtr in
            PluginEntry.enterV2(UnsafeRawPointer(hostPtr), api: &testPluginAPI)
        }
        XCTAssertNotNil(result)
        withUnsafePointer(to: &testPluginAPI) { expected in
            XCTAssertEqual(result, UnsafeRawPointer(expected))
        }
        XCTAssertTrue(HostBridge.shared.isInstalled)
        XCTAssertEqual(HostBridge.shared.hostVersion, 6)
    }

    func testEnterV2WithNilHostLeavesBridgeUninstalled() {
        let result = PluginEntry.enterV2(nil, api: &testPluginAPI)
        XCTAssertNotNil(result)
        XCTAssertFalse(HostBridge.shared.isInstalled)
    }
}
