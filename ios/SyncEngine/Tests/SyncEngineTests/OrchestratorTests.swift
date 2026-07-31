import XCTest
@testable import SyncEngine

// MARK: - Fakes

final class FakeLocalStore: LocalContactsStore, @unchecked Sendable {
    var contacts: [String: SyncContact] = [:]
    var nextID = 1
    var createdIDs: [String] = []
    var deletedIDs: [String] = []

    func fetchAll() async throws -> [LocalContact] {
        contacts.map { LocalContact(id: $0.key, contact: $0.value) }
            .sorted { $0.id < $1.id }
    }

    func create(_ new: [SyncContact]) async throws -> [String] {
        new.map { c in
            let id = "LC\(nextID)"
            nextID += 1
            contacts[id] = c
            createdIDs.append(id)
            return id
        }
    }

    func update(id: String, contact: SyncContact) async throws {
        contacts[id] = contact
    }

    func delete(ids: [String]) async throws {
        for id in ids {
            contacts.removeValue(forKey: id)
            deletedIDs.append(id)
        }
    }

    func count() async throws -> Int { contacts.count }
}

final class FakeRemoteAPI: GooglePeopleAPI, @unchecked Sendable {
    var people: [String: (etag: String, contact: SyncContact)] = [:]
    var deletedTombstones: Set<String> = []
    var nextID = 1
    var listedSyncTokens: [String?] = []
    var throwOnCreate: Error?
    /// When set, listConnections returns only these resourceNames (delta simulation).
    var deltaOnly: Set<String>?
    /// Number of times createContacts has been invoked (batch counter).
    var createCallCount = 0
    /// If set, the Nth (1-based) createContacts call throws quotaExhausted.
    var throwQuotaOnCreateCall: Int?
    /// If true, the next token-bearing listConnections rejects the token once (as Google
    /// does after ~7 days) so the orchestrator falls back to a full re-list.
    var throwExpiredOnNextTokenList = false
    /// If true, createContacts returns an empty etag (as Google occasionally does) even
    /// though the stored person has a real etag — reproduces the empty-etag lockout.
    var createReturnsEmptyEtag = false

    func getContact(resourceName: String) async throws -> (resourceName: String, etag: String) {
        guard let existing = people[resourceName] else {
            throw PeopleAPIError.http(status: 404, message: "")
        }
        return (resourceName, existing.etag)
    }

    func listConnections(syncToken: String?) async throws -> RemoteDelta {
        listedSyncTokens.append(syncToken)
        if throwExpiredOnNextTokenList, syncToken != nil {
            throwExpiredOnNextTokenList = false
            throw PeopleAPIError.expiredSyncToken
        }
        var records: [GoogleFieldMapper.PersonRecord] = []
        for (name, entry) in people.sorted(by: { $0.key < $1.key }) {
            if let deltaOnly, !deltaOnly.contains(name) { continue }
            records.append(.init(resourceName: name, etag: entry.etag, deleted: false, contact: entry.contact))
        }
        for name in deletedTombstones where deltaOnly?.contains(name) ?? true {
            records.append(.init(resourceName: name, etag: "", deleted: true, contact: SyncContact()))
        }
        return RemoteDelta(records: records, nextSyncToken: "token-\(listedSyncTokens.count)")
    }

    func createContacts(_ contacts: [SyncContact]) async throws -> [(resourceName: String, etag: String)] {
        createCallCount += 1
        if let call = throwQuotaOnCreateCall, call == createCallCount {
            throw PeopleAPIError.quotaExhausted
        }
        if let e = throwOnCreate { throw e }
        return contacts.map { c in
            let name = "people/C\(nextID)"
            nextID += 1
            people[name] = ("etag-1", c)
            return (name, createReturnsEmptyEtag ? "" : "etag-1")
        }
    }

