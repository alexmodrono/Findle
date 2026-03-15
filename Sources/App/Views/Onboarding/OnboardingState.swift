// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import SharedDomain
import FoodleNetworking

@MainActor
final class OnboardingState: ObservableObject {
    @Published var serverURL = ""
    @Published var username = ""
    @Published var password = ""
    @Published var validatedSite: MoodleSite?
    @Published var errorMessage: String?
    @Published var showEmbeddedSSO = false
    @Published var embeddedAuthCoordinator: EmbeddedAuthCoordinator?
}
