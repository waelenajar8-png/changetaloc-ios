import SwiftUI
import MapKit
import CoreLocation

// MARK: - Manette : se déplacer en direct.

/// Vitesse de déplacement avec la manette.
enum JoystickSpeed: String, CaseIterable, Identifiable {
    case walk, run, bike, car

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: return "Marche"
        case .run: return "Course"
        case .bike: return "Vélo"
        case .car: return "Voiture"
        }
    }

    var kmh: Int {
        switch self {
        case .walk: return 5
        case .run: return 10
        case .bike: return 18
        case .car: return 50
        }
    }

    var metersPerSecond: Double { Double(kmh) / 3.6 }

    var systemImage: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .bike: return "bicycle"
        case .car: return "car.fill"
        }
    }
}

/// Position suivante quand on avance de `meters` dans la direction (est, nord).
func joystickStep(
    from coordinate: CLLocationCoordinate2D,
    east: Double,
    north: Double,
    meters: Double
) -> CLLocationCoordinate2D {
    let length = max((east * east + north * north).squareRoot(), 0.0001)
    let metersNorth = meters * north / length
    let metersEast = meters * east / length
    let latitude = coordinate.latitude + metersNorth / 111_111
    let longitudeScale = max(cos(coordinate.latitude * .pi / 180), 0.01)
    var longitude = coordinate.longitude + metersEast / (111_111 * longitudeScale)
    if longitude > 180 { longitude -= 360 }
    if longitude < -180 { longitude += 360 }
    return CLLocationCoordinate2D(latitude: min(max(latitude, -85), 85), longitude: longitude)
}

/// Manette ronde : on fait glisser le rond central dans la direction voulue.
/// `vector` : x vers l'est, y vers le nord, longueur entre 0 et 1.
struct JoystickPad: View {
    @Binding var vector: CGVector
    var size: CGFloat = 128

    @State private var knobOffset: CGSize = .zero

    private var knobSize: CGFloat { size * 0.38 }
    private var travel: CGFloat { size / 2 - knobSize / 2 }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(0.08))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1.5))

            ForEach(0..<4, id: \.self) { index in
                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .offset(y: -(size / 2 - 12))
                    .rotationEffect(.degrees(Double(index) * 90))
            }

            Circle()
                .fill(Color.accentColor)
                .frame(width: knobSize, height: knobSize)
                .overlay(
                    Image(systemName: "location.north.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .rotationEffect(knobAngle)
                        .opacity(knobOffset == .zero ? 0 : 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .offset(knobOffset)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    var translation = value.translation
                    let length = (translation.width * translation.width + translation.height * translation.height).squareRoot()
                    if length > travel, length > 0 {
                        translation = CGSize(
                            width: translation.width / length * travel,
                            height: translation.height / length * travel
                        )
                    }
                    knobOffset = translation
                    vector = CGVector(dx: translation.width / travel, dy: -translation.height / travel)
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                        knobOffset = .zero
                    }
                    vector = .zero
                }
        )
        .sensoryFeedback(.impact(weight: .light), trigger: knobOffset == .zero)
        .accessibilityLabel("Manette de déplacement")
    }

    private var knobAngle: Angle {
        .radians(Double(atan2(knobOffset.width, -knobOffset.height)))
    }
}

// MARK: - Circuits tout prêts.

struct TourStop {
    let name: String
    let latitude: Double
    let longitude: Double
}

/// Un parcours prêt à lancer : départ, étapes et arrivée, avec le mode conseillé.
struct TourCircuit: Identifiable {
    let id: String
    let title: String
    let summary: String
    /// Valeur brute du mode de déplacement (« walk », « car »…).
    let mode: String
    let stops: [TourStop]

    var systemImage: String {
        switch mode {
        case "walk": return "figure.walk"
        case "bike": return "bicycle"
        case "moto": return "scooter"
        default: return "car.fill"
        }
    }

    var modeLabel: String {
        switch mode {
        case "walk": return "à pied"
        case "bike": return "à vélo"
        case "moto": return "en moto"
        default: return "en voiture"
        }
    }
}

