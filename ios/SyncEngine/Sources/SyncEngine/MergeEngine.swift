import Foundation

/// Field-level three-way merge between the last-synced base and the two live copies.
///
/// Rules (from the design spec):
/// - Changed on one side only → propagate the change.
/// - Scalar changed on both sides to different values → keep the iPhone (local) value,
///   record the discarded Google value as a `Conflict` (no wall-clock guessing).
/// - Multi-value list changed on both sides → union (never silently drop a phone/email);
///   clean one-side edits (including removals) propagate as-is.
public enum MergeEngine {

    public struct Result: Equatable, Sendable {
        public var merged: SyncContact
        public var conflicts: [Conflict]
        /// merged differs from the local input → local store needs a write
        public var localNeedsUpdate: Bool
        /// merged differs from the remote input → remote store needs a write
        public var remoteNeedsUpdate: Bool
    }

    public static func merge(base: SyncContact?, local: SyncContact, remote: SyncContact) -> Result {
        let base = base ?? SyncContact()
        var out = SyncContact()
        var conflicts: [Conflict] = []

        func scalar(_ field: String,
                    _ path: WritableKeyPath<SyncContact, String>) {
            out[keyPath: path] = mergeScalar(
                field: field,
                base: base[keyPath: path],
                local: local[keyPath: path],
                remote: remote[keyPath: path],
                conflicts: &conflicts)
        }

        scalar("First name", \.givenName)
        scalar("Last name", \.familyName)
        scalar("Middle name", \.middleName)
        scalar("Prefix", \.namePrefix)
        scalar("Suffix", \.nameSuffix)
        scalar("Phonetic first name", \.phoneticGivenName)
        scalar("Phonetic last name", \.phoneticFamilyName)
        scalar("Nickname", \.nickname)
        scalar("Company", \.organization)
        scalar("Department", \.department)
        scalar("Job title", \.jobTitle)

        out.phones = mergeList("Phone numbers", base: base.phones, local: local.phones,
                               remote: remote.phones, conflicts: &conflicts)
        out.emails = mergeList("Email addresses", base: base.emails, local: local.emails,
                               remote: remote.emails, conflicts: &conflicts)
        out.urls = mergeList("URLs", base: base.urls, local: local.urls,
                             remote: remote.urls, conflicts: &conflicts)
        out.imAddresses = mergeList("IM addresses", base: base.imAddresses, local: local.imAddresses,
                                    remote: remote.imAddresses, conflicts: &conflicts)
        out.relations = mergeList("Related names", base: base.relations, local: local.relations,
                                  remote: remote.relations, conflicts: &conflicts)
        out.addresses = mergeList("Addresses", base: base.addresses, local: local.addresses,
                                  remote: remote.addresses, conflicts: &conflicts)
        out.otherDates = mergeList("Dates", base: base.otherDates, local: local.otherDates,
                                   remote: remote.otherDates, conflicts: &conflicts)

        out.birthday = mergeOptionalScalar(
            field: "Birthday", base: base.birthday, local: local.birthday,
            remote: remote.birthday, conflicts: &conflicts, describe: { "\($0.month)/\($0.day)" + ($0.year.map { "/\($0)" } ?? "") })

        out.photoHash = mergeOptionalScalar(
            field: "Photo", base: base.photoHash, local: local.photoHash,
            remote: remote.photoHash, conflicts: &conflicts, describe: { String($0.prefix(8)) })

        return Result(merged: out,
                      conflicts: conflicts,
                      localNeedsUpdate: out != local,
                      remoteNeedsUpdate: out != remote)
    }

    // MARK: - Scalar

    private static func mergeScalar(field: String, base: String, local: String, remote: String,
                                    conflicts: inout [Conflict]) -> String {
        if local == remote { return local }
        if local == base { return remote }   // only remote changed
        if remote == base { return local }   // only local changed
        // Both changed to different values: keep local, log the loss.
        conflicts.append(Conflict(field: field, keptValue: local,
                                  discardedValue: remote, keptFrom: .local))
        return local
    }

    private static func mergeOptionalScalar<T: Equatable>(
        field: String, base: T?, local: T?, remote: T?,
        conflicts: inout [Conflict], describe: (T) -> String) -> T? {
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }
        conflicts.append(Conflict(field: field,
                                  keptValue: local.map(describe) ?? "(none)",
                                  discardedValue: remote.map(describe) ?? "(none)",
                                  keptFrom: .local))
        return local
    }

    // MARK: - Multi-value lists

    private static func mergeList<T: Hashable>(_ field: String, base: [T], local: [T], remote: [T],
                                               conflicts: inout [Conflict]) -> [T] {
        if local == remote { return local }
        if local == base { return remote }   // clean remote edit (incl. removals)
        if remote == base { return local }   // clean local edit
        // Both sides edited: union, preserving local order first, then novel remote items.
        var seen = Set(local)
        var result = local
        for item in remote where !seen.contains(item) {
            seen.insert(item)
            result.append(item)
        }
        conflicts.append(Conflict(field: field,
                                  keptValue: "merged \(result.count) entries from both sides",
                                  discardedValue: "",
                                  keptFrom: .local))
        return result
    }
}
