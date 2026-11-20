//
//  AccountGateView.swift
//  ChangeTaLoc
//
//  Écran affiché avant la carte : connexion, puis accès selon l'abonnement.
//

import SwiftUI

private let brandYellow = Color(red: 1.0, green: 0.9, blue: 0.0)

struct AccountGateView: View {
    @ObservedObject private var account = AccountStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch account.state {
            case .loading:
                GateBackground {
                    ProgressView().tint(brandYellow).controlSize(.large)
                }
            case .signedOut:
                LoginView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .blocked(let reason):
                BlockedView(reason: reason)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .allowed:
                MainTabView()
                    .transition(.opacity)
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.35), value: account.state)
        .onAppear { account.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { account.refreshAccess() }
        }
    }
}

private struct GateBackground<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .preferredColorScheme(.dark)
    }
}

private struct BrandHeader: View {
    var subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "location.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 76, height: 76)
                .background(brandYellow, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("ChangeTaLoc")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
        }
    }
}

private struct PrimaryButtonLabel: View {
    var title: String
    var loading = false

    var body: some View {
        ZStack {
            if loading {
                ProgressView().tint(.black)
            } else {
                Text(title).font(.headline)
            }
        }
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(brandYellow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct LoginView: View {
    @ObservedObject private var account = AccountStore.shared
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    /// Par défaut : connexion par code reçu par e-mail (pas de mot de passe à créer). Le mot de passe reste possible.
    @State private var withPassword = false
    @State private var codeSent = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @FocusState private var focus: Field?

    private enum Field { case email, password, code }

    private var canSubmit: Bool {
        guard email.contains("@"), !account.isWorking else { return false }
        if withPassword { return !password.isEmpty }
        return codeSent ? code.filter(\.isNumber).count >= 6 : true
    }

    private var buttonTitle: String {
        if withPassword { return "Se connecter" }
        return codeSent ? "Valider le code" : "Recevoir mon code"
    }

    var body: some View {
        GateBackground {
            ScrollView {
                VStack(spacing: 28) {
                    BrandHeader(subtitle: withPassword ? "Connecte-toi avec ton compte ChangeTaLoc." : "Entre l'e-mail utilisé au paiement : on t'envoie un code.")
                        .padding(.top, 56)

                    VStack(spacing: 12) {
                        TextField("", text: $email, prompt: Text("E-mail").foregroundStyle(.white.opacity(0.4)))
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(withPassword ? .next : .go)
                            .focused($focus, equals: .email)
                            .disabled(codeSent && !withPassword)
                            .onSubmit { if withPassword { focus = .password } else { submit() } }
                            .gateField()

                        if withPassword {
                            SecureField("", text: $password, prompt: Text("Mot de passe").foregroundStyle(.white.opacity(0.4)))
                                .textContentType(.password)
                                .submitLabel(.go)
                                .focused($focus, equals: .password)
                                .onSubmit(submit)
                                .gateField()
                        } else if codeSent {
                            TextField("", text: $code, prompt: Text("Code reçu par e-mail").foregroundStyle(.white.opacity(0.4)))
                                .textContentType(.oneTimeCode)
                                .keyboardType(.numberPad)
                                .focused($focus, equals: .code)
                                .font(.title3.monospacedDigit())
                                .gateField()
                        }

                        if let infoMessage, errorMessage == nil {
                            Text(infoMessage)
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.75))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Button(action: submit) {
                        PrimaryButtonLabel(title: buttonTitle, loading: account.isWorking)
                    }
                    .disabled(!canSubmit)
                    .opacity(canSubmit || account.isWorking ? 1 : 0.5)

                    VStack(spacing: 14) {
                        if !withPassword && codeSent {
                            Button("Changer d'e-mail ou renvoyer un code") {
                                codeSent = false
                                code = ""
                                infoMessage = nil
                                errorMessage = nil
                            }
                        }
                        Button(withPassword ? "Me connecter avec un code par e-mail" : "J'ai un mot de passe") {
                            withPassword.toggle()
                            codeSent = false
                            code = ""
                            errorMessage = nil
                            infoMessage = nil
                        }
                        if withPassword {
                            Link("Mot de passe oublié", destination: URL(string: "https://changetaloc.com/connexion?mode=forgot")!)
                        }
                        Link("Pas encore abonné ? Essai gratuit 48 h", destination: URL(string: "https://changetaloc.com/#tarifs")!)
                    }
                    .font(.footnote)
                    .tint(brandYellow)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        errorMessage = nil
        focus = nil
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if withPassword {
            let pass = password
            Task {
                let message = await account.signIn(email: mail, password: pass)
                await MainActor.run {
                    errorMessage = message
                    if message == nil { password = "" }
                }
            }
        } else if !codeSent {
            Task {
                let message = await account.requestCode(email: mail)
                await MainActor.run {
                    // Un code déjà envoyé (par exemple juste après le paiement) reste valable : on passe quand même à la saisie.
                    if message == nil || message?.contains("Attends une minute") == true {
                        codeSent = true
                        infoMessage = "Code envoyé à \(mail). Ouvre l'e-mail « Connexion à ChangeTaLoc » et tape le code ici. Pense aux spams."
                        focus = .code
                    } else {
                        errorMessage = message
                    }
                }
            }
        } else {
            let typed = code.filter(\.isNumber)
            Task {
                let message = await account.signIn(email: mail, code: typed)
                await MainActor.run {
                    errorMessage = message
                    if message == nil { code = "" }
                }
            }
        }
    }
}

private extension View {
    func gateField() -> some View {
        self
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.12)))
    }
}

private struct BlockedView: View {
    @ObservedObject private var account = AccountStore.shared
    var reason: AccountStore.BlockReason

    private var title: String {
        switch reason {
        case .noSubscription: return "Choisis ta formule"
        case .trialEnded: return "Ton essai gratuit est terminé"
        case .paymentPending: return "Paiement en attente"
        case .subscriptionEnded: return "Ton abonnement est terminé"
        case .offline: return "Pas de connexion"
        }
    }

    private var message: String {
        switch reason {
        case .noSubscription:
            return "Ton compte n'a pas encore d'abonnement. Choisis ta formule sur le site, puis reviens ici."
        case .trialEnded:
            return "Ton temps d'essai est écoulé. Passe à l'abonnement maintenant pour tout débloquer tout de suite (trajets, manette, circuits…), puis reviens ici. Pas convaincu ? Résilie depuis ton compte avant la fin des 48 h : tu ne paies rien."
        case .paymentPending:
            return "Ton dernier paiement n'est pas passé. Mets à jour ton moyen de paiement pour retrouver l'accès."
        case .subscriptionEnded:
            return "Reprends un abonnement pour changer de nouveau ta position."
        case .offline:
            return "Impossible de vérifier ton abonnement. Vérifie ta connexion à Internet puis réessaie."
        }
    }

    private var actionTitle: String? {
        switch reason {
        case .noSubscription: return "Voir les formules"
        case .trialEnded: return "Passer à l'abonnement maintenant"
        case .paymentPending: return "Mettre à jour le paiement"
        case .subscriptionEnded: return "Reprendre un abonnement"
        case .offline: return nil
        }
    }

    var body: some View {
        GateBackground {
            VStack(spacing: 24) {
                Spacer()
                BrandHeader(subtitle: account.email ?? "")
                VStack(spacing: 10) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                Spacer()
                VStack(spacing: 12) {
                    if let actionTitle {
                        Link(destination: account.buyURL) {
                            PrimaryButtonLabel(title: actionTitle)
                        }
                    }
                    Button(action: account.refreshAccess) {
                        Text(reason == .offline ? "Réessayer" : "J'ai payé, vérifier à nouveau")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    Button("Se déconnecter", action: account.signOut)
                        .font(.footnote)
                        .tint(.white.opacity(0.6))
                        .padding(.top, 4)
                }
            }
            .padding(24)
            .frame(maxWidth: 460)
        }
    }
}

// Pastille d'essai affichée sous la barre de recherche de la carte, sans masquer les boutons.
struct TrialBadge: View {
    @ObservedObject private var account = AccountStore.shared

    var body: some View {
        if account.status == "trialing", let left = account.trialSecondsLeft {
            let minutes = max(Int((Double(left) / 60).rounded(.up)), 0)
            Link(destination: account.buyURL) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.fill")
                    Text("Essai : \(minutes) min restantes")
                        .contentTransition(.numericText())
                    Text("· Passer à l'abonnement")
                        .opacity(0.7)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(brandYellow, in: Capsule())
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
