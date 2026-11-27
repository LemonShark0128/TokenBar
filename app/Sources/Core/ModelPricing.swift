import Foundation

/// 用户指定的公开 API 标价估算快照，美元 / 百万 token；不是套餐实际账单。
struct ModelPrice: Equatable {
    var input: Double
    var cachedInput: Double
    var cacheWrite: Double
    var output: Double
}

struct TokenBreakdown: Equatable, Codable {
    var input = 0
    var cachedInput = 0
    var cacheWrite = 0
    var output = 0

    static func + (a: Self, b: Self) -> Self {
        Self(input: a.input + b.input, cachedInput: a.cachedInput + b.cachedInput,
             cacheWrite: a.cacheWrite + b.cacheWrite, output: a.output + b.output)
    }
}

enum ModelPricing {
    static func price(model raw: String) -> ModelPrice? {
        let model = raw.lowercased()
        for (family, input, output) in [("fable", 10.0, 50.0), ("opus", 5, 25), ("sonnet", 3, 15), ("haiku", 1, 5)] {
            if model.contains(family) {
                return ModelPrice(input: input, cachedInput: input * 0.1, cacheWrite: input * 1.25, output: output)
            }
        }
        let rates: (Double, Double, Double)
        if model.contains("gpt-5.5") { rates = (5, 0.5, 30) }
        else if ["gpt-5.2", "gpt-5.3", "gpt-5.4"].contains(where: model.contains) { rates = (1.75, 0.175, 14) }
        // 版本后只接受名称结束或 '-'，避免 gpt-5.6 / gpt-5.10 被旧档吞掉。
        else if ["gpt-5.1", "gpt-5"].contains(where: { name in
            guard let range = model.range(of: name) else { return false }
            return range.upperBound == model.endIndex || model[range.upperBound] == "-"
        }) { rates = (1.25, 0.125, 10) }
        else if model.hasPrefix("gpt-") { rates = (5, 0.5, 30) }
        else { return nil }
        return ModelPrice(input: rates.0, cachedInput: rates.1, cacheWrite: rates.0, output: rates.2)
    }

    static func usd(_ t: TokenBreakdown, model: String) -> Double? {
        guard let p = price(model: model) else { return nil }
        return (Double(t.input) * p.input + Double(t.cachedInput) * p.cachedInput
                + Double(t.cacheWrite) * p.cacheWrite + Double(t.output) * p.output) / 1_000_000
    }
}

/// 两处日志读取共用同一个累计增量口径。缺失字段按 0；截断的首条由调用方仅用作基线。
struct CodexTokenUsage: Decodable {
    var total_tokens: Int?
    var input_tokens: Int?
    var cached_input_tokens: Int?
    var output_tokens: Int?
    var reasoning_output_tokens: Int?

    func delta(from previous: Self) -> TokenBreakdown {
        let reset = total_tokens.map { $0 < (previous.total_tokens ?? 0) } ?? false
        let p = reset ? Self() : previous
        func diff(_ current: Int?, _ old: Int?) -> Int { max(0, (current ?? 0) - (old ?? 0)) }
        let cached = diff(cached_input_tokens, p.cached_input_tokens)
        let included = total_tokens != nil && total_tokens == (input_tokens ?? 0) + (output_tokens ?? 0)
        return TokenBreakdown(input: max(0, diff(input_tokens, p.input_tokens) - cached), cachedInput: cached,
                              output: diff(output_tokens, p.output_tokens)
                                + (included ? 0 : diff(reasoning_output_tokens, p.reasoning_output_tokens)))
    }
}
