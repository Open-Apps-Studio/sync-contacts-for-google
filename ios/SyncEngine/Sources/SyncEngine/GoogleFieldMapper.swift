import Foundation

/// Maps between `SyncContact` and Google People API `Person` JSON.
/// Patch semantics: `updatePersonFields` must list only fields we own/changed so
/// Google fields we don't model (fileAs, memberships, biographies…) are never destroyed.
public enum GoogleFieldMapper {

    /// The person fields we read and write.
    public static let personFields = [
        "names", "nicknames", "organizations", "phoneNumbers", "emailAddresses",
        "addresses", "urls", "imClients", "relations", "birthdays", "events",
        "photos", "metadata"
    ].joined(separator: ",")

    /// Fields we may include in updateContact's updatePersonFields mask.
    public static let updatableFields = [
        "names", "nicknames", "organizations", "phoneNumbers", "emailAddresses",
        "addresses", "urls", "imClients", "relations", "birthdays", "events"
    ]

    public struct PersonRecord: Equatable, Sendable {
        public var resourceName: String
        public var etag: String
        public var deleted: Bool
        public var contact: SyncContact

        public init(resourceName: String, etag: String, deleted: Bool, contact: SyncContact) {
            self.resourceName = resourceName
            self.etag = etag
            self.deleted = deleted
            self.contact = contact
        }
    }

    // MARK: - Person JSON → SyncContact

    public static func fromPerson(_ json: [String: Any]) -> PersonRecord {
        var c = SyncContact()

        if let names = json["names"] as? [[String: Any]], let n = primary(names) {
            c.givenName = str(n["givenName"])
            c.familyName = str(n["familyName"])
            c.middleName = str(n["middleName"])
            c.namePrefix = str(n["honorificPrefix"])
            c.nameSuffix = str(n["honorificSuffix"])
            c.phoneticGivenName = str(n["phoneticGivenName"])
            c.phoneticFamilyName = str(n["phoneticFamilyName"])
        }
        if let nicks = json["nicknames"] as? [[String: Any]], let n = primary(nicks) {
            c.nickname = str(n["value"])
        }
        if let orgs = json["organizations"] as? [[String: Any]], let o = primary(orgs) {
            c.organization = str(o["name"])
            c.department = str(o["department"])
            c.jobTitle = str(o["title"])
        }
        c.phones = (json["phoneNumbers"] as? [[String: Any]] ?? []).compactMap {
            let v = str($0["value"])
            return v.isEmpty ? nil : LabeledValue(label: googleTypeToLabel($0), value: v)
        }
        c.emails = (json["emailAddresses"] as? [[String: Any]] ?? []).compactMap {
            let v = str($0["value"])
            return v.isEmpty ? nil : LabeledValue(label: googleTypeToLabel($0), value: v)
        }
        c.urls = (json["urls"] as? [[String: Any]] ?? []).compactMap {
            let v = str($0["value"])
            return v.isEmpty ? nil : LabeledValue(label: googleTypeToLabel($0), value: v)
        }
        c.imAddresses = (json["imClients"] as? [[String: Any]] ?? []).compactMap {
            let v = str($0["username"])
            return v.isEmpty ? nil : LabeledValue(label: str($0["protocol"], default: "other"), value: v)
        }
        c.relations = (json["relations"] as? [[String: Any]] ?? []).compactMap {
            let v = str($0["person"])
            return v.isEmpty ? nil : LabeledValue(label: googleTypeToLabel($0), value: v)
        }
        c.addresses = (json["addresses"] as? [[String: Any]] ?? []).map {
            PostalAddress(label: googleTypeToLabel($0),
                          street: str($0["streetAddress"]),
                          city: str($0["city"]),
                          state: str($0["region"]),
                          postalCode: str($0["postalCode"]),
                          country: str($0["country"]))
        }.filter { !$0.isEmpty }
        if let bdays = json["birthdays"] as? [[String: Any]], let b = primary(bdays),
           let date = b["date"] as? [String: Any],
           let month = date["month"] as? Int, let day = date["day"] as? Int {
            c.birthday = DateValue(label: "birthday", year: date["year"] as? Int, month: month, day: day)
        }
        c.otherDates = (json["events"] as? [[String: Any]] ?? []).compactMap {
            guard let date = $0["date"] as? [String: Any],
                  let month = date["month"] as? Int, let day = date["day"] as? Int else { return nil }
            return DateValue(label: googleTypeToLabel($0), year: date["year"] as? Int, month: month, day: day)
        }
        // Only real photos count; `default: true` is Google's generated monogram.
        if let photos = json["photos"] as? [[String: Any]],
           let p = photos.first(where: { !(($0["default"] as? Bool) ?? false) }),
           let url = p["url"] as? String, !url.isEmpty {
            c.photoHash = "gurl:" + url
        }

        let meta = json["metadata"] as? [String: Any]
        let deleted = (meta?["deleted"] as? Bool) ?? false
        return PersonRecord(resourceName: str(json["resourceName"]),
                            etag: str(json["etag"]),
                            deleted: deleted,
                            contact: c)
    }

    // MARK: - SyncContact → Person JSON

