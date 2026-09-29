//
//  FileOperation.swift
//  osaurus
//
//  Models for tracking folder-tool file operations for undo capability.
//

import Foundation

// MARK: - Operation Type

/// Type of file operation performed by folder tools.
public enum FileOperationType: String, Codable, Sendable {
    case create  // New file created
    case write  // Existing file modified
    case fileEdit  // File modified by file_edit (targeted in-place replace)
    case move  // File/directory moved
    case copy  // File/directory copied
    case delete  // File/directory deleted
    case dirCreate  // New directory created
}

// MARK: - File Operation

/// A recorded file operation that can be undone.
/// How `FileOperation.previousContent` is stored (upstream #91). `utf8` is
/// the plain text body (historical default); `base64` carries arbitrary
/// bytes so an overwritten binary document restores exactly on undo.
public enum FileOperationContentEncoding: String, Codable, Sendable {
    case utf8
    case base64
}

public struct FileOperation: Codable, Sendable, Identifiable {
    public let id: UUID
    public let type: FileOperationType
    public let path: String  // Relative path from root
    public let destinationPath: String?  // For move/copy operations
    public let previousContent: String?  // For write/delete (to restore)
    /// Encoding of `previousContent`; absent (older entries) means `.utf8`.
    public let previousContentEncoding: FileOperationContentEncoding?
    public let timestamp: Date
    /// Owning chat session id (used to scope undo per conversation).
    public let sessionId: String
    public let batchId: UUID?  // For batch operations (nil for non-batch)

    public init(
        id: UUID = UUID(),
        type: FileOperationType,
        path: String,
        destinationPath: String? = nil,
        previousContent: String? = nil,
        previousContentEncoding: FileOperationContentEncoding? = nil,
        timestamp: Date = Date(),
        sessionId: String,
        batchId: UUID? = nil
    ) {
        self.id = id
        self.type = type
        self.path = path
        self.destinationPath = destinationPath
        self.previousContent = previousContent
        self.previousContentEncoding = previousContentEncoding
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.batchId = batchId
    }
}

// MARK: - Display Helpers

extension FileOperationType {
    /// SF Symbol for this operation type
    public var iconName: String {
        switch self {
        case .create: return "doc.badge.plus"
        case .write: return "pencil"
        case .fileEdit: return "pencil.line"
        case .move: return "arrow.right"
        case .copy: return "doc.on.doc"
        case .delete: return "trash"
        case .dirCreate: return "folder.badge.plus"
        }
    }

    /// Human-readable description
    public var displayName: String {
        switch self {
        case .create: return "Created"
        case .write: return "Modified"
        case .fileEdit: return "Edited"
        case .move: return "Moved"
        case .copy: return "Copied"
        case .delete: return "Deleted"
        case .dirCreate: return "Created folder"
        }
    }
}

extension FileOperation {
    /// `previousContent` fields for arbitrary bytes: UTF-8 text stays
    /// readable in history; anything else is base64.
    public static func encodePreviousContent(_ data: Data?) -> (
        content: String?, encoding: FileOperationContentEncoding?
    ) {
        guard let data else { return (nil, nil) }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        return (data.base64EncodedString(), .base64)
    }

    /// Bytes to restore on undo, honouring the stored encoding.
    public var previousContentData: Data? {
        guard let previousContent else { return nil }
        switch previousContentEncoding ?? .utf8 {
        case .utf8: return previousContent.data(using: .utf8)
        case .base64: return Data(base64Encoded: previousContent)
        }
    }

    /// Display filename (last path component)
    public var filename: String {
        (path as NSString).lastPathComponent
    }

    /// Display path for destination (for move/copy)
    public var destinationFilename: String? {
        destinationPath.map { ($0 as NSString).lastPathComponent }
    }
}
