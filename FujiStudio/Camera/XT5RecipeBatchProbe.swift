import FujiCameraCore
import Foundation

struct XT5RecipeBatchEvidence: Sendable, Encodable {
    struct Slot: Sendable, Encodable {
        let slot: Int
        let dormantGrainSizeNotApplied: Bool
        var capture: XT5RawBaselineEvidence?
        var cleanup: XT5ExactCleanupObservation?
    }
    let label = "finite imported-bank experiment; visible fidelity and dormant grain-size encoding unvalidated"
    var freshContextValidated = false
    var beforeBanksMatch = false
    var afterBanksMatch = false
    var beforeScan: XT5BankImportEvidence?
    var afterScan: XT5BankImportEvidence?
    var initialOutputAbsent = false
    var initialCleanup: XT5ExactCleanupObservation?
    var slots: [Slot] = []
    var sessionClosure = "notAttempted"
    var failure: String?
    var complete = false
    let inputBufferCleanup = "unconfirmed"
}
struct XT5RecipeBatchFailure: Error, Sendable { let evidence: XT5RecipeBatchEvidence }

/// All helper instances and their permits are private to this owner. The outer permit remains
/// held across bank scans, every trial/cleanup and actual native close; no reconnect can interleave.
actor XT5RecipeBatchProbe {
    private let transport: any PTPTransport
    private let generation: UInt64
    private let validateSession: @Sendable () async throws -> Void
    private let closeSession: @Sendable () async throws -> Void
    private let settle: @Sendable (Duration) async throws -> Void
    private let pollWait: @Sendable () async throws -> Void
    private let gate: SerialCameraGate
    private var transaction: UInt32 = 1
    init(transport: any PTPTransport, sessionGeneration: UInt64,
         validateSession: @escaping @Sendable () async throws -> Void,
         closeSession: @escaping @Sendable () async throws -> Void,
         settle: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for:$0) },
         pollWait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for:.seconds(1)) },
         gate: SerialCameraGate = SerialCameraGate()) {
        self.transport=transport;generation=sessionGeneration;self.validateSession=validateSession;self.closeSession=closeSession
        self.settle=settle;self.pollWait=pollWait;self.gate=gate
    }
    func run(raw: PreparedRAW, reference: XT5FilmProbeReference, referenceBanks: [RecipeSnapshot], initialTarget: XT5ExactCleanupTarget, directory: URL,
             onUpdate: @escaping @Sendable (XT5RecipeBatchEvidence) async -> Void = { _ in }) async throws -> XT5RecipeBatchEvidence {
        do {
            return try await gate.withExclusiveAccess { try await self.runExclusively(raw:raw,reference:reference,referenceBanks:referenceBanks,initialTarget:initialTarget,directory:directory,onUpdate:onUpdate) }
        } catch let failure as XT5RecipeBatchFailure {
            throw failure // The entered owner has already awaited native close.
        } catch {
            // Cancellation can reject acquisition before the operation body runs. Acquire an
            // uncancelled close-only permit, never resume a profile/selector/upload operation.
            var evidence=XT5RecipeBatchEvidence();evidence.failure=Self.safe(error)
            let close=Task.detached { try await self.gate.withExclusiveAccess { try await self.closeSession() } }
            do { try await close.value;evidence.sessionClosure="confirmed" }
            catch { evidence.sessionClosure="unconfirmed" }
            await onUpdate(evidence)
            throw XT5RecipeBatchFailure(evidence:evidence)
        }
    }
    private func runExclusively(raw: PreparedRAW, reference: XT5FilmProbeReference, referenceBanks: [RecipeSnapshot], initialTarget: XT5ExactCleanupTarget, directory: URL,
                               onUpdate: @escaping @Sendable (XT5RecipeBatchEvidence) async -> Void) async throws -> XT5RecipeBatchEvidence {
        var evidence=XT5RecipeBatchEvidence()
        let adapter=XT5BatchTransport { command,data in try await self.send(command.opcode,command.parameters,data) }
        do {
            try reference.validate(raw:raw)
            guard try ResourceChecksum.sha256(raw.fileURL) == raw.sha256, initialTarget.sourceSHA256 == raw.sha256 else { throw XT5RecipeBatchIssue.invalidReference }
            // Validate ALL finite domains before any camera command. Values still come from live
            // snapshots after equality checks, never from this preflight's generated candidates.
            for bank in referenceBanks { _ = try XT5FiniteRecipePatch.make(bank:bank,referenceBanks:referenceBanks,reference:reference) }
            guard referenceBanks.count == 7 else { throw XT5RecipeBatchIssue.invalidReference }
            let info=try PTPDatasets.deviceInfo(await send(0x1001,[],nil).data)
            guard info.manufacturer == "FUJIFILM",info.model == "X-T5",info.firmware == "4.31" else { throw XT5RawBaselineIssue.unsupportedContext }
            guard [UInt16(0x1005),0x1007,0x1008,0x1009,0x100B,0x1015,0x1016,0x900C,0x900D].allSatisfy(info.operations.contains),
                  ([UInt16(0xD16E),0xD183,0xD185,0xD186,0xD187,0xD18C,0xD18D] + Array(0xD18E...0xD1A4)).allSatisfy(info.properties.contains) else { throw XT5RawBaselineIssue.missingCapability }
            guard try await send(0x1015,[0xD16E],nil).data == Data([6,0]) else { throw XT5RawBaselineIssue.unsupportedContext }
            for property:UInt32 in [0xD186,0xD187] {
                guard try PTPDatasets.value(await send(0x1015,[property],nil).data,type:0xffff).string == "X-T5_0200" else { throw XT5RawBaselineIssue.unsupportedContext }
            }
            evidence.freshContextValidated=true
            await onUpdate(evidence)
            // Controlled ordering experiment: only known-J maintenance may precede bank equality.
            // This does not infer that deleting the visible output releases the opaque RAW buffer.
            let handles=try FujiConversionCodec.objectHandles(await send(0x1007,[UInt32.max,0,0],nil).data)
            if handles.isEmpty { evidence.initialOutputAbsent=true }
            else {
                let prior=evidence
                let result=await cleanup(initialTarget,raw:raw,directory:directory) { partial in var next=prior;next.initialCleanup=partial;await onUpdate(next) }
                evidence.initialCleanup=result
                guard result.failure == nil && result.emptyViewVerified else { throw XT5RecipeBatchIssue.cleanupFailed }
            }
            await onUpdate(evidence)
            let before=try await scan(adapter:adapter,directory:directory,phase:"before",raw:raw)
            evidence.beforeScan=before.evidence
            guard XT5FiniteRecipePatch.sameBanks(before.recipes,referenceBanks) else { throw XT5RecipeBatchIssue.bankMismatch }
            evidence.beforeBanksMatch=true
            await onUpdate(evidence)
            for slot in [7,1,2,3,4,5,6] {
                try Task.checkCancellation()
                guard let bank=before.recipes.first(where: { $0.slot == slot }) else { throw XT5RecipeBatchIssue.bankMismatch }
                let patch=try XT5FiniteRecipePatch.make(bank:bank,referenceBanks:referenceBanks,reference:reference)
                let trialDirectory=directory.appendingPathComponent("C\(slot)",isDirectory:true)
                try FileManager.default.createDirectory(at:trialDirectory,withIntermediateDirectories:false,attributes:[.protectionKey:FileProtectionType.complete])
                try write(bank,to:trialDirectory.appendingPathComponent("imported-bank.json"))
                evidence.slots.append(.init(slot:slot,dormantGrainSizeNotApplied:patch.dormantGrainSizeNotApplied))
                let index=evidence.slots.count-1, prior=evidence
                let trial=XT5RawBaselineProbe(transport:adapter,validateSession:validateSession,closeSession:closeSession,pollWait:pollWait)
                do {
                    evidence.slots[index].capture=try await trial.captureBatchTrial(raw:raw,patch:patch,directory:trialDirectory) { partial in
                        var next=prior;next.slots[index].capture=partial;await onUpdate(next)
                    }
                } catch let failure as XT5RawBaselineFailure {
                    evidence.slots[index].capture=failure.evidence;throw failure
                }
                // Only a successful same-operation capture can supply ownership here. The loader
                // independently checks empty→unique history, raw metadata and local JPEG context.
                let target=try XT5CreatedOutputProof.load(directory:trialDirectory,raw:raw)
                let captured=evidence
                let result=await cleanup(target,raw:raw,directory:trialDirectory) { partial in
                    var next=captured;next.slots[index].cleanup=partial;await onUpdate(next)
                }
                evidence.slots[index].cleanup=result
                guard result.failure == nil && result.emptyViewVerified else { throw XT5RecipeBatchIssue.cleanupFailed }
                await onUpdate(evidence)
            }
        } catch {
            if let failure=error as? XT5BankImportFailure { evidence.beforeScan=failure.evidence }
            evidence.failure=Self.safe(error)
        }
        // No cancelled/profile-mutating work is resumed. If the context remains usable, the
        // ordinary importer verifies all banks and performs its existing bounded restoration.
        if evidence.beforeBanksMatch {
            do {
                try Task.checkCancellation();try await validateSession()
                let after=try await scan(adapter:adapter,directory:directory,phase:"after",raw:raw)
                evidence.afterScan=after.evidence
                guard XT5FiniteRecipePatch.sameBanks(after.recipes,referenceBanks), after.evidence.originalSelector == evidence.beforeScan?.restoredSelector else { throw XT5RecipeBatchIssue.bankMismatch }
                evidence.afterBanksMatch=true
            } catch {
                if let failure=error as? XT5BankImportFailure { evidence.afterScan=failure.evidence }
                evidence.failure=evidence.failure ?? Self.safe(error)
            }
        }
        await onUpdate(evidence)
        let close=Task.detached { try await self.closeSession() }
        do { try await close.value;evidence.sessionClosure="confirmed" }
        catch { evidence.sessionClosure="unconfirmed";evidence.failure=evidence.failure ?? Self.safe(error) }
        if Task.isCancelled { evidence.failure=evidence.failure ?? "cancelled" }
        evidence.complete=evidence.failure == nil && evidence.beforeBanksMatch && evidence.afterBanksMatch && evidence.slots.count == 7 && evidence.slots.allSatisfy { $0.cleanup?.emptyViewVerified == true } && evidence.sessionClosure == "confirmed"
        await onUpdate(evidence)
        guard evidence.complete else { throw XT5RecipeBatchFailure(evidence:evidence) }
        return evidence
    }
    private func scan(adapter:XT5BatchTransport,directory:URL,phase:String,raw:PreparedRAW) async throws -> XT5BankImportResult {
        let importer=XT5BankImporter(transport:adapter,sessionGeneration:generation,validateSession:validateSession,settle:settle)
        let result=try await importer.importRecipesVerified()
        struct Capture: Encodable { let sourceSHA256:String;let evidence:XT5BankImportEvidence;let snapshots:[RecipeSnapshot] }
        try write(Capture(sourceSHA256:raw.sha256,evidence:result.evidence,snapshots:result.recipes),to:directory.appendingPathComponent("banks-\(phase).json"))
        return result
    }
    private func cleanup(_ target:XT5ExactCleanupTarget,raw:PreparedRAW,directory:URL,onUpdate:@escaping @Sendable (XT5ExactCleanupObservation) async -> Void) async -> XT5ExactCleanupObservation {
        await XT5ExactOutputCleanup(send:{ opcode,params,data in
            guard data == nil,[UInt16(0x1005),0x1007,0x1008,0x1009,0x100B].contains(opcode),opcode != 0x100B || params == [target.handle,0] else { throw PTPError.invalidParameters }
            return try await self.send(opcode,params,nil)
        }).run(target:target,raw:raw,directory:directory,onUpdate:onUpdate)
    }
    private func send(_ opcode:UInt16,_ parameters:[UInt32],_ data:Data?) async throws -> PTPReply {
        try Task.checkCancellation();try await validateSession();try Task.checkCancellation()
        guard transaction < UInt32.max else { throw PTPError.invalidParameters }
        let id=transaction;transaction += 1
        let reply=try await transport.execute(PTPCommand(opcode:opcode,parameters:parameters,transactionID:id),data:data)
        try await validateSession();return reply
    }
    private func write<T:Encodable>(_ value:T,to url:URL) throws {
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to:url,options:[.atomic,.completeFileProtection])
    }
    private static func safe(_ error:any Error) -> String {
        if let failure=error as? XT5RawBaselineFailure { return failure.evidence.failure ?? "trial incomplete" }
        if let failure=error as? XT5BankImportFailure { return failure.evidence.failure ?? "bank scan incomplete" }
        return XT5RawBaselineProbe.safeFailure(error)
    }
}
private struct XT5BatchTransport: PTPTransport {
    let send: @Sendable (PTPCommand,Data?) async throws -> PTPReply
    func execute(_ command:PTPCommand,data:Data?) async throws -> PTPReply { try await send(command,data) }
}

