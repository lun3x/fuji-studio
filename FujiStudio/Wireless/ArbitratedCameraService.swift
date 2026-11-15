import FujiCameraCore

struct ArbitratedCameraService: CameraServing {
    private let service: any CameraServing
    let arbiter: CameraUseArbiter

    init(_ service: any CameraServing, arbiter: CameraUseArbiter) {
        self.service = service
        self.arbiter = arbiter
    }

    func states() async -> AsyncStream<CameraState> { await service.states() }
    func executionContext() async throws -> CameraExecutionContext { try await service.executionContext() }
    func support(for context: CameraExecutionContext) async throws -> VerifiedCameraSupport {
        try await service.support(for: context)
    }

    func connect() async throws {
        try await arbiter.withUSB({ try await service.connect() }, closeIfUnavailable: {
            try await service.disconnectConfirmed()
        })
    }

    func resetConnection() async throws {
        try Task.checkCancellation()
        try await arbiter.recoverUSBIfNeeded { try await service.disconnectConfirmed() }
        try await arbiter.withUSB { try await service.resetConnection() }
    }

    func importRecipes() async throws -> ImportedRecipeCollection {
        try await arbiter.withUSB { try await service.importRecipes() }
    }

    func render(raw: PreparedRAW, recipe: RecipeSnapshot, policy: OutputPolicy) async throws -> CameraJPEG {
        try await arbiter.withUSB { try await service.render(raw: raw, recipe: recipe, policy: policy) }
    }

    func disconnect() async {
        try? await arbiter.disconnectUSB(explicitly: false) { try await service.disconnectConfirmed() }
    }

    func disconnectConfirmed() async throws {
        try await arbiter.disconnectUSB(explicitly: true) { try await service.disconnectConfirmed() }
    }

    func wirelessOwnership(invalidatePreview: @escaping @Sendable () async -> Void) -> some WirelessCameraOwnershipGateway {
        USBHandoff(arbiter: arbiter, invalidatePreview: invalidatePreview, service: service)
    }

    private struct USBHandoff: WirelessCameraOwnershipGateway {
        let arbiter: CameraUseArbiter
        let invalidatePreview: @Sendable () async -> Void
        let service: any CameraServing

        func acquireWireless() async throws -> CameraUseLease {
            do {
                return try await arbiter.acquireWireless(invalidatePreview: invalidatePreview) {
                    try await service.disconnectConfirmed()
                }
            } catch CameraServiceError.closeUnconfirmed {
                throw WirelessFailure.usbCloseUnconfirmed
            }
        }

        func releaseWireless(_ lease: CameraUseLease) async {
            await arbiter.releaseWireless(lease)
        }
    }
}