    func updateContact(resourceName: String, etag: String,
                       contact: SyncContact, updateMask: [String]) async throws -> String {
        guard let existing = people[resourceName] else { throw PeopleAPIError.http(status: 404, message: "") }
        // Mirror the real client: an empty stored etag is recovered via getContact so the
        // update can proceed instead of being permanently rejected as stale.
        let effectiveEtag = etag.isEmpty ? try await getContact(resourceName: resourceName).etag : etag
        guard existing.etag == effectiveEtag else { throw PeopleAPIError.staleEtag }
        let newEtag = existing.etag + "'"
        people[resourceName] = (newEtag, contact)
        return newEtag
    }

    func deleteContacts(resourceNames: [String]) async throws {
        for n in resourceNames {
            people.removeValue(forKey: n)
            deletedTombstones.insert(n)
        }
    }
}

// MARK: - Tests

final class OrchestratorTests: XCTestCase {
    var local: FakeLocalStore!
    var remote: FakeRemoteAPI!
    var mapping: MappingStore!
    var settings = SyncSettings()
    var dbPath: String!

    override func setUpWithError() throws {
        local = FakeLocalStore()
        remote = FakeRemoteAPI()
        dbPath = NSTemporaryDirectory() + "/orch-\(UUID().uuidString).sqlite"
        mapping = try MappingStore(path: dbPath)
        settings = SyncSettings()
    }

