import Foundation

/// First-sync matching: pairs up contacts that exist on both sides so they can be
/// merged instead of duplicated. Comparison-only normalization — stored values are
/// never rewritten.
public enum Matching {

    public struct Candidate: Equatable, Sendable {
        public var id: String
        public var contact: SyncContact
        public init(id: String, contact: SyncContact) {
            self.id = id
            self.contact = contact
        }
    }

    public struct MatchResult: Equatable, Sendable {
        public var pairs: [(local: Candidate, remote: Candidate)]
        public var localOnly: [Candidate]
        public var remoteOnly: [Candidate]

        public static func == (lhs: MatchResult, rhs: MatchResult) -> Bool {
            lhs.localOnly == rhs.localOnly && lhs.remoteOnly == rhs.remoteOnly
                && lhs.pairs.map { [$0.local, $0.remote] } == rhs.pairs.map { [$0.local, $0.remote] }
        }
    }

    /// Case- and diacritic-insensitive name folding ("Åsa Ö" == "asa o").
    public static func foldName(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                  locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Digits-only phone normalization for comparison. "+1 (415) 555-0100" == "14155550100".
    /// Two numbers also match when one is a suffix of the other with ≥7 shared digits
    /// (handles missing country codes).
    public static func normalizePhone(_ s: String) -> String {
        let digits = String(s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
        // Drop trunk-prefix zeros ("020 7946…" vs "+44 20 7946…") for comparison.
        return String(digits.drop(while: { $0 == "0" }))
    }

    public static func phonesMatch(_ a: String, _ b: String) -> Bool {
        let na = normalizePhone(a), nb = normalizePhone(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        let shorter = na.count <= nb.count ? na : nb
        let longer = na.count <= nb.count ? nb : na
        return shorter.count >= 7 && longer.hasSuffix(shorter)
    }

    static func fullNameKey(_ c: SyncContact) -> String {
        foldName([c.givenName, c.middleName, c.familyName].filter { !$0.isEmpty }.joined(separator: " "))
    }

    static func contactsMatch(_ a: SyncContact, _ b: SyncContact) -> Bool {
        let nameA = fullNameKey(a), nameB = fullNameKey(b)
        let emailsA = Set(a.emails.map { $0.value.lowercased().trimmingCharacters(in: .whitespaces) })
        let emailsB = Set(b.emails.map { $0.value.lowercased().trimmingCharacters(in: .whitespaces) })
        let shareEmail = !emailsA.intersection(emailsB).filter { !$0.isEmpty }.isEmpty
        let sharePhone = a.phones.contains { pa in b.phones.contains { pb in phonesMatch(pa.value, pb.value) } }

        if !nameA.isEmpty && nameA == nameB {
            // Same name — pair when they share a channel, or when either side has
            // no phone/email at all (name is all we have to go on).
            if shareEmail || sharePhone { return true }
            let aBare = a.phones.isEmpty && a.emails.isEmpty
            let bBare = b.phones.isEmpty && b.emails.isEmpty
            return aBare || bBare
        }
        // Company-only contacts (no person name on either side).
        if nameA.isEmpty && nameB.isEmpty && !a.organization.isEmpty {
            let orgA = foldName(a.organization), orgB = foldName(b.organization)
            if orgA == orgB && (shareEmail || sharePhone) { return true }
        }
        return false
    }

    public static func match(local: [Candidate], remote: [Candidate]) -> MatchResult {
        var pairs: [(local: Candidate, remote: Candidate)] = []
        var usedRemote = Set<Int>()
        var localOnly: [Candidate] = []

        for l in local {
            var matched = false
            for (idx, r) in remote.enumerated() where !usedRemote.contains(idx) {
                if contactsMatch(l.contact, r.contact) {
                    pairs.append((local: l, remote: r))
                    usedRemote.insert(idx)
                    matched = true
                    break
                }
            }
            if !matched { localOnly.append(l) }
        }
        let remoteOnly = remote.enumerated()
            .filter { !usedRemote.contains($0.offset) }
            .map { $0.element }
        return MatchResult(pairs: pairs, localOnly: localOnly, remoteOnly: remoteOnly)
    }
}
