import SwiftUI
import AppKit

struct OAuthLoginView: View {
    @StateObject private var oauth = CodexOAuthManager.shared

    var body: some View {
        VStack(spacing: 16) {
            switch oauth.phase {
            case .idle:
                idleView
            case .awaitingUser(let code, let verificationURL, let expiresAt):
                awaitingView(code: code, verificationURL: verificationURL, expiresAt: expiresAt)
            case .exchanging:
                ProgressView()
                    .controlSize(.large)
                Text("Exchanging code for tokens…")
                    .foregroundStyle(.secondary)
            case .authenticated(let account):
                authenticatedView(account: account)
            case .failed(let message):
                failedView(message: message)
            }
        }
        .padding(24)
        .frame(maxWidth: 420, minHeight: 240)
        .onAppear {
            oauth.loadStoredAccount()
            // If we have a stored account, surface it as authenticated so the
            // user sees the signed-in state without re-running the flow.
            if let account = oauth.account, case .idle = oauth.phase {
                oauth.surfaceStoredAccount(account)
            }
        }
    }

    // MARK: - Subviews

    private var idleView: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text("Sign in with ChatGPT")
                .font(.title3.bold())
            Text("Use your ChatGPT Plus or Pro subscription with Codex CLI. A device code will be generated for you to enter at OpenAI.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Start sign-in") {
                oauth.startDeviceFlow()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func awaitingView(code: String, verificationURL: URL, expiresAt: Date) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "key.viewfinder")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)
            Text("Enter this code at OpenAI")
                .font(.headline)
            Text(code)
                .font(.system(.title2, design: .monospaced).bold())
                .textSelection(.enabled)
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Button("Open verification page") {
                NSWorkspace.shared.open(verificationURL)
            }
            .buttonStyle(.borderedProminent)
            Text("Expires \(expiresAt.formatted(date: .omitted, time: .shortened)). Waiting for approval…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Cancel") { oauth.cancel() }
                .buttonStyle(.borderless)
        }
    }

    private func authenticatedView(account: CodexOAuthManager.CodexOAuthAccount) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Signed in")
                .font(.title3.bold())
            if let email = account.email, !email.isEmpty {
                Text(email)
                    .foregroundStyle(.secondary)
            }
            Text("Account: \(account.accountId.prefix(8))…")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("Codex CLI is configured to use your ChatGPT login.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Sign out") { oauth.signOut() }
                .buttonStyle(.borderless)
        }
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.octagon")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("Sign-in failed")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") { oauth.startDeviceFlow() }
                .buttonStyle(.borderedProminent)
        }
    }
}
