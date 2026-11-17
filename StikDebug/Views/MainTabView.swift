//
//  MainTabView.swift
//  StikDebug
//
//  Created by Stephen on 3/27/25.
//

import SwiftUI
import Foundation
import CoreLocation

private enum ExternalLocationAction: Identifiable {
    case simulate(URL, Double, Double)
    case clear

    var id: String {
        switch self {
        case .simulate(let url, _, _):
            return "simulate-\(url.absoluteString)"
        case .clear:
            return "clear-location"
        }
    }

    var title: String {
        switch self {
        case .simulate:
            return "Changer la position ?"
        case .clear:
            return "Revenir à la vraie position ?"
        }
    }

    var message: String {
        switch self {
        case .simulate(_, let latitude, let longitude):
            return String(format: "Un lien veut placer ta position sur %.6f, %.6f.", latitude, longitude)
        case .clear:
            return "Un lien veut te ramener à ta vraie position."
        }
    }

    var confirmationTitle: String {
        switch self {
        case .simulate:
            return "Changer la position"
        case .clear:
            return "Retour à ma vraie position"
        }
    }
}

// MARK: - Annonce de mise à jour

enum AppRelease {
    /// Numéro de cette version de l'app. Pour annoncer une mise à jour aux clients :
    /// augmenter ce numéro de 1, publier l'app, puis mettre le même numéro dans
    /// LATEST_RELEASE sur le site (app/api/app/version). Les anciennes versions affichent alors le bandeau.
    static let current = 2
}

/// Demande au site s'il existe une version plus récente de l'app.
/// L'app ne peut pas se mettre à jour seule : on invite le client à rebrancher son iPhone.
@MainActor
final class UpdateNotice: ObservableObject {
    static let shared = UpdateNotice()

    @Published private(set) var latest = 0
    private var lastCheck: Date?

    func refresh() {
        // Une vérification par heure suffit.
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 3600 { return }
        lastCheck = Date()
        Task {
            var request = URLRequest(url: URL(string: "https://changetaloc.com/api/app/version")!)
            request.timeoutInterval = 10
            request.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = object["latest"] as? Int else {
                // Pas de réseau ou site injoignable : on réessaiera à la prochaine ouverture.
                lastCheck = nil
                return
            }
            latest = value
        }
    }
}

struct MainTabView: View {
    @AppStorage("primaryTabSelection") private var selection: String = AppFeature.location.id
    @AppStorage("dismissedRelease") private var dismissedRelease = 0
    @ObservedObject private var updateNotice = UpdateNotice.shared
    @Environment(\.scenePhase) private var scenePhase

    private var showsUpdateBanner: Bool {
        updateNotice.latest > AppRelease.current && dismissedRelease < updateNotice.latest
    }

