@MainActor
func registerSmokeTests() {
    test("harnessRuns") { try checkEqual(1 + 1, 2) }
}
