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

    @Test("Settings unified chrome installs the shared visible traffic lights")
    func settingsUsesUnifiedToolbarChrome() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        let delegate = IntelManagementToolbarDelegate()
        IntelNativeWindowRendering.configureUnifiedTitlebar(
            in: window,
            toolbarIdentifier: "IntelManagementToolbarTests",
            delegate: delegate
        )

        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titlebarSeparatorStyle == .none)
        #expect(window.toolbar != nil)
        #expect(window.toolbar?.delegate === delegate)
        #expect(
            window.toolbar?.items.contains {
                $0.itemIdentifier == IntelManagementToolbarDelegate.chromeAnchor
                    && ($0.view?.frame.height ?? 0) > 0
            } == true
        )
        #expect(window.toolbar?.items.contains { $0.itemIdentifier == .flexibleSpace } == true)
        #expect(window.toolbarStyle == .unified)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        #expect(window.standardWindowButton(.zoomButton)?.isHidden == true)
        #expect(window.titlebarAccessoryViewControllers.isEmpty)
        #expect(
            window.contentView?.subviews.contains {
                $0.identifier == IntelTrafficLightStripView.viewIdentifier
            } == false
        )
        let nativeClose = window.standardWindowButton(.closeButton)
        let frameRoot = window.contentView?.superview
        let strip = IntelNativeWindowRendering.managementTrafficLightStrip(in: window)
        #expect(strip?.subviews.count == 3)
        #expect(strip?.superview === frameRoot)
        #expect(
            nativeClose?.superview?.subviews.contains {
                $0.identifier == IntelTrafficLightStripView.viewIdentifier
            } == false
        )
    }

    @Test("Settings lifecycle restores a discarded titlebar strip")
    func settingsLifecycleRestoresDiscardedStrip() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let delegate = IntelManagementToolbarDelegate()
        IntelNativeWindowRendering.configureUnifiedTitlebar(
            in: window,
            toolbarIdentifier: "IntelManagementLifecycleTests",
            delegate: delegate
        )
        let lifecycle = IntelManagementWindowLifecycle(window: window)
        let frameRoot = window.contentView?.superview
        let original = IntelNativeWindowRendering.managementTrafficLightStrip(in: window)
        #expect(original != nil)

        original?.removeFromSuperview()
        #expect(
            frameRoot?.subviews.contains {
                $0.identifier == IntelTrafficLightStripView.viewIdentifier
            } == false
        )

        lifecycle.repairNow(reason: "test-invalidated-attachment")

        let restored = IntelNativeWindowRendering.managementTrafficLightStrip(in: window)
        #expect(restored != nil)
        #expect(restored !== original)
        #expect(restored?.subviews.count == 3)
        #expect(restored?.superview === frameRoot)
    }

    @Test("Core Model menu always owns a visible selection title")
    func coreModelSelectionTitle() {
        let item = ModelPickerItem(
            id: "deepseek/deepseek-chat",
            displayName: "deepseek-chat",
            source: .remote(providerName: "DeepSeek", providerId: UUID())
        )

        #expect(
            CoreModelSelectionPresentation.title(identifier: "", items: [item])
                == "Use chat model (default)"
        )
        #expect(
            CoreModelSelectionPresentation.title(
                identifier: "deepseek/deepseek-chat", items: [item])
                == "deepseek-chat"
        )
        #expect(
            CoreModelSelectionPresentation.title(identifier: "missing/model", items: [item])
                == "missing/model (unavailable)"
        )
    }

    @Test("Knowledge deletion waits behind the shared confirmation")
    func knowledgeDeletionRequiresConfirmation() {
        var deleted = false
        KnowledgeDeleteConfirmation.present(collectionName: "Recipes") {
            deleted = true
        }

        #expect(!deleted)
        let request = ThemedAlertCenter.shared.active(for: .management)
        #expect(request?.title == "Delete \"Recipes\"?")
        #expect(request?.buttons.contains { $0.title == "Cancel" } == true)

        request?.buttons.first { $0.title == "Delete Collection" }?.action()
        #expect(deleted)
        if let request {
            ThemedAlertCenter.shared.dismiss(scope: .management, id: request.id)
        }
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
