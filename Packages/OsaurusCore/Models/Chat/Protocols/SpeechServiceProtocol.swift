//
//  SpeechServiceProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on SpeechService.
//

import Foundation

protocol SpeechServiceProtocol: AnyObject {
    var isRecording: Bool { get }
    func stopStreamingTranscription() async
    func clearTranscription()
}
