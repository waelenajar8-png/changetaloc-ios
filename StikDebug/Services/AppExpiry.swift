import Foundation
import SwiftUI
import UserNotifications

/// Date à laquelle l'app cesse de s'ouvrir (signature gratuite Apple de 7 jours).
/// Lue dans le fichier d'installation embarqué dans l'app, pour prévenir le client avant qu'il soit bloqué.
enum AppExpiry {
    static let expirationDate: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        // Le fichier est signé : la liste de propriétés lisible se trouve entre <?xml et </plist>.
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else { return nil }
        return plist["ExpirationDate"] as? Date
    }()

    /// Jours entiers restants (0 = expire aujourd'hui).
    static func daysLeft(now: Date = Date()) -> Int? {
        guard let expirationDate else { return nil }
        return max(0, Int(expirationDate.timeIntervalSince(now) / 86_400))
    }

    static var expirationText: String? {
        guard let expirationDate else { return nil }
        let day = expirationDate.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR")))
        let time = expirationDate.formatted(date: .omitted, time: .shortened)
        return "\(day) à \(time)"
    }

    /// Rappels la veille et 2 h avant : « rebranche ton iPhone ».
    static func scheduleReminders() {
        guard let expirationDate else { return }
        let center = UNUserNotificationCenter.current()
        let ids = ["ctl-expiry-24h", "ctl-expiry-2h"]
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let reminders: [(String, TimeInterval, String)] = [
                (ids[0], 24 * 3600, "Ta signature Apple expire demain"),
                (ids[1], 2 * 3600, "Ta signature Apple expire dans 2 h"),
            ]
            for (id, before, title) in reminders {
                let fireDate = expirationDate.addingTimeInterval(-before)
                guard fireDate > Date() else { continue }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = "Pour que ChangeTaLoc continue de s'ouvrir : branche ton iPhone à ton ordi, ouvre l'assistant et clique sur « Mettre à jour ou renouveler ». 1 minute, tes réglages sont gardés."
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireDate.timeIntervalSinceNow, repeats: false)
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
        }
    }
}

/// Pastille affichée en haut de la carte quand il reste 2 jours ou moins.
/// Ton rassurant : c'est un geste d'une minute, pas un problème.
struct ExpiryBadge: View {
    @State private var expanded = false

    private var title: String {
        switch AppExpiry.daysLeft() ?? 0 {
        case 0: return "Signature Apple à renouveler aujourd'hui"
        case 1: return "Signature Apple à renouveler d'ici demain"
        default: return "Signature Apple à renouveler d'ici 2 jours"
        }
    }

    var body: some View {
        if let days = AppExpiry.daysLeft(), days <= 2 {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                        Text("1 min")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.12), in: Capsule())
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold))
                    }
                    if expanded {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("ChangeTaLoc n'est pas sur l'App Store : Apple l'autorise sur ton iPhone avec une signature valable 7 jours. Pour la renouveler :")
                                .font(.caption)
                                .opacity(0.8)
                                .fixedSize(horizontal: false, vertical: true)
                            step("1", "Branche ton iPhone à ton ordinateur.")
                            step("2", "Ouvre l'assistant ChangeTaLoc.")
                            step("3", "Clique sur « Mettre à jour ou renouveler ».")
                            Text("C'est tout. Tes réglages et tes favoris sont gardés, et c'est reparti pour 7 jours. Ton abonnement n'est pas concerné.")
                                .font(.caption)
                                .opacity(0.8)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .foregroundStyle(.black)
                .padding(12)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(number)
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(Color.black.opacity(0.12), in: Circle())
            Text(text)
                .font(.footnote.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
