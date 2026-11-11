//
//  IntelHostReclaimableMemoryTests.swift
//  osaurusTests
//
//  The system monitor's RAM gauge counts reclaimable memory from disjoint page
//  classes (free, file-backed, purgeable, speculative), upstream #3306.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelHostReclaimableMemoryTests {
    private func bytes(
        physical: Int64 = 1 << 30, page: Int64 = 4096, free: Int64, file: Int64,
        purgeable: Int64, speculative: Int64
    ) -> Int64 {
        ResourceSampler.reclaimableMemoryBytes(
            physicalBytes: physical, pageSize: page, freePages: free,
            fileBackedPages: file, purgeablePages: purgeable, speculativePages: speculative)
    }

    @Test func countsDisjointClassesAndSubtractsSpeculativeOverlapOnce() {
        // free 100 (40 of them speculative) + file-backed 200 + purgeable 10.
        #expect(bytes(free: 100, file: 200, purgeable: 10, speculative: 40) == (60 + 200 + 10) * 4096)
    }

    @Test func malformedOrOverflowingSnapshotsReportNothingReclaimable() {
        let invalid: [(Int64, Int64, Int64, Int64, Int64, Int64)] = [
            (0, 4096, 1, 0, 0, 0),
            (16384, 0, 1, 0, 0, 0),
            (16384, 4096, -1, 0, 0, 0),
            (16384, 4096, 1, -1, 0, 0),
            (16384, 4096, 1, 0, -1, 0),
            (16384, 4096, 1, 0, 0, -1),
            (16384, 4096, 0, 1, 0, 1),  // speculative exceeds free
            (Int64.max, 1, Int64.max, 1, 0, 0),
            (Int64.max, Int64.max, 2, 0, 0, 0),
            (16384, 4096, 5, 0, 0, 0),  // more than physical
        ]
        for row in invalid {
            #expect(
                ResourceSampler.reclaimableMemoryBytes(
                    physicalBytes: row.0, pageSize: row.1, freePages: row.2,
                    fileBackedPages: row.3, purgeablePages: row.4, speculativePages: row.5) == 0)
        }
    }
}
