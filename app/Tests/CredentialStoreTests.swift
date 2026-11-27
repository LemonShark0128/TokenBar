import Foundation

@MainActor
func registerCredentialStoreTests() {
    let prefix = "com.lemon.deepseek-tokenbar.test"
    // 以前用 .standard：读写 ~/Library/Preferences/TokenBarTests.plist，结果受上次运行留下的 accountAdded.* 影响。
    // 这组测试之间仍共用一份（和原来共用 .standard 一样），只是每次运行都从空开始
    let d = freshDefaults()
    func store() -> KeychainCredentialStore { KeychainCredentialStore(servicePrefix: prefix, defaults: d) }

    test("saveThenLoad") {
        let s = store(); defer { try? s.delete(.deepseek) }
        let c = Credentials(values: ["apiKey": "sk-test-0000", "webToken": "tok-test"])
        try s.save(c, for: .deepseek)
        try checkEqual(s.load(.deepseek), c)
    }
    test("overwrite") {
        let s = store(); defer { try? s.delete(.deepseek) }
        try s.save(Credentials(values: ["apiKey": "sk-test-0000", "webToken": "tok-test"]), for: .deepseek)
        try s.save(Credentials(values: ["apiKey": "sk-test-1111"]), for: .deepseek)
        try checkEqual(s.load(.deepseek), Credentials(values: ["apiKey": "sk-test-1111"]))
    }
    test("deleteRemoves") {
        let s = store()
        try s.save(Credentials(values: ["apiKey": "sk-test-0000"]), for: .deepseek)
        try s.delete(.deepseek)
        try check(s.load(.deepseek) == nil, "删除后应读不到")
    }
    test("missingItemReturnsNil") {
        try check(store().load(.siliconflow) == nil, "从未保存过应返回 nil")
    }
    test("deleteMissingDoesNotThrow") {
        try store().delete(.siliconflow)
    }
    test("inMemoryRoundTrip") {
        let s = InMemoryCredentialStore()
        try s.save(Credentials(values: ["apiKey": "k"]), for: .deepseek)
        try checkEqual(s.load(.deepseek), Credentials(values: ["apiKey": "k"]))
        try s.delete(.deepseek)
        try check(s.load(.deepseek) == nil)
    }
}