enum TourCatalog {
    static let all: [TourCircuit] = [
        TourCircuit(
            id: "paris-monuments",
            title: "Paris, les monuments",
            summary: "Tour Eiffel, Arc de Triomphe, Concorde, Louvre et Notre-Dame.",
            mode: "car",
            stops: [
                TourStop(name: "Tour Eiffel", latitude: 48.85837, longitude: 2.29448),
                TourStop(name: "Arc de Triomphe", latitude: 48.87380, longitude: 2.29504),
                TourStop(name: "Place de la Concorde", latitude: 48.86563, longitude: 2.32124),
                TourStop(name: "Musée du Louvre", latitude: 48.86099, longitude: 2.33583),
                TourStop(name: "Notre-Dame de Paris", latitude: 48.85297, longitude: 2.34988),
            ]
        ),
        TourCircuit(
            id: "paris-montmartre",
            title: "Montmartre à pied",
            summary: "Du Moulin Rouge au Sacré-Cœur, en passant par la place du Tertre.",
            mode: "walk",
            stops: [
                TourStop(name: "Moulin Rouge", latitude: 48.88409, longitude: 2.33227),
                TourStop(name: "Place du Tertre", latitude: 48.88651, longitude: 2.34072),
                TourStop(name: "Sacré-Cœur", latitude: 48.88671, longitude: 2.34310),
            ]
        ),
        TourCircuit(
            id: "riviera",
            title: "Nice → Monaco par la côte",
            summary: "La Promenade des Anglais, Villefranche, Èze, puis le Casino de Monte-Carlo.",
            mode: "car",
            stops: [
                TourStop(name: "Promenade des Anglais", latitude: 43.69478, longitude: 7.25689),
                TourStop(name: "Port de Nice", latitude: 43.69563, longitude: 7.28474),
                TourStop(name: "Villefranche-sur-Mer", latitude: 43.70396, longitude: 7.31125),
                TourStop(name: "Èze", latitude: 43.72783, longitude: 7.36182),
                TourStop(name: "Casino de Monte-Carlo", latitude: 43.73912, longitude: 7.42743),
            ]
        ),
        TourCircuit(
            id: "cannes-croisette",
            title: "Cannes, la Croisette",
            summary: "Du Palais des Festivals au Martinez, jusqu'au bout de la Croisette.",
            mode: "walk",
            stops: [
                TourStop(name: "Palais des Festivals", latitude: 43.55107, longitude: 7.01760),
                TourStop(name: "Hôtel Martinez", latitude: 43.54850, longitude: 7.03220),
                TourStop(name: "Pointe Croisette", latitude: 43.54380, longitude: 7.04400),
            ]
        ),
        TourCircuit(
            id: "london",
            title: "Londres en voiture",
            summary: "Buckingham Palace, Trafalgar Square, Big Ben et Tower Bridge.",
            mode: "car",
            stops: [
                TourStop(name: "Buckingham Palace", latitude: 51.50136, longitude: -0.14189),
                TourStop(name: "Trafalgar Square", latitude: 51.50803, longitude: -0.12807),
                TourStop(name: "Big Ben", latitude: 51.50073, longitude: -0.12463),
                TourStop(name: "Tower Bridge", latitude: 51.50546, longitude: -0.07536),
            ]
        ),
        TourCircuit(
            id: "new-york",
            title: "Manhattan, New York",
            summary: "Central Park, Times Square, l'Empire State Building et le One World Trade Center.",
            mode: "car",
            stops: [
                TourStop(name: "Central Park (Columbus Circle)", latitude: 40.76808, longitude: -73.98193),
                TourStop(name: "Times Square", latitude: 40.75800, longitude: -73.98552),
                TourStop(name: "Empire State Building", latitude: 40.74844, longitude: -73.98566),
                TourStop(name: "One World Trade Center", latitude: 40.71274, longitude: -74.01338),
            ]
        ),
        TourCircuit(
            id: "las-vegas",
            title: "Le Strip de Las Vegas",
            summary: "Du panneau « Welcome to Las Vegas » aux fontaines du Bellagio, jusqu'à la Strat.",
            mode: "car",
            stops: [
                TourStop(name: "Welcome to Las Vegas", latitude: 36.08209, longitude: -115.17284),
                TourStop(name: "Bellagio", latitude: 36.11255, longitude: -115.17448),
                TourStop(name: "Caesars Palace", latitude: 36.11620, longitude: -115.17450),
                TourStop(name: "The Strat", latitude: 36.14749, longitude: -115.15563),
            ]
        ),
        TourCircuit(
            id: "dubai",
            title: "Dubaï, de la tour à la Marina",
            summary: "Burj Khalifa, Burj Al Arab, l'Atlantis sur la Palm, puis Dubai Marina.",
            mode: "car",
            stops: [
                TourStop(name: "Burj Khalifa", latitude: 25.19720, longitude: 55.27437),
                TourStop(name: "Burj Al Arab", latitude: 25.14115, longitude: 55.18528),
                TourStop(name: "Atlantis The Palm", latitude: 25.13044, longitude: 55.11718),
                TourStop(name: "Dubai Marina", latitude: 25.08050, longitude: 55.14030),
            ]
        ),
        TourCircuit(
            id: "miami",
            title: "Miami Beach",
            summary: "De South Pointe à Ocean Drive, jusqu'à Lincoln Road.",
            mode: "bike",
            stops: [
                TourStop(name: "South Pointe Park", latitude: 25.76540, longitude: -80.13340),
                TourStop(name: "Ocean Drive", latitude: 25.78170, longitude: -80.13010),
                TourStop(name: "Lincoln Road", latitude: 25.79060, longitude: -80.13860),
            ]
        ),
    ]
}

