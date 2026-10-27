//
//  VolumeFreeSpaceTests.swift
//  osaurusTests
//
//  Upstream #3217's free-space tests. Upstream keeps them in
//  `ModelDownloadServiceStorageTests`, which Intel's test target excludes
//  (it covers local model downloads); on Intel the figure feeds the
//  menu-bar panel's storage reading (`SystemMonitorService`).
//

import Foundation
import os
import Testing

@testable import OsaurusCore

struct VolumeFreeSpaceTests {
    @Test func purgeableInclusiveCapacityWinsOverStrictFreeSpace() {
        // The reported 8 TB Mac: strict free 18 GB, System Settings 1.44 TB.
        let strict: Int64 = 18_000_000_000
        let important: Int64 = 1_440_000_000_000
        let bytes = OsaurusPaths.resolvedVolumeFreeBytes(
            importantCapacity: important,
            legacyFree: strict
        )
        #expect(bytes == important)
    }

    @Test func strictFreeSpaceWinsWhenTheImportantCapacityIsSmaller() {
        let strict: Int64 = 512 * 1024 * 1024 * 1024
        let important: Int64 = 100 * 1024 * 1024 * 1024
        let bytes = OsaurusPaths.resolvedVolumeFreeBytes(
            importantCapacity: important,
            legacyFree: strict
        )
        #expect(bytes == strict)
    }

    @Test func positiveStrictFreeSpaceIsUsedBeforeTheCacheHasAValue() {
        let strict: Int64 = 18_000_000_000
        #expect(OsaurusPaths.resolvedVolumeFreeBytes(importantCapacity: nil, legacyFree: strict) == strict)
    }
}

struct VolumeAvailableCapacityCacheTests {
    @Test func cachedBytesNeverWaitsForTheCapacityQuery() async throws {
        // CacheDelete can stall the important-usage query for minutes; the
        // caller must get the last value immediately and the refresh must
        // happen in the background.
        let cache = VolumeAvailableCapacityCache(query: { _ in
            Thread.sleep(forTimeInterval: 1.0)
            return 1_440_000_000_000
        })
        let path = NSTemporaryDirectory()
        let start = Date()
        #expect(cache.cachedBytes(forPath: path) == nil)
        #expect(Date().timeIntervalSince(start) < 0.5)

        var value: Int64?
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            value = cache.cachedBytes(forPath: path)
            if value != nil { break }
        }
        #expect(value == 1_440_000_000_000)
    }

    @Test func aFailedRefreshKeepsTheLastGoodValue() {
        let answers = OSAllocatedUnfairLock<[Int64?]>(initialState: [1_000, nil])
        let cache = VolumeAvailableCapacityCache(maxAge: 0, query: { _ in
            answers.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        })
        let path = NSTemporaryDirectory()
        cache.refreshNow(forPath: path)
        cache.refreshNow(forPath: path)
        #expect(cache.cachedBytes(forPath: path) == 1_000)
    }

    @Test func pathsOnOneVolumeShareAnEntry() {
        let tmp = NSTemporaryDirectory()
        let nested = (tmp as NSString).appendingPathComponent(".")
        #expect(
            VolumeAvailableCapacityCache.volumeKey(forPath: tmp)
                == VolumeAvailableCapacityCache.volumeKey(forPath: nested)
        )
        #expect(VolumeAvailableCapacityCache.volumeKey(forPath: "/").hasPrefix("/"))
    }
}
