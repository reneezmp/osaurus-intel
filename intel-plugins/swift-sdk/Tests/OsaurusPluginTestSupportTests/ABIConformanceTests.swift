//
//  ABIConformanceTests.swift
//

import XCTest
import OsaurusPluginABI

@testable import OsaurusPluginTestSupport

private let dummyInit: OsrInitFn = { OsrPluginCtx(bitPattern: 0x1) }
private let dummyDestroy: OsrDestroyFn = { _ in }
private let dummyGetManifest: OsrGetManifestFn = { _ in osrMakeCString("{}") }
private let dummyInvoke: OsrInvokeFn = { _, _, _, _ in osrMakeCString("{\"ok\":true}") }
private let dummyHandleRoute: OsrHandleRouteFn = { _, _ in osrMakeCString("{}") }

private func fullAPI(version: UInt32 = 2) -> OsrPluginAPI {
    PluginEntry.makeAPI(
        version: version,
        init: dummyInit,
        destroy: dummyDestroy,
        getManifest: dummyGetManifest,
        invoke: dummyInvoke)
}

private let routeManifest = """
    {
      "plugin_id": "osaurus.example", "version": "1.0.0",
      "capabilities": {
        "routes": [{"id": "webhook", "path": "/webhook", "methods": ["POST"]}]
      }
    }
    """

final class ABIConformanceTests: XCTestCase {

    func testFullV1SurfacePasses() throws {
        try ABIConformance.assertPluginAPIConformance(fullAPI(version: 0))
        try ABIConformance.assertPluginAPIConformance(fullAPI(version: 2))
    }

    func testEachMissingRequiredCallbackIsReported() {
        let mutations: [(String, (inout OsrPluginAPI) -> Void)] = [
            ("free_string", { $0.free_string = nil }),
            ("init", { $0.`init` = nil }),
            ("destroy", { $0.destroy = nil }),
            ("get_manifest", { $0.get_manifest = nil }),
            ("invoke", { $0.invoke = nil }),
        ]
        for (name, mutate) in mutations {
            var api = fullAPI()
            mutate(&api)
            XCTAssertThrowsError(
                try ABIConformance.assertPluginAPIConformance(api),
                "nil \(name) must fail conformance"
            ) { error in
                XCTAssertTrue("\(error)".contains(name), "message should name '\(name)'")
            }
        }
    }

    func testNullEntryResultFails() {
        XCTAssertThrowsError(try ABIConformance.assertEntryConformance(nil))
    }

    func testEntryPointerVariantReadsTheTable() throws {
        var api = fullAPI()
        try withUnsafePointer(to: &api) { ptr in
            try ABIConformance.assertEntryConformance(UnsafeRawPointer(ptr))
        }

        var broken = fullAPI()
        broken.invoke = nil
        try withUnsafePointer(to: &broken) { ptr in
            XCTAssertThrowsError(
                try ABIConformance.assertEntryConformance(UnsafeRawPointer(ptr)))
        }
    }

    func testV2WithDeclaredRoutesRequiresHandleRoute() {
        // Declared route capability but no handle_route callback → fail.
        let api = fullAPI(version: 2)
        XCTAssertThrowsError(
            try ABIConformance.assertPluginAPIConformance(api, manifestJSON: routeManifest)
        ) { error in
            XCTAssertTrue("\(error)".contains("handle_route"))
        }
    }

    func testV2WithRoutesAndHandleRoutePasses() throws {
        var api = fullAPI(version: 2)
        api.handle_route = dummyHandleRoute
        try ABIConformance.assertPluginAPIConformance(api, manifestJSON: routeManifest)
    }

    func testV1PluginIsNotHeldToV2CapabilityChecks() throws {
        // version 0 (v1 plugin): declared routes cannot be honored anyway;
        // the v2 capability check must not apply.
        let api = fullAPI(version: 0)
        try ABIConformance.assertPluginAPIConformance(api, manifestJSON: routeManifest)
    }

    func testUnparseableManifestFailsWhenProvided() {
        XCTAssertThrowsError(
            try ABIConformance.assertPluginAPIConformance(
                fullAPI(version: 2), manifestJSON: "{broken"))
    }
}
