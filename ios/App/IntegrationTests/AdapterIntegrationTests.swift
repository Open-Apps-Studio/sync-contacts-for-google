import XCTest
import Contacts
@testable import SyncEngine

/// Real-device (simulator) integration test for `CNContactStoreAdapter`.
///
/// Unlike the unit tests in the SyncEngine package (which never touch a real
/// `CNContactStore`), this suite runs inside the ContactsSync app host on the
/// iOS Simulator, so it can exercise the adapter against the live Contacts
/// framework: create → fetchAll → update → fetchAll → delete → fetchAll.
///
/// The whole suite skips (never fails) when Contacts access is not authorized,
/// so it is CI-safe. To make it RUN, pre-grant contacts permission to the test
/// host, e.g.:
///   xcrun simctl privacy booted grant contacts com.openappsstudio.contactssync
final class AdapterIntegrationTests: XCTestCase {

    var store: CNContactStore!
    var adapter: CNContactStoreAdapter!
    /// IDs created during a test, cleaned up in tearDown even on failure.
    var createdIDs: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        store = CNContactStore()
        adapter = CNContactStoreAdapter(store: store)
        createdIDs = []

        // Best-effort: request access. On the simulator this returns whatever
        // the pre-granted TCC state allows without prompting under xcodebuild.
        var status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            _ = try? await store.requestAccess(for: .contacts)
            status = CNContactStore.authorizationStatus(for: .contacts)
        }

        // We need WRITE access. `.limited` (iOS 18) is not enough for creating
        // arbitrary contacts, so require full `.authorized`.
        guard status == .authorized else {
            throw XCTSkip("Contacts not authorized (status=\(status.rawValue)); "
                + "grant with: xcrun simctl privacy booted grant contacts com.openappsstudio.contactssync")
        }
    }

    override func tearDown() async throws {
        if let adapter, !createdIDs.isEmpty {
            try? await adapter.delete(ids: createdIDs)
        }
        adapter = nil
        store = nil
        createdIDs = []
        try await super.tearDown()
    }

    /// A contact exercising every field the adapter maps.
    private func sampleContact(tag: String) -> SyncContact {
        var c = SyncContact()
        c.givenName = "Grace"
        c.familyName = "Hopper-\(tag)"
        c.middleName = "Brewster"
        c.namePrefix = "Rear Admiral"
        c.nameSuffix = "USN"
        c.nickname = "Amazing Grace"
        c.organization = "US Navy"
        c.department = "Computing"
        c.jobTitle = "Computer Scientist"
        c.phones = [
            LabeledValue(label: "mobile", value: "+1 202 555 0143"),
            LabeledValue(label: "work", value: "+1 202 555 0199"),
        ]
        c.emails = [LabeledValue(label: "work", value: "grace.\(tag)@example.com")]
        c.addresses = [PostalAddress(label: "work", street: "1 Navy Way", city: "Arlington",
                                     state: "VA", postalCode: "22202", country: "USA")]
        c.birthday = DateValue(label: "birthday", year: 1906, month: 12, day: 9)
        return c
    }

    // MARK: - Full lifecycle round trip

    func testCreateFetchUpdateFetchDeleteFetch() async throws {
        let tag = UUID().uuidString.prefix(8).description
        let original = sampleContact(tag: tag)

        // 1. CREATE
        let ids = try await adapter.create([original])
        createdIDs = ids
        XCTAssertEqual(ids.count, 1, "create should return one id")
        let id = try XCTUnwrap(ids.first)
        XCTAssertFalse(id.isEmpty, "created id should be non-empty")

        // 2. FETCH ALL → find it and verify field mapping survived the round trip.
        let afterCreate = try await adapter.fetchAll()
        let foundCreate = try XCTUnwrap(afterCreate.first { $0.id == id },
                                        "created contact should appear in fetchAll")
        let mapped = foundCreate.contact

        // Name
        XCTAssertEqual(mapped.givenName, original.givenName)
        XCTAssertEqual(mapped.familyName, original.familyName)
        XCTAssertEqual(mapped.middleName, original.middleName)
        XCTAssertEqual(mapped.namePrefix, original.namePrefix)
        XCTAssertEqual(mapped.nameSuffix, original.nameSuffix)
        XCTAssertEqual(mapped.nickname, original.nickname)
        // Org
        XCTAssertEqual(mapped.organization, original.organization)
        XCTAssertEqual(mapped.department, original.department)
        XCTAssertEqual(mapped.jobTitle, original.jobTitle)
        // Phones (labels normalized: mobile/work)
        XCTAssertEqual(mapped.phones, original.phones, "phones + labels should round trip")
        // Emails
        XCTAssertEqual(mapped.emails, original.emails, "emails + labels should round trip")
        // Address
        XCTAssertEqual(mapped.addresses, original.addresses, "postal address should round trip")
        // Birthday
        XCTAssertEqual(mapped.birthday, original.birthday, "birthday should round trip")

        // count() should reflect at least this contact.
        let count = try await adapter.count()
        XCTAssertGreaterThanOrEqual(count, 1)

        // 3. UPDATE a couple of fields.
        var edited = original
        edited.jobTitle = "Pioneer of Computing"
        edited.emails = [LabeledValue(label: "home", value: "grace.\(tag)@home.example")]
        try await adapter.update(id: id, contact: edited)

        // 4. FETCH ALL → see the change.
        let afterUpdate = try await adapter.fetchAll()
        let foundUpdate = try XCTUnwrap(afterUpdate.first { $0.id == id },
                                        "updated contact should still be present")
        XCTAssertEqual(foundUpdate.contact.jobTitle, "Pioneer of Computing",
                       "jobTitle change should be visible after fetchAll")
        XCTAssertEqual(foundUpdate.contact.emails,
                       [LabeledValue(label: "home", value: "grace.\(tag)@home.example")],
                       "email change (value + label) should be visible after fetchAll")
        // Unchanged fields remain.
        XCTAssertEqual(foundUpdate.contact.givenName, original.givenName)
        XCTAssertEqual(foundUpdate.contact.phones, original.phones)

        // 5. DELETE
        try await adapter.delete(ids: [id])
        createdIDs = []  // deleted; nothing for tearDown to clean.

        // 6. FETCH ALL → gone.
        let afterDelete = try await adapter.fetchAll()
        XCTAssertNil(afterDelete.first { $0.id == id },
                     "deleted contact must not appear in fetchAll")
    }

    // MARK: - Container discovery smoke test

    func testWritableContainerIsResolvable() throws {
        // Should not throw and should be a stable identifier on the simulator.
        let containerID = try adapter.writableContainerID()
        XCTAssertFalse(containerID.isEmpty, "writable container id should be non-empty")
        // hasGoogleCardDAVContainer just needs to answer without crashing.
        _ = adapter.hasGoogleCardDAVContainer()
    }
}
