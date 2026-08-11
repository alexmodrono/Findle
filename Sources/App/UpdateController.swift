// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Sparkle

@MainActor
final class UpdateController: ObservableObject {
    // SPUStandardUpdaterController owns the user driver that drives Sparkle's
    // update UI. Discarding it (storing only `updater`) invalidates the driver
    // and update prompts silently no-op, so retain it for the lifetime of the
    // controller.
    private let updaterController: SPUStandardUpdaterController
    let updater: SPUUpdater

    /// Whether this build has an update feed at all.
    ///
    /// Nightly builds are distributed as unsigned CI artifacts with no appcast,
    /// so `SUFeedURL` is empty there. Starting Sparkle without a feed makes it
    /// raise a configuration error, so the updater stays stopped instead and the
    /// UI hides the update controls.
    let updatesSupported: Bool

    @Published var canCheckForUpdates = false

    init() {
        let feedURL = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) ?? ""
        let supported = !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.updatesSupported = supported

        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: supported,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updater = updaterController.updater

        guard supported else { return }
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        guard updatesSupported else { return }
        updater.checkForUpdates()
    }
}
