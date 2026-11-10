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
                        if account.hasPremium { PremiumBadge() }
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
            support
        }
        .scrollContentBackground(.hidden)
        .background { AmbientBackground() }
        .navigationTitle("Account")
        .task { await account.refreshStatus() }
        .navigationBarTitleDisplayMode(.inline)
        .task { await account.refresh() }
        .refreshable {
            await account.refresh(force: true)
            await account.sync()
        }
    }

    /// Help, by email: for the account, Premium or the app.
    @ViewBuilder private var support: some View {
        if let supportURL = account.supportURL, let address = account.supportEmail {
            Section {
                Button {
                    openURL(supportURL)
                } label: {
                    LabeledContent {
                        Text(address).lineLimit(1)
                    } label: {
                        Label("Scrivi all'assistenza", systemImage: "envelope")
                    }
                }
            } header: {
                Text("Assistenza")
            } footer: {
                Text("Per l'account, Premium o un problema con l'app.")
            }
        }
    }

    @ViewBuilder private var signedOut: some View {
        Section {
            VStack(spacing: 12) {
                AccountAvatar(name: nil, size: 72)
                Text("Account Seaglass")
                    .font(.title2.weight(.bold))
                Text("Accedi per salvare playlist, preferiti, cronologia e preferenze, ritrovarli su iPhone, iPad e Mac e usare Premium.")
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
                    if account.hasPremium { PremiumBadge() }
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
                LabeledContent("Piano", value: account.hasPremium
                               ? String(localized: "Seaglass Premium") : String(localized: "Seaglass Free"))
                LabeledContent("Su Seaglass dal", value: details.memberSince.formatted(date: .long, time: .omitted))
            }
        }
        // As in Spotify's app: Premium is bought on the website, the app only leads there.
        if account.premiumEnabled, !account.hasPremium, account.premiumURL != nil {
            Section {
                Button {
                    account.expectPremium()
                    openPage(premium: true)
                } label: {
                    Label("Passa a Premium", systemImage: "crown.fill")
                        .fontWeight(.semibold)
                }
            } footer: {
                Text("Premium sblocca AutoMix, l'import delle playlist da link, il riconoscimento dei brani, la traduzione dei testi, il karaoke AI e il Tempo.")
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
            if account.manageURL != nil {
                Button {
                    openPage(premium: false)
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
            Text("Nome, password, abbonamento Premium ed eliminazione dell'account si gestiscono sul sito di Seaglass.")
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

    /// The account page in the browser, signed in as in the app.
    private func openPage(premium: Bool) {
        Task {
            if let url = await account.signedInPage(premium: premium) { openURL(url) }
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

/// Shown beside the name of a Premium account.
struct PremiumBadge: View {
    var body: some View {
        Label("Premium", systemImage: "crown.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(LinearGradient(colors: [.pink, .purple], startPoint: .leading, endPoint: .trailing)))
    }
}

// MARK: Premium

/// What a Premium feature shows without Premium: what Premium unlocks and where to get it. As in
/// Spotify's app, it is bought on the website (the account page, with Patreon), not in the app.
struct PremiumView: View {
    let feature: PremiumFeature
    @ObservedObject private var account = AccountService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink
    @State private var checking = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [accent.color, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .padding(.top, 12)
                    VStack(spacing: 8) {
                        Text("Seaglass Premium")
                            .font(.largeTitle.weight(.bold))
                        Text(String(localized: "\(feature.title) fa parte di Premium."))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(PremiumFeature.allCases) { item in
                            Label(item.title, systemImage: item.symbol)
                                .fontWeight(item == feature ? .semibold : .regular)
                                .foregroundStyle(item == feature ? accent.color : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(18)
                    .background(.thinMaterial, in: .rect(cornerRadius: 18))
                    actions
                    Text("Premium è l'abbonamento a Seaglass su Patreon: si attiva e si gestisce sul sito di Seaglass e vale su iPhone, iPad e Mac.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
        .onChange(of: account.hasPremium) { _, premium in
            if premium { dismiss() }
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 12) {
            if account.isSignedIn {
                if account.premiumURL != nil {
                    Button {
                        account.expectPremium()
                        Task {
                            if let url = await account.signedInPage(premium: true) { openURL(url) }
                        }
                    } label: {
                        Text("Passa a Premium")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent.color)
                }
                Button {
                    Task {
                        checking = true
                        await account.refresh(force: true)
                        checking = false
                    }
                } label: {
                    if checking { ProgressView() } else { Text("Ho già Premium") }
                }
                .disabled(checking)
            } else {
                Button {
                    Task { await account.signIn(using: webAuthenticationSession) }
                } label: {
                    Group {
                        if account.isSigningIn { ProgressView() } else { Text("Accedi per usare Premium").fontWeight(.semibold) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent.color)
                .disabled(account.isSigningIn)
                if let error = account.signInError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
    }
}

extension View {
    /// Shows `PremiumView` for the feature set in `feature`.
    func premiumPaywall(_ feature: Binding<PremiumFeature?>) -> some View {
        sheet(item: feature) { PremiumView(feature: $0).appEnvironment() }
    }
}

/// A small crown on a control whose feature needs Premium.
struct PremiumLock: View {
    var body: some View {
        Image(systemName: "crown.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(3)
            .background(Circle().fill(LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .accessibilityLabel(Text("Premium"))
    }
}
