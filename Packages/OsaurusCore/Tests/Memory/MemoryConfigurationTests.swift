import Foundation
import Testing

@testable import OsaurusCore

@Suite("Memory configuration")
struct MemoryConfigurationTests {
    @Test func defaultValues() {
        let config = MemoryConfiguration()
        #expect(config.enabled)
        #expect(config.memoryBudgetTokens == 800)
        #expect(config.extractionMode == .sessionEnd)
        #expect(config.relevanceGateMode == .heuristic)
        #expect(config.salienceFloor == 0.2)
        #expect(config.episodeRetentionDays == 365)
        #expect(config.episodeMergeCosineThreshold == 0.9)
        #expect(config.consolidationIntervalHours == 24)
        #expect(config.distillationEnabledAgents.isEmpty)
    }

    @Test func decodesWithMissingKeys() throws {
        let data = Data(#"{"enabled": false}"#.utf8)
        let config = try JSONDecoder().decode(MemoryConfiguration.self, from: data)
        #expect(!config.enabled)
        #expect(config.memoryBudgetTokens == 800)
        #expect(config.episodeMergeCosineThreshold == 0.9)
        #expect(config.embeddingBackend == "mlx")
        #expect(config.distillationEnabledAgents.isEmpty)
    }

    @Test func roundTrips() throws {
        var config = MemoryConfiguration()
        config.memoryBudgetTokens = 1500
        config.salienceFloor = 0.35
        config.enabled = false
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MemoryConfiguration.self, from: data)
        #expect(decoded == config)
    }

    @Test func validationClampsBelowSupportedSliderMinimum() {
        var config = MemoryConfiguration()
        config.memoryBudgetTokens = -500
        config.summaryDebounceSeconds = -5
        config.salienceFloor = -1.0
        config.consolidationIntervalHours = -1
        config.episodeMergeCosineThreshold = -1.0
        let validated = config.validated()
        #expect(validated.memoryBudgetTokens == 100)
        #expect(validated.summaryDebounceSeconds == 10)
        #expect(validated.salienceFloor == 0.0)
        #expect(validated.consolidationIntervalHours == 1)
        #expect(validated.episodeMergeCosineThreshold == 0.5)
    }

    @Test func validationClampsExcessiveValues() {
        var config = MemoryConfiguration()
        config.memoryBudgetTokens = 999_999
        config.consolidationIntervalHours = 999_999
        config.episodeRetentionDays = 999_999
        config.episodeMergeCosineThreshold = 1.5
        let validated = config.validated()
        #expect(validated.memoryBudgetTokens == 4000)
        #expect(validated.consolidationIntervalHours == 168)
        #expect(validated.episodeRetentionDays == 3650)
        #expect(validated.episodeMergeCosineThreshold == 1.0)
    }
}
