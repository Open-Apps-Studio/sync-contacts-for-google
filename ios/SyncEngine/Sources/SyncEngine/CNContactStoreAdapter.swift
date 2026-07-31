#if canImport(Contacts)
import Foundation
import Contacts
import CryptoKit

/// Bridges CNContactStore to the engine's `LocalContactsStore`.
///
/// - Operates on non-unified, per-container contacts (unified IDs go unstable when
///   the user links/unlinks cards; Google has no linked-card concept).
/// - Writes carry a transactionAuthor so our own saves are distinguishable.
/// - Detects Google CardDAV containers so setup can warn about native-sync overlap.
public final class CNContactStoreAdapter: LocalContactsStore, @unchecked Sendable {

    public static let transactionAuthor = "com.openappsstudio.contactssync"

    private let store: CNContactStore

    public init(store: CNContactStore = CNContactStore()) {
        self.store = store
    }

    public static let fetchKeys: [CNKeyDescriptor] = [
        CNContactGivenNameKey, CNContactFamilyNameKey, CNContactMiddleNameKey,
        CNContactNamePrefixKey, CNContactNameSuffixKey,
        CNContactPhoneticGivenNameKey, CNContactPhoneticFamilyNameKey,
        CNContactNicknameKey, CNContactOrganizationNameKey,
        CNContactDepartmentNameKey, CNContactJobTitleKey,
        CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactUrlAddressesKey,
        CNContactInstantMessageAddressesKey, CNContactRelationsKey,
        CNContactPostalAddressesKey, CNContactBirthdayKey, CNContactDatesKey,
        CNContactImageDataAvailableKey, CNContactThumbnailImageDataKey
    ] as [CNKeyDescriptor]

    // MARK: - Container discovery

    /// The container the app writes to (the default container — iCloud when enabled).
    public func writableContainerID() throws -> String {
        store.defaultContainerIdentifier()
    }

    /// True when a Google CardDAV account also syncs contacts on this device
    /// (native-sync overlap → duplicate risk; setup wizard warns).
    public func hasGoogleCardDAVContainer() -> Bool {
        guard let containers = try? store.containers(matching: nil) else { return false }
        return containers.contains { $0.type == .cardDAV && $0.name.lowercased().contains("gmail") }
            || containers.contains { $0.type == .cardDAV && $0.name.lowercased().contains("google") }
    }

    // MARK: - LocalContactsStore

    public func fetchAll() async throws -> [LocalContact] {
        let containerID = try writableContainerID()
        let request = CNContactFetchRequest(keysToFetch: Self.fetchKeys)
        request.unifyResults = false
        request.predicate = CNContact.predicateForContactsInContainer(withIdentifier: containerID)

        var results: [LocalContact] = []
        try store.enumerateContacts(with: request) { cn, _ in
            results.append(LocalContact(id: cn.identifier, contact: Self.toSyncContact(cn)))
        }
        return results
    }

    public func create(_ contacts: [SyncContact]) async throws -> [String] {
        let containerID = try writableContainerID()
        var ids: [String] = []
        for chunk in contacts.chunked(into: 100) {
            let save = CNSaveRequest()
            save.transactionAuthor = Self.transactionAuthor
            var mutables: [CNMutableContact] = []
            for c in chunk {
                let m = CNMutableContact()
                Self.apply(c, to: m)
                save.add(m, toContainerWithIdentifier: containerID)
                mutables.append(m)
            }
            try store.execute(save)
            ids.append(contentsOf: mutables.map(\.identifier))
        }
        return ids
    }

    public func update(id: String, contact: SyncContact) async throws {
        guard let existing = try? store.unifiedContact(withIdentifier: id, keysToFetch: Self.fetchKeys),
              let mutable = existing.mutableCopy() as? CNMutableContact
        else { return }
        Self.apply(contact, to: mutable)
        let save = CNSaveRequest()
        save.transactionAuthor = Self.transactionAuthor
        save.update(mutable)
        try store.execute(save)
    }

