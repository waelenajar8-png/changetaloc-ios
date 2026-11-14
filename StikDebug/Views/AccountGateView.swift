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
            case .blocked(let reason):
                BlockedView(reason: reason)
            case .allowed:
                MainTabView()
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if account.status == "trialing", let left = account.trialSecondsLeft {
                            TrialBanner(secondsLeft: left)
                        }
                    }
            }
        }
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
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    private var canSubmit: Bool {
        email.contains("@") && !password.isEmpty && !account.isWorking
    }

    var body: some View {
        GateBackground {
            ScrollView {
                VStack(spacing: 28) {
                    BrandHeader(subtitle: "Connecte-toi avec ton compte ChangeTaLoc.")
                        .padding(.top, 56)

                    VStack(spacing: 12) {
                        TextField("", text: $email, prompt: Text("E-mail").foregroundStyle(.white.opacity(0.4)))
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focus, equals: .email)
                            .onSubmit { focus = .password }
                            .gateField()

                        SecureField("", text: $password, prompt: Text("Mot de passe").foregroundStyle(.white.opacity(0.4)))
                            .textContentType(.password)
                            .submitLabel(.go)
                            .focused($focus, equals: .password)
                            .onSubmit(submit)
                            .gateField()

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Button(action: submit) {
                        PrimaryButtonLabel(title: "Se connecter", loading: account.isWorking)
                    }
                    .disabled(!canSubmit)
                    .opacity(canSubmit || account.isWorking ? 1 : 0.5)

                    VStack(spacing: 14) {
                        Link("Pas encore de compte ? Créer un compte", destination: AccountStore.signUpURL)
                        Link("Mot de passe oublié", destination: AccountStore.signUpURL)
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
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = password
        Task {
            let message = await account.signIn(email: mail, password: pass)
            await MainActor.run {
                errorMessage = message
                if message == nil { password = "" }
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
        case .noSubscription: return "Démarre ton essai gratuit"
        case .trialEnded: return "Ton essai est terminé"
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
            return "Tu as utilisé tes 30 minutes d'essai. L'accès complet reprend dès le début de ton abonnement."
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
        case .trialEnded: return "Gérer mon abonnement"
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
                        Link(destination: reason == .trialEnded ? URL(string: "https://changetaloc.com/compte")! : account.buyURL) {
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

private struct TrialBanner: View {
    var secondsLeft: Int

    var body: some View {
        let minutes = max(Int((Double(secondsLeft) / 60).rounded(.up)), 0)
        Text("Essai gratuit : \(minutes) min restantes")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(brandYellow)
    }
}
