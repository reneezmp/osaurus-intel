//
//  HarnessBinaryArchitecture.swift
//  osaurus
//
//  Intel-only addition (no upstream counterpart): whether a harness command can
//  run on this Mac. Intel Macs have no Rosetta, so an arm64-only `claude` or
//  `pi` copied from an Apple silicon Mac dies with "Bad CPU type in
//  executable" at launch. Reading the Mach-O header tells the Test button and
//  the launcher to say so up front instead. Scripts (`#!/usr/bin/env node`
//  npm installs) carry no architecture and are treated as runnable.
//

import Foundation

public enum HarnessBinaryArchitecture {
    /// The CPU this app runs on.
    public enum Host: String, Sendable, Equatable {
        case x86_64
        case arm64

        public static var current: Host {
            #if arch(arm64)
                return .arm64
            #else
                return .x86_64
            #endif
        }

        /// Whether a binary with `slices` can run here. An Intel Mac needs an
        /// x86_64 slice (no Rosetta). Apple silicon runs an arm64 slice, and
        /// an x86_64-only binary is assumed to run under Rosetta.
        func canRun(_ slices: [String]) -> Bool {
            switch self {
            case .x86_64: return slices.contains("x86_64")
            case .arm64: return slices.contains("arm64") || slices.contains("x86_64")
            }
        }
    }

    public enum Verdict: Sendable, Equatable {
        /// A Mach-O with a slice this Mac can run.
        case compatible(slices: [String])
        /// Not a Mach-O (a script, or unreadable): runnable as far as the
        /// header can tell.
        case notNative
        /// A Mach-O with no slice this Mac can run.
        case incompatible(slices: [String])

        public var isIncompatible: Bool {
            if case .incompatible = self { return true }
            return false
        }
    }

    // Mach-O constants (<mach-o/loader.h>, <mach-o/fat.h>).
    private static let cpuArchABI64: UInt32 = 0x0100_0000
    private static let cpuTypeX86: UInt32 = 7
    private static let cpuTypeARM: UInt32 = 12

    /// Classify the file at `path`. Symlinks are followed.
    public static func verdict(forFileAt path: String, host: Host = .current) -> Verdict {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let handle = FileHandle(forReadingAtPath: resolved) else { return .notNative }
        defer { try? handle.close() }
        // 8 + 32 * 16 covers the header of a fat file with up to 16 slices.
        guard let head = try? handle.read(upToCount: 520) else { return .notNative }
        return verdict(forHeader: head, host: host)
    }

    /// Classify a file by its first bytes.
    public static func verdict(forHeader head: Data, host: Host = .current) -> Verdict {
        guard let slices = slices(inHeader: head) else { return .notNative }
        return host.canRun(slices) ? .compatible(slices: slices) : .incompatible(slices: slices)
    }

    /// The architectures named in a Mach-O (thin or fat) header, or nil when
    /// the bytes are not a Mach-O.
    public static func slices(inHeader head: Data) -> [String]? {
        let bytes = [UInt8](head)
        guard bytes.count >= 8 else { return nil }
        func be32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            return bytes[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        func le32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            return bytes[offset..<offset + 4].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }

        // Thin, little-endian (every Mac CPU): MH_MAGIC / MH_MAGIC_64.
        if let magic = le32(0), magic == 0xFEED_FACE || magic == 0xFEED_FACF, let cpu = le32(4) {
            return [name(forCPUType: cpu)]
        }
        // Fat: FAT_MAGIC / FAT_MAGIC_64, big-endian. A Java class file shares
        // 0xCAFEBABE, so a count that no real fat file reaches is rejected.
        if let magic = be32(0), magic == 0xCAFE_BABE || magic == 0xCAFE_BABF, let count = be32(4),
            count >= 1, count <= 16
        {
            let entrySize = magic == 0xCAFE_BABF ? 32 : 20
            var found: [String] = []
            for index in 0..<Int(count) {
                guard let cpu = be32(8 + index * entrySize) else { break }
                found.append(name(forCPUType: cpu))
            }
            return found.isEmpty ? nil : found
        }
        return nil
    }

    private static func name(forCPUType cpu: UInt32) -> String {
        switch cpu {
        case cpuTypeX86 | cpuArchABI64: return "x86_64"
        case cpuTypeARM | cpuArchABI64: return "arm64"
        case cpuTypeX86: return "i386"
        case cpuTypeARM: return "arm"
        default: return "cpu-\(cpu)"
        }
    }

    /// The user-facing sentence for an Incompatible verdict.
    public static func incompatibleMessage(command: String, slices: [String], host: Host = .current) -> String {
        let found = slices.joined(separator: ", ")
        switch host {
        case .x86_64:
            return String(
                format: L(
                    "\"%@\" was built only for Apple silicon (%@) and this Intel Mac can't run it. Install a build for Intel (x86_64), or the npm version."
                ),
                command,
                found
            )
        case .arm64:
            return String(
                format: L("\"%@\" has no build this Mac can run (%@)."),
                command,
                found
            )
        }
    }
}
