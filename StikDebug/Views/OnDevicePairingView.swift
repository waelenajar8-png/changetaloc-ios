import SwiftUI

struct OnDevicePairingView: View {
    @ObservedObject var service: OnDevicePairingService
    @State private var appleTVPIN = ""
    @State private var pairingAppleTV = false
    @State private var showingAppPlacement = false

    var body: some View {
        Form {
            content
        }
        .navigationTitle("Associer cet iPhone")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.default, value: service.phase)
        .sheet(isPresented: $showingAppPlacement) {
            if let url = service.exportURL {
                PairingFilePlacementView(pairingFileURL: url, target: service.placementTarget)
            }
        }
        .onDisappear {
            service.cancel()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch service.phase {
        case .idle:
            Section {
                Button {
                    pairingAppleTV = false
                    service.start(discoverAppleTVs: false)
                } label: {
                    Label("Associer cet iPhone", systemImage: "iphone")
                }
            } footer: {
                Text("Crée le fichier de jumelage sans ordinateur. L'iPhone doit être sous iOS 27 ou plus récent. Sinon, rebranche simplement ton iPhone à l'ordinateur et relance l'assistant ChangeTaLoc.")
            }

        case .discovering:
            if pairingAppleTV {
                Section {
                    if service.appleTVDevices.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Recherche des Apple TV…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(service.appleTVDevices) { device in
                            Button {
                                appleTVPIN = ""
                                service.pairAppleTV(device)
                            } label: {
                                Label(device.name, systemImage: "appletv")
                            }
                        }
                    }
                } header: {
                    Text("Choisis une Apple TV")
                } footer: {
                    Text("Sur l'Apple TV, ouvre Réglages › Télécommandes et appareils › App Remote et appareils.")
                }
            } else {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("En attente de l'iPhone…")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    guideStep(1, "Ouvre Réglages sur l'iPhone.")
                    guideStep(2, "Va dans Confidentialité et sécurité › Mode développeur.")
                    guideStep(3, "Touche « Associer à \(service.hostname) ».")
                    guideStep(4, "Tape le code affiché par ChangeTaLoc ou dans sa notification.")
                } header: {
                    Text("Sur l'iPhone")
                } footer: {
                    Text("ChangeTaLoc reste active pendant que tu ouvres Réglages : le code s'affiche aussi dans une notification.")
                }
            }
            cancelSection

        case .waiting:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(service.mode == .appleTV
                         ? "Association avec \(service.selectedAppleTVName ?? "l'Apple TV")…"
                         : "Vérification de l'association…")
                }
            }
            cancelSection

        case .pin(let pin):
            Section {
                VStack(spacing: 14) {
                    Text(service.mode == .localDevice
                         ? "Tape ce code dans Réglages sur cet iPhone"
                         : "Tape ce code sur l'autre appareil")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(pin)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .tracking(6)
                        .textSelection(.enabled)
                    ProgressView()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            cancelSection

        case .appleTVPIN:
            Section {
                TextField("Code à 6 chiffres", text: $appleTVPIN)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .onChange(of: appleTVPIN) { _, newValue in
                        appleTVPIN = String(newValue.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                    }
                Button("Associer") {
                    service.submitAppleTVPIN(appleTVPIN)
                    appleTVPIN = ""
                }
                .disabled(appleTVPIN.count != 6)
            } header: {
                Text("Associer \(service.selectedAppleTVName ?? "l'Apple TV")")
            } footer: {
                Text("Tape le code à 6 chiffres affiché sur ton Apple TV.")
            }
            cancelSection

        case .success(let name, let model, let isLocal):
            Section {
                Label("Association réussie", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if !name.isEmpty || !model.isEmpty {
                    Text([name, model].filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                if isLocal {
                    Label("ChangeTaLoc l'utilise maintenant", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            Section {
                if service.exportURL != nil {
                    Button {
                        showingAppPlacement = true
                    } label: {
                        Label("Placer dans une autre app", systemImage: "square.and.arrow.down.on.square")
                    }
                }
                if let exportURL = service.exportURL {
                    ShareLink(item: exportURL) {
                        Label("Exporter le fichier de jumelage", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text(isLocal
                     ? "Le fichier de jumelage est enregistré dans ChangeTaLoc. Tu peux revenir à la carte."
                     : "Tu peux placer ce fichier dans une app compatible de l'autre appareil, ou l'exporter.")
            }

        case .failed(let message):
            Section {
                Label("L'association a échoué", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Section {
                Button("Réessayer") {
                    service.reset()
                }
            }
        }
    }

    private var cancelSection: some View {
        Section {
            Button("Annuler", role: .cancel) {
                service.cancel()
            }
        }
    }

    private func guideStep(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.tint, in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PairingFilePlacementView: View {
    @Environment(\.dismiss) private var dismiss
    let pairingFileURL: URL
    let target: PairingPlacementTarget?
    @State private var apps: [PairingDestinationApp] = []
    @State private var isLoading = true
    @State private var placingApp: PairingDestinationApp?
    @State private var pendingApp: PairingDestinationApp?
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isLoading {
                        ProgressView("Chargement des apps…")
                            .frame(maxWidth: .infinity)
                    } else if apps.isEmpty {
                        Text(target == nil
                             ? "Aucune app compatible sur cet iPhone."
                             : "Aucune app compatible sur l'autre appareil.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(apps) { app in
                            Button {
                                pendingApp = app
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.name)
                                    Text(app.bundleID)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(placingApp != nil)
                        }
                    }
                } header: {
                    Text("Choisis une app")
                } footer: {
                    Text(target == nil
                         ? "LocalDevVPN doit être activé. Seules les apps compatibles sont listées."
                         : "Garde les deux appareils sur le même Wi-Fi. Seules les apps compatibles sont listées.")
                }
                if let placingApp {
                    Section {
                        ProgressView("Copie du fichier dans \(placingApp.name)…")
                            .frame(maxWidth: .infinity)
                    }
                }
                if let message {
                    Section {
                        Label(message, systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle")
                            .foregroundStyle(isError ? .red : .green)
                    }
                }
            }
            .navigationTitle("Placer le fichier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("OK") { dismiss() }
                        .disabled(placingApp != nil)
                }
            }
            .confirmationDialog(
                "Remplacer le fichier de jumelage de \(pendingApp?.name ?? "cette app") ?",
                isPresented: Binding(
                    get: { pendingApp != nil },
                    set: { if !$0 { pendingApp = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingApp
            ) { app in
                Button("Placer le fichier", role: .destructive) {
                    pendingApp = nil
                    place(in: app)
                }
                Button("Annuler", role: .cancel) { pendingApp = nil }
            } message: { app in
                Text("L'ancien fichier de jumelage de cette app sera remplacé.")
            }
        }
        .interactiveDismissDisabled(placingApp != nil)
        .task {
            do {
                let loaded = try await Task.detached {
                    try JITEnableContext.shared.pairingDestinationApps(target: target)
                }.value
                guard !Task.isCancelled else { return }
                apps = loaded
            } catch {
                guard !Task.isCancelled else { return }
                isError = true
                message = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func place(in app: PairingDestinationApp) {
        placingApp = app
        message = nil
        Task {
            do {
                let data = try Data(contentsOf: pairingFileURL)
                try await Task.detached {
                    try JITEnableContext.shared.placePairingFile(data, in: app, target: target)
                }.value
                isError = false
                message = "Fichier de jumelage placé dans \(app.name)."
            } catch {
                isError = true
                message = error.localizedDescription
            }
            placingApp = nil
        }
    }
}