    public func delete(ids: [String]) async throws {
        for chunk in ids.chunked(into: 100) {
            let save = CNSaveRequest()
            save.transactionAuthor = Self.transactionAuthor
            for id in chunk {
                guard let existing = try? store.unifiedContact(withIdentifier: id,
                                                               keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor]),
                      let mutable = existing.mutableCopy() as? CNMutableContact
                else { continue }
                save.delete(mutable)
            }
            try store.execute(save)
        }
    }

    public func count() async throws -> Int {
        try await fetchAll().count
    }

    // MARK: - CNContact ↔ SyncContact

    public static func toSyncContact(_ cn: CNContact) -> SyncContact {
        var c = SyncContact()
        c.givenName = cn.givenName
        c.familyName = cn.familyName
        c.middleName = cn.middleName
        c.namePrefix = cn.namePrefix
        c.nameSuffix = cn.nameSuffix
        c.phoneticGivenName = cn.phoneticGivenName
        c.phoneticFamilyName = cn.phoneticFamilyName
        c.nickname = cn.nickname
        c.organization = cn.organizationName
        c.department = cn.departmentName
        c.jobTitle = cn.jobTitle
        c.phones = cn.phoneNumbers.map {
            LabeledValue(label: cleanLabel($0.label), value: $0.value.stringValue)
        }
        c.emails = cn.emailAddresses.map {
            LabeledValue(label: cleanLabel($0.label), value: $0.value as String)
        }
        c.urls = cn.urlAddresses.map {
            LabeledValue(label: cleanLabel($0.label), value: $0.value as String)
        }
        c.imAddresses = cn.instantMessageAddresses.map {
            LabeledValue(label: $0.value.service, value: $0.value.username)
        }
        c.relations = cn.contactRelations.map {
            LabeledValue(label: cleanLabel($0.label), value: $0.value.name)
        }
        c.addresses = cn.postalAddresses.map {
            PostalAddress(label: cleanLabel($0.label),
                          street: $0.value.street, city: $0.value.city,
                          state: $0.value.state, postalCode: $0.value.postalCode,
                          country: $0.value.country)
        }
        if let b = cn.birthday, let month = b.month, let day = b.day {
            c.birthday = DateValue(label: "birthday", year: b.year, month: month, day: day)
        }
        c.otherDates = cn.dates.compactMap {
            let comps = $0.value as DateComponents
            guard let month = comps.month, let day = comps.day else { return nil }
            return DateValue(label: cleanLabel($0.label), year: comps.year,
                             month: month, day: day)
        }
        if cn.imageDataAvailable, let thumb = cn.thumbnailImageData {
            // Stable across process launches — Swift's hashValue is randomized per
            // process, which would make the same photo hash differently each launch
            // and trigger perpetual false "photo changed" churn. SHA-256 is stable.
            c.photoHash = "cn:" + SHA256.hash(data: thumb).map { String(format: "%02x", $0) }.joined()
        }
        return c
    }

    public static func apply(_ c: SyncContact, to m: CNMutableContact) {
        m.givenName = c.givenName
        m.familyName = c.familyName
        m.middleName = c.middleName
        m.namePrefix = c.namePrefix
        m.nameSuffix = c.nameSuffix
        m.phoneticGivenName = c.phoneticGivenName
        m.phoneticFamilyName = c.phoneticFamilyName
        m.nickname = c.nickname
        m.organizationName = c.organization
        m.departmentName = c.department
        m.jobTitle = c.jobTitle
        m.phoneNumbers = c.phones.map {
            CNLabeledValue(label: cnLabel($0.label), value: CNPhoneNumber(stringValue: $0.value))
        }
        m.emailAddresses = c.emails.map {
            CNLabeledValue(label: cnLabel($0.label), value: $0.value as NSString)
        }
        m.urlAddresses = c.urls.map {
            CNLabeledValue(label: cnLabel($0.label), value: $0.value as NSString)
        }
        m.instantMessageAddresses = c.imAddresses.map {
            CNLabeledValue(label: nil,
                           value: CNInstantMessageAddress(username: $0.value, service: $0.label))
        }
        m.contactRelations = c.relations.map {
            CNLabeledValue(label: cnLabel($0.label), value: CNContactRelation(name: $0.value))
        }
        m.postalAddresses = c.addresses.map { a in
            let postal = CNMutablePostalAddress()
            postal.street = a.street
            postal.city = a.city
            postal.state = a.state
            postal.postalCode = a.postalCode
            postal.country = a.country
            return CNLabeledValue(label: cnLabel(a.label), value: postal)
        }
        if let b = c.birthday {
            var comps = DateComponents()
            comps.year = b.year
            comps.month = b.month
            comps.day = b.day
            m.birthday = comps
        } else {
            m.birthday = nil
        }
        m.dates = c.otherDates.map { d in
            var comps = DateComponents()
            comps.year = d.year
            comps.month = d.month
            comps.day = d.day
            return CNLabeledValue(label: cnLabel(d.label), value: comps as NSDateComponents)
        }
    }

    /// "_$!<Home>!$_" → "home"; freeform labels pass through.
    static func cleanLabel(_ label: String?) -> String {
        guard let label, !label.isEmpty else { return "" }
        if label.hasPrefix("_$!<") && label.hasSuffix(">!$_") {
            return String(label.dropFirst(4).dropLast(4)).lowercased()
        }
        return label
    }

    /// Map common labels back to Apple's canonical constants, keep custom as-is.
    static func cnLabel(_ label: String) -> String? {
        switch label.lowercased() {
        case "": return nil
        case "home": return CNLabelHome
        case "work": return CNLabelWork
        case "mobile", "cell": return CNLabelPhoneNumberMobile
        case "main": return CNLabelPhoneNumberMain
        case "iphone": return CNLabelPhoneNumberiPhone
        case "other": return CNLabelOther
        default: return label
        }
    }
}
#endif