/// Private evidence for an output created after a proved empty view, never a recovered/card object.
/// The batch's successful capture check remains required; this loader is also used for exact J proof.
enum XT5CreatedOutputProof {
    private struct Conversion: Decodable {
        let sourceSHA256:String,outputSHA256:String
        let candidateHandle:UInt32
        let readOnlyRecovery:Bool,privateQuarantine:Bool
        let handleViews:[[UInt32]]
    }
    private struct ProtocolManifest: Decodable { let sourceSHA256:String;let beforeHandles:[UInt32];let afterHandles:[UInt32] }
    static func load(directory:URL,raw:PreparedRAW) throws -> XT5ExactCleanupTarget {
        let conversion=try JSONDecoder().decode(Conversion.self,from:bounded("conversion-manifest.json",directory:directory,maximum:1_048_576))
        let proto=try JSONDecoder().decode(ProtocolManifest.self,from:bounded("protocol-manifest.json",directory:directory,maximum:1_048_576))
        let h=conversion.candidateHandle
        guard !conversion.readOnlyRecovery,conversion.privateQuarantine,conversion.sourceSHA256 == raw.sha256,proto.sourceSHA256 == raw.sha256,
              proto.beforeHandles.isEmpty,proto.afterHandles == [h],conversion.handleViews.first == [],conversion.handleViews.last == [h],
              conversion.handleViews.allSatisfy({ $0.isEmpty || $0 == [h] }) else { throw XT5ExactCleanupIssue.invalidPreservedProof }
        let info=try bounded("output-object-info.bin",directory:directory,maximum:4096)
        guard try bounded("output-object-info-after.bin",directory:directory,maximum:4096) == info else { throw XT5ExactCleanupIssue.invalidPreservedProof }
        let target=XT5ExactCleanupTarget(handle:h,sourceSHA256:raw.sha256,outputSHA256:conversion.outputSHA256,quarantineURL:directory.appendingPathComponent("quarantined-candidate.bin"),objectInfo:info,storageInfo:try bounded("output-storage-info.bin",directory:directory,maximum:4096))
        _ = try target.validateLocal(raw:raw)
        do {
            let jpeg=try bounded("quarantined-candidate.bin",directory:directory,maximum:PTPCodec.maximumDataBytes)
            let observed=try FujiConversionCodec.jpegObservation(jpeg,expected:raw.metadata)
            guard observed.modelMatches,observed.recordedGeometryMatches,observed.orientationMatches else { throw XT5ExactCleanupIssue.invalidPreservedProof }
        }
        return target
    }
    static func bounded(_ name:String,directory:URL,maximum:Int) throws -> Data {
        let url=directory.appendingPathComponent(name)
        guard let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size > 0,size <= maximum else { throw XT5ExactCleanupIssue.invalidPreservedProof }
        return try Data(contentsOf:url)
    }
}
