/// A local a test body keeps changing while a closure it handed to the code
/// under test keeps reading it: the clock a test advances, the frame list a
/// probe returns. The closures are main-actor or `@Sendable`, so a plain
/// `var` captured by them and then mutated is a data-race warning. Holding
/// the value in a class keeps the declaration a one-word change
/// (`@Captured var seconds = 5_000`) and every use unchanged. Every test
/// that uses it runs on one actor, so nothing here is shared across threads.
@propertyWrapper
final class Captured<Value>: @unchecked Sendable {
    var wrappedValue: Value

    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
