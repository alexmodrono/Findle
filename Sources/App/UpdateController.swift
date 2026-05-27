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

    @Published var canCheckForUpdates = false

    init() {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updater = updaterController.updater

        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
