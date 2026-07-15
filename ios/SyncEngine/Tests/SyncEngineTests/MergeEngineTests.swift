import XCTest
@testable import SyncEngine

final class MergeEngineTests: XCTestCase {

    func contact(_ given: String = "Ada", phone: String? = nil) -> SyncContact {
        var c = SyncContact()
        c.givenName = given
        c.familyName = "Lovelace"
        if let phone { c.phones = [LabeledValue(label: "mobile", value: phone)] }
        return c
    }

    func testNoChangesProducesNoWrites() {
        let base = contact(phone: "+1 555 0100")
        let r = MergeEngine.merge(base: base, local: base, remote: base)
        XCTAssertFalse(r.localNeedsUpdate)
        XCTAssertFalse(r.remoteNeedsUpdate)
        XCTAssertTrue(r.conflicts.isEmpty)
        XCTAssertEqual(r.merged, base)
    }

    func testLocalOnlyChangePropagatesToRemote() {
        let base = contact()
        var local = base
        local.jobTitle = "Mathematician"
        let r = MergeEngine.merge(base: base, local: local, remote: base)
        XCTAssertEqual(r.merged.jobTitle, "Mathematician")
        XCTAssertFalse(r.localNeedsUpdate)
        XCTAssertTrue(r.remoteNeedsUpdate)
        XCTAssertTrue(r.conflicts.isEmpty)
    }

    func testRemoteOnlyChangePropagatesToLocal() {
        let base = contact()
        var remote = base
        remote.organization = "Analytical Engines Ltd"
        let r = MergeEngine.merge(base: base, local: base, remote: remote)
        XCTAssertEqual(r.merged.organization, "Analytical Engines Ltd")
        XCTAssertTrue(r.localNeedsUpdate)
        XCTAssertFalse(r.remoteNeedsUpdate)
    }

    func testBothChangedScalarKeepsLocalAndLogsConflict() {
        let base = contact()
        var local = base
        local.jobTitle = "Engineer"
        var remote = base
        remote.jobTitle = "Scientist"
        let r = MergeEngine.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(r.merged.jobTitle, "Engineer")
        XCTAssertEqual(r.conflicts.count, 1)
        XCTAssertEqual(r.conflicts[0].field, "Job title")
        XCTAssertEqual(r.conflicts[0].discardedValue, "Scientist")
        XCTAssertEqual(r.conflicts[0].keptFrom, .local)
        XCTAssertTrue(r.remoteNeedsUpdate)   // remote must adopt local's value
        XCTAssertFalse(r.localNeedsUpdate)
    }

    func testBothChangedSameValueIsNotAConflict() {
        let base = contact()
        var local = base
        local.nickname = "Ada L"
        var remote = base
        remote.nickname = "Ada L"
        let r = MergeEngine.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(r.merged.nickname, "Ada L")
        XCTAssertTrue(r.conflicts.isEmpty)
        XCTAssertFalse(r.localNeedsUpdate)
        XCTAssertFalse(r.remoteNeedsUpdate)
    }

    func testCleanLocalPhoneRemovalPropagates() {
        let base = contact(phone: "+1 555 0100")
        var local = base
        local.phones = []
        let r = MergeEngine.merge(base: base, local: local, remote: base)
        XCTAssertTrue(r.merged.phones.isEmpty)
        XCTAssertTrue(r.remoteNeedsUpdate)
    }

    func testBothEditedPhonesUnionsWithoutLoss() {
        let base = contact(phone: "+1 555 0100")
        var local = base
        local.phones.append(LabeledValue(label: "work", value: "+1 555 0200"))
        var remote = base
        remote.phones.append(LabeledValue(label: "home", value: "+1 555 0300"))
        let r = MergeEngine.merge(base: base, local: local, remote: remote)
        let values = Set(r.merged.phones.map(\.value))
        XCTAssertEqual(values, ["+1 555 0100", "+1 555 0200", "+1 555 0300"])
        XCTAssertTrue(r.localNeedsUpdate)
        XCTAssertTrue(r.remoteNeedsUpdate)
    }

    func testDeleteVsEditIsHandledUpstream_editedContactSurvivesMerge() {
        // MergeEngine never sees deletions (orchestrator's job) — sanity: nil base
        // behaves as "brand new on both sides" union.
        var local = contact(phone: "111")
        local.emails = [LabeledValue(label: "home", value: "ada@example.com")]
        var remote = contact(phone: "111")
        remote.urls = [LabeledValue(label: "profile", value: "https://ada.example")]
        let r = MergeEngine.merge(base: nil, local: local, remote: remote)
        XCTAssertEqual(r.merged.emails.count, 1)
        XCTAssertEqual(r.merged.urls.count, 1)
        XCTAssertEqual(r.merged.phones.count, 1)
    }

    func testBirthdayConflictKeepsLocal() {
        var base = contact()
        base.birthday = DateValue(label: "birthday", year: 1815, month: 12, day: 10)
        var local = base
        local.birthday = DateValue(label: "birthday", year: nil, month: 12, day: 10)
        var remote = base
        remote.birthday = DateValue(label: "birthday", year: 1815, month: 12, day: 11)
        let r = MergeEngine.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(r.merged.birthday, local.birthday)
        XCTAssertEqual(r.conflicts.count, 1)
    }

    func testEveryScalarFieldMergesIndependently() {
        var base = SyncContact()
        base.givenName = "A"
        var local = base
        local.familyName = "LocalLast"
        var remote = base
        remote.middleName = "RemoteMiddle"
        let r = MergeEngine.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(r.merged.familyName, "LocalLast")
        XCTAssertEqual(r.merged.middleName, "RemoteMiddle")
        XCTAssertTrue(r.conflicts.isEmpty)
        XCTAssertTrue(r.localNeedsUpdate)
        XCTAssertTrue(r.remoteNeedsUpdate)
    }
}