struct CircuitsSheet: View {
    let onSelect: (TourCircuit) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choisis un parcours : le départ, les étapes et l'arrivée sont déjà placés. Tu peux changer le mode de déplacement, puis lancer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(TourCatalog.all) { circuit in
                        Button {
                            onSelect(circuit)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: circuit.systemImage)
                                    .font(.title3.weight(.semibold))
                                    .frame(width: 42, height: 42)
                                    .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(circuit.title)
                                        .font(.headline)
                                    Text(circuit.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text("\(circuit.stops.count) lieux · \(circuit.modeLabel)")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Circuits tout prêts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Étapes et départ programmé.

/// Recherche d'un lieu à ajouter comme étape du trajet.
struct StopSearchSheet: View {
    let onSelect: (String, CLLocationCoordinate2D) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var completer = LocationSearchCompleter()
    @State private var query = ""
    @State private var isResolving = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Ville, adresse, lieu…", text: $query)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($isFocused)
                        .onChange(of: query) { _, newValue in
                            completer.update(query: newValue)
                        }
                } footer: {
                    Text("Le trajet passera par ce lieu, dans l'ordre où tu ajoutes les étapes.")
                }

                if isResolving {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Recherche du lieu…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if !completer.results.isEmpty {
                    Section {
                        ForEach(completer.results, id: \.self) { result in
                            Button {
                                resolve(result)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title)
                                        .foregroundStyle(.primary)
                                    if !result.subtitle.isEmpty {
                                        Text(result.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isResolving)
                        }
                    }
                }
            }
            .navigationTitle("Ajouter une étape")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
            .onAppear { isFocused = true }
        }
    }

    private func resolve(_ completion: MKLocalSearchCompletion) {
        isResolving = true
        errorMessage = nil
        MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start { response, _ in
            DispatchQueue.main.async {
                isResolving = false
                guard let item = response?.mapItems.first else {
                    errorMessage = "Lieu introuvable. Essaie une autre recherche."
                    return
                }
                let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                onSelect(name.isEmpty ? completion.title : name, item.placemark.coordinate)
            }
        }
    }
}

/// Choix de l'heure de départ du trajet.
struct DepartureTimeSheet: View {
    @State private var time: Date
    let onConfirm: (Date) -> Void
    let onDepartNow: () -> Void

    init(initial: Date, onConfirm: @escaping (Date) -> Void, onDepartNow: @escaping () -> Void) {
        _time = State(initialValue: initial)
        self.onConfirm = onConfirm
        self.onDepartNow = onDepartNow
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Choisis l'heure de départ. Tu es placé au point de départ tout de suite, et le trajet démarre tout seul à l'heure choisie.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                DatePicker("Heure de départ", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()

                Button {
                    onConfirm(Self.nextOccurrence(of: time))
                } label: {
                    Text("Valider l'heure")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Button("Partir maintenant", action: onDepartNow)
                    .font(.subheadline.weight(.semibold))
            }
            .padding()
            .navigationTitle("Départ programmé")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Prochaine fois que l'horloge affichera cette heure : aujourd'hui, ou demain si elle est passée.
    static func nextOccurrence(of time: Date) -> Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        let now = Date()
        var candidate = calendar.date(
            bySettingHour: parts.hour ?? 0,
            minute: parts.minute ?? 0,
            second: 0,
            of: now
        ) ?? time
        if candidate <= now {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }
}

/// « 1 h 05 min », « 12 min 30 s » ou « 45 s ».
func departureCountdownText(until date: Date, now: Date) -> String {
    let seconds = max(0, Int(date.timeIntervalSince(now)))
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let rest = seconds % 60
    if hours > 0 { return "\(hours) h \(String(format: "%02d", minutes)) min" }
    if minutes > 0 { return "\(minutes) min \(String(format: "%02d", rest)) s" }
    return "\(rest) s"
}
