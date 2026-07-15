import Foundation

public protocol SnapshotManaging: Sendable {
    /// Persist a pre-write safety snapshot of the affected contacts (vCard).
    func createSnapshot(reason: String, localContacts: [SyncContact], remoteContacts: [SyncContact]) throws
}

public struct SnapshotInfo: Identifiable, Equatable, Sendable {
    public var id: String       // directory name
    public var date: Date
    public var reason: String
    public var localCount: Int
    public var remoteCount: Int
}

/// vCard-based snapshots on the local filesystem, rotated to the newest N.
public final class SnapshotManager: SnapshotManaging, @unchecked Sendable {
    private let directory: URL
    private let keep: Int
    private let fm = FileManager.default

    public init(directory: URL, keep: Int = 10) {
        self.directory = directory
        self.keep = keep
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func createSnapshot(reason: String,
                               localContacts: [SyncContact],
                               remoteContacts: [SyncContact]) throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = directory.appendingPathComponent("\(stamp)_\(reason.replacingOccurrences(of: " ", with: "-"))")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try VCard.serialize(localContacts)
            .write(to: dir.appendingPathComponent("iphone.vcf"), atomically: true, encoding: .utf8)
        try VCard.serialize(remoteContacts)
            .write(to: dir.appendingPathComponent("google.vcf"), atomically: true, encoding: .utf8)
        let meta: [String: Any] = ["reason": reason, "date": stamp,
                                   "localCount": localContacts.count,
                                   "remoteCount": remoteContacts.count]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: dir.appendingPathComponent("meta.json"))
        rotate()
    }

    public func listSnapshots() -> [SnapshotInfo] {
        let dirs = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            let dateStr = (meta["date"] as? String ?? "").replacingOccurrences(of: "-", with: ":")
            return SnapshotInfo(id: dir.lastPathComponent,
                                date: ISO8601DateFormatter().date(from: restoreStamp(meta["date"] as? String ?? "")) ?? Date.distantPast,
                                reason: meta["reason"] as? String ?? dateStr,
                                localCount: meta["localCount"] as? Int ?? 0,
                                remoteCount: meta["remoteCount"] as? Int ?? 0)
        }.sorted { $0.date > $1.date }
    }

    public func contacts(inSnapshot id: String, side: Side) throws -> [SyncContact] {
        let file = directory.appendingPathComponent(id)
            .appendingPathComponent(side == .local ? "iphone.vcf" : "google.vcf")
        return VCard.parse(try String(contentsOf: file, encoding: .utf8))
    }

    public func exportURL(forSnapshot id: String, side: Side) -> URL {
        directory.appendingPathComponent(id)
            .appendingPathComponent(side == .local ? "iphone.vcf" : "google.vcf")
    }

    public enum Side { case local, remote }

    private func rotate() {
        let snapshots = listSnapshots()
        guard snapshots.count > keep else { return }
        for old in snapshots.dropFirst(keep) {
            try? fm.removeItem(at: directory.appendingPathComponent(old.id))
        }
    }

    private func restoreStamp(_ s: String) -> String {
        // "2026-07-15T12-30-00Z" → "2026-07-15T12:30:00Z" (only time colons were replaced)
        guard let tIndex = s.firstIndex(of: "T") else { return s }
        let date = String(s[..<tIndex])
        let time = String(s[s.index(after: tIndex)...]).replacingOccurrences(of: "-", with: ":")
        return "\(date)T\(time)"
    }
}

/// Minimal vCard 4.0 serialization for our field set — snapshots and exports only.
public enum VCard {

    public static func serialize(_ contacts: [SyncContact]) -> String {
        contacts.map(serializeOne).joined(separator: "\r\n") + (contacts.isEmpty ? "" : "\r\n")
    }