    public static func toPerson(_ c: SyncContact, etag: String? = nil) -> [String: Any] {
        var json: [String: Any] = [:]
        if let etag { json["etag"] = etag }

        var name: [String: Any] = [:]
        if !c.givenName.isEmpty { name["givenName"] = c.givenName }
        if !c.familyName.isEmpty { name["familyName"] = c.familyName }
        if !c.middleName.isEmpty { name["middleName"] = c.middleName }
        if !c.namePrefix.isEmpty { name["honorificPrefix"] = c.namePrefix }
        if !c.nameSuffix.isEmpty { name["honorificSuffix"] = c.nameSuffix }
        if !c.phoneticGivenName.isEmpty { name["phoneticGivenName"] = c.phoneticGivenName }
        if !c.phoneticFamilyName.isEmpty { name["phoneticFamilyName"] = c.phoneticFamilyName }
        if !name.isEmpty { json["names"] = [name] }

        if !c.nickname.isEmpty { json["nicknames"] = [["value": c.nickname]] }

        var org: [String: Any] = [:]
        if !c.organization.isEmpty { org["name"] = c.organization }
        if !c.department.isEmpty { org["department"] = c.department }
        if !c.jobTitle.isEmpty { org["title"] = c.jobTitle }
        if !org.isEmpty { json["organizations"] = [org] }

        if !c.phones.isEmpty {
            json["phoneNumbers"] = c.phones.map { labeledToGoogle($0, valueKey: "value") }
        }
        if !c.emails.isEmpty {
            json["emailAddresses"] = c.emails.map { labeledToGoogle($0, valueKey: "value") }
        }
        if !c.urls.isEmpty {
            json["urls"] = c.urls.map { labeledToGoogle($0, valueKey: "value") }
        }
        if !c.imAddresses.isEmpty {
            json["imClients"] = c.imAddresses.map { ["protocol": $0.label, "username": $0.value] }
        }
        if !c.relations.isEmpty {
            json["relations"] = c.relations.map { labeledToGoogle($0, valueKey: "person") }
        }
        if !c.addresses.isEmpty {
            json["addresses"] = c.addresses.map { a -> [String: Any] in
                var d: [String: Any] = [:]
                if !a.label.isEmpty { d["type"] = a.label }
                if !a.street.isEmpty { d["streetAddress"] = a.street }
                if !a.city.isEmpty { d["city"] = a.city }
                if !a.state.isEmpty { d["region"] = a.state }
                if !a.postalCode.isEmpty { d["postalCode"] = a.postalCode }
                if !a.country.isEmpty { d["country"] = a.country }
                return d
            }
        }
        if let b = c.birthday {
            var date: [String: Any] = ["month": b.month, "day": b.day]
            if let y = b.year { date["year"] = y }
            json["birthdays"] = [["date": date]]
        }
        if !c.otherDates.isEmpty {
            json["events"] = c.otherDates.map { d -> [String: Any] in
                var date: [String: Any] = ["month": d.month, "day": d.day]
                if let y = d.year { date["year"] = y }
                var entry: [String: Any] = ["date": date]
                if !d.label.isEmpty { entry["type"] = d.label }
                return entry
            }
        }
        return json
    }

    /// updatePersonFields mask: only the field groups that differ between old and new.
    public static func updateMask(from old: SyncContact, to new: SyncContact) -> [String] {
        var mask: [String] = []
        func nameChanged() -> Bool {
            old.givenName != new.givenName || old.familyName != new.familyName
                || old.middleName != new.middleName || old.namePrefix != new.namePrefix
                || old.nameSuffix != new.nameSuffix
                || old.phoneticGivenName != new.phoneticGivenName
                || old.phoneticFamilyName != new.phoneticFamilyName
        }
        if nameChanged() { mask.append("names") }
        if old.nickname != new.nickname { mask.append("nicknames") }
        if old.organization != new.organization || old.department != new.department
            || old.jobTitle != new.jobTitle { mask.append("organizations") }
        if old.phones != new.phones { mask.append("phoneNumbers") }
        if old.emails != new.emails { mask.append("emailAddresses") }
        if old.addresses != new.addresses { mask.append("addresses") }
        if old.urls != new.urls { mask.append("urls") }
        if old.imAddresses != new.imAddresses { mask.append("imClients") }
        if old.relations != new.relations { mask.append("relations") }
        if old.birthday != new.birthday { mask.append("birthdays") }
        if old.otherDates != new.otherDates { mask.append("events") }
        return mask
    }

    // MARK: - Helpers

    private static func primary(_ entries: [[String: Any]]) -> [String: Any]? {
        entries.first {
            (($0["metadata"] as? [String: Any])?["primary"] as? Bool) ?? false
        } ?? entries.first
    }

    private static func str(_ any: Any?, default def: String = "") -> String {
        (any as? String) ?? def
    }

    /// iOS labels are freeform; Google types are enum-ish plus free "type" for custom.
    private static func googleTypeToLabel(_ entry: [String: Any]) -> String {
        let t = str(entry["type"])
        if !t.isEmpty { return t }
        return str(entry["formattedType"]).lowercased()
    }

    private static func labeledToGoogle(_ lv: LabeledValue, valueKey: String) -> [String: Any] {
        var d: [String: Any] = [valueKey: lv.value]
        if !lv.label.isEmpty { d["type"] = lv.label }
        return d
    }
}
