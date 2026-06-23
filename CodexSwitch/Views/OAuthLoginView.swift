import SwiftUI
import AppKit

/// Displays the current ChatGPT login state (read from the app Keychain or
/// `~/.codex/auth.json`). Pure info view — no sign-in/sign-out buttons; the
/// host view is responsible for action buttons.
struct ChatGPTLoginStatus: View {
    @ObservedObject var oauth: CodexOAuthManager

    var body: some View {
        switch oauth.phase {
        case .idle:
            Text("Not signed in")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .awaitingUser(let code, let verificationURL, let expiresAt):
            awaitingView(code: code, verificationURL: verificationURL, expiresAt: expiresAt)
        case .exchanging:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Exchanging code for tokens…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .authenticated(let account):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Signed in")
                        .font(.subheadline.weight(.semibold))
                }
                if let email = account.email, !email.isEmpty {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Account: \(account.accountId.prefix(8))…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.octagon")
                        .foregroundStyle(.red)
                    Text("Sign-in failed")
                        .font(.subheadline.weight(.semibold))
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func awaitingView(code: String, verificationURL: URL, expiresAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enter this code at OpenAI")
                .font(.subheadline.weight(.semibold))
            Text(code)
                .font(.system(.body, design: .monospaced).bold())
                .textSelection(.enabled)
                .padding(6)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Button("Open verification page") {
                NSWorkspace.shared.open(verificationURL)
            }
            .buttonStyle(.borderedProminent)
            Text("Expires \(expiresAt.formatted(date: .omitted, time: .shortened)). Waiting for approval…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
