//
//  AppRecipeTests.swift
//  OsaurusCoreTests — Computer Use
//
//  PR3 coverage for per-app recipes: matcher resolution (universal + named),
//  the merged `RecipeSignals`, and — the point of the feature — that those
//  signals refine `EffectClassifier` so app-specific prompts ("Leave Site",
//  "Don't Save", "Clear browsing data") escalate to `consequential` where the
//  app-agnostic vocabulary alone would let them through as a plain navigate.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Matching + signal merge

@Suite struct AppRecipeTests {
    @Test func testUniversalDialogAppliesEverywhere() {
        #expect(AppRecipes.matching(app: "Notes").contains { $0.id == "dialog" })
        #expect(AppRecipes.matching(app: nil).contains { $0.id == "dialog" })
        // A named recipe never applies to an unrelated app.
        #expect(!(AppRecipes.matching(app: "Notes").contains { $0.id == "safari" }))
    }

    @Test func testNamedRecipeMatchesByNameFragment() {
        let safari = AppRecipes.matching(app: "Safari").map(\.id)
        #expect(Set(safari) == ["dialog", "safari"])

        let chrome = AppRecipes.matching(app: "Google Chrome").map(\.id)
        #expect(Set(chrome) == ["dialog", "chromium"])

        let textEdit = AppRecipes.matching(app: "TextEdit").map(\.id)
        #expect(Set(textEdit) == ["dialog", "textedit"])
    }

    @Test func testSignalsMergeUniversalAndNamed() {
        let safari = AppRecipes.signals(for: "Safari")
        #expect(safari.consequential.contains("leave site"))  // safari
        #expect(safari.consequential.contains("don't save"))  // dialog (universal)

        let chrome = AppRecipes.signals(for: "Google Chrome")
        #expect(chrome.consequential.contains("clear browsing data"))

        // No app ⇒ only the universal dialog signals.
        let none = AppRecipes.signals(for: nil)
        #expect(none.consequential.contains("discard"))
        #expect(!(none.consequential.contains("leave site")))
    }

    @Test func testFlowsExposeForMatchedApps() {
        #expect(!(AppRecipes.flows(for: "Safari").isEmpty))
    }

    @Test func testGuidanceTextRendersFlowsForApp() {
        guard let safari = AppRecipes.guidanceText(for: "Safari") else {
            Issue.record("expected guidance text for Safari"); return
        }
        #expect(safari.hasPrefix("Hints for Safari:"))
        #expect(safari.contains("Navigate to a URL"))
        #expect(safari.lowercased().contains("address bar"))
        // Steps are joined into an ordered hint with arrows.
        #expect(safari.contains("->"))
    }

    @Test func testTextEditGuidanceStopsAfterOneReplacementWithoutImplicitSave() {
        guard let text = AppRecipes.guidanceText(for: "TextEdit") else {
            Issue.record("expected TextEdit guidance"); return
        }
        #expect(text.contains("Create a blank document"))
        #expect(text.contains("click New Document"))
        #expect(text.contains("without typing example or placeholder text"))
        #expect(text.contains("Use set_value once"))
        #expect(text.contains("finish with done"))
        #expect(text.contains("Do not save"))
    }

    @Test func testGuidanceTextFallsBackToUniversalDialog() {
        // Even an app with no named recipe matches the universal dialog (which
        // carries a flow), so guidance is still produced.
        guard let text = AppRecipes.guidanceText(for: nil) else {
            Issue.record("expected universal dialog guidance"); return
        }
        #expect(text.contains("Save dialog"))
    }
}

// MARK: - Recipe-refined classification

@Suite struct RecipeClassifierTests {
    private func click(_ describe: String) -> AgentAction {
        AgentAction(verb: .click, target: AgentTarget(describe: describe))
    }

    @Test func testSafariLeaveSiteNeedsRecipeToEscalate() {
        let action = click("Leave Site")
        // App-agnostic vocabulary doesn't know "Leave Site" — stays navigate.
        #expect(EffectClassifier.classify(
                action: action,
                resolvedRole: "AXButton",
                resolvedLabel: "Leave Site",
                appName: "Safari"
            ) == .navigate)
        // With the Safari recipe merged in, it escalates.
        #expect(EffectClassifier.classify(
                action: action,
                resolvedRole: "AXButton",
                resolvedLabel: "Leave Site",
                appName: "Safari",
                recipeSignals: AppRecipes.signals(for: "Safari")
            ) == .consequential)
    }

    @Test func testDialogDontSaveEscalatesViaUniversalRecipe() {
        let action = click("Don't Save")
        // App-agnostic vocabulary now treats the bare commit token ("save") as
        // an `edit` (so it confirms under balanced rather than auto-running),
        // but it does NOT know "Don't Save" discards work — that stays edit.
        #expect(EffectClassifier.classify(
                action: action,
                resolvedRole: "AXButton",
                resolvedLabel: "Don't Save",
                appName: "Notes"
            ) == .edit)
        // The universal dialog recipe is what recognizes "Don't Save" as a
        // discard and escalates it the rest of the way to consequential.
        #expect(EffectClassifier.classify(
                action: action,
                resolvedRole: "AXButton",
                resolvedLabel: "Don't Save",
                appName: "Notes",
                recipeSignals: AppRecipes.signals(for: "Notes")
            ) == .consequential)
    }

    @Test func testChromeClearBrowsingDataEscalatesWithRecipe() {
        let action = click("Clear browsing data")
        #expect(EffectClassifier.classify(
                action: action,
                resolvedRole: "AXButton",
                resolvedLabel: "Clear browsing data",
                appName: "Google Chrome",
                recipeSignals: AppRecipes.signals(for: "Google Chrome")
            ) == .consequential)
    }

    @Test func testRecipeStillCannotLowerBaseline() {
        // A benign edit in Safari stays at least edit even with recipe signals.
        let action = AgentAction(verb: .type, target: AgentTarget(mark: 1), text: "hello")
        let effect = EffectClassifier.classify(
            action: action,
            resolvedRole: "AXTextField",
            resolvedLabel: "Address",
            appName: "Safari",
            recipeSignals: AppRecipes.signals(for: "Safari")
        )
        #expect(effect >= .edit)
    }

    /// Finder guidance must reach the model whole: the universal dialog flow
    /// takes the first of the three rendered slots, so Finder keeps two.
    @Test func testFinderGuidanceWarnsReturnRenamesAndKeepsFolderFlow() {
        let matched = AppRecipes.matching(app: "Finder").map(\.id)
        #expect(Set(matched) == ["dialog", "finder"])
        guard let text = AppRecipes.guidanceText(for: "Finder") else {
            Issue.record("Finder should render guidance"); return
        }
        #expect(text.contains("Go to a folder or open an item"))
        #expect(text.contains("Create a folder and move files into it"))
        #expect(text.contains("return RENAMES"))
        #expect(text.contains("open with the folder path"))
        #expect(text.contains("cmd+option+v"), "moves should use paste-move, not drag")
        #expect(AppRecipes.signals(for: "Finder").consequential.contains("empty trash"))
    }
}
