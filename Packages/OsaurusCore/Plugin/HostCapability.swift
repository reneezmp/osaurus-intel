//
//  HostCapability.swift
//  OsaurusCore
//
//  M9: Capability-aware plugin loading — vocabulary + registry.
//

import Foundation

/// Known host capabilities that plugins can declare as required or optional.
public enum HostCapability: String, CaseIterable, Sendable {
    /// Plugin can make outbound HTTP calls via the host's HTTP service.
    case http
    /// Per-plugin SQLite database access.
    case sqlite
    /// Keychain-backed configuration storage.
    case config
    /// Structured and level-based logging.
    case logging
    /// Schedule tasks via the host's task dispatcher.
    case dispatch
    /// Sandboxed file I/O through the host.
    case fileIO = "file_io"

    // MARK: Apple Silicon only
    /// Run local LLM inference via MLX.
    case mlxInference = "mlx_inference"
    /// Use the host's VecturaKit-backed vector store.
    case vectorStorage = "vector_storage"
    /// FluidAudio-based voice transcription.
    case voiceTranscription = "voice_transcription"
    /// FluidAudio-based text-to-speech.
    case voiceTTS = "voice_tts"
    /// Run code in the Containerization sandbox VM.
    case sandboxExecution = "sandbox_execution"
    /// Read and manipulate the host's model catalog.
    case modelPicker = "model_picker"
}

/// Declares which host capabilities the current Osaurus build supports.
public enum OsaurusHostCapabilities {
    public static let supported: Set<String> = {
        var caps: Set<String> = [
            HostCapability.http.rawValue,
            HostCapability.sqlite.rawValue,
            HostCapability.config.rawValue,
            HostCapability.logging.rawValue,
            HostCapability.dispatch.rawValue,
            HostCapability.fileIO.rawValue,
        ]
#if !OSAURUS_INTEL
        caps.formUnion([
            HostCapability.mlxInference.rawValue,
            HostCapability.vectorStorage.rawValue,
            HostCapability.voiceTranscription.rawValue,
            HostCapability.voiceTTS.rawValue,
            HostCapability.sandboxExecution.rawValue,
            HostCapability.modelPicker.rawValue,
        ])
#endif
        return caps
    }()
}
