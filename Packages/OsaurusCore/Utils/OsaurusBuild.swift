//
//  OsaurusBuild.swift
//  OsaurusCore
//
//  Intel fork — build-time platform detection.
//

public enum OsaurusBuild {
#if OSAURUS_INTEL
    public static let isIntel = true
#else
    public static let isIntel = false
#endif
}
