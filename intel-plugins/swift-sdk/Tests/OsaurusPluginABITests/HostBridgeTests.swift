//
//  HostBridgeTests.swift
//
//  Exercises the defensive `host.version >= N && slot != nil` gating and
//  the string-ownership paths of `HostBridge` against fake host tables.
//  `@convention(c)` trampolines cannot capture Swift state, so they write
//  into a file-scope recorder that each test resets.
//

import XCTest

@testable import OsaurusPluginABI

// MARK: - File-scope recorder for C trampolines

final class HostRecorder {
    static let shared = HostRecorder()
    private let lock = NSLock()

    private var _configValues: [String: String] = [:]
    private var _configSets: [(String, String)] = []
    private var _configDeletes: [String] = []
    private var _logs: [(Int32, String)] = []
    private var _structuredLogs: [(Int32, String, String?)] = []
    private var _agentId: String?
    private var _hostFreeCount = 0

    func reset(configValues: [String: String] = [:], agentId: String? = nil) {
        lock.lock()
        _configValues = configValues
        _configSets = []
        _configDeletes = []
        _logs = []
        _structuredLogs = []
        _agentId = agentId
        _hostFreeCount = 0
        lock.unlock()
    }

    func configValue(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return _configValues[key] }
    func recordSet(_ key: String, _ value: String) { lock.lock(); _configSets.append((key, value)); lock.unlock() }
    func recordDelete(_ key: String) { lock.lock(); _configDeletes.append(key); lock.unlock() }
    func recordLog(_ level: Int32, _ msg: String) { lock.lock(); _logs.append((level, msg)); lock.unlock() }
    func recordStructured(_ level: Int32, _ msg: String, _ payload: String?) {
        lock.lock(); _structuredLogs.append((level, msg, payload)); lock.unlock()
    }
    func recordHostFree() { lock.lock(); _hostFreeCount += 1; lock.unlock() }

    var configSets: [(String, String)] { lock.lock(); defer { lock.unlock() }; return _configSets }
    var configDeletes: [String] { lock.lock(); defer { lock.unlock() }; return _configDeletes }
    var logs: [(Int32, String)] { lock.lock(); defer { lock.unlock() }; return _logs }
    var structuredLogs: [(Int32, String, String?)] { lock.lock(); defer { lock.unlock() }; return _structuredLogs }
    var agentId: String? { lock.lock(); defer { lock.unlock() }; return _agentId }
    var hostFreeCount: Int { lock.lock(); defer { lock.unlock() }; return _hostFreeCount }
}

private let trampConfigGet: OsrConfigGetFn = { keyPtr in
    guard let keyPtr else { return nil }
    guard let value = HostRecorder.shared.configValue(String(cString: keyPtr)) else { return nil }
    return osrMakeCString(value)
}
private let trampConfigSet: OsrConfigSetFn = { keyPtr, valuePtr in
    guard let keyPtr, let valuePtr else { return }
    HostRecorder.shared.recordSet(String(cString: keyPtr), String(cString: valuePtr))
}
private let trampConfigDelete: OsrConfigDeleteFn = { keyPtr in
    guard let keyPtr else { return }
    HostRecorder.shared.recordDelete(String(cString: keyPtr))
}
private let trampLog: OsrLogFn = { level, msgPtr in
    guard let msgPtr else { return }
    HostRecorder.shared.recordLog(level, String(cString: msgPtr))
}
private let trampLogStructured: OsrLogStructuredFn = { level, msgPtr, payloadPtr in
    guard let msgPtr else { return }
    HostRecorder.shared.recordStructured(
        level, String(cString: msgPtr), payloadPtr.map { String(cString: $0) })
}
private let trampGetActiveAgentId: OsrGetActiveAgentIdFn = {
    guard let id = HostRecorder.shared.agentId else { return nil }
    return osrMakeCString(id)
}
private let trampHostFreeString: OsrHostFreeStringFn = { ptr in
    guard let ptr else { return }
    HostRecorder.shared.recordHostFree()
    free(UnsafeMutableRawPointer(mutating: ptr))
}

private func makeFullHost(version: UInt32) -> OsrHostAPI {
    OsrHostAPI(
        version: version,
        config_get: trampConfigGet,
        config_set: trampConfigSet,
        config_delete: trampConfigDelete,
        log: trampLog,
        get_active_agent_id: trampGetActiveAgentId,
        log_structured: trampLogStructured,
        free_string: trampHostFreeString
    )
}

private func withHostBridge<R>(_ api: OsrHostAPI, _ body: (HostBridge) throws -> R) rethrows -> R {
    var api = api
    return try withUnsafePointer(to: &api) { ptr in
        try body(HostBridge(host: ptr))
    }
}

// MARK: - Tests

