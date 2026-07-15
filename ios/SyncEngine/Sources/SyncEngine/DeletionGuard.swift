import Foundation

/// Circuit breaker for mass deletions: a single sync pass may not delete more than
/// max(10, 20% of the affected side) without explicit user confirmation.
public enum DeletionGuard {

    public static let absoluteFloor = 10
    public static let fraction = 0.20

    public static func threshold(totalContacts: Int) -> Int {
        max(absoluteFloor, Int((Double(totalContacts) * fraction).rounded(.down)))
    }

    /// - Parameters:
    ///   - pendingDeletes: deletions this pass wants to perform on one side
    ///   - totalContacts: contact count on that side before the pass
    public static func allows(pendingDeletes: Int, totalContacts: Int) -> Bool {
        pendingDeletes <= threshold(totalContacts: totalContacts)
    }
}
