import Foundation

/// A labeled multi-value entry (phone, email, URL, IM, relation).
public struct LabeledValue: Codable, Equatable, Hashable, Sendable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct PostalAddress: Codable, Equatable, Hashable, Sendable {
    public var label: String
    public var street: String
    public var city: String
    public var state: String
    public var postalCode: String
    public var country: String

    public init(label: String = "", street: String = "", city: String = "",
                state: String = "", postalCode: String = "", country: String = "") {
        self.label = label
        self.street = street
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.country = country
    }

    public var isEmpty: Bool {
        street.isEmpty && city.isEmpty && state.isEmpty && postalCode.isEmpty && country.isEmpty
    }
}

/// A (possibly year-less) calendar date with a label, e.g. birthday or anniversary.
public struct DateValue: Codable, Equatable, Hashable, Sendable {
    public var label: String
    public var year: Int?
    public var month: Int
    public var day: Int

    public init(label: String = "", year: Int? = nil, month: Int, day: Int) {
        self.label = label
        self.year = year
        self.month = month
        self.day = day
    }
}

/// The normalized, store-agnostic representation of one contact.
/// Both CNContact and Google Person map into this.
public struct SyncContact: Codable, Equatable, Sendable {
    public var givenName: String = ""
    public var familyName: String = ""
    public var middleName: String = ""
    public var namePrefix: String = ""
    public var nameSuffix: String = ""
    public var phoneticGivenName: String = ""
    public var phoneticFamilyName: String = ""
    public var nickname: String = ""
    public var organization: String = ""
    public var department: String = ""
    public var jobTitle: String = ""
    public var phones: [LabeledValue] = []
    public var emails: [LabeledValue] = []
    public var urls: [LabeledValue] = []
    public var imAddresses: [LabeledValue] = []
    public var relations: [LabeledValue] = []
    public var addresses: [PostalAddress] = []
    public var birthday: DateValue?
    public var otherDates: [DateValue] = []
    /// SHA-256 of the photo bytes, if any. Photo bytes travel out-of-band.
    public var photoHash: String?

    public init() {}

    public var displayName: String {
        let name = [namePrefix, givenName, middleName, familyName, nameSuffix]
            .filter { !$0.isEmpty }.joined(separator: " ")
        if !name.isEmpty { return name }
        if !organization.isEmpty { return organization }
        if let email = emails.first?.value, !email.isEmpty { return email }
        if let phone = phones.first?.value, !phone.isEmpty { return phone }
        return "No Name"
    }

    public var isEffectivelyEmpty: Bool {
        givenName.isEmpty && familyName.isEmpty && middleName.isEmpty
            && namePrefix.isEmpty && nameSuffix.isEmpty
            && nickname.isEmpty && organization.isEmpty
            && department.isEmpty && jobTitle.isEmpty
            && phones.isEmpty && emails.isEmpty && addresses.isEmpty
            && urls.isEmpty && imAddresses.isEmpty && relations.isEmpty
            && birthday == nil && otherDates.isEmpty
    }
}

public enum SyncMode: String, Codable, CaseIterable, Sendable {
    case twoWay
    case iphoneToGoogle
    case googleToIphone
}

public struct SyncSettings: Codable, Equatable, Sendable {
    public var mode: SyncMode = .twoWay
    public var syncDeletions: Bool = true
    public var syncPhotos: Bool = true
    public var syncGroups: Bool = true
    public var automaticSync: Bool = true

    public init() {}
}

/// One row of the identity map between the two stores.
public struct Mapping: Codable, Equatable, Sendable {
    public var localID: String
    public var remoteResourceName: String
    public var remoteEtag: String
    /// The normalized contact as of the last successful sync (3-way-merge base).
    public var base: SyncContact
    public var updatedAt: Date

    public init(localID: String, remoteResourceName: String, remoteEtag: String,
                base: SyncContact, updatedAt: Date = Date()) {
        self.localID = localID
        self.remoteResourceName = remoteResourceName
        self.remoteEtag = remoteEtag
        self.base = base
        self.updatedAt = updatedAt
    }
}

public struct Conflict: Codable, Equatable, Sendable {
    public var field: String
    public var keptValue: String
    public var discardedValue: String
    /// Which side the kept value came from.
    public var keptFrom: Side

    public enum Side: String, Codable, Sendable { case local, remote }

    public init(field: String, keptValue: String, discardedValue: String, keptFrom: Side) {
        self.field = field
        self.keptValue = keptValue
        self.discardedValue = discardedValue
        self.keptFrom = keptFrom
    }
}

public enum ActivityKind: String, Codable, Sendable {
    case addedToGoogle, addedToiPhone
    case updatedOnGoogle, updatedOniPhone
    case deletedFromGoogle, deletedFromiPhone
    case merged, conflictResolved, snapshotCreated, snapshotRestored
    case syncStarted, syncCompleted, syncFailed, syncPaused
}

public struct ActivityEvent: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64
    public var timestamp: Date
    public var kind: ActivityKind
    public var summary: String
    public var detail: String?

    public init(id: Int64 = 0, timestamp: Date = Date(), kind: ActivityKind,
                summary: String, detail: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.summary = summary
        self.detail = detail
    }
}

/// Result of one sync pass.
public struct SyncSummary: Codable, Equatable, Sendable {
    public var addedToGoogle = 0
    public var addedToiPhone = 0
    public var updatedOnGoogle = 0
    public var updatedOniPhone = 0
    public var deletedFromGoogle = 0
    public var deletedFromiPhone = 0
    public var conflicts = 0
    public var paused: PauseReason?

    public init() {}

    public enum PauseReason: Codable, Equatable, Sendable {
        /// Deletion guard tripped: the pass wanted to delete more than the threshold.
        case deletionGuard(pendingLocalDeletes: Int, pendingRemoteDeletes: Int)
        /// Google's daily contact-write quota was exhausted mid-pass; resumes automatically.
        case remoteQuotaExhausted
    }

    public var totalChanges: Int {
        addedToGoogle + addedToiPhone + updatedOnGoogle + updatedOniPhone
            + deletedFromGoogle + deletedFromiPhone
    }
}
