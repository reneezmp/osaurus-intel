import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Intel Ventura rendering contracts")
struct IntelVenturaRenderingTests {
    @Test("Settings native controls stay in the light Aqua appearance")
    func settingsUsesAquaAppearance() {
        let light = IntelNativeWindowRendering.appearance(
            declaredDark: false, backgroundColor: .white)
        let darkAgent = IntelNativeWindowRendering.appearance(
            declaredDark: true, backgroundColor: .black)

        #expect(light?.name == .aqua)
        #expect(darkAgent?.name == .aqua)
    }

    @Test("Completed assistant turns emit statistics and actions")
    func completedAssistantFooter() {
        let turn = ChatTurn(role: .assistant, content: "Done.")
        turn.timeToFirstToken = 0.4
        turn.generationTokensPerSecond = 12.5
        turn.generationTokenCount = 20

        let blocks = BlockMemoizer().blocks(from: [turn], agentName: "Assistant")

        #expect(blocks.contains { if case .generationStats = $0.kind { true } else { false } })
        #expect(blocks.contains { if case .assistantActions = $0.kind { true } else { false } })
    }

    @Test("A restored token count alone still emits statistics")
    func restoredTokenCountFooter() {
        let turn = ChatTurn(role: .assistant, content: "Restored.")
        turn.generationTokenCount = 42

        let blocks = BlockMemoizer().blocks(from: [turn], agentName: "Assistant")

        #expect(blocks.contains { if case .generationStats = $0.kind { true } else { false } })
        #expect(blocks.contains { if case .assistantActions = $0.kind { true } else { false } })
    }

    @Test("Streaming assistant turns do not emit a footer")
    func streamingAssistantHasNoFooter() {
        let turn = ChatTurn(role: .assistant, content: "Still writing")
        turn.generationTokenCount = 3

        let blocks = BlockMemoizer().blocks(
            from: [turn],
            streamingTurnId: turn.id,
            agentName: "Assistant"
        )

        #expect(!blocks.contains { if case .generationStats = $0.kind { true } else { false } })
        #expect(!blocks.contains { if case .assistantActions = $0.kind { true } else { false } })
    }
}
