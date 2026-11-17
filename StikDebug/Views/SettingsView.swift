//  SettingsView.swift
//  StikDebug
//
//  Created by Stephen on 3/27/25.

import SwiftUI
import UIKit

private enum SettingsLinks {
    static let githubStars = URL(string: "https://github.com/StikDebug/StikDebug")!
    static let pairingFileGuide = URL(string: "https://github.com/StikDebug/StikDebug/blob/main/PAIRING.md")!
    static let discord = URL(string: "https://discord.gg/qahjXNTDwS")!
}

struct SettingsView: View {
    @AppStorage("microMovements") private var microMovements = false
    @AppStorage("autoReturnMinutes") private var autoReturnMinutes = 0
    @StateObject private var onDevicePairing = OnDevicePairingService.shared
    @AppStorage(UserDefaults.Keys.txmOverride) private var overrideTXMDetection = false
    @AppStorage(UserDefaults.Keys.confirmExternalJITRequests) private var confirmExternalJITRequests = true
    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true
    @AppStorage(UserDefaults.Keys.targetDeviceIP) private var targetDeviceIP = DeviceConnectionContext.defaultTargetIPAddress
    @AppStorage("TunnelRemotePairingPort") private var remotePairingPortOverride = ""
    @AppStorage(UserDefaults.Keys.mallocDebug) private var mallocDebug = false

    private enum ConnectionField: Hashable {
        case address
        case port
    }

    @FocusState private var focusedConnectionField: ConnectionField?
    @State private var targetDeviceIPInput = ""
    @State private var remotePairingPortInput = ""
    @State private var automaticPortPlaceholder = "Discovering…"
    @State private var isShowingPairingFilePicker = false
    @State private var isImportingFile = false
    @State private var pairingImportMessage: (text: String, isError: Bool)?
    @State private var showDDIConfirmation = false
    @State private var isRedownloadingDDI = false
    @State private var ddiDownloadProgress: Double = 0.0
    @State private var ddiStatusMessage: String = ""
    @State private var ddiResultMessage: (text: String, isError: Bool)?

