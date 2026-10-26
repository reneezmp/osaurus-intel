//
//  PluginLoaderAbiValidationTests.swift
//  OsaurusCoreTests
//
//  Intel: upstream #3079's slot checks (Sentry APPLE-MACOS-337) against
//  `IntelPluginLoader`, which replaces upstream's `PluginManager` loader. A
//  populated ABI slot must point at code in a loaded image, or the table is
//  rejected before `init` runs. Intel's `osaurus_plugin.h` predates
//  upstream's per-slot typedefs (`osr_free_string_t`, …), so slot types are
//  inferred from `osr_plugin_api`. Upstream's manifest and v1-prefix tests
//  in the same file exercise upstream's manifest model and are covered for
//  Intel by `IntelPluginSecretsTests`.
//

import Darwin
import Foundation
import Testing

@testable import OsaurusCore

struct PluginLoaderAbiValidationTests {

    private func completeAPI() -> osr_plugin_api {
        osr_plugin_api(
            free_string: { _ in },
            init: { nil },
            destroy: { _ in },
            get_manifest: { _ in nil },
            invoke: { _, _, _, _ in nil },
            version: 2,
            handle_route: nil,
            on_config_changed: nil,
            on_task_event: nil
        )
    }

    /// A C function-pointer value built from a raw integer, the way a
    /// struct-layout mismatch lands an int/bool field of the plugin's own
    /// struct in one of our function-pointer slots.
    private static func bogus<F>(_ value: UInt) -> F {
        unsafeBitCast(UnsafeRawPointer(bitPattern: value)!, to: F.self)
    }

    @Test func completeTableWithRealFunctionsPasses() {
        #expect(IntelPluginLoader.abiTableValidationFailure(completeAPI()) == nil)
    }

    @Test func freeStringSlotHoldingASmallIntegerIsRejected() throws {
        var api = completeAPI()
        api.free_string = Self.bogus(0x1)
        let msg = try #require(IntelPluginLoader.abiTableValidationFailure(api))
        #expect(msg.contains("free_string=0x1"))
        #expect(msg.contains("osaurus_plugin.h"))
    }

    @Test func secondLaunchValueIsRejectedToo() throws {
        var api = completeAPI()
        api.free_string = Self.bogus(0x2)
        let msg = try #require(IntelPluginLoader.abiTableValidationFailure(api))
        #expect(msg.contains("free_string=0x2"))
    }

    @Test func garbageInAnOptionalSlotIsRejected() throws {
        var api = completeAPI()
        api.on_task_event = Self.bogus(0xDEAD_BEEF)
        let msg = try #require(IntelPluginLoader.abiTableValidationFailure(api))
        #expect(msg.contains("on_task_event=0xdeadbeef"))
        #expect(!msg.contains("free_string"))
    }

    @Test func everyBadSlotIsNamed() throws {
        var api = completeAPI()
        api.destroy = Self.bogus(0x10)
        api.invoke = Self.bogus(0x20)
        api.handle_route = Self.bogus(0x30)
        let msg = try #require(IntelPluginLoader.abiTableValidationFailure(api))
        #expect(msg.contains("destroy=0x10"))
        #expect(msg.contains("invoke=0x20"))
        #expect(msg.contains("handle_route=0x30"))
    }

    @Test func realFunctionsInAnyLoadedImagePass() {
        // Plugin code and system library code both live in loaded images: a
        // plugin that sets free_string to libc's free() must still load.
        var api = completeAPI()
        api.free_string = unsafeBitCast(dlsym(dlopen(nil, RTLD_NOW), "free"), to: type(of: api.free_string))
        #expect(api.free_string != nil)
        #expect(IntelPluginLoader.abiTableValidationFailure(api) == nil)
        #expect(
            IntelPluginLoader.isCodePointerInLoadedImage(
                unsafeBitCast(api.free_string!, to: UnsafeRawPointer.self)))
        #expect(!IntelPluginLoader.isCodePointerInLoadedImage(UnsafeRawPointer(bitPattern: 0x1)!))
    }
}