    private var updateBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nouvelle version disponible")
                    .font(.subheadline.weight(.semibold))
                Text("Rebranche ton iPhone à l'ordinateur et clique sur « Mettre à jour ou renouveler » dans l'assistant ChangeTaLoc.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    dismissedRelease = updateNotice.latest
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .accessibilityLabel("Masquer")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
    @State private var detachedFeature: AppFeature?
    @AppStorage("didShowWelcomeGuide") private var didShowWelcomeGuide = false
    @State private var didSetInitialHome = false
    @State private var pendingLocationAction: ExternalLocationAction?

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(AppFeature.mainTabs) { feature in
                    feature.destination
                        .tabItem { Label(feature.title, systemImage: feature.systemImage) }
                        .tag(feature.id)
                }
            }
            .onAppear {
                ensureSelectionIsValid()
                if !didSetInitialHome {
                    selection = AppFeature.location.id
                    didSetInitialHome = true
                }
            }
            .onOpenURL { url in
                handleURL(url)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if showsUpdateBanner {
                    updateBanner
                }
            }
            .animation(.easeOut(duration: 0.25), value: showsUpdateBanner)
            .task {
                updateNotice.refresh()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    updateNotice.refresh()
                }
            }
            .confirmationDialog(
                pendingLocationAction?.title ?? "Demande de position",
                isPresented: Binding(
                    get: { pendingLocationAction != nil },
                    set: { isPresented in
                        if !isPresented {
                            pendingLocationAction = nil
                        }
                    }
                ),
                titleVisibility: .visible,
                presenting: pendingLocationAction
            ) { action in
                Button(action.confirmationTitle, role: .destructive) {
                    performLocationAction(action)
                    pendingLocationAction = nil
                }
                Button("Annuler", role: .cancel) {
                    pendingLocationAction = nil
                }
            } message: { action in
                Text(action.message)
            }
            .fullScreenCover(isPresented: Binding(
                get: { !didShowWelcomeGuide },
                set: { isPresented in
                    if !isPresented { didShowWelcomeGuide = true }
                }
            )) {
                WelcomeGuideView {
                    didShowWelcomeGuide = true
                }
            }
            .sheet(item: $detachedFeature) { feature in
                NavigationStack {
                    feature.destination
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Fermer") {
                                    detachedFeature = nil
                                }
                            }
                        }
                }
            }
        }
    }

    private func ensureSelectionIsValid() {
        let ids = AppFeature.mainTabs.map { $0.id }
        if ids.contains(selection) {
            return
        }
        selection = AppFeature.location.id
    }

    private func handleURL(_ url: URL) {
        guard let host = url.host()?.lowercased() else { return }

        switch host {
        case "simulate-location", "set-location":
            confirmSimulatedLocation(from: url)
        case "location", "location-simulation":
            if coordinate(from: url) == nil {
                openFeature(id: AppFeature.location.id)
            } else {
                confirmSimulatedLocation(from: url)
            }
        case "clear-location", "stop-location":
            pendingLocationAction = .clear
        default:
            break
        }
    }

    private func openFeature(id: String) {
        guard let feature = AppFeature(rawValue: id) else {
            return
        }

        if AppFeature.mainTabs.contains(feature) {
            selection = feature.id
        } else {
            detachedFeature = feature
        }
    }

    private func confirmSimulatedLocation(from url: URL) {
        guard let coordinate = coordinate(from: url) else {
            showAlert(
                title: "Lien invalide",
                message: "Use stikdebug://simulate-location?lat=37.3349&lon=-122.0090",
                showOk: true
            )
            return
        }

        guard coordinateIsValid(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            showAlert(
                title: "Coordonnées invalides",
                message: "La latitude va de -90 à 90 et la longitude de -180 à 180.",
                showOk: true
            )
            return
        }

        pendingLocationAction = .simulate(url, coordinate.latitude, coordinate.longitude)
    }

    private func performLocationAction(_ action: ExternalLocationAction) {
        switch action {
        case .simulate(let url, _, _):
            simulateLocation(from: url)
        case .clear:
            clearSimulatedLocation()
        }
    }

    private func simulateLocation(from url: URL) {
        guard let coordinate = coordinate(from: url) else {
            showAlert(
                title: "Lien invalide",
                message: "Use stikdebug://simulate-location?lat=37.3349&lon=-122.0090",
                showOk: true
            )
            return
        }

        guard coordinateIsValid(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            showAlert(
                title: "Coordonnées invalides",
                message: "La latitude va de -90 à 90 et la longitude de -180 à 180.",
                showOk: true
            )
            return
        }

        let pairingFile = PairingFileStore.prepareURL()
        guard FileManager.default.fileExists(atPath: pairingFile.path) else {
            showAlert(
                title: "Liaison avec l'iPhone manquante",
                message: "Relance l'assistant ChangeTaLoc sur ton ordinateur avant d'utiliser ce lien.",
                showOk: true
            )
            return
        }

        LocationSimulationCommandQueue.shared.async {
            let code = simulate_location(
                DeviceConnectionContext.targetIPAddress,
                coordinate.latitude,
                coordinate.longitude,
                pairingFile.path
            )

            DispatchQueue.main.async {
                if code == 0 {
                    LocationSimulationSession.shared.clearRoute()
                    LocationSimulationSession.shared.startResending(
                        at: CLLocationCoordinate2D(
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude
                        )
                    ) {
                        LocationSimulationCommandQueue.shared.async {
                            _ = simulate_location(
                                DeviceConnectionContext.targetIPAddress,
                                coordinate.latitude,
                                coordinate.longitude,
                                pairingFile.path
                            )
                        }
                    }
                    LogManager.shared.addInfoLog(
                        String(format: "Simulated location from URL: %.6f, %.6f", coordinate.latitude, coordinate.longitude)
                    )
                } else {
                    showAlert(
                        title: "Changement impossible",
                        message: "Impossible de changer la position (erreur \(code)). Vérifie que LocalDevVPN est activé.",
                        showOk: true
                    )
                }
            }
        }
    }

    private func clearSimulatedLocation() {
        LocationSimulationCommandQueue.shared.async {
            let code = clear_simulated_location()
            DispatchQueue.main.async {
                if code == 0 {
                    LocationSimulationSession.shared.stop()
                    LogManager.shared.addInfoLog("Cleared simulated location from URL")
                } else {
                    showAlert(
                        title: "Retour impossible",
                        message: "Impossible de revenir à la vraie position (erreur \(code)).",
                        showOk: true
                    )
                }
            }
        }
    }

    private func coordinate(from url: URL) -> (latitude: Double, longitude: Double)? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        func queryValue(_ names: [String]) -> String? {
            for name in names {
                if let value = queryItems.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value {
                    return value
                }
            }
            return nil
        }

        if let latitudeText = queryValue(["lat", "latitude"]),
           let longitudeText = queryValue(["lon", "lng", "long", "longitude"]),
           let latitude = Double(latitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
           let longitude = Double(longitudeText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return (latitude, longitude)
        }

        let coordinateText = queryValue(["coordinate", "coordinates", "coords", "q", "ll"])
            ?? components?.path
            ?? ""
        let values = numbers(in: coordinateText)
        guard values.count >= 2 else { return nil }
        return (values[0], values[1])
    }

    private func coordinateIsValid(latitude: Double, longitude: Double) -> Bool {
        (-90.0...90.0).contains(latitude) && (-180.0...180.0).contains(longitude)
    }

    private func numbers(in text: String) -> [Double] {
        let pattern = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return Double(text[matchRange])
        }
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
    }
}
