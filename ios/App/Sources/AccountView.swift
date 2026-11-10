import SwiftUI

/// The account row on the launcher: who plays, sign in, switch, sign out.
struct AccountView: View {
    @ObservedObject var accounts: Accounts

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let current = accounts.current {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text(current.name).font(.headline)
                        Text("Microsoft account").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        ForEach(accounts.list) { account in
                            Button {
                                accounts.select(account)
                            } label: {
                                if account == current {
                                    Label(account.name, systemImage: "checkmark")
                                } else {
                                    Text(account.name)
                                }
                            }
                        }
                        Divider()
                        Button("Add account", systemImage: "plus") { accounts.signIn() }
                        Button("Sign out \(current.name)", systemImage: "rectangle.portrait.and.arrow.right",
                               role: .destructive) { accounts.signOut(current) }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3)
                    }
                }
            } else if AuthConfig.configured {
                Button {
                    accounts.signIn()
                } label: {
                    Label("Sign in with Microsoft", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(accounts.busy)
                Text("Playing offline. Sign in to join online servers.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Playing offline", systemImage: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
                Text("Microsoft sign-in isn't set up in this build yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if accounts.busy { ProgressView().controlSize(.small) }
            if let error = accounts.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
