import XCTest
@testable import SyncEngine

final class MatchingTests: XCTestCase {

    func make(_ id: String, given: String, family: String = "", phone: String? = nil,
              email: String? = nil, org: String = "") -> Matching.Candidate {
        var c = SyncContact()
        c.givenName = given
        c.familyName = family
        c.organization = org
        if let phone { c.phones = [LabeledValue(label: "mobile", value: phone)] }
        if let email { c.emails = [LabeledValue(label: "home", value: email)] }
        return Matching.Candidate(id: id, contact: c)
    }

    func testExactMatchByNameAndPhone() {
        let result = Matching.match(
            local: [make("L1", given: "Priya", family: "Sharma", phone: "+1 (415) 555-0100")],
            remote: [make("R1", given: "Priya", family: "Sharma", phone: "4155550100")])
        XCTAssertEqual(result.pairs.count, 1)
        XCTAssertTrue(result.localOnly.isEmpty)
        XCTAssertTrue(result.remoteOnly.isEmpty)
    }

    func testDiacriticsAndCaseFoldInNames() {
        let result = Matching.match(
            local: [make("L1", given: "Åsa", family: "Öberg", email: "asa@ex.com")],
            remote: [make("R1", given: "asa", family: "oberg", email: "ASA@ex.com")])
        XCTAssertEqual(result.pairs.count, 1)
    }

    func testSameNameDifferentChannelsDoesNotMatch() {
        let result = Matching.match(
            local: [make("L1", given: "John", family: "Smith", phone: "111 222 3333")],
            remote: [make("R1", given: "John", family: "Smith", phone: "999 888 7777")])
        XCTAssertTrue(result.pairs.isEmpty)
        XCTAssertEqual(result.localOnly.count, 1)
        XCTAssertEqual(result.remoteOnly.count, 1)
    }

    func testSameNameBareContactMatches() {
        // A name-only contact on one side pairs with the richer copy on the other.
        let result = Matching.match(
            local: [make("L1", given: "Grace", family: "Hopper")],
            remote: [make("R1", given: "Grace", family: "Hopper", phone: "555", email: "g@navy.mil")])
        XCTAssertEqual(result.pairs.count, 1)
    }

    func testCompanyOnlyContactsMatchOnOrgAndPhone() {
        let result = Matching.match(
            local: [make("L1", given: "", phone: "+44 20 7946 0000", org: "Acme Plumbing")],
            remote: [make("R1", given: "", phone: "020 7946 0000", org: "ACME plumbing")])
        XCTAssertEqual(result.pairs.count, 1)
    }

    func testPhoneSuffixMatchRequiresSevenDigits() {
        XCTAssertTrue(Matching.phonesMatch("+14155550100", "4155550100"))
        XCTAssertFalse(Matching.phonesMatch("0100", "555-0100"))
        XCTAssertFalse(Matching.phonesMatch("", ""))
    }

    func testEachRemoteMatchesAtMostOnce() {
        let result = Matching.match(
            local: [make("L1", given: "Sam", family: "Lee", email: "sam@ex.com"),
                    make("L2", given: "Sam", family: "Lee", email: "sam@ex.com")],
            remote: [make("R1", given: "Sam", family: "Lee", email: "sam@ex.com")])
        XCTAssertEqual(result.pairs.count, 1)
        XCTAssertEqual(result.localOnly.count, 1)
    }
}

final class DeletionGuardTests: XCTestCase {

    func testSmallBooksUseAbsoluteFloor() {
        XCTAssertEqual(DeletionGuard.threshold(totalContacts: 20), 10)
        XCTAssertTrue(DeletionGuard.allows(pendingDeletes: 10, totalContacts: 20))
        XCTAssertFalse(DeletionGuard.allows(pendingDeletes: 11, totalContacts: 20))
    }

    func testLargeBooksUseTwentyPercent()  {
        XCTAssertEqual(DeletionGuard.threshold(totalContacts: 1000), 200)
        XCTAssertTrue(DeletionGuard.allows(pendingDeletes: 200, totalContacts: 1000))
        XCTAssertFalse(DeletionGuard.allows(pendingDeletes: 201, totalContacts: 1000))
    }

    func testZeroDeletesAlwaysAllowed() {
        XCTAssertTrue(DeletionGuard.allows(pendingDeletes: 0, totalContacts: 0))
    }
}
