import Foundation
import SwiftData

/// A dedicated serial model executor owns every context and record. Only value DTOs leave it.
actor SwiftDataCatalog: ModelActor, CatalogStoring {
    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor

    init(storeURL: URL) throws {
        do {
            let schema = Schema([CatalogSourceRecord.self, CatalogRecipeRecord.self,
                CatalogCollectionRecord.self, CatalogJobRecord.self,
                CatalogOperationRecord.self, CatalogVersionRecord.self, CatalogPhoneRecipeRecord.self])
            let configuration = ModelConfiguration("FujiStudioLocal", schema: schema,
                url: storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            modelContainer = container
            modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        } catch { throw CatalogError.durableFailure(String(describing: error)) }
    }

    func upsertSources(_ sources: [PhotoSource]) throws {
        try write {
            for source in sources { try upsert(source) }
        }
    }

    func replaceRecipes(_ snapshots: [RecipeSnapshot]) throws {
        guard snapshots.count == 7, Set(snapshots.map(\.slot)) == Set(1...7),
              Set(snapshots.map(\.id)).count == 7,
              let context = snapshots.first?.cameraContext,
              snapshots.allSatisfy({ $0.cameraContext == context && !$0.isPhoneRecipe }) else {
            throw CatalogError.invalidRecipeCollection
        }
        let ordered = snapshots.sorted { $0.slot < $1.slot }
        try write {
            for snapshot in ordered { try retain(snapshot) }
            let data = try encode(ordered.map(\.id))
            if let current = try modelContext.fetch(FetchDescriptor<CatalogCollectionRecord>()).first {
                current.snapshotIDs = data
            } else { modelContext.insert(CatalogCollectionRecord(snapshotIDs: data)) }
        }
    }

    func latestRecipes() throws -> [RecipeSnapshot] {
        try read {
            guard let current = try modelContext.fetch(FetchDescriptor<CatalogCollectionRecord>()).first else { return [] }
            let ids = try decode([UUID].self, current.snapshotIDs)
            return try ids.map { id in
                guard let record = try recipeRecord(id) else {
                    throw CatalogError.durableFailure("Active recipe snapshot is missing")
                }
                return try decode(RecipeSnapshot.self, record.payload)
            }
        }
    }

    func phoneRecipes() throws -> [RecipeSnapshot] {
        try read {
            let request = FetchDescriptor<CatalogPhoneRecipeRecord>(sortBy: [SortDescriptor(\.savedAt), SortDescriptor(\.snapshotID)])
            return try modelContext.fetch(request).map { try phoneSnapshot($0) }
        }
    }

    /// The actor serializes repeat taps; membership and the immutable snapshot save atomically.
    func copyRecipeToPhone(_ recipe: RecipeSnapshot) throws -> RecipeSnapshot {
        guard !recipe.isPhoneRecipe, (1...7).contains(recipe.slot) else { throw CatalogError.invalidRecipeCollection }
        let sourceID = recipe.id
        let request = FetchDescriptor<CatalogPhoneRecipeRecord>(predicate: #Predicate { $0.sourceSnapshotID == sourceID })
        if let existing = try read({ try modelContext.fetch(request).first }) { return try read { try phoneSnapshot(existing) } }
        let copy = recipe.copiedToPhone()
        try write {
            try retain(recipe)
            try retain(copy)
            modelContext.insert(CatalogPhoneRecipeRecord(sourceSnapshotID: sourceID, snapshotID: copy.id))
        }
        return copy
    }

    private func phoneSnapshot(_ membership: CatalogPhoneRecipeRecord) throws -> RecipeSnapshot {
        guard let record = try recipeRecord(membership.snapshotID) else {
            throw CatalogError.durableFailure("Saved phone recipe is missing")
        }
        let recipe = try decode(RecipeSnapshot.self, record.payload)
        guard recipe.copiedFromRecipeID == membership.sourceSnapshotID else {
            throw CatalogError.durableFailure("Saved phone recipe provenance does not match")
        }
        return recipe
    }

    func recipes(camera: CameraExecutionContext) throws -> [RecipeSnapshot] {
        let snapshots = try latestRecipes()
        guard let observed = snapshots.first?.cameraContext,
              observed.model == camera.model, observed.firmware == camera.firmware,
              observed.capability == camera.capability, observed.sessionIdentity == camera.sessionIdentity,
              observed.sessionGeneration == camera.generation else { return [] }
        return snapshots
    }

    func versions(sourceID: SourceID) throws -> [SavedVersion] {
        try read {
            let request = FetchDescriptor<CatalogVersionRecord>(
                predicate: #Predicate { $0.sourceID == sourceID }, sortBy: [SortDescriptor(\.exportedAt)])
            return try modelContext.fetch(request).map { try decode(SavedVersion.self, $0.payload) }
        }
    }

    func saveJob(_ job: ExportJob) throws {
        try write {
            guard !job.items.isEmpty, Set(job.items.map(\.operationID)).count == job.items.count,
                  Set(job.items.map(\.source.id)).count == job.items.count else {
                throw CatalogError.invalidState("A submission needs distinct ordered sources and save operations")
            }
            let record = try jobRecord(job.id)
            let previous = try record.map { try decode(ExportJob.self, $0.payload) }
            if let previous {
                guard sameSubmission(previous, job) else {
                    throw CatalogError.invalidState("Submitted sources and recipe are immutable")
                }
            }
            for (index, item) in job.items.enumerated() {
                if let owner = try operationRecord(item.operationID), owner.jobID != job.id {
                    throw CatalogError.conflictingOperation(item.operationID)
                }
                try validate(item, recipe: job.recipeSnapshot)
                if let previous { try preserveUncertainty(from: previous.items[index], to: item) }
                if case .saved = item.state {
                    guard let previous, previous.items[index].state == item.state else {
                        throw CatalogError.invalidState("Saved outcomes require atomic confirmation")
                    }
                }
                if let previous, case .saved = previous.items[index].state,
                   previous.items[index].state != item.state {
                    throw CatalogError.invalidState("A saved outcome cannot be reverted")
                }
            }
            try retain(job.recipeSnapshot)
            for item in job.items {
                if try sourceRecord(item.source.id) == nil { try upsert(item.source) }
                if try operationRecord(item.operationID) == nil {
                    modelContext.insert(CatalogOperationRecord(operationID: item.operationID, jobID: job.id))
                }
            }
            let payload = try encode(job)
            if let record {
                record.payload = payload; record.unfinished = isUnfinished(job)
            } else {
                modelContext.insert(CatalogJobRecord(job: job, unfinished: isUnfinished(job), payload: payload))
            }
        }
    }

    func job(id: UUID) throws -> ExportJob {
        try read {
            guard let record = try jobRecord(id) else { throw CatalogError.missingJob(id) }
            return try decode(ExportJob.self, record.payload)
        }
    }

    func unfinishedJobs() throws -> [ExportJob] {
        try read {
            let request = FetchDescriptor<CatalogJobRecord>(predicate: #Predicate { $0.unfinished },
                sortBy: [SortDescriptor(\.submittedAt)])
            return try modelContext.fetch(request).map { try decode(ExportJob.self, $0.payload) }
        }
    }

    func confirmSaved(jobID: UUID, operationID: UUID, version: SavedVersion) throws {
        try write {
            guard let record = try jobRecord(jobID) else { throw CatalogError.missingJob(jobID) }
            var job = try decode(ExportJob.self, record.payload)
            guard let index = job.items.firstIndex(where: { $0.operationID == operationID }),
                  version.operationID == operationID, version.sourceID == job.items[index].source.id,
                  version.recipeSnapshot == job.recipeSnapshot, !version.outputAssetID.isEmpty else {
                throw CatalogError.conflictingOperation(operationID)
            }
            if let canonical = try versionRecord(operationID) {
                let saved = try decode(SavedVersion.self, canonical.payload)
                guard sameConfirmation(saved, version), job.items[index].state == .saved(saved.id) else {
                    throw CatalogError.conflictingOperation(operationID)
                }
                return
            }
            let pending: PendingSave
            switch job.items[index].state {
            case .pendingSave(let value), .unresolved(let value): pending = value
            default: throw CatalogError.invalidState("The item has no durable pending save")
            }
            switch pending.submission {
            case .submitted, .unknown: break
            case .notSubmitted, .definitivelyRejected:
                throw CatalogError.invalidState("An unsubmitted or rejected save cannot be confirmed")
            }
            guard pending.jpeg == version.jpeg, pending.operationID == operationID,
                  pending.placeholderID == nil || pending.placeholderID == version.outputAssetID,
                  pending.submission.attemptedAt == version.exportedAt else {
                throw CatalogError.conflictingOperation(operationID)
            }
            let versionID = version.id
            guard try modelContext.fetch(FetchDescriptor<CatalogVersionRecord>(
                predicate: #Predicate { $0.versionID == versionID })).isEmpty else {
                throw CatalogError.conflictingOperation(operationID)
            }
            modelContext.insert(CatalogVersionRecord(version: version, payload: try encode(version)))
            job.items[index].state = .saved(version.id)
            if job.items.allSatisfy({ if case .saved = $0.state { true } else { false } }) { job.state = .saved }
            record.payload = try encode(job)
            record.unfinished = isUnfinished(job)
        }
    }

    func setAvailability(assetID: String, availability: AssetAvailability) throws {
        try write {
            if let source = try sourceRecord(assetID) { source.availability = availability.rawValue }
            let request = FetchDescriptor<CatalogVersionRecord>(predicate: #Predicate { $0.outputAssetID == assetID })
            for record in try modelContext.fetch(request) {
                var version = try decode(SavedVersion.self, record.payload)
                version.availability = availability
                record.payload = try encode(version)
            }
        }
    }

    private func validate(_ item: ExportItem, recipe: RecipeSnapshot) throws {
        let pending: PendingSave
        switch item.state {
        case .pendingSave(let value), .unresolved(let value): pending = value
        default: return
        }
        let jpeg = pending.jpeg, key = jpeg.key
        guard pending.operationID == item.operationID, pending.operationID != jpeg.operationID,
              pending.filename == "FujiStudio-\(item.operationID.uuidString).jpg",
              jpeg.sourceID == item.source.id, jpeg.sourceRevision == item.source.resourceRevision,
              jpeg.settingsDigest == recipe.settingsDigest, key.sourceID == jpeg.sourceID,
              key.sourceRevision == jpeg.sourceRevision, key.sourceSHA256 == jpeg.sourceSHA256,
              key.settingsDigest == jpeg.settingsDigest, key.cameraContext == jpeg.cameraContext,
              key.width == jpeg.width, key.height == jpeg.height, key.orientation == jpeg.orientation,
              key.quality == jpeg.quality, jpeg.fileURL.isFileURL else {
            throw CatalogError.conflictingOperation(item.operationID)
        }
    }

    private func sameSubmission(_ a: ExportJob, _ b: ExportJob) -> Bool {
        a.id == b.id && a.submittedAt == b.submittedAt && a.recipeSnapshot == b.recipeSnapshot &&
        a.items.map(\.operationID) == b.items.map(\.operationID) && a.items.map(\.source) == b.items.map(\.source)
    }

    /// A journal update must not erase a system transaction whose outcome is still uncertain.
    /// Task8 supplies evidence for definitive rejection; absence from a lookup is not evidence.
    private func preserveUncertainty(from previous: ExportItem, to next: ExportItem) throws {
        let pinned: PendingSave
        switch previous.state {
        case .pendingSave(let value), .unresolved(let value): pinned = value
        default: return
        }
        switch pinned.submission {
        case .notSubmitted, .definitivelyRejected: return
        case .submitted, .unknown: break
        }
        let updated: PendingSave
        switch next.state {
        case .pendingSave(let value), .unresolved(let value): updated = value
        default: throw CatalogError.invalidState("An uncertain save must remain pending until confirmed or rejected")
        }
        guard updated.operationID == pinned.operationID, updated.jpeg == pinned.jpeg,
              updated.submission.attemptedAt == pinned.submission.attemptedAt,
              pinned.placeholderID == nil || updated.placeholderID == pinned.placeholderID else {
            throw CatalogError.invalidState("An uncertain save's pinned attempt cannot be replaced")
        }
        if case .notSubmitted = updated.submission {
            throw CatalogError.invalidState("A submitted save cannot become unsubmitted without definitive rejection")
        }
    }

    private func sameConfirmation(_ a: SavedVersion, _ b: SavedVersion) -> Bool {
        a.operationID == b.operationID && a.sourceID == b.sourceID && a.outputAssetID == b.outputAssetID &&
        a.recipeSnapshot == b.recipeSnapshot && a.jpeg == b.jpeg && a.exportedAt == b.exportedAt
    }

    private func isUnfinished(_ job: ExportJob) -> Bool {
        job.items.contains {
            switch $0.state {
            // Terminal failures/cancellations still need an explicit user retry after restart.
            // Discovery never grants permission to execute or replace an uncertain save.
            case .queued, .preparing, .converting, .pendingSave, .unresolved, .failed, .cancelled, .unprocessed: true
            case .saved: false
            }
        }
    }

    private func upsert(_ source: PhotoSource) throws {
        let payload = try encode(source)
        if let record = try sourceRecord(source.id) { record.payload = payload }
        else { modelContext.insert(CatalogSourceRecord(sourceID: source.id, payload: payload)) }
    }

    private func retain(_ snapshot: RecipeSnapshot) throws {
        if let record = try recipeRecord(snapshot.id) {
            guard try decode(RecipeSnapshot.self, record.payload) == snapshot else {
                throw CatalogError.conflictingSnapshot(snapshot.id)
            }
        } else {
            modelContext.insert(CatalogRecipeRecord(snapshotID: snapshot.id, payload: try encode(snapshot)))
        }
    }

    private func sourceRecord(_ id: String) throws -> CatalogSourceRecord? {
        try modelContext.fetch(FetchDescriptor<CatalogSourceRecord>(predicate: #Predicate { $0.sourceID == id })).first
    }
    private func recipeRecord(_ id: UUID) throws -> CatalogRecipeRecord? {
        try modelContext.fetch(FetchDescriptor<CatalogRecipeRecord>(predicate: #Predicate { $0.snapshotID == id })).first
    }
    private func jobRecord(_ id: UUID) throws -> CatalogJobRecord? {
        try modelContext.fetch(FetchDescriptor<CatalogJobRecord>(predicate: #Predicate { $0.jobID == id })).first
    }
    private func operationRecord(_ id: UUID) throws -> CatalogOperationRecord? {
        try modelContext.fetch(FetchDescriptor<CatalogOperationRecord>(predicate: #Predicate { $0.operationID == id })).first
    }
    private func versionRecord(_ id: UUID) throws -> CatalogVersionRecord? {
        try modelContext.fetch(FetchDescriptor<CatalogVersionRecord>(predicate: #Predicate { $0.operationID == id })).first
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    private func decode<T: Decodable>(_ type: T.Type, _ payload: Data) throws -> T { try JSONDecoder().decode(type, from: payload) }

    private func read<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as CatalogError { throw error }
        catch { throw CatalogError.durableFailure(String(describing: error)) }
    }

    private func write(_ body: () throws -> Void) throws {
        do {
            try modelContext.transaction {
                try body()
                try modelContext.save()
            }
        } catch {
            modelContext.rollback()
            if let catalogError = error as? CatalogError { throw catalogError }
            throw CatalogError.durableFailure(String(describing: error))
        }
    }
}
