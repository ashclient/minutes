import Foundation

// Bound in-flight work, report actual completions, and retain source order even
// when later requests finish first. Errors cancel the remaining child tasks.
enum OrderedBatch {
    static func map<Input: Sendable, Output: Sendable>(_ inputs: [Input], concurrency: Int, progress: @escaping @MainActor (Double) -> Void = { _ in }, operation: @escaping @Sendable (Input) async throws -> Output) async throws -> [Output] {
        guard !inputs.isEmpty else { await progress(1); return [] }
        await progress(0)
        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            let limit = min(inputs.count, max(1, concurrency))
            var next = limit, completed = 0
            var results = [Output?](repeating: nil, count: inputs.count)
            for index in 0..<limit { group.addTask { (index, try await operation(inputs[index])) } }
            while let (index, value) = try await group.next() {
                try Task.checkCancellation()
                results[index] = value; completed += 1
                await progress(Double(completed) / Double(inputs.count))
                if next < inputs.count {
                    let index = next; next += 1
                    group.addTask { (index, try await operation(inputs[index])) }
                }
            }
            return results.compactMap { $0 }
        }
    }
}
