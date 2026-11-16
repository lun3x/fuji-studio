import Foundation

enum GalleryOriginalRestoration {
  case setting(WirelessIdentityTrace.GalleryOriginalMode, slot: UInt32)
  case owed(WirelessIdentityTrace.GalleryOriginalMode, slot: UInt32)
  case refused(UInt16)
  case unconfirmed
}

extension CameraHostedTransferSession {
  func prepareGalleryOriginalMode(slot: UInt32) async throws {
    guard selectedStorage == slot else { throw WirelessFailure.unavailableStorage }
    let confirmOnly: Bool
    switch galleryOriginalRestoration {
    case .owed:
      // A retry can confirm this setting without replacing the saved prior value.
      confirmOnly = true
    case .refused(let code):
      throw PTPError.responseCode(code)
    case .setting, .unconfirmed:
      throw WirelessFailure.originalSizeUnavailable
    case nil:
      confirmOnly = galleryOriginalModePrepared
    }
    if confirmOnly {
      try await requireGalleryOriginalMode()
      galleryOriginalModePrepared = true
      return
    }

    let prior = try await readGalleryOriginalMode(stage: .galleryOriginalModeRead)
    if prior != .original {
      let stage = WirelessIdentityTrace.Stage.galleryOriginalModeWrite
      transport.observeIdentity(.init(stage, .waiting, gallerySlot: slot, galleryOriginalMode: .original))
      galleryOriginalRestoration = .setting(prior, slot: slot)
      do {
        try await setProperty(0xd226, WirelessIdentityTrace.GalleryOriginalMode.original.rawValue, width: 2) {
          if case .setting = galleryOriginalRestoration {
            galleryOriginalRestoration = .owed(prior, slot: slot)
          }
        }
        transport.observeIdentity(.init(stage, .completed, gallerySlot: slot, galleryOriginalMode: .original))
      } catch let PTPError.responseCode(code) {
        if case .setting = galleryOriginalRestoration { galleryOriginalRestoration = nil }
        transport.observeIdentity(.init(stage, .failed, failure: .rejected, responseCode: code, gallerySlot: slot))
        throw PTPError.responseCode(code)
      } catch {
        transport.observeIdentity(.init(stage, .failed, failure: .init(error), gallerySlot: slot))
        if case .setting = galleryOriginalRestoration {
          markGalleryRestorationUnconfirmed(.init(error))
        }
        throw error
      }
      try await requireGalleryOriginalMode()
    }
    galleryOriginalModePrepared = true
  }

  private func requireGalleryOriginalMode() async throws {
    _ = try await readGalleryOriginalMode(stage: .galleryOriginalModeConfirmation, requireOriginal: true)
  }

  private func readGalleryOriginalMode(
    stage: WirelessIdentityTrace.Stage, requireOriginal: Bool = false
  ) async throws -> WirelessIdentityTrace.GalleryOriginalMode {
    let slot = selectedStorage
    transport.observeIdentity(.init(stage, .waiting, gallerySlot: slot))
    do {
      let value = try await readScalar(0xd226, widths: [2, 4])
      guard let mode = WirelessIdentityTrace.GalleryOriginalMode(rawValue: value),
        !requireOriginal || mode == .original
      else { throw WirelessFailure.originalSizeUnavailable }
      transport.observeIdentity(.init(stage, .completed, gallerySlot: slot, galleryOriginalMode: mode))
      return mode
    } catch {
      let response: UInt16?
      if case PTPError.responseCode(let code) = error { response = code } else { response = nil }
      transport.observeIdentity(.init(stage, .failed, failure: .init(error), responseCode: response, gallerySlot: slot))
      if response == 0x200a { throw WirelessFailure.originalSizeUnavailable }
      throw error
    }
  }

  // Restore before D244 changes the slot. D226 has no verified cross-card scope.
  func restoreGalleryOriginalMode(canRestore: Bool, whileClosing: Bool) async throws {
    guard let restoration = galleryOriginalRestoration else { return }
    if case .refused(let code) = restoration { throw PTPError.responseCode(code) }
    guard canRestore, case .owed(let prior, let slot) = restoration, selectedStorage == slot else {
      markGalleryRestorationUnconfirmed(canRestore ? .connectionLost : .cancelled)
      throw WirelessFailure.originalSizeUnavailable
    }
    let stage = WirelessIdentityTrace.Stage.galleryOriginalModeRestore
    transport.observeIdentity(.init(stage, .waiting, gallerySlot: slot, galleryOriginalMode: prior))
    do {
      try await setProperty(0xd226, prior.rawValue, width: 2, whileClosing: whileClosing) {
        galleryOriginalRestoration = nil
        transport.observeIdentity(.init(stage, .completed, gallerySlot: slot, galleryOriginalMode: prior))
      }
    } catch let PTPError.responseCode(code) {
      galleryOriginalRestoration = .refused(code)
      transport.observeIdentity(.init(stage, .failed, failure: .rejected, responseCode: code,
        gallerySlot: slot, galleryOriginalMode: prior))
      throw PTPError.responseCode(code)
    } catch {
      markGalleryRestorationUnconfirmed(.init(error))
      throw error
    }
  }

  func markGalleryRestorationUnconfirmed(_ failure: WirelessIdentityTrace.Failure) {
    let prior: WirelessIdentityTrace.GalleryOriginalMode
    let slot: UInt32
    switch galleryOriginalRestoration {
    case .setting(let mode, let changedSlot), .owed(let mode, let changedSlot):
      prior = mode
      slot = changedSlot
    case .refused, .unconfirmed, nil: return
    }
    galleryOriginalRestoration = .unconfirmed
    transport.observeIdentity(.init(.galleryOriginalModeRestoreUnconfirmed, .failed,
      failure: failure, gallerySlot: slot, galleryOriginalMode: prior))
  }
}