    override func tearDownWithError() throws {
        mapping = nil
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    func makeOrchestrator(limited: Bool = false) -> SyncOrchestrator {
        let s = settings
        return SyncOrchestrator(deps: .init(local: local, remote: remote, store: mapping,
                                            snapshots: nil,
                                            localAccessLimited: { limited },
                                            settings: { s }))
    }

    func person(_ name: String, phone: String? = nil) -> SyncContact {
        var c = SyncContact()
        let parts = name.split(separator: " ")
        c.givenName = String(parts.first ?? "")
        c.familyName = parts.count > 1 ? String(parts[1]) : ""
        if let phone { c.phones = [LabeledValue(label: "mobile", value: phone)] }
        return c
    }

    func testFirstSyncMergesAndCopiesBothWays() async throws {
        local.contacts["L1"] = person("Ada Lovelace", phone: "+1 555 0100")   // both sides
        local.contacts["L2"] = person("Only Local")
        remote.people["people/R1"] = ("e1", person("Ada Lovelace", phone: "5550100"))
        remote.people["people/R9"] = ("e9", person("Only Remote"))

        let summary = try await makeOrchestrator().sync(isFirstSync: true)

        XCTAssertEqual(summary.addedToGoogle, 1)      // Only Local
        XCTAssertEqual(summary.addedToiPhone, 1)      // Only Remote
        XCTAssertEqual(try mapping.allMappings().count, 3)
        XCTAssertEqual(remote.people.count, 3)
        XCTAssertEqual(local.contacts.count, 3)
    }

    func testDifferentAccountResetsMappingsAndNeverDeletesLocal() async throws {
        // Account A: Ada exists on both the phone and Google account A.
        local.contacts["L1"] = person("Ada Lovelace", phone: "+1 555 0100")
        remote.people["people/RA"] = ("eA", person("Ada Lovelace", phone: "5550100"))
        _ = try await makeOrchestrator().sync(isFirstSync: true, accountKey: "a@example.com")
        XCTAssertEqual(try mapping.allMappings().count, 1)
        XCTAssertEqual(try mapping.cursor("google.accountKey"), "a@example.com")

        // The user disconnects and connects a DIFFERENT Google account B whose People
        // list is entirely different (Ada is not in account B). Ada is still on the phone.
        remote.people = ["people/RB": ("eB", person("Bob Newman"))]
        remote.deletedTombstones = []
        remote.deltaOnly = nil

        let summary = try await makeOrchestrator().sync(accountKey: "b@example.com")

        // The phone's Ada must NOT be deleted just because account B doesn't have her.
        XCTAssertTrue(local.deletedIDs.isEmpty,
                      "reconnecting a different account must never delete local contacts")
        XCTAssertNotNil(local.contacts["L1"], "Ada should still be on the phone")
        // The stale account-A mapping is gone; state now reflects account B only.
        XCTAssertNil(try mapping.mapping(forRemoteName: "people/RA"))
        XCTAssertEqual(try mapping.cursor("google.accountKey"), "b@example.com")
        // Treated as a fresh first sync for B: Bob is pulled down to the phone.
        XCTAssertEqual(summary.addedToiPhone, 1)
    }

    func testSecondPassIsIdempotent() async throws {
        local.contacts["L1"] = person("Ada Lovelace")
        _ = try await makeOrchestrator().sync(isFirstSync: true)
        let second = try await makeOrchestrator().sync()
        XCTAssertEqual(second.totalChanges, 0)
    }

    func testLocalEditPropagatesToRemote() async throws {
        local.contacts["L1"] = person("Ada Lovelace")
        _ = try await makeOrchestrator().sync(isFirstSync: true)

        var edited = local.contacts["L1"]!
        edited.jobTitle = "Mathematician"
        local.contacts["L1"] = edited

        let summary = try await makeOrchestrator().sync()
        XCTAssertEqual(summary.updatedOnGoogle, 1)
        let remoteContact = remote.people.values.first!.contact
        XCTAssertEqual(remoteContact.jobTitle, "Mathematician")
    }

    func testRemoteEditPropagatesToLocal() async throws {
        local.contacts["L1"] = person("Ada Lovelace")
        _ = try await makeOrchestrator().sync(isFirstSync: true)

        let name = remote.people.keys.first!
        var edited = remote.people[name]!.contact
        edited.organization = "Analytical Engines"
        remote.people[name] = ("etag-2", edited)

        let summary = try await makeOrchestrator().sync()
        XCTAssertEqual(summary.updatedOniPhone, 1)
        XCTAssertEqual(local.contacts["L1"]?.organization, "Analytical Engines")
    }

    func testNoEchoLoopAfterPropagation() async throws {
        local.contacts["L1"] = person("Ada Lovelace")
        _ = try await makeOrchestrator().sync(isFirstSync: true)
        var edited = local.contacts["L1"]!
        edited.nickname = "Ada"
        local.contacts["L1"] = edited
        _ = try await makeOrchestrator().sync()
        // A third pass must be a no-op: the write we made must not bounce back.
        let third = try await makeOrchestrator().sync()
        XCTAssertEqual(third.totalChanges, 0)
    }

    func testLocalDeletePropagates() async throws {
        local.contacts["L1"] = person("Ada Lovelace")
        local.contacts["L2"] = person("Grace Hopper")
        // Big enough book that guard floor (10) isn't hit... it's 2 contacts; deleting 1 <= 10 → allowed.
        _ = try await makeOrchestrator().sync(isFirstSync: true)

        local.contacts.removeValue(forKey: "L1")
        let summary = try await makeOrchestrator().sync()
        XCTAssertEqual(summary.deletedFromGoogle, 1)
        XCTAssertEqual(remote.people.count, 1)
        XCTAssertEqual(try mapping.allMappings().count, 1)
    }

    func testRemoteDeleteTombstonePropagates() async throws {
        local.contacts["L1"] = person("Ada Lovelace")
        _ = try await makeOrchestrator().sync(isFirstSync: true)

        let name = remote.people.keys.first!
        remote.people.removeValue(forKey: name)
        remote.deletedTombstones.insert(name)

        let summary = try await makeOrchestrator().sync()
        XCTAssertEqual(summary.deletedFromiPhone, 1)
        XCTAssertTrue(local.contacts.isEmpty)
    }

    func testEditBeatsDelete() async throws {
        local.contacts["L1"] = person("Ada Lovelace")
        _ = try await makeOrchestrator().sync(isFirstSync: true)

        // Deleted on Google, edited on the phone → edit wins, recreated on Google.
        let name = remote.people.keys.first!
        remote.people.removeValue(forKey: name)
        remote.deletedTombstones.insert(name)
        var edited = local.contacts["L1"]!
        edited.jobTitle = "Survivor"
        local.contacts["L1"] = edited

        let summary = try await makeOrchestrator().sync()
        XCTAssertEqual(summary.deletedFromiPhone, 0)
        XCTAssertEqual(summary.addedToGoogle, 1)
        XCTAssertEqual(local.contacts.count, 1)
        XCTAssertTrue(remote.people.values.contains { $0.contact.jobTitle == "Survivor" })
    }

    func testDeletionGuardPausesMassDelete() async throws {
        for i in 1...30 {
            local.contacts["L\(i)"] = person("Person Number\(i)", phone: "555\(String(format: "%04d", i))")
        }
        _ = try await makeOrchestrator().sync(isFirstSync: true)
        XCTAssertEqual(remote.people.count, 30)

        // Simulate catastrophe: 25 of 30 vanish locally.
        for i in 1...25 { local.contacts.removeValue(forKey: "L\(i)") }

        let orch = makeOrchestrator()
        let summary = try await orch.sync()
        guard case .deletionGuard(_, let pendingRemote)? = summary.paused else {
            return XCTFail("expected deletion-guard pause, got \(String(describing: summary.paused))")
        }
        XCTAssertEqual(pendingRemote, 25)
        XCTAssertEqual(remote.people.count, 30)   // nothing deleted yet

        // User confirms → deletions apply.
        let resumed = try await orch.confirmDeletionsAndResume()
        XCTAssertEqual(resumed.deletedFromGoogle, 25)
        XCTAssertEqual(remote.people.count, 5)
    }

    func testOneWayIphoneToGoogleNeverWritesLocal() async throws {
        settings.mode = .iphoneToGoogle
        local.contacts["L1"] = person("Ada Lovelace")
        remote.people["people/R9"] = ("e9", person("Only Remote"))

        let summary = try await makeOrchestrator().sync(isFirstSync: true)
        XCTAssertEqual(summary.addedToGoogle, 1)
        XCTAssertEqual(summary.addedToiPhone, 0)
        XCTAssertEqual(local.contacts.count, 1)   // remote-only contact NOT copied
    }

    func testOneWayGoogleToIphoneNeverWritesRemote() async throws {
        settings.mode = .googleToIphone
        local.contacts["L1"] = person("Only Local")
        remote.people["people/R1"] = ("e1", person("Remote Person"))

        let summary = try await makeOrchestrator().sync(isFirstSync: true)
        XCTAssertEqual(summary.addedToiPhone, 1)
        XCTAssertEqual(summary.addedToGoogle, 0)
        XCTAssertEqual(remote.people.count, 1)
    }

    func testQuotaExhaustionPausesGracefully() async throws {
        local.contacts["L1"] = person("Ada Lovelace")
        remote.throwOnCreate = PeopleAPIError.quotaExhausted
        let summary = try await makeOrchestrator().sync(isFirstSync: true)
        XCTAssertEqual(summary.paused, .remoteQuotaExhausted)
    }

    func testSyncTokenIsStoredAndReused() async throws {
        local.contacts["L1"] = person("Ada Lovelace")
        _ = try await makeOrchestrator().sync(isFirstSync: true)
        _ = try await makeOrchestrator().sync()
        XCTAssertEqual(remote.listedSyncTokens.first!, nil)
        XCTAssertNotNil(remote.listedSyncTokens.last!)
    }

    func testEmptyContactsAreNotSynced() async throws {
        local.contacts["L1"] = SyncContact()   // completely empty
        let summary = try await makeOrchestrator().sync(isFirstSync: true)
        XCTAssertEqual(summary.addedToGoogle, 0)
    }

    // MARK: - Edge-case hardening

    /// #2/#9 Limited Contacts Access (iOS 18): a contact absent from the *partial*
    /// local view must never be read as a deletion and propagated to Google.
    func testLimitedAccessNeverDeletesRemoteForMissingLocal() async throws {
        settings.syncDeletions = true
        local.contacts["L1"] = person("Ada Lovelace")
        local.contacts["L2"] = person("Grace Hopper")
        _ = try await makeOrchestrator().sync(isFirstSync: true)
        XCTAssertEqual(remote.people.count, 2)

        // Contact vanishes from the *visible* subset (limited access) — not truly deleted.
        local.contacts.removeValue(forKey: "L1")

        let orch = makeOrchestrator(limited: true)
        let summary = try await orch.sync()
        XCTAssertEqual(summary.deletedFromGoogle, 0)          // never deleted from Google
        XCTAssertEqual(remote.people.count, 2)               // both still present
        XCTAssertEqual(try mapping.allMappings().count, 2)   // mapping preserved for later
    }

    /// Contrast: with *full* access the same disappearance is a real deletion.
    func testFullAccessStillDeletesRemoteForMissingLocal() async throws {
        settings.syncDeletions = true
        local.contacts["L1"] = person("Ada Lovelace")
        local.contacts["L2"] = person("Grace Hopper")
        _ = try await makeOrchestrator().sync(isFirstSync: true)
        local.contacts.removeValue(forKey: "L1")
        let summary = try await makeOrchestrator(limited: false).sync()
        XCTAssertEqual(summary.deletedFromGoogle, 1)
    }

    /// #3 Expired sync token → transparent full re-list; returning the same people must
    /// neither duplicate contacts nor lose mappings.
    func testExpiredSyncTokenFullRelistDoesNotDuplicateOrLose() async throws {
        local.contacts["L1"] = person("Ada Lovelace")
        remote.people["people/R9"] = ("e9", person("Grace Hopper"))
        _ = try await makeOrchestrator().sync(isFirstSync: true)
        XCTAssertEqual(try mapping.allMappings().count, 2)

        // Next pass presents the stored token; Google rejects it, forcing a full re-list
        // that happens to return exactly the same people.
        remote.throwExpiredOnNextTokenList = true
        let summary = try await makeOrchestrator().sync()

        XCTAssertEqual(summary.totalChanges, 0)              // nothing actually changed
        XCTAssertEqual(try mapping.allMappings().count, 2)   // no lost mappings
        XCTAssertEqual(local.contacts.count, 2)             // no duplicate locals
        XCTAssertEqual(remote.people.count, 2)             // no duplicate remotes
        XCTAssertTrue(remote.listedSyncTokens.contains { $0 != nil })  // token was tried
        XCTAssertEqual(remote.listedSyncTokens.last!, nil)            // then a full re-list
    }

    /// #4 Concurrent triggers (push + manual + BGTask): a second concurrent sync must
    /// coalesce to a no-op and never double-apply.
    func testConcurrentSyncCoalesces() async throws {
        local.contacts["L1"] = person("Ada Lovelace")
        local.contacts["L2"] = person("Grace Hopper")
        let orch = makeOrchestrator()
        async let a = orch.sync(isFirstSync: true)
        async let b = orch.sync(isFirstSync: true)
        let (r1, r2) = try await (a, b)
        XCTAssertEqual(r1.addedToGoogle + r2.addedToGoogle, 2)  // work done exactly once
        XCTAssertEqual(remote.people.count, 2)                 // no double-create
        XCTAssertEqual(try mapping.allMappings().count, 2)
    }

    /// #5/#23 Company-only contacts are valid and must sync; truly-empty ones must not.
    func testCompanyOnlyContactIsSyncedButEmptyIsNot() async throws {
        var withPhone = SyncContact()
        withPhone.organization = "Acme Corp"
        withPhone.phones = [LabeledValue(label: "work", value: "5551234")]
        local.contacts["L1"] = withPhone

        var orgOnly = SyncContact()
        orgOnly.organization = "NoPhone LLC"
        local.contacts["L2"] = orgOnly

        local.contacts["L3"] = SyncContact()   // truly empty → excluded

        let summary = try await makeOrchestrator().sync(isFirstSync: true)
        XCTAssertEqual(summary.addedToGoogle, 2)   // both company contacts, not the empty one
    }

    /// #6 A remote update whose mask ends up empty (only a non-updatable field like a
    /// photo differs) must be skipped — no wasted/invalid updateContact call.
    func testRemoteUpdateWithEmptyMaskIsSkipped() async throws {
        local.contacts["L1"] = person("Ada Lovelace")
        _ = try await makeOrchestrator().sync(isFirstSync: true)

        var edited = local.contacts["L1"]!
        edited.photoHash = "cn:12345"   // photos aren't part of the update mask
        local.contacts["L1"] = edited

        let summary = try await makeOrchestrator().sync()
        XCTAssertEqual(summary.updatedOnGoogle, 0)
    }

    /// #7 Network failure mid-sync must propagate and leave NO orphan mappings, so a
    /// later retry succeeds cleanly (no partial-mapping corruption).
    func testNetworkFailureDuringCreateLeavesNoOrphanMappings() async throws {
        local.contacts["L1"] = person("Ada Lovelace")
        remote.throwOnCreate = URLError(.notConnectedToInternet)
        do {
            _ = try await makeOrchestrator().sync(isFirstSync: true)
            XCTFail("expected URLError to propagate")
        } catch is URLError {
            // expected
        }
        XCTAssertEqual(try mapping.allMappings().count, 0)   // nothing half-written
        XCTAssertTrue(remote.people.isEmpty)

        remote.throwOnCreate = nil
        let summary = try await makeOrchestrator().sync(isFirstSync: true)
        XCTAssertEqual(summary.addedToGoogle, 1)
        XCTAssertEqual(try mapping.allMappings().count, 1)
    }

    /// #8/#10 A quota throw partway through a large first sync must leave the
    /// already-created contacts mapped, so the next run resumes instead of restarting
    /// (and re-creating duplicates).
    func testQuotaMidCreateKeepsAlreadyCreatedMappings() async throws {
        for i in 1...250 {
            local.contacts["L\(i)"] = person("Person N\(i)", phone: "555\(String(format: "%05d", i))")
        }
        remote.throwQuotaOnCreateCall = 2   // first batch (200) commits, second throws

        let summary = try await makeOrchestrator().sync(isFirstSync: true)
        XCTAssertEqual(summary.paused, .remoteQuotaExhausted)
        XCTAssertEqual(remote.people.count, 200)             // first batch created
        XCTAssertEqual(try mapping.allMappings().count, 200) // and mapped → resumable

        // Recover: a follow-up pass finishes the remaining 50 without duplicating.
        remote.throwQuotaOnCreateCall = nil
        let resumed = try await makeOrchestrator().sync()
        XCTAssertEqual(resumed.addedToGoogle, 50)
        XCTAssertEqual(remote.people.count, 250)
        XCTAssertEqual(try mapping.allMappings().count, 250)
    }

    /// #3 Empty-etag lockout: a contact created with a blank etag must not be locked out
    /// of future updates. The stale/empty etag would make Google reject every update as
    /// staleEtag forever; the client recovers the current etag so the update proceeds.
    func testEmptyEtagFromCreateDoesNotLockOutUpdates() async throws {
        remote.createReturnsEmptyEtag = true
        local.contacts["L1"] = person("Ada Lovelace")
        _ = try await makeOrchestrator().sync(isFirstSync: true)

        // The mapping was persisted with the empty etag Google handed back.
        XCTAssertEqual(try mapping.allMappings().first?.remoteEtag, "")

        // Edit locally → a remote update is required, carrying the empty etag.
        var edited = local.contacts["L1"]!
        edited.jobTitle = "Mathematician"
        local.contacts["L1"] = edited

        let summary = try await makeOrchestrator().sync()
        XCTAssertEqual(summary.updatedOnGoogle, 1)   // update succeeded despite empty etag
        XCTAssertTrue(remote.people.values.contains { $0.contact.jobTitle == "Mathematician" })
        // And the mapping now carries a real (non-empty) etag going forward.
        XCTAssertFalse((try mapping.allMappings().first?.remoteEtag ?? "").isEmpty)
    }
}
