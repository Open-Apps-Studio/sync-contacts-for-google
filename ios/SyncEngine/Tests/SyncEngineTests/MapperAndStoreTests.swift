import XCTest
@testable import SyncEngine

final class GoogleFieldMapperTests: XCTestCase {

    func fullContact() -> SyncContact {
        var c = SyncContact()
        c.givenName = "Ada"
        c.familyName = "Lovelace"
        c.middleName = "Augusta"
        c.namePrefix = "Countess"
        c.nameSuffix = "of Lovelace"
        c.phoneticGivenName = "AY-da"
        c.nickname = "Ada"
        c.organization = "Analytical Engines"
        c.department = "Programs"
        c.jobTitle = "Mathematician"
        c.phones = [LabeledValue(label: "mobile", value: "+44 20 7946 0000"),
                    LabeledValue(label: "work", value: "+44 20 7946 0001")]
        c.emails = [LabeledValue(label: "home", value: "ada@example.com")]
        c.urls = [LabeledValue(label: "homepage", value: "https://ada.example")]
        c.imAddresses = [LabeledValue(label: "jabber", value: "ada@jabber.example")]
        c.relations = [LabeledValue(label: "spouse", value: "William King")]
        c.addresses = [PostalAddress(label: "home", street: "12 St James Sq", city: "London",
                                     state: "", postalCode: "SW1Y 4JH", country: "UK")]
        c.birthday = DateValue(label: "birthday", year: 1815, month: 12, day: 10)
        c.otherDates = [DateValue(label: "anniversary", year: nil, month: 7, day: 8)]
        return c
    }

    func testRoundTripThroughPersonJSONIsLossless() {
        let original = fullContact()
        let json = GoogleFieldMapper.toPerson(original)
        var restored = GoogleFieldMapper.fromPerson(json).contact
        restored.photoHash = original.photoHash   // photos travel out-of-band
        XCTAssertEqual(restored, original)
    }

    func testYearlessBirthdayRoundTrips() {
        var c = SyncContact()
        c.givenName = "X"
        c.birthday = DateValue(label: "birthday", year: nil, month: 2, day: 29)
        let restored = GoogleFieldMapper.fromPerson(GoogleFieldMapper.toPerson(c)).contact
        XCTAssertEqual(restored.birthday, c.birthday)
    }

    func testMonogramPhotoIsIgnored() {
        let json: [String: Any] = [
            "resourceName": "people/x", "etag": "e",
            "photos": [["url": "https://img", "default": true]]
        ]
        XCTAssertNil(GoogleFieldMapper.fromPerson(json).contact.photoHash)
    }

    func testRealPhotoIsCaptured() {
        let json: [String: Any] = [
            "resourceName": "people/x", "etag": "e",
            "photos": [["url": "https://img"]]
        ]
        XCTAssertEqual(GoogleFieldMapper.fromPerson(json).contact.photoHash, "gurl:https://img")
    }

    func testDeletedFlagIsRead() {
        let json: [String: Any] = [
            "resourceName": "people/x", "etag": "e",
            "metadata": ["deleted": true]
        ]
        XCTAssertTrue(GoogleFieldMapper.fromPerson(json).deleted)
    }

    func testUpdateMaskListsOnlyChangedFieldGroups() {
        let old = fullContact()
        var new = old
        new.jobTitle = "Countess"
        new.phones.removeLast()
        let mask = GoogleFieldMapper.updateMask(from: old, to: new)
        XCTAssertEqual(Set(mask), ["organizations", "phoneNumbers"])
    }

    func testUpdateMaskEmptyWhenNothingChanged() {
        let c = fullContact()
        XCTAssertTrue(GoogleFieldMapper.updateMask(from: c, to: c).isEmpty)
    }
}

