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
                (ids[0], 24 * 3600, "ChangeTaLoc expire demain"),
                (ids[1], 2 * 3600, "ChangeTaLoc expire dans 2 h"),
            ]
            for (id, before, title) in reminders {
                let fireDate = expirationDate.addingTimeInterval(-before)
                guard fireDate > Date() else { continue }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = "Rebranche ton iPhone à l'ordinateur et clique sur « Mettre à jour ou renouveler » dans l'assistant. 2 minutes, et c'est reparti pour 7 jours."
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireDate.timeIntervalSinceNow, repeats: false)
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
        }
    }
}

/// Pastille affichée en haut de la carte quand il reste 2 jours ou moins.
struct ExpiryBadge: View {
    var body: some View {
        if let days = AppExpiry.daysLeft(), days <= 2 {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text(days == 0 ? "Ton app expire aujourd'hui" : (days == 1 ? "Ton app expire demain" : "Ton app expire dans 2 jours"))
                        .font(.subheadline.weight(.semibold))
                    Text("Rebranche ton iPhone à l'ordinateur et clique sur « Mettre à jour ou renouveler » dans l'assistant.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.black)
            .padding(12)
            .background(Color.orange, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
