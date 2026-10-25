// 最小测试框架：本机 SwiftPM 无法运行、也没有 XCTest，所以测试编译成一个独立可执行文件。
// 每个测试文件提供 registerXxxTests()，在 TestMain 里显式调用；有失败时 exit(1)。
import Foundation

/// 收集日志行：传给后台跑的 log 回调（要求 Sendable）。@unchecked Sendable：lines 只在 lock 里读写
final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    func add(_ s: String) { lock.withLock { stored.append(s) } }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

/// 测试体一律在主线程（MainActor）上跑：UsageStore 等被测对象是 @MainActor，测试和它们同在一处，编译器才能检查
@MainActor var allTests: [(name: String, body: @MainActor () async throws -> Void)] = []

@MainActor
func test(_ name: String, _ body: @escaping @MainActor () throws -> Void) {
    allTests.append((name, { try body() }))
}

@MainActor
func testAsync(_ name: String, _ body: @escaping @MainActor () async throws -> Void) {
    allTests.append((name, body))
}

func check(_ condition: Bool, _ message: String = "条件不成立", file: String = #file, line: Int = #line) throws {
    if !condition { throw TestFailure(description: "\((file as NSString).lastPathComponent):\(line) \(message)") }
}

func checkEqual<T: Equatable>(_ a: T, _ b: T, file: String = #file, line: Int = #line) throws {
    if a != b { throw TestFailure(description: "\((file as NSString).lastPathComponent):\(line) 期望相等：\(a) ≠ \(b)") }
}

@main
struct TestMain {
    @MainActor
    static func main() async {
        // 断言里的文案都是中文：不管本机系统是什么语言，测试一律按中文界面跑（英文用例自己临时切）
        L10n.lang = .zh
        registerAllTests()
        var failed = 0
        for t in allTests {
            do {
                try await t.body()
                print("PASS \(t.name)")
            } catch {
                failed += 1
                print("FAIL \(t.name): \(error)")
            }
        }
        print("\(allTests.count - failed)/\(allTests.count) passed")
        exit(failed == 0 ? 0 : 1)
    }
}
