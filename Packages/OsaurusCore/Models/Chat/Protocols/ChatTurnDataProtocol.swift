//
//  ChatTurnDataProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on ChatTurnData.
//

import Foundation

protocol ChatTurnDataProtocol: Sendable {
    init(from turn: any ChatTurnProtocol)
}
