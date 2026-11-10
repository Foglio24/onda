import AuthenticationServices
import SwiftUI

/// The account's row at the top of Settings, as the iPhone's Apple Account one.
struct AccountSettingsRow: View {
    @EnvironmentObject private var account: AccountService

    var body: some View {
        HStack(spacing: 14) {
            AccountAvatar(name: account.isSignedIn ? account.details?.name : nil, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                if account.isSignedIn {
                    HStack(spacing: 6) {
                        Text(account.details?.name ?? String(localized: "Account Seaglass"))
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        if account.details?.isSupporter == true { SupporterBadge() }
                    }
                    Text(account.details?.email ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Account Seaglass")
                        .font(.title3.weight(.semibold))
                    Text("Accedi per sincronizzare la libreria")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The account, read-only as in Spotify's app: what it is, its plan and its sync. Changing it
/// happens on the account page, in the browser.
struct AccountSettingsView: View {
    @EnvironmentObject private var account: AccountService
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.openURL) private var openURL
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            if account.isSignedIn {
                signedIn
            } else {
                signedOut
            }
        }
        .scrollContentBackground(.hidden)
        .background { AmbientBackground() }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .task { await account.refresh() }
        .refreshable {
            await account.refresh(force: true)
            await account.sync()
        }
    }

    @ViewBuilder private var signedOut: some View {
        Section {
            VStack(spacing: 12) {
                AccountAvatar(name: nil, size: 72)
                Text("Account Seaglass")
                    .font(.title2.weight(.bold))
                Text("Accedi per salvare playlist, preferiti, cronologia e preferenze, e ritrovarli su iPhone, iPad e Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
        Section {
            Button {
                Task { await account.signIn(using: webAuthenticationSession) }
            } label: {
                HStack {
                    Text("Accedi o crea un account")
                        .fontWeight(.semibold)
                    Spacer()
                    if account.isSigningIn { ProgressView() }
                }
            }
            .disabled(account.isSigningIn)
        } footer: {
            if let error = account.signInError {
                Text(error).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var signedIn: some View {
        let details = account.details
        Section {
            VStack(spacing: 8) {
                AccountAvatar(name: details?.name, size: 72)
                HStack(spacing: 8) {
                    Text(details?.name ?? String(localized: "Account Seaglass"))
                        .font(.title2.weight(.bold))
                    if details?.isSupporter == true { SupporterBadge() }
                }
                if let email = details?.email {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
        if let details {
            Section {
                if let fullName = details.fullName {
                    LabeledContent("Nome", value: fullName)
                }
                LabeledContent("Email") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(details.email)
                        if !details.emailVerified {
                            Text("Email non confermata").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                LabeledContent("Piano", value: details.isSupporter
                               ? String(localized: "Sostenitore su Patreon") : String(localized: "Gratuito"))
                LabeledContent("Su Seaglass dal", value: details.memberSince.formatted(date: .long, time: .omitted))
            }
        }
        Section {
            LabeledContent("Ultima sincronizzazione", value: syncDescription)
            if let records = details?.records {
                LabeledContent("Playlist", value: "\(records.playlist ?? 0)")
                LabeledContent("Preferiti", value: "\(records.favorites ?? 0)")
            }
            Button {
                Task { await account.sync() }
            } label: {
                HStack {
                    Text("Sincronizza ora")
                    Spacer()
                    if account.syncState == .syncing { ProgressView() }
                }
            }
            .disabled(account.syncState == .syncing)
        } header: {
            Text("Sincronizzazione")
        } footer: {
            if case .failed(let message) = account.syncState {
                Text(message).foregroundStyle(.red)
            } else {
                Text("Playlist, preferiti, cronologia e preferenze di ascolto sono gli stessi su tutti i dispositivi collegati all'account.")
            }
        }
        Section {
            if let manageURL = account.manageURL {
                Button {
                    openURL(manageURL)
                } label: {
                    HStack {
                        Text("Gestisci account")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            Text("Nome, password, abbonamento ed eliminazione dell'account si gestiscono sul sito di Seaglass.")
        }
        Section {
            Button("Esci", role: .destructive) { confirmSignOut = true }
                .confirmationDialog("Uscire dall'account?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                    Button("Esci", role: .destructive) { Task { await account.signOut() } }
                } message: {
                    Text("La libreria resta su questo dispositivo, ma non si sincronizza più.")
                }
        }
    }

    private var syncDescription: String {
        if account.syncState == .syncing { return String(localized: "In corso…") }
        guard let lastSync = account.lastSync else { return String(localized: "Mai") }
        return lastSync.formatted(.relative(presentation: .named))
    }
}

/// The account's initial in a circle, or a person when signed out.
private struct AccountAvatar: View {
    let name: String?
    let size: CGFloat
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink

    var body: some View {
        ZStack {
            Circle().fill(accent.color.gradient)
            if let initial = name?.trimmingCharacters(in: .whitespaces).first {
                Text(String(initial).uppercased())
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Shown beside the name of who supports Seaglass on Patreon.
struct SupporterBadge: View {
    var body: some View {
        Label("Sostenitore", systemImage: "heart.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(LinearGradient(colors: [.pink, .purple], startPoint: .leading, endPoint: .trailing)))
    }
}