    private var appVersion: String {
        let marketingVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return marketingVersion
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            Image("StikDebug")
                                .resizable().aspectRatio(contentMode: .fit)
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            Text("ChangeTaLoc").font(.title2.weight(.semibold))
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 8)
                }

                Section("Mon compte") {
                    if let email = AccountStore.shared.email {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connecté")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(email)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    if let expiry = AppExpiry.expirationText {
                        LabeledContent {
                            Text(expiry)
                                .foregroundStyle((AppExpiry.daysLeft() ?? 7) <= 2 ? Color.orange : Color.secondary)
                        } label: {
                            Label("App valable jusqu'au", systemImage: "calendar.badge.clock")
                        }
                    }
                    Link(destination: URL(string: "https://changetaloc.com/compte")!) {
                        Label("Gérer mon abonnement", systemImage: "creditcard")
                    }
                    Button(role: .destructive, action: AccountStore.shared.signOut) {
                        Label("Se déconnecter", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }

                Section("Connexion à l'iPhone") {
                    NavigationLink {
                        OnDevicePairingView(service: onDevicePairing)
                    } label: {
                        Label("Associer cet iPhone", systemImage: "iphone.and.arrow.forward")
                    }

                    Button {
                        isShowingPairingFilePicker = true
                    } label: {
                        Label("Importer le fichier de jumelage", systemImage: "doc.badge.plus")
                    }
                    .disabled(isImportingFile)

                    if isImportingFile {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Import du fichier de jumelage…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let pairingImportMessage {
                        Label(
                            pairingImportMessage.text,
                            systemImage: pairingImportMessage.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(pairingImportMessage.isError ? .red : .green)
                    }
                }

                Section {
                    Toggle(isOn: $keepAliveAudio) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Audio silencieux")
                            Text("Garde l'app active en arrière-plan grâce à un son inaudible.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: keepAliveAudio) { _, enabled in
                        handleAudioKeepAliveChange(enabled)
                    }

                    Toggle(isOn: $keepAliveLocation) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Position en arrière-plan")
                            Text("Garde ta position choisie active quand tu utilises une autre app.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: keepAliveLocation) { _, enabled in
                        handleLocationKeepAliveChange(enabled)
                    }

                } header: {
                    Text("Rester actif en arrière-plan")
                }

                Section {
                    Toggle(isOn: $microMovements) {
                        Label("Micro-mouvements", systemImage: "dot.radiowaves.left.and.right")
                    }
                    Picker(selection: $autoReturnMinutes) {
                        Text("Jamais").tag(0)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("1 heure").tag(60)
                        Text("2 heures").tag(120)
                        Text("4 heures").tag(240)
                        Text("8 heures").tag(480)
                    } label: {
                        Label("Retour automatique", systemImage: "timer")
                    }
                } header: {
                    Text("Réalisme")
                } footer: {
                    Text("Micro-mouvements : ta position bouge de quelques mètres, comme un vrai téléphone. Retour automatique : ta vraie position revient seule après la durée choisie.")
                }

                Section("Dépannage") {
                    Button { showDDIConfirmation = true } label: {
                        Label("Réparer la connexion", systemImage: "arrow.down.circle")
                    }.foregroundStyle(.primary).disabled(isRedownloadingDDI)
                    if isRedownloadingDDI {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: ddiDownloadProgress, total: 1.0)
                            Text(ddiStatusMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let result = ddiResultMessage {
                        Text(result.text).font(.caption).foregroundStyle(result.isError ? .red : .green)
                    }
                }

                Section("Aide") {
                    Button(action: connectLocalDevVPN) {
                        Label("Ouvrir LocalDevVPN", systemImage: "network")
                    }
                    Link(destination: URL(string: "https://changetaloc.com/aide")!) {
                        Label("Aide et contact", systemImage: "questionmark.circle")
                    }
                    Link(destination: URL(string: "https://github.com/waelenajar8-png/changetaloc-ios")!) {
                        Label("Code source et licences", systemImage: "doc.text")
                    }
                }

                Section {
                    Text(versionFooter)
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Réglages")
            .background(KeyboardTapDismissal())
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            targetDeviceIPInput = targetDeviceIP
            remotePairingPortInput = remotePairingPortOverride
        }
        .task(id: targetDeviceIP) {
            automaticPortPlaceholder = "Discovering…"
            let result = await Task.detached {
                RemotePairingPortResolver.discover()
            }.value
            guard !Task.isCancelled else { return }
            automaticPortPlaceholder = result.source == "Bonjour"
                ? "Bonjour (\(result.port))"
                : "Fallback (\(result.port))"
        }
        .onChange(of: focusedConnectionField) { _, field in
            if field == nil {
                applyConnectionSettings()
            }
        }
        .onDisappear {
            applyConnectionSettings()
        }
        .fileImporter(
            isPresented: $isShowingPairingFilePicker,
            allowedContentTypes: PairingFileStore.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }

                let fileManager = FileManager.default
                isImportingFile = true
                pairingImportMessage = nil

                do {
                    try PairingFileStore.importFromPicker(url, fileManager: fileManager)
                    isImportingFile = false
                    pairingImportMessage = (String(localized: "Imported successfully"), false)
                    startTunnelInBackground()
                    schedulePairingStatusDismiss()
                } catch {
                    isImportingFile = false
                    pairingImportMessage = (String(localized: "Import failed: \(error.localizedDescription)"), true)
                    schedulePairingStatusDismiss()
                }
            case .failure(let error):
                isImportingFile = false
                pairingImportMessage = (String(localized: "Import failed: \(error.localizedDescription)"), true)
                schedulePairingStatusDismiss()
            }
        }
        .confirmationDialog("Réparer la connexion ?", isPresented: $showDDIConfirmation, titleVisibility: .visible) {
            Button("Réparer", role: .destructive) {
                redownloadDDIPressed()
            }
            Button("Annuler", role: .cancel) { }
        } message: {
            Text("Les fichiers de connexion seront retéléchargés. Garde une connexion Internet.")
        }
    }

    private func applyConnectionSettings() {
        let address = targetDeviceIPInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = remotePairingPortInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address != targetDeviceIP || port != remotePairingPortOverride else { return }
        targetDeviceIP = address
        remotePairingPortOverride = port
        TunnelManager.shared.restart()
    }

    private var versionFooter: String {
        let processInfo = ProcessInfo.processInfo
        let txmLabel: String
        if processInfo.isTXMOverridden {
            txmLabel = "TXM (Override)"
        } else {
            txmLabel = processInfo.hasTXM ? "TXM" : "Non TXM"
        }
        return "Version \(appVersion) • iOS \(UIDevice.current.systemVersion) • \(txmLabel)"
    }

    private func handleAudioKeepAliveChange(_ enabled: Bool) {
        if !enabled, !keepAliveLocation {
            keepAliveLocation = true
            BackgroundLocationManager.shared.requestAuthorizationIfNeeded()
        }
        BackgroundAudioManager.shared.configurationDidChange()
        BackgroundLocationManager.shared.configurationDidChange()
    }

    private func handleLocationKeepAliveChange(_ enabled: Bool) {
        if enabled {
            BackgroundLocationManager.shared.requestAuthorizationIfNeeded()
        } else if !keepAliveAudio {
            keepAliveAudio = true
        }
        BackgroundAudioManager.shared.configurationDidChange()
        BackgroundLocationManager.shared.configurationDidChange()
    }

    // MARK: - Business Logic

    private func openAppFolder() {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let path = documentsURL.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
        if let url = URL(string: path) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    private func redownloadDDIPressed() {
        guard !isRedownloadingDDI else { return }
        Task {
            await MainActor.run {
                isRedownloadingDDI = true
                ddiDownloadProgress = 0
                ddiStatusMessage = String(localized: "Preparing download…")
                ddiResultMessage = nil
            }
            do {
                try await redownloadDDI { progress, status in
                    Task { @MainActor in
                        self.ddiDownloadProgress = progress
                        self.ddiStatusMessage = status
                    }
                }
                await MainActor.run {
                    isRedownloadingDDI = false
                    ddiResultMessage = (String(localized: "DDI files refreshed successfully."), false)
                }
            } catch {
                await MainActor.run {
                    isRedownloadingDDI = false
                    ddiResultMessage = (String(localized: "Failed to redownload DDI files: \(error.localizedDescription)"), true)
                }
            }
        }
        scheduleDDIStatusDismiss()
    }

    private func schedulePairingStatusDismiss() {
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                if !isImportingFile {
                    pairingImportMessage = nil
                }
            }
        }
    }

    private func scheduleDDIStatusDismiss() {
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                if !isRedownloadingDDI {
                    ddiResultMessage = nil
                }
            }
        }
    }
}

private struct KeyboardTapDismissal: UIViewRepresentable {
    func makeUIView(context: Context) -> DismissalView {
        DismissalView()
    }

    func updateUIView(_ uiView: DismissalView, context: Context) {}

    final class DismissalView: UIView, UIGestureRecognizerDelegate {
        private weak var attachedWindow: UIWindow?
        private lazy var tapRecognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachedWindow?.removeGestureRecognizer(tapRecognizer)
            attachedWindow = window
            window?.addGestureRecognizer(tapRecognizer)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView || current is UIInputView {
                    return false
                }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc private func dismissKeyboard() {
            window?.endEditing(true)
        }
    }
}

func connectLocalDevVPN() {
    let callbackScheme = ProcessInfo.processInfo.environment["LC_HOME_PATH"] != nil
        ? "livecontainer"
        : "stikdebug"
    guard let url = URL(string: "localdevvpn://enable?scheme=\(callbackScheme)") else { return }
    UIApplication.shared.open(url, options: [:]) { opened in
        if !opened {
            DispatchQueue.main.async {
                UIApplication.shared.open(URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!)
            }
        }
    }
}