    static func serializeOne(_ c: SyncContact) -> String {
        var lines = ["BEGIN:VCARD", "VERSION:4.0"]
        lines.append("FN:" + escape(c.displayName))
        lines.append("N:\(escape(c.familyName));\(escape(c.givenName));\(escape(c.middleName));\(escape(c.namePrefix));\(escape(c.nameSuffix))")
        if !c.nickname.isEmpty { lines.append("NICKNAME:" + escape(c.nickname)) }
        if !c.organization.isEmpty || !c.department.isEmpty {
            lines.append("ORG:" + escape(c.organization) + (c.department.isEmpty ? "" : ";" + escape(c.department)))
        }
        if !c.jobTitle.isEmpty { lines.append("TITLE:" + escape(c.jobTitle)) }
        for p in c.phones {
            lines.append("TEL;TYPE=\(sanitizeType(p.label)):\(escape(p.value))")
        }
        for e in c.emails {
            lines.append("EMAIL;TYPE=\(sanitizeType(e.label)):\(escape(e.value))")
        }
        for u in c.urls {
            lines.append("URL;TYPE=\(sanitizeType(u.label)):\(escape(u.value))")
        }
        for a in c.addresses {
            lines.append("ADR;TYPE=\(sanitizeType(a.label)):;;\(escape(a.street));\(escape(a.city));\(escape(a.state));\(escape(a.postalCode));\(escape(a.country))")
        }
        if let b = c.birthday {
            let y = b.year.map { String(format: "%04d", $0) } ?? "--"
            lines.append("BDAY:\(y)\(String(format: "%02d", b.month))\(String(format: "%02d", b.day))")
        }
        lines.append("END:VCARD")
        return lines.joined(separator: "\r\n")
    }

    public static func parse(_ text: String) -> [SyncContact] {
        var contacts: [SyncContact] = []
        var current: SyncContact?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let upper = line.uppercased()
            if upper == "BEGIN:VCARD" { current = SyncContact(); continue }
            if upper == "END:VCARD" {
                if let c = current { contacts.append(c) }
                current = nil
                continue
            }
            guard var c = current, let colon = line.firstIndex(of: ":") else { continue }
            let head = String(line[..<colon]).uppercased()
            let value = unescape(String(line[line.index(after: colon)...]))
            let prop = head.split(separator: ";").first.map(String.init) ?? head
            let type = head.range(of: "TYPE=").map {
                String(head[$0.upperBound...]).split(separator: ";").first.map(String.init) ?? ""
            }?.lowercased() ?? ""

            switch prop {
            case "N":
                let parts = splitStructured(String(line[line.index(after: colon)...]))
                if parts.count > 0 { c.familyName = unescape(parts[0]) }
                if parts.count > 1 { c.givenName = unescape(parts[1]) }
                if parts.count > 2 { c.middleName = unescape(parts[2]) }
                if parts.count > 3 { c.namePrefix = unescape(parts[3]) }
                if parts.count > 4 { c.nameSuffix = unescape(parts[4]) }
            case "NICKNAME": c.nickname = value
            case "ORG":
                let parts = splitStructured(String(line[line.index(after: colon)...]))
                if parts.count > 0 { c.organization = unescape(parts[0]) }
                if parts.count > 1 { c.department = unescape(parts[1]) }
            case "TITLE": c.jobTitle = value
            case "TEL": c.phones.append(LabeledValue(label: type, value: value))
            case "EMAIL": c.emails.append(LabeledValue(label: type, value: value))
            case "URL": c.urls.append(LabeledValue(label: type, value: value))
            case "ADR":
                let parts = splitStructured(String(line[line.index(after: colon)...]))
                var addr = PostalAddress(label: type)
                if parts.count > 2 { addr.street = unescape(parts[2]) }
                if parts.count > 3 { addr.city = unescape(parts[3]) }
                if parts.count > 4 { addr.state = unescape(parts[4]) }
                if parts.count > 5 { addr.postalCode = unescape(parts[5]) }
                if parts.count > 6 { addr.country = unescape(parts[6]) }
                if !addr.isEmpty { c.addresses.append(addr) }
            case "BDAY":
                if value.hasPrefix("--"), value.count >= 6 {
                    // RFC 6350 year-less form: --MMDD
                    let mStr = String(value.dropFirst(2).prefix(2))
                    let dStr = String(value.dropFirst(4).prefix(2))
                    if let m = Int(mStr), let d = Int(dStr) {
                        c.birthday = DateValue(label: "birthday", year: nil, month: m, day: d)
                    }
                } else if value.count >= 8 {
                    let yStr = String(value.prefix(4))
                    let mStr = String(value.dropFirst(4).prefix(2))
                    let dStr = String(value.dropFirst(6).prefix(2))
                    if let m = Int(mStr), let d = Int(dStr) {
                        c.birthday = DateValue(label: "birthday", year: Int(yStr), month: m, day: d)
                    }
                }
            default: break
            }
            current = c
        }
        return contacts
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// Split on unescaped semicolons.
    static func splitStructured(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaped = false
        for ch in s {
            if escaped {
                current.append("\\")
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == ";" {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    static func sanitizeType(_ label: String) -> String {
        let cleaned = label.lowercased().filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? "other" : cleaned
    }
}
