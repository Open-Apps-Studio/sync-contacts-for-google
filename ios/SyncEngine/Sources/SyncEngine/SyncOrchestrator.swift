import Foundation

/// The heart of the engine: one serialized sync pass.
///
/// Strategy: full-state three-way reconciliation. The mapping table holds the last
/// synced state (base) per pair; each pass diffs both live stores against it. This is
/// echo-proof (no-op diffs produce no writes) and survives lost change-history tokens.
public actor SyncOrchestrator {

    public struct Dependencies {
        public var local: LocalContactsStore
        public var remote: GooglePeopleAPI
        public var store: MappingStore
        public var snapshots: SnapshotManaging?
        /// True when the OS only grants a *partial* view of the address book
        /// (iOS 18 Limited Contacts Access). In that mode a contact that is
        /// "missing locally" may simply be invisible, so local-side deletions
        /// must never be inferred/propagated.
        public var localAccessLimited: () -> Bool
        public var settings: () -> SyncSettings

        public init(local: LocalContactsStore, remote: GooglePeopleAPI, store: MappingStore,
                    snapshots: SnapshotManaging? = nil,
                    localAccessLimited: @escaping () -> Bool = { false },
                    settings: @escaping () -> SyncSettings) {
            self.local = local
            self.remote = remote
            self.store = store
            self.snapshots = snapshots
            self.localAccessLimited = localAccessLimited
            self.settings = settings
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        case syncing
        case pausedDeletionGuard(pendingLocalDeletes: Int, pendingRemoteDeletes: Int)
        case pausedQuota
    }

    private let deps: Dependencies
    private var isSyncing = false
    public private(set) var state: State = .idle
    /// Set when the deletion guard pauses a pass; confirmDeletionsAndResume applies them.
    private var pendingGuardedPass: PlannedPass?

    public init(deps: Dependencies) {
        self.deps = deps
    }

    private static let remoteSyncTokenKey = "google.syncToken"
    private static let accountKeyKey = "google.accountKey"

    // MARK: - Planning types

    struct PlannedPass {
        var createRemote: [(localID: String, contact: SyncContact)] = []
        var updateRemote: [(mapping: Mapping, contact: SyncContact, mask: [String])] = []
        var deleteRemote: [Mapping] = []
        var createLocal: [GoogleFieldMapper.PersonRecord] = []
        var updateLocal: [(mapping: Mapping, contact: SyncContact)] = []
        var deleteLocal: [Mapping] = []
        var rebaseOnly: [(mapping: Mapping, merged: SyncContact, etag: String?)] = []
        var conflicts: [(name: String, conflicts: [Conflict])] = []
        var nextSyncToken: String?
        var localTotal = 0
        var remoteTotal = 0
    }

    // MARK: - Public API

    /// Runs one sync pass. Concurrent calls coalesce (the second returns the first's outcome
    /// conservatively as an empty summary).
    @discardableResult
    public func sync(isFirstSync: Bool = false, accountKey: String? = nil) async throws -> SyncSummary {
        guard !isSyncing else { return SyncSummary() }
        isSyncing = true
        state = .syncing
        defer { isSyncing = false }

        var firstSync = isFirstSync
        if let accountKey {
            let previous = try? deps.store.cursor(Self.accountKeyKey)
            if let previous, previous != accountKey {
                // The connected Google account changed. The old account's identity
                // mappings and sync token are meaningless — and dangerous — for the new
                // account: stale resourceNames would either duplicate contacts or, worse,
                // be read as remote deletions and wipe the phone. Reset to a clean
                // first-sync for the new account instead of mixing the two.
                try deps.store.deleteAllMappings()
                try deps.store.clearWorkQueue()
                try deps.store.setCursor(Self.remoteSyncTokenKey, nil)
                firstSync = true
                try? deps.store.log(ActivityEvent(
                    kind: .syncStarted,
                    summary: "Connected Google account changed — resetting local sync state"))
            }
            try? deps.store.setCursor(Self.accountKeyKey, accountKey)
        }

        try? deps.store.log(ActivityEvent(kind: .syncStarted, summary: "Sync started"))
        do {
            let plan = try await buildPlan(isFirstSync: firstSync)
            let settings = deps.settings()

            // Deletion guard — across both directions, before any write.
            if settings.syncDeletions {
                let localOK = DeletionGuard.allows(pendingDeletes: plan.deleteLocal.count,
                                                   totalContacts: plan.localTotal)
                let remoteOK = DeletionGuard.allows(pendingDeletes: plan.deleteRemote.count,
                                                    totalContacts: plan.remoteTotal)
                if !localOK || !remoteOK {
                    pendingGuardedPass = plan
                    state = .pausedDeletionGuard(pendingLocalDeletes: plan.deleteLocal.count,
                                                 pendingRemoteDeletes: plan.deleteRemote.count)
                    var summary = SyncSummary()
                    summary.paused = .deletionGuard(pendingLocalDeletes: plan.deleteLocal.count,
                                                    pendingRemoteDeletes: plan.deleteRemote.count)
                    try? deps.store.log(ActivityEvent(
                        kind: .syncPaused,
                        summary: "Sync paused: would delete \(plan.deleteLocal.count + plan.deleteRemote.count) contacts",
                        detail: "Deletion guard requires confirmation"))
                    return summary
                }
            }

            let summary = try await apply(plan: plan)
            state = .idle
            try? deps.store.log(ActivityEvent(kind: .syncCompleted,
                                              summary: summaryLine(summary)))
            return summary
        } catch PeopleAPIError.quotaExhausted {
            state = .pausedQuota
            var summary = SyncSummary()
            summary.paused = .remoteQuotaExhausted
            try? deps.store.log(ActivityEvent(kind: .syncPaused,
                                              summary: "Google's daily update limit reached — sync resumes automatically",
                                              detail: nil))
            return summary
        } catch {
            state = .idle
            try? deps.store.log(ActivityEvent(kind: .syncFailed, summary: "Sync failed",
                                              detail: String(describing: error)))
            throw error
        }
    }

    /// User confirmed the deletion-guard prompt: apply the paused pass, deletions included.
    @discardableResult
    public func confirmDeletionsAndResume() async throws -> SyncSummary {
        guard let plan = pendingGuardedPass else { return SyncSummary() }
        pendingGuardedPass = nil
        state = .syncing
        let summary = try await apply(plan: plan)
        state = .idle
        try? deps.store.log(ActivityEvent(kind: .syncCompleted,
                                          summary: summaryLine(summary)))
        return summary
    }

    /// User rejected the pending deletions: rebase the would-be-deleted pairs so the
    /// deletion stops being proposed (the surviving copy is re-adopted as truth).
    public func rejectPendingDeletions() async throws {
        guard let plan = pendingGuardedPass else { return }
        pendingGuardedPass = nil
        // Re-adopt: drop mappings so both sides' survivors get re-matched next pass.
        for m in plan.deleteLocal { try deps.store.deleteMapping(localID: m.localID) }
        for m in plan.deleteRemote { try deps.store.deleteMapping(localID: m.localID) }
        state = .idle
    }

    // MARK: - Planning

    private func buildPlan(isFirstSync: Bool) async throws -> PlannedPass {
        let settings = deps.settings()
        // With only partial (Limited) contacts access the local list is a subset of
        // the truth, so "missing locally" must never be read as a deletion.
        let limitedAccess = deps.localAccessLimited()
        var plan = PlannedPass()

        // 1. Load both sides.
        let localContacts = try await deps.local.fetchAll()
        plan.localTotal = localContacts.count
        let localByID = Dictionary(uniqueKeysWithValues: localContacts.map { ($0.id, $0.contact) })

        let storedToken = try deps.store.cursor(Self.remoteSyncTokenKey)
        let delta: RemoteDelta
        var syncTokenExpired = false
        do {
            delta = try await deps.remote.listConnections(syncToken: isFirstSync ? nil : storedToken)
        } catch PeopleAPIError.expiredSyncToken {
            // The token was rejected, so we re-fetched the FULL connection list.
            // Treat this pass as tokenless (below) — otherwise remote deletions that
            // happened during the token gap are absent from the full list yet never
            // inferred as deletions, leaving ghost contacts on the phone forever.
            syncTokenExpired = true
            delta = try await deps.remote.listConnections(syncToken: nil)
        }
        plan.nextSyncToken = delta.nextSyncToken

        let mappings = try deps.store.allMappings()
        let mappingByLocal = Dictionary(uniqueKeysWithValues: mappings.map { ($0.localID, $0) })
        let mappingByRemote = Dictionary(uniqueKeysWithValues: mappings.map { ($0.remoteResourceName, $0) })

        // Remote state: with a sync token the delta only contains changed people, so
        // build "current remote view" = mappings ⊕ delta.
        var remoteChanged: [String: GoogleFieldMapper.PersonRecord] = [:]
        var remoteDeleted = Set<String>()
        for record in delta.records {
            if record.deleted {
                remoteDeleted.insert(record.resourceName)
            } else {
                remoteChanged[record.resourceName] = record
            }
        }
        let hadToken = (storedToken != nil) && !isFirstSync && !syncTokenExpired
        plan.remoteTotal = hadToken
            ? mappings.count + remoteChanged.keys.filter { mappingByRemote[$0] == nil }.count - remoteDeleted.count
            : delta.records.filter { !$0.deleted }.count

        // 2. First sync (or lost mapping): match unmapped locals against unmapped remotes.
        if mappings.isEmpty {
            let localCandidates = localContacts
                .filter { !$0.contact.isEffectivelyEmpty }
                .map { Matching.Candidate(id: $0.id, contact: $0.contact) }
            let remoteCandidates = delta.records.filter { !$0.deleted && !$0.contact.isEffectivelyEmpty }
                .map { Matching.Candidate(id: $0.resourceName, contact: $0.contact) }
            let match = Matching.match(local: localCandidates, remote: remoteCandidates)

            for pair in match.pairs {
                let record = remoteChanged[pair.remote.id]
                    ?? delta.records.first { $0.resourceName == pair.remote.id }!
                let merged = MergeEngine.merge(base: nil, local: pair.local.contact,
                                               remote: record.contact)
                let mapping = Mapping(localID: pair.local.id, remoteResourceName: record.resourceName,
                                      remoteEtag: record.etag, base: pair.local.contact)
                if merged.remoteNeedsUpdate && settings.mode != .googleToIphone {
                    plan.updateRemote.append((mapping, merged.merged,
                                              GoogleFieldMapper.updateMask(from: record.contact, to: merged.merged)))
                }
                if merged.localNeedsUpdate && settings.mode != .iphoneToGoogle {
                    plan.updateLocal.append((mapping, merged.merged))
                }
                if !merged.remoteNeedsUpdate && !merged.localNeedsUpdate {
                    plan.rebaseOnly.append((mapping, merged.merged, record.etag))
                }
                if !merged.conflicts.isEmpty {
                    plan.conflicts.append((merged.merged.displayName, merged.conflicts))
                }
            }
            if settings.mode != .googleToIphone {
                plan.createRemote = match.localOnly.map { ($0.id, $0.contact) }
            }
            if settings.mode != .iphoneToGoogle {
                plan.createLocal = match.remoteOnly.compactMap { cand in
                    delta.records.first { $0.resourceName == cand.id }
                }
            }
            return plan
        }

        // 3. Steady state: walk existing mappings.
        for mapping in mappings {
            let local = localByID[mapping.localID]
            let remoteRecord = remoteChanged[mapping.remoteResourceName]
            let isRemoteDeleted = remoteDeleted.contains(mapping.remoteResourceName)
            // Without a sync token, absence from the full list = deleted remotely.
            let remoteMissingInFullList = !hadToken
                && remoteRecord == nil
                && !delta.records.contains { $0.resourceName == mapping.remoteResourceName }

            switch (local, isRemoteDeleted || remoteMissingInFullList) {
            case (nil, true):
                // Gone on both sides — just forget the mapping.
                try deps.store.deleteMapping(localID: mapping.localID)
            case (nil, false):
                // Under Limited Contacts Access a contact absent from our partial
                // view is not necessarily deleted — leave the mapping untouched so
                // we never delete from Google (or restore/forget) on a blind spot.
                // Add/update flow for visible contacts is unaffected.
                if limitedAccess { continue }
                // Deleted locally.
                let remoteContact = remoteRecord?.contact ?? mapping.base
                if remoteContact != mapping.base {
                    // Edit-vs-delete: edit wins — restore locally.
                    plan.createLocal.append(remoteRecord
                        ?? GoogleFieldMapper.PersonRecord(resourceName: mapping.remoteResourceName,
                                                          etag: mapping.remoteEtag, deleted: false,
                                                          contact: remoteContact))
                    try deps.store.deleteMapping(localID: mapping.localID)
                } else if settings.syncDeletions && settings.mode != .googleToIphone {
                    plan.deleteRemote.append(mapping)
                } else {
                    try deps.store.deleteMapping(localID: mapping.localID)
                }
            case (let l?, true):
                if l != mapping.base {
                    // Edit-vs-delete: edit wins — recreate remotely.
                    plan.createRemote.append((mapping.localID, l))
                    try deps.store.deleteMapping(localID: mapping.localID)
                } else if settings.syncDeletions && settings.mode != .iphoneToGoogle {
                    plan.deleteLocal.append(mapping)
                } else {
                    try deps.store.deleteMapping(localID: mapping.localID)
                }
            case (let l?, false):
                let remote = remoteRecord?.contact ?? mapping.base
                let merged = MergeEngine.merge(base: mapping.base, local: l, remote: remote)
                let etag = remoteRecord?.etag ?? mapping.remoteEtag
                var updated = mapping
                updated.remoteEtag = etag
                if merged.remoteNeedsUpdate && settings.mode != .googleToIphone {
                    plan.updateRemote.append((updated, merged.merged,
                                              GoogleFieldMapper.updateMask(from: remote, to: merged.merged)))
                }
                if merged.localNeedsUpdate && settings.mode != .iphoneToGoogle {
                    plan.updateLocal.append((updated, merged.merged))
                }
                let anyWrite = (merged.remoteNeedsUpdate && settings.mode != .googleToIphone)
                    || (merged.localNeedsUpdate && settings.mode != .iphoneToGoogle)
                if !anyWrite && (merged.merged != mapping.base || etag != mapping.remoteEtag) {
                    plan.rebaseOnly.append((updated, merged.merged, etag))
                }
                if !merged.conflicts.isEmpty {
                    plan.conflicts.append((merged.merged.displayName, merged.conflicts))
                }
            }
        }

        // 4. Unmapped locals → new on the phone.
        if settings.mode != .googleToIphone {
            for lc in localContacts where mappingByLocal[lc.id] == nil && !lc.contact.isEffectivelyEmpty {
                plan.createRemote.append((lc.id, lc.contact))
            }
        }
        // 5. Unmapped remote records in the delta → new on Google.
        if settings.mode != .iphoneToGoogle {
            for (name, record) in remoteChanged where mappingByRemote[name] == nil && !record.contact.isEffectivelyEmpty {
                plan.createLocal.append(record)
            }
        }
        return plan
    }

    // MARK: - Applying

    private func apply(plan: PlannedPass) async throws -> SyncSummary {
        var summary = SyncSummary()
        summary.conflicts = plan.conflicts.reduce(0) { $0 + $1.conflicts.count }

        // Safety snapshot before anything destructive. The UI promises "a backup was
        // already saved on this phone" before deletes/overwrites, so if a snapshot
        // manager is configured its failure MUST abort the pass — we never proceed to
        // delete or overwrite contacts with no backup.
        if !plan.deleteLocal.isEmpty || !plan.deleteRemote.isEmpty
            || !plan.updateLocal.isEmpty || !plan.updateRemote.isEmpty {
            let affectedLocal = plan.deleteLocal.map(\.base) + plan.updateLocal.map(\.mapping.base)
            let affectedRemote = plan.deleteRemote.map(\.base) + plan.updateRemote.map(\.mapping.base)
            try deps.snapshots?.createSnapshot(reason: "pre-sync",
                                               localContacts: affectedLocal,
                                               remoteContacts: affectedRemote)
        }

        // Remote writes (sequential per Google's guidance). Create in batches and
        // persist each batch's mappings before starting the next, so a mid-sync throw
        // (quota/network) leaves already-created contacts mapped — the next run resumes
        // instead of re-creating duplicates.
        for batch in plan.createRemote.chunked(into: GooglePeopleClient.createBatchLimit) {
            let created = try await deps.remote.createContacts(batch.map(\.contact))
            for (idx, result) in created.enumerated() {
                let (localID, contact) = batch[idx]
                try deps.store.upsert(Mapping(localID: localID, remoteResourceName: result.resourceName,
                                              remoteEtag: result.etag, base: contact))
                summary.addedToGoogle += 1
                try? deps.store.log(ActivityEvent(kind: .addedToGoogle,
                                                  summary: "Added \"\(contact.displayName)\" to Google"))
            }
        }
        for (mapping, contact, mask) in plan.updateRemote {
            guard !mask.isEmpty else { continue }
            do {
                let newEtag = try await deps.remote.updateContact(
                    resourceName: mapping.remoteResourceName, etag: mapping.remoteEtag,
                    contact: contact, updateMask: mask)
                try deps.store.upsert(Mapping(localID: mapping.localID,
                                              remoteResourceName: mapping.remoteResourceName,
                                              remoteEtag: newEtag, base: contact))
                summary.updatedOnGoogle += 1
                try? deps.store.log(ActivityEvent(kind: .updatedOnGoogle,
                                                  summary: "Updated \"\(contact.displayName)\" on Google"))
            } catch PeopleAPIError.staleEtag {
                // Someone edited mid-pass; next pass re-merges with the fresh copy.
                continue
            }
        }
        if !plan.deleteRemote.isEmpty {
            try await deps.remote.deleteContacts(resourceNames: plan.deleteRemote.map(\.remoteResourceName))
            for mapping in plan.deleteRemote {
                try deps.store.deleteMapping(localID: mapping.localID)
                summary.deletedFromGoogle += 1
                try? deps.store.log(ActivityEvent(kind: .deletedFromGoogle,
                                                  summary: "Removed \"\(mapping.base.displayName)\" from Google"))
            }
        }

        // Local writes.
        if !plan.createLocal.isEmpty {
            let ids = try await deps.local.create(plan.createLocal.map(\.contact))
            for (idx, id) in ids.enumerated() {
                let record = plan.createLocal[idx]
                try deps.store.upsert(Mapping(localID: id, remoteResourceName: record.resourceName,
                                              remoteEtag: record.etag, base: record.contact))
                summary.addedToiPhone += 1
                try? deps.store.log(ActivityEvent(kind: .addedToiPhone,
                                                  summary: "Added \"\(record.contact.displayName)\" to iPhone"))
            }
        }
        for (mapping, contact) in plan.updateLocal {
            try await deps.local.update(id: mapping.localID, contact: contact)
            try deps.store.upsert(Mapping(localID: mapping.localID,
                                          remoteResourceName: mapping.remoteResourceName,
                                          remoteEtag: mapping.remoteEtag, base: contact))
            summary.updatedOniPhone += 1
            try? deps.store.log(ActivityEvent(kind: .updatedOniPhone,
                                              summary: "Updated \"\(contact.displayName)\" on iPhone"))
        }
        if !plan.deleteLocal.isEmpty {
            try await deps.local.delete(ids: plan.deleteLocal.map(\.localID))
            for mapping in plan.deleteLocal {
                try deps.store.deleteMapping(localID: mapping.localID)
                summary.deletedFromiPhone += 1
                try? deps.store.log(ActivityEvent(kind: .deletedFromiPhone,
                                                  summary: "Removed \"\(mapping.base.displayName)\" from iPhone"))
            }
        }

        // Rebases (content merged but neither side needed writes, or bookkeeping).
        for (mapping, merged, etag) in plan.rebaseOnly {
            try deps.store.upsert(Mapping(localID: mapping.localID,
                                          remoteResourceName: mapping.remoteResourceName,
                                          remoteEtag: etag ?? mapping.remoteEtag, base: merged))
        }

        for (name, conflicts) in plan.conflicts {
            for conflict in conflicts {
                try? deps.store.log(ActivityEvent(
                    kind: .conflictResolved,
                    summary: "Kept \(conflict.keptFrom == .local ? "iPhone" : "Google")'s \(conflict.field.lowercased()) for \"\(name)\"",
                    detail: "Other value: \(conflict.discardedValue)"))
            }
        }

        if let token = plan.nextSyncToken {
            try deps.store.setCursor(Self.remoteSyncTokenKey, token)
        }
        return summary
    }

    private func summaryLine(_ s: SyncSummary) -> String {
        if s.totalChanges == 0 { return "Everything already in sync" }
        var parts: [String] = []
        if s.addedToGoogle > 0 { parts.append("\(s.addedToGoogle) added to Google") }
        if s.addedToiPhone > 0 { parts.append("\(s.addedToiPhone) added to iPhone") }
        if s.updatedOnGoogle > 0 { parts.append("\(s.updatedOnGoogle) updated on Google") }
        if s.updatedOniPhone > 0 { parts.append("\(s.updatedOniPhone) updated on iPhone") }
        if s.deletedFromGoogle > 0 { parts.append("\(s.deletedFromGoogle) removed from Google") }
        if s.deletedFromiPhone > 0 { parts.append("\(s.deletedFromiPhone) removed from iPhone") }
        return "Synced: " + parts.joined(separator: ", ")
    }
}
