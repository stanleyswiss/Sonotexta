import Testing
import Foundation
import Security
@testable import Sonotexta

/// In-memory engine selection so tests never touch AppSettings.shared (the
/// test host shares the installed app's bundle id and UserDefaults domain).
private final class FakeEngineStore: OpenSourceMigrationEngineStore {
    var selectedEngine: STTEngineType
    var profiles: [Profile]
    init(selectedEngine: STTEngineType, profiles: [Profile] = []) {
        self.selectedEngine = selectedEngine
        self.profiles = profiles
    }
}

private final class MigrationFixture {
    let suiteName = "Sonotexta-test-\(UUID().uuidString)"
    let defaults: UserDefaults
    let root: URL
    let trialURL: URL
    var deletedAccounts: [String] = []

    init() throws {
        defaults = UserDefaults(suiteName: suiteName)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        trialURL = root.appendingPathComponent(".trial")
    }
    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func run(store: OpenSourceMigrationEngineStore, keys: Set<STTEngineType> = [], aiKeyMissing: Bool = false) -> Bool {
        OpenSourceMigration.runIfNeeded(
            defaults: defaults,
            store: store,
            hasKey: { keys.contains($0) },
            aiKeyMissing: { aiKeyMissing },
            deleteKeychainAccount: { [unowned self] account in
                deletedAccounts.append(account)
                return errSecItemNotFound
            },
            trialBackupURL: trialURL
        )
    }
}

struct OpenSourceMigrationTests {
    @Test(arguments: [STTEngineType.openAIRealtime, .deepgram, .elevenLabsScribe])
    func cloudEngineWithoutKeyFallsBackToAppleSpeech(engine: STTEngineType) {
        #expect(OpenSourceMigration.fallbackEngine(engine, hasKey: { _ in false }) == .appleSpeech)
        #expect(OpenSourceMigration.fallbackEngine(engine, hasKey: { _ in true }) == engine)
    }

    @Test(arguments: [STTEngineType.appleSpeech, .whisper, .parakeet, .parakeetRealtime, .qwen])
    func localEnginesAreNeverChanged(engine: STTEngineType) {
        #expect(OpenSourceMigration.fallbackEngine(engine, hasKey: { _ in false }) == engine)
    }

    @Test func globalAndProfileOverridesMigrateIndependently() {
        let proxyUser = Profile(name: "Proxy", engineOverride: .openAIRealtime)
        let byokUser = Profile(name: "BYOK", engineOverride: .deepgram)
        let local = Profile(name: "Local", engineOverride: .whisper)
        let inherit = Profile(name: "Inherit")
        let store = FakeEngineStore(selectedEngine: .elevenLabsScribe, profiles: [proxyUser, byokUser, local, inherit])

        let changed = OpenSourceMigration.migrateEngines(in: store, hasKey: { $0 == .deepgram })

        #expect(changed)
        #expect(store.selectedEngine == .appleSpeech)
        #expect(store.profiles.map(\.engineOverride) == [.appleSpeech, .deepgram, .whisper, nil])
    }

    @Test func nothingChangesWhenEveryCloudEngineHasItsKey() {
        let store = FakeEngineStore(selectedEngine: .openAIRealtime, profiles: [Profile(engineOverride: .deepgram)])
        #expect(!OpenSourceMigration.migrateEngines(in: store, hasKey: { _ in true }))
        #expect(store.selectedEngine == .openAIRealtime)
        #expect(store.profiles.first?.engineOverride == .deepgram)
    }

    @Test func runsOnceRemovesLegacyStateAndSetsFlag() throws {
        let fixture = try MigrationFixture()
        try Data("2026-01-01T00:00:00Z".utf8).write(to: fixture.trialURL)
        let store = FakeEngineStore(selectedEngine: .openAIRealtime)

        #expect(fixture.run(store: store))
        #expect(fixture.defaults.bool(forKey: OpenSourceMigration.flagKey))
        #expect(!FileManager.default.fileExists(atPath: fixture.trialURL.path))
        #expect(fixture.deletedAccounts == OpenSourceMigration.legacyLicenseKeychainAccounts)
        #expect(store.selectedEngine == .appleSpeech)

        // Second run is a no-op: no deletes, and a cloud engine the user picks
        // afterwards is left alone.
        store.selectedEngine = .deepgram
        fixture.deletedAccounts = []
        #expect(!fixture.run(store: store))
        #expect(fixture.deletedAccounts.isEmpty)
        #expect(store.selectedEngine == .deepgram)
    }