final class MappingStoreTests: XCTestCase {
    var store: MappingStore!
    var path: String!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "/mapping-\(UUID().uuidString).sqlite"
        store = try MappingStore(path: path)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(atPath: path)
    }

    func testMappingRoundTrip() throws {
        var c = SyncContact()
        c.givenName = "Ada"
        let m = Mapping(localID: "L1", remoteResourceName: "people/1", remoteEtag: "e1", base: c)
        try store.upsert(m)
        let loaded = try store.mapping(forLocalID: "L1")
        XCTAssertEqual(loaded?.remoteResourceName, "people/1")
        XCTAssertEqual(loaded?.base.givenName, "Ada")
        XCTAssertEqual(try store.mapping(forRemoteName: "people/1")?.localID, "L1")
        XCTAssertEqual(try store.allMappings().count, 1)
    }

    func testUpsertReplaces() throws {
        let c = SyncContact()
        try store.upsert(Mapping(localID: "L1", remoteResourceName: "people/1", remoteEtag: "e1", base: c))
        try store.upsert(Mapping(localID: "L1", remoteResourceName: "people/1", remoteEtag: "e2", base: c))
        XCTAssertEqual(try store.mapping(forLocalID: "L1")?.remoteEtag, "e2")
        XCTAssertEqual(try store.allMappings().count, 1)
    }

    func testDeleteMapping() throws {
        try store.upsert(Mapping(localID: "L1", remoteResourceName: "people/1", remoteEtag: "e", base: SyncContact()))
        try store.deleteMapping(localID: "L1")
        XCTAssertNil(try store.mapping(forLocalID: "L1"))
    }

    func testCursors() throws {
        XCTAssertNil(try store.cursor("google.syncToken"))
        try store.setCursor("google.syncToken", "tok123")
        XCTAssertEqual(try store.cursor("google.syncToken"), "tok123")
        try store.setCursor("google.syncToken", nil)
        XCTAssertNil(try store.cursor("google.syncToken"))
    }

    func testActivityLogOrderAndPrune() throws {
        for i in 1...5 {
            try store.log(ActivityEvent(kind: .syncCompleted, summary: "run \(i)"))
        }
        let recent = try store.recentActivity(limit: 3)
        XCTAssertEqual(recent.map(\.summary), ["run 5", "run 4", "run 3"])
        try store.pruneActivity(keeping: 2)
        XCTAssertEqual(try store.recentActivity(limit: 10).count, 2)
    }

    func testWorkQueue() throws {
        try store.enqueue(.init(kind: .createRemote, payload: Data("a".utf8)))
        try store.enqueue(.init(kind: .deleteLocal, payload: Data("b".utf8)))
        let pending = try store.pendingWork()
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending[0].kind, .createRemote)
        try store.completeWork(id: pending[0].id)
        XCTAssertEqual(try store.pendingWork().count, 1)
    }

    func testPersistsAcrossReopen() throws {
        try store.upsert(Mapping(localID: "L1", remoteResourceName: "people/1", remoteEtag: "e", base: SyncContact()))
        store = nil
        store = try MappingStore(path: path)
        XCTAssertEqual(try store.allMappings().count, 1)
    }
}

final class VCardTests: XCTestCase {

    func testRoundTrip() {
        var c = SyncContact()
        c.givenName = "José"
        c.familyName = "García; Jr"
        c.organization = "Acme, Inc"
        c.phones = [LabeledValue(label: "mobile", value: "+34 600 000 000")]
        c.emails = [LabeledValue(label: "work", value: "jose@acme.example")]
        c.addresses = [PostalAddress(label: "home", street: "Calle Mayor 1", city: "Madrid",
                                     state: "", postalCode: "28013", country: "España")]
        c.birthday = DateValue(label: "birthday", year: 1990, month: 1, day: 31)

        let parsed = VCard.parse(VCard.serialize([c]))
        XCTAssertEqual(parsed.count, 1)
        let p = parsed[0]
        XCTAssertEqual(p.givenName, "José")
        XCTAssertEqual(p.familyName, "García; Jr")
        XCTAssertEqual(p.organization, "Acme, Inc")
        XCTAssertEqual(p.phones, c.phones)
        XCTAssertEqual(p.emails, c.emails)
        XCTAssertEqual(p.addresses, c.addresses)
        XCTAssertEqual(p.birthday, c.birthday)
    }

    func testYearlessBirthday() {
        var c = SyncContact()
        c.givenName = "X"
        c.birthday = DateValue(label: "birthday", year: nil, month: 3, day: 4)
        let parsed = VCard.parse(VCard.serialize([c]))
        XCTAssertEqual(parsed[0].birthday?.year, nil)
        XCTAssertEqual(parsed[0].birthday?.month, 3)
        XCTAssertEqual(parsed[0].birthday?.day, 4)
    }

    func testMultipleCards() {
        var a = SyncContact(); a.givenName = "A"
        var b = SyncContact(); b.givenName = "B"
        XCTAssertEqual(VCard.parse(VCard.serialize([a, b])).count, 2)
    }
}

// MARK: - isEffectivelyEmpty

final class EffectivelyEmptyTests: XCTestCase {

    func testTrulyEmptyContactIsEffectivelyEmpty() {
        XCTAssertTrue(SyncContact().isEffectivelyEmpty)
    }

    /// A nickname-only contact carries real content and must NOT be treated as empty,
    /// otherwise it would never be created on the other side.
    func testNicknameOnlyContactIsNotEffectivelyEmpty() {
        var c = SyncContact()
        c.nickname = "Ada"
        XCTAssertFalse(c.isEffectivelyEmpty)
    }

    /// Same for a URL-only contact (and IM / birthday / other dates).
    func testUrlOnlyContactIsNotEffectivelyEmpty() {
        var c = SyncContact()
        c.urls = [LabeledValue(label: "homepage", value: "https://ada.example")]
        XCTAssertFalse(c.isEffectivelyEmpty)
    }

    func testImOnlyContactIsNotEffectivelyEmpty() {
        var c = SyncContact()
        c.imAddresses = [LabeledValue(label: "jabber", value: "ada@jabber.example")]
        XCTAssertFalse(c.isEffectivelyEmpty)
    }

    func testBirthdayOnlyContactIsNotEffectivelyEmpty() {
        var c = SyncContact()
        c.birthday = DateValue(label: "birthday", year: 1815, month: 12, day: 10)
        XCTAssertFalse(c.isEffectivelyEmpty)
    }
}
