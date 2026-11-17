//
//  WelcomeGuide.swift
//  ChangeTaLoc
//
//  Mini-guide de bienvenue : trois écrans, montrés une seule fois au premier lancement.
//

import SwiftUI

private struct WelcomePage: Identifiable {
    let id: Int
    let systemImage: String
    let title: String
    let text: String
}

private let welcomePages: [WelcomePage] = [
    WelcomePage(
        id: 0,
        systemImage: "mappin.and.ellipse",
        title: "Choisis un lieu",
        text: "Touche la carte, cherche une adresse, ou ouvre les destinations et les circuits tout prêts."
    ),
    WelcomePage(
        id: 1,
        systemImage: "location.fill",
        title: "Touche « Changer ma position ici »",
        text: "Ton iPhone se place à cet endroit. Ferme puis rouvre Snapchat ou Plans : ils affichent ta nouvelle position."
    ),
    WelcomePage(
        id: 2,
        systemImage: "arrow.uturn.backward.circle.fill",
        title: "Reviens à ta vraie position",
        text: "Quand tu veux, touche « Retour à ma vraie position ». Pense à rebrancher ton iPhone à l'ordinateur une fois par semaine."
    ),
]

struct WelcomeGuideView: View {
    let onFinish: () -> Void
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Passer", action: onFinish)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            TabView(selection: $page) {
                ForEach(welcomePages) { item in
                    VStack(spacing: 22) {
                        Spacer(minLength: 0)
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.18))
                                .frame(width: 140, height: 140)
                            Image(systemName: item.systemImage)
                                .font(.system(size: 58, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        Text("Étape \(item.id + 1) sur \(welcomePages.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(item.title)
                            .font(.title.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text(item.text)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 28)
                        Spacer(minLength: 0)
                    }
                    .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < welcomePages.count - 1 {
                    withAnimation(.easeInOut(duration: 0.25)) { page += 1 }
                } else {
                    onFinish()
                }
            } label: {
                Text(page < welcomePages.count - 1 ? "Suivant" : "C'est parti")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .padding(.top, 8)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }
}