    @Test func missingTrialFileIsNotAnError() throws {
        let fixture = try MigrationFixture()
        let store = FakeEngineStore(selectedEngine: .appleSpeech)
        #expect(fixture.run(store: store))
        #expect(fixture.defaults.bool(forKey: OpenSourceMigration.flagKey))
    }

    @Test func aiCleanupIsSwitchedOffOnlyWhenTheAIKeyIsMissing() {
        let store = FakeEngineStore(selectedEngine: .appleSpeech, profiles: [
            Profile(name: "Cleanup", aiPostProcessing: true),
            Profile(name: "Plain", aiPostProcessing: false),
        ])
        #expect(!OpenSourceMigration.migrateAIPostProcessing(in: store, aiKeyMissing: false))
        #expect(store.profiles.map(\.aiPostProcessing) == [true, false])

        #expect(OpenSourceMigration.migrateAIPostProcessing(in: store, aiKeyMissing: true))
        #expect(store.profiles.map(\.aiPostProcessing) == [false, false])
    }

    @Test func failedLegacyDeleteStillCompletesTheMigration() throws {
        let fixture = try MigrationFixture()
        let store = FakeEngineStore(selectedEngine: .appleSpeech)
        let ran = OpenSourceMigration.runIfNeeded(
            defaults: fixture.defaults,
            store: store,
            hasKey: { _ in true },
            aiKeyMissing: { false },
            deleteKeychainAccount: { _ in errSecInteractionNotAllowed },
            trialBackupURL: fixture.trialURL
        )
        #expect(ran)
        #expect(fixture.defaults.bool(forKey: OpenSourceMigration.flagKey))
    }

    @Test func unknownKeychainAccountIsReportedAbsentNotUnknown() {
        // A random account definitely doesn't exist: the lookup must answer
        // false (absent), never nil, or migrated users would keep a broken engine.
        #expect(OpenSourceMigration.keychainItemExists(account: "sonotexta-test-\(UUID().uuidString)") == false)
    }

    @Test func neverTargetsBYOKKeychainAccounts() {
        let llmAccounts = LLMService.Provider.allCases.flatMap { [$0.keychainAccount, "llm-\($0.keychainAccount)"] }
        let byokAccounts = llmAccounts + ["deepgram", "elevenlabs", "deepl-api-key"]
        for account in OpenSourceMigration.legacyLicenseKeychainAccounts {
            #expect(!byokAccounts.contains(account))
            #expect(account.hasPrefix("com.voiceflow."))
        }
    }
}

struct FeatureGateRemovalTests {
    @Test(arguments: STTEngineType.allCases)
    func everyEngineIsUsedAsSelected(engine: STTEngineType) {
        #expect(DictationManager.resolveEngineType(profileOverride: nil, globalEngine: engine) == engine)
        #expect(DictationManager.resolveEngineType(profileOverride: engine, globalEngine: .appleSpeech) == engine)
    }

    @Test func appleSpeechIsNotPromotedToACloudEngine() {
        #expect(DictationManager.resolveEngineType(profileOverride: nil, globalEngine: .appleSpeech) == .appleSpeech)
    }

    @Test func aiPostProcessingFollowsTheProfileOnly() {
        #expect(DictationManager.shouldPostProcessWithAI(profile: Profile(aiPostProcessing: true)))
        #expect(!DictationManager.shouldPostProcessWithAI(profile: Profile(aiPostProcessing: false)))
        #expect(!DictationManager.shouldPostProcessWithAI(profile: nil))
    }
}