final class HostBridgeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HostRecorder.shared.reset()
    }

    func testUninstalledBridgeIsSafeNoOp() {
        let bridge = HostBridge()
        XCTAssertFalse(bridge.isInstalled)
        XCTAssertEqual(bridge.hostVersion, 0)
        XCTAssertNil(bridge.configGet("k"))
        bridge.configSet("k", "v")
        bridge.configDelete("k")
        bridge.log(OsrLogLevel.info, "message")
        bridge.logStructured(OsrLogLevel.info, "message", payload: "{}")
        XCTAssertNil(bridge.activeAgentId())
        bridge.hostFree(nil)
    }

    func testConfigGetCopiesAndFreesThroughHostFreeString() {
        HostRecorder.shared.reset(configValues: ["token": "secret"])
        withHostBridge(makeFullHost(version: 6)) { bridge in
            XCTAssertTrue(bridge.isInstalled)
            XCTAssertEqual(bridge.hostVersion, 6)
            XCTAssertEqual(bridge.configGet("token"), "secret")
            XCTAssertNil(bridge.configGet("missing"))
            // The returned string was released via host->free_string (v6).
            XCTAssertEqual(HostRecorder.shared.hostFreeCount, 1)
        }
    }

    func testConfigGetPreservesEmptyStringValue() {
        // Empty string is a real value per the header — must NOT be
        // coerced to nil.
        HostRecorder.shared.reset(configValues: ["tunnel_url": ""])
        withHostBridge(makeFullHost(version: 6)) { bridge in
            XCTAssertEqual(bridge.configGet("tunnel_url"), "")
        }
    }

    func testConfigSetAndDeleteForwarded() {
        withHostBridge(makeFullHost(version: 6)) { bridge in
            bridge.configSet("a", "1")
            bridge.configDelete("b")
        }
        XCTAssertEqual(HostRecorder.shared.configSets.count, 1)
        XCTAssertEqual(HostRecorder.shared.configSets[0].0, "a")
        XCTAssertEqual(HostRecorder.shared.configSets[0].1, "1")
        XCTAssertEqual(HostRecorder.shared.configDeletes, ["b"])
    }

    func testLogForwarded() {
        withHostBridge(makeFullHost(version: 6)) { bridge in
            bridge.log(OsrLogLevel.warn, "careful")
        }
        XCTAssertEqual(HostRecorder.shared.logs.count, 1)
        XCTAssertEqual(HostRecorder.shared.logs[0].0, OsrLogLevel.warn)
        XCTAssertEqual(HostRecorder.shared.logs[0].1, "careful")
    }

    func testLogStructuredUsesSlotOnV5Plus() {
        withHostBridge(makeFullHost(version: 6)) { bridge in
            bridge.logStructured(OsrLogLevel.info, "event", payload: "{\"k\":1}")
            bridge.logStructured(OsrLogLevel.info, "bare", payload: nil)
        }
        XCTAssertEqual(HostRecorder.shared.structuredLogs.count, 2)
        XCTAssertEqual(HostRecorder.shared.structuredLogs[0].1, "event")
        XCTAssertEqual(HostRecorder.shared.structuredLogs[0].2, "{\"k\":1}")
        XCTAssertNil(HostRecorder.shared.structuredLogs[1].2)
        XCTAssertTrue(HostRecorder.shared.logs.isEmpty)
    }

    func testLogStructuredFallsBackToPlainLogBelowV5() {
        // Host advertises v4: even though the slot happens to be populated
        // in this fake, the version gate must route to plain `log`.
        withHostBridge(makeFullHost(version: 4)) { bridge in
            bridge.logStructured(OsrLogLevel.error, "oauth_failed", payload: "{\"retry\":3}")
        }
        XCTAssertTrue(HostRecorder.shared.structuredLogs.isEmpty)
        XCTAssertEqual(HostRecorder.shared.logs.count, 1)
        XCTAssertEqual(HostRecorder.shared.logs[0].1, "oauth_failed {\"retry\":3}")
    }

    func testLogStructuredFallsBackWhenSlotIsNil() {
        var api = makeFullHost(version: 6)
        api.log_structured = nil
        withHostBridge(api) { bridge in
            bridge.logStructured(OsrLogLevel.info, "event", payload: nil)
        }
        XCTAssertEqual(HostRecorder.shared.logs.map { $0.1 }, ["event"])
    }

    func testActiveAgentIdGatedOnV4() {
        HostRecorder.shared.reset(agentId: "AGENT-UUID-1234")

        withHostBridge(makeFullHost(version: 6)) { bridge in
            XCTAssertEqual(bridge.activeAgentId(), "AGENT-UUID-1234")
        }
        // v3 host: slot populated in the fake, but version gate wins.
        withHostBridge(makeFullHost(version: 3)) { bridge in
            XCTAssertNil(bridge.activeAgentId())
        }
        // v4 host, no agent frame: NULL comes back as nil.
        HostRecorder.shared.reset(agentId: nil)
        withHostBridge(makeFullHost(version: 4)) { bridge in
            XCTAssertNil(bridge.activeAgentId())
        }
    }

    func testHostFreeUsesHostSlotOnV6() {
        withHostBridge(makeFullHost(version: 6)) { bridge in
            bridge.hostFree(osrMakeCString("owned-by-host"))
        }
        XCTAssertEqual(HostRecorder.shared.hostFreeCount, 1)
    }

    func testHostFreeFallsBackToLibcFreeBelowV6() {
        // v5 host with a nil free_string slot: hostFree must call plain
        // libc free() and never touch the recorder.
        var api = makeFullHost(version: 5)
        api.free_string = nil
        withHostBridge(api) { bridge in
            bridge.hostFree(osrMakeCString("freed-via-libc"))
            bridge.hostFree(nil)  // no-op
        }
        XCTAssertEqual(HostRecorder.shared.hostFreeCount, 0)
    }

    func testInstallNilUninstalls() {
        withHostBridge(makeFullHost(version: 6)) { bridge in
            XCTAssertTrue(bridge.isInstalled)
            bridge.install(nil)
            XCTAssertFalse(bridge.isInstalled)
            XCTAssertNil(bridge.configGet("token"))
        }
    }
}
