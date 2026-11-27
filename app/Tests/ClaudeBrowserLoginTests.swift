import Foundation

@MainActor
func registerClaudeBrowserLoginTests() {
    test("claudeBrowserNormalizesSessionKey") {
        for input in ["sk-ant-test", " \n sk-ant-test\r\n", "\"sk-ant-test\"", "'sk-ant-test'", "sessionKey=sk-ant-test", "Cookie: other=x; sessionKey=sk-ant-test; last=y", "cookie: sessionKey=\"sk-ant-test\"; other=x"] {
            try checkEqual(try ClaudeBrowserLogin.normalize(input), "sk-ant-test")
        }
    }
    test("claudeBrowserRejectsInvalidInput") {
        for input in ["", " \n\"\"", "abc", "sessionKey=wrong", "Cookie: other=sk-ant-test", "sk-ant-test\r\nInjected: x", "sk-ant-test; other=x"] {
            do {
                _ = try ClaudeBrowserLogin.normalize(input)
                throw TestFailure(description: "Expected invalid input rejection")
            } catch is ClaudeBrowserLogin.InputError { }
        }
    }
    test("claudeBrowserNormalizationEdges") {
        for input in ["sessionKey=sk-ant-test; sessionKey=sk-ant-second", "sessionKey=%73k-ant-test", "“sk-ant-test”", "‘sk-ant-test’"] {
            try checkEqual(try ClaudeBrowserLogin.normalize(input), "sk-ant-test")
        }
        try checkEqual(try ClaudeBrowserLogin.normalize("sk-ant-" + String(repeating: "a", count: 4089)).count, 4096)
        do {
            _ = try ClaudeBrowserLogin.normalize("sk-ant-" + String(repeating: "a", count: 4090))
            throw TestFailure(description: "Expected length rejection")
        } catch is ClaudeBrowserLogin.InputError { }
    }
    testAsync("claudeBrowserPersistenceAcknowledgedBeforeRefreshAndStaleWriteRejected") {
        let clock = FakeClock()
        let provider = FakeProvider([], id: .claudePlan)
        let (store, _) = try makeStore(provider, clock: clock, creds: false)
        let attempts = ClaudeLoginAttempts()
        let old = attempts.begin()
        let current = attempts.begin()
        var acknowledged = false
        do {
            try await store.saveCredentials([ClaudeWebUsage.credentialKey: "sk-ant-old"], for: .claudePlan,
                                            attempt: old, onPersisted: { acknowledged = true }, refresh: false)
            throw TestFailure(description: "Stale save was allowed")
        } catch is CancellationError { }
        try check(!acknowledged)
        try check(!store.isAdded(.claudePlan))
        var callsAtAcknowledgement = -1
        try await store.saveCredentials([ClaudeWebUsage.credentialKey: "sk-ant-new"], for: .claudePlan,
                                        attempt: current, onPersisted: {
            acknowledged = true
            callsAtAcknowledgement = provider.calls
        }, refresh: false)
        try check(acknowledged)
        try checkEqual(callsAtAcknowledgement, 0)
        try checkEqual(provider.calls, 0)
        let saved = await store.readCredentials(.claudePlan)
        try checkEqual(saved, .found(Credentials(values: [ClaudeWebUsage.credentialKey: "sk-ant-new"])))
        await store.refresh(.claudePlan)
        try checkEqual(provider.calls, 1)
    }
    testAsync("claudeBrowserSupersededValidationCannotSaveOrActivate") {
        let attempts = ClaudeLoginAttempts()
        let first = attempts.begin()
        var events: [String] = []
        let result = await ClaudeBrowserLogin.connect("sk-ant-old", isCurrent: { first.isCurrent }, validate: { _ in
            _ = attempts.begin()
            return nil
        }, save: { _ in events.append("save") }, activate: { events.append("activate") })
        try check(!result.ok)
        try check(events.isEmpty)
        do {
            try first.commit { events.append("late write") }
            throw TestFailure(description: "Stale queued write was allowed")
        } catch is CancellationError { }
        try check(events.isEmpty)
        let latest = attempts.begin()
        try latest.commit { events.append("new write") }
        try checkEqual(events, ["new write"])
    }
    testAsync("claudeBrowserSupersededSaveCannotActivate") {
        let attempts = ClaudeLoginAttempts()
        let first = attempts.begin()
        var activated = false
        let result = await ClaudeBrowserLogin.connect("sk-ant-old", isCurrent: { first.isCurrent },
            validate: { _ in nil }, save: { _ in _ = attempts.begin() }, activate: { activated = true })
        try check(!result.ok && !activated)
    }
    testAsync("claudeBrowserValidationAndSaveOrdering") {
        var events: [String] = []
        for failValidation in [true, false] {
            events = []
            let credentials = InMemoryCredentialStore()
            var source = ClaudePlanSource.terminal
            let result = await ClaudeBrowserLogin.connect("sk-ant-test", validate: { _ in
                events.append("validate")
                return failValidation ? .auth(L("claudeWeb.expired")) : nil
            }, save: { key in
                try credentials.save(Credentials(values: [ClaudeWebUsage.credentialKey: key]), for: .claudePlan)
                events.append("save")
            }, activate: { source = .web; events.append("web") })
            try checkEqual(result.ok, !failValidation)
            try checkEqual(source, failValidation ? .terminal : .web)
            try checkEqual(credentials.read(.claudePlan), failValidation ? .notFound :
                .found(Credentials(values: [ClaudeWebUsage.credentialKey: "sk-ant-test"])))
            try checkEqual(events, failValidation ? ["validate"] : ["validate", "save", "web"])
        }
    }
    testAsync("claudeBrowserValidationErrorsAreSafeAndInline") {
        let errors: [(ProviderError, String)] = [
            (.auth("private detail"), "claudeWeb.expired"),
            (.unavailable(L("claudeWeb.cloudflare")), "claudeWeb.cloudflare"),
            (.unavailable(L("claudeWeb.throttled")), "claudeWeb.throttled"),
            (.schemaChanged("private detail"), "claudeWeb.unrecognized"),
            (.network("private detail"), "claudeWeb.unrecognized")
        ]
        for (error, messageKey) in errors {
            var saved = false
            let result = await ClaudeBrowserLogin.connect("sk-ant-test", validate: { _ in error },
                save: { _ in saved = true }, activate: { saved = true })
            try check(!result.ok && !saved)
            try checkEqual(result.message, L(messageKey))
        }
    }
    testAsync("claudeBrowserInvalidInputNeverRequestsAndSaveFailureKeepsSource") {
        var events: [String] = []
        let invalid = await ClaudeBrowserLogin.connect("wrong", validate: { _ in events.append("validate"); return nil },
            save: { _ in events.append("save") }, activate: { events.append("web") })
        try check(!invalid.ok)
        try check(events.isEmpty)
        let failed = await ClaudeBrowserLogin.connect("sk-ant-test", validate: { _ in nil },
            save: { _ in throw TestFailure(description: "secret must not appear") }, activate: { events.append("web") })
        try check(!failed.ok)
        try check(events.isEmpty)
        try check(!failed.message.contains("secret must not appear"))
    }
}
