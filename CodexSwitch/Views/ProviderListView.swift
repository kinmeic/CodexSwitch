import SwiftUI

struct ProviderListView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var l10n = Localization.shared
    @State private var selectedId: UUID?
    @State private var showAddSheet = false

    var body: some View {
        HSplitView {
            sidebar
            detailPane
        }
        .onAppear { selectInitialProviderIfNeeded() }
        .onChange(of: appState.providers) { _ in reconcileSelection() }
        .sheet(isPresented: $showAddSheet) {
            AddProviderSheet().environmentObject(appState)
        }
    }

    // Provider list — narrow sidebar
    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedId) {
                ForEach(appState.providers) { provider in
                    ProviderRow(provider: provider, isActive: provider.id == appState.activeProviderId)
                        .tag(provider.id)
                        .contextMenu {
                            if !provider.isOfficial {
                                Button(l10n.tr("Duplicate")) {
                                    let copy = appState.duplicateProvider(provider)
                                    selectedId = copy.id
                                }
                                Button(l10n.tr("Set Active")) {
                                    appState.setActive(provider)
                                }
                                Divider()
                                Button(l10n.tr("Delete"), role: .destructive) {
                                    appState.removeProvider(provider)
                                    if selectedId == provider.id { selectedId = nil }
                                }
                            }
                        }
                }
            }
            .listStyle(.sidebar)

            // Bottom toolbar
            HStack {
                Button { showAddSheet = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help(l10n.tr("Add provider"))
                Spacer()
                if let selectedId, let provider = appState.providers.first(where: { $0.id == selectedId }) {
                    Button { appState.setActive(provider) } label: { Image(systemName: "checkmark.circle") }
                        .buttonStyle(.borderless)
                        .help(l10n.tr("Set as active provider"))
                    if !provider.isOfficial {
                        Button {
                            appState.removeProvider(provider)
                            self.selectedId = nil
                        } label: { Image(systemName: "minus") }
                            .buttonStyle(.borderless)
                            .help(l10n.tr("Remove provider"))
                    }
                }
            }
            .padding(8)
        }
        .frame(minWidth: 170, idealWidth: 200, maxWidth: 240)
    }

    // Detail editor
    @ViewBuilder
    private var detailPane: some View {
        if let selectedId, let provider = appState.providers.first(where: { $0.id == selectedId }) {
            ProviderEditor(provider: provider, onSelectInSidebar: { id in self.selectedId = id })
                .environmentObject(appState)
                .id(provider.id)
                .frame(maxWidth: .infinity)
        } else {
            VStack { Spacer(); Text(l10n.tr("Select a provider")).foregroundStyle(.secondary); Spacer() }
                .frame(maxWidth: .infinity)
        }
    }

    private func selectInitialProviderIfNeeded() {
        guard selectedId == nil else { return }
        selectedId = appState.activeProviderId ?? appState.providers.first?.id
    }

    private func reconcileSelection() {
        if let selectedId, appState.providers.contains(where: { $0.id == selectedId }) {
            return
        }
        selectedId = appState.activeProviderId ?? appState.providers.first?.id
    }
}

// MARK: - Provider Row

struct ProviderRow: View {
    let provider: CodexProvider
    let isActive: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(provider.name)
                        .fontWeight(isActive ? .semibold : .regular)
                        .lineLimit(1)
                    if provider.isOfficial {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(.blue)
                            .font(.caption)
                    } else if provider.isAuthAccount {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .foregroundStyle(.purple)
                            .font(.caption)
                    }
                }
                if provider.isAuthAccount {
                    Text("auth.json")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if !provider.isOfficial {
                    Text(provider.apiFormat.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Provider Editor

struct ProviderEditor: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var l10n = Localization.shared
    let provider: CodexProvider
    /// Notifies the parent list that a newly-created provider should be
    /// selected in the sidebar (e.g. after "Save Current Login as Account").
    var onSelectInSidebar: ((UUID) -> Void)? = nil

    @StateObject private var oauth = CodexOAuthManager.shared
    @State private var draft: CodexProvider = PresetProviders.officialProvider
    @State private var hasChanges = false
    @State private var isLoaded = false
    @State private var testResult: String?
    @State private var testing = false
    @State private var testSucceeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if provider.isOfficial {
                        officialView
                    } else if provider.isAuthAccount {
                        authAccountView
                    } else {
                        customView
                    }
                }
            }

            if !provider.isOfficial {
                bottomBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { load(provider) }
        .onChange(of: provider.id) { _ in load(provider) }
        .onChange(of: draft.name) { _ in markChanged() }
        .onChange(of: draft.baseURL) { _ in markChanged() }
        .onChange(of: draft.apiKey) { _ in markChanged() }
        .onChange(of: draft.apiFormat) { newValue in
            if newValue == .responses {
                draft.chatReasoning = nil
            } else if draft.chatReasoning == nil {
                draft.chatReasoning = .default
            }
            markChanged()
        }
        .onChange(of: draft.modelCatalog) { _ in markChanged() }
        .onChange(of: draft.chatReasoning) { _ in markChanged() }
        .onChange(of: draft.reviewModel) { _ in markChanged() }
        .onChange(of: draft.goalsEnabled) { _ in markChanged() }
        .onChange(of: draft.authJSON) { _ in markChanged() }
    }

    // MARK: Subviews

    /// Bottom action bar: Test Connection (third-party only) + Save.
    /// Auth-accounts authenticate via the official endpoint, so they show no
    /// connection test.
    @ViewBuilder
    private var bottomBar: some View {
        Divider()
        HStack {
            if !provider.isAuthAccount {
                testConnectionButton
            }
            if let testResult {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(testSucceeded ? .green : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            if hasChanges {
                Button(l10n.tr("Save")) { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var testConnectionButton: some View {
        Button {
            testing = true
            testResult = nil
            testSucceeded = false
            appState.testConnection(provider: draft) { result in
                testing = false
                switch result {
                case .success(let msg):
                    testResult = msg
                    testSucceeded = true
                case .failure(let err):
                    testResult = String(format: l10n.tr("Failed: %@"), err.localizedDescription)
                    testSucceeded = false
                }
            }
        } label: {
            HStack {
                if testing { ProgressView().controlSize(.small) }
                Text(l10n.tr("Test Connection"))
            }
        }
        .disabled(testing || draft.apiKey.isEmpty)
    }

    private var officialView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l10n.tr("OpenAI Official"))
                .font(.headline)
            Text(l10n.tr("Uses your ChatGPT login for authentication. Select this provider to restore the official Codex CLI configuration."))
                .foregroundStyle(.secondary)

            // Current ChatGPT login state (from Keychain or ~/.codex/auth.json).
            // Info-only; the action button (sign in / sign out) lives in the
            // row below alongside "Restore Official Login".
            ChatGPTLoginStatus(oauth: oauth)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)

            HStack {
                if case .idle = oauth.phase {
                    Button(l10n.tr("Sign in with ChatGPT")) {
                        oauth.startDeviceFlow()
                    }
                    .buttonStyle(.bordered)
                } else if case .authenticated = oauth.phase {
                    Button(l10n.tr("Sign out")) {
                        oauth.signOut()
                    }
                    .buttonStyle(.bordered)
                } else if case .failed = oauth.phase {
                    Button(l10n.tr("Try again")) {
                        oauth.startDeviceFlow()
                    }
                    .buttonStyle(.bordered)
                }
                // Awaiting/exchanging phases: no extra button needed —
                // the flow's own controls live inside ChatGPTLoginStatus.

                Button(l10n.tr("Save Current Login as Account")) {
                    guard let live = CodexConfigManager.readLiveAuthJSON() else { return }
                    let count = appState.providers.filter { $0.isAuthAccount }.count + 1
                    let account = CodexProvider(
                        name: String(format: l10n.tr("Account %d"), count),
                        baseURL: "",
                        apiKey: "",
                        isAuthAccount: true,
                        authJSON: live
                    )
                    appState.addProvider(account)
                    onSelectInSidebar?(account.id)
                }
                .buttonStyle(.bordered)
                .disabled(CodexConfigManager.readLiveAuthJSON() == nil)

                Button(l10n.tr("Restore Official Login")) {
                    appState.setActive(provider)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            oauth.loadStoredAccount()
            if let account = oauth.account, case .idle = oauth.phase {
                oauth.surfaceStoredAccount(account)
            } else {
                oauth.surfaceAuthJSONAccountIfPresent()
            }
        }
        .padding(20)
    }

    /// Editor for an auth-account provider: a name plus the full
    /// `~/.codex/auth.json` content pasted verbatim. Switching to this
    /// account overwrites the live auth.json with this blob.
    private var authAccountView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l10n.tr("Codex Auth Account"))
                .font(.headline)
            Text(l10n.tr("Switches the Codex CLI account by overwriting ~/.codex/auth.json with the content below. Both the API-key schema and the ChatGPT-login schema are supported."))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(l10n.tr("General"))
                VStack(spacing: 0) {
                    fieldRow(label: l10n.tr("Name")) {
                        TextField("", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

                sectionHeader("auth.json")
                Text(l10n.tr("Paste the full content of ~/.codex/auth.json here."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                ZStack(alignment: .topLeading) {
                    if draft.authJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("{\n  \"OPENAI_API_KEY\": \"sk-...\"\n}")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $draft.authJSON)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .controlBackgroundColor))
                }
                .frame(minHeight: 220)
                .cornerRadius(6)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

                HStack {
                    Button {
                        if let live = CodexConfigManager.readLiveAuthJSON() {
                            draft.authJSON = live
                        }
                    } label: {
                        Label(l10n.tr("Import from ~/.codex/auth.json"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .padding(20)
    }

    private var customView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // General
            sectionHeader(l10n.tr("General"))
            VStack(spacing: 0) {
                fieldRow(label: l10n.tr("Name")) {
                    TextField("", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                }
                Divider().padding(.horizontal, 8)
                fieldRow(label: l10n.tr("Base URL")) {
                    TextField("https://api.example.com", text: $draft.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                }
                Divider().padding(.horizontal, 8)
                fieldRow(label: l10n.tr("API Key")) {
                    SecureField("", text: $draft.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                }
                Divider().padding(.horizontal, 8)
                fieldRow(label: l10n.tr("API Format")) {
                    Picker("", selection: $draft.apiFormat) {
                        ForEach(CodexApiFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Divider().padding(.horizontal, 8)
                fieldRow(label: l10n.tr("Review Model")) {
                    TextField("gpt-5.5", text: $draft.reviewModel)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                }
                Divider().padding(.horizontal, 8)
                fieldRow(label: l10n.tr("Goal Mode")) {
                    Spacer()
                    Toggle("", isOn: $draft.goalsEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                        .labelsHidden()
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            // Model Catalog
            sectionHeader(l10n.tr("Model Catalog"))
            Text(l10n.tr("Model ID is what Codex CLI sees. Display Name appears in Codex; both are sent to the provider as available models."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            ModelCatalogTable(models: $draft.modelCatalog)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            // Chat Reasoning (Chat Completions only)
            if draft.apiFormat == .chatCompletions {
                sectionHeader(l10n.tr("Chat Reasoning"))
                VStack(spacing: 0) {
                    fieldRow(label: l10n.tr("Enable Thinking")) {
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { draft.chatReasoning?.supportsThinking ?? false },
                            set: { draft.chatReasoning?.supportsThinking = $0 }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                        .labelsHidden()
                    }
                    Divider().padding(.horizontal, 8)
                    fieldRow(label: l10n.tr("Enable Effort")) {
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { draft.chatReasoning?.supportsEffort ?? false },
                            set: { draft.chatReasoning?.supportsEffort = $0 }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                        .labelsHidden()
                    }
                    Divider().padding(.horizontal, 8)
                    fieldRow(label: l10n.tr("Thinking Param")) {
                        Picker("", selection: Binding(
                            get: { draft.chatReasoning?.thinkingParam ?? "thinking" },
                            set: { draft.chatReasoning?.thinkingParam = $0 }
                        )) {
                            Text("thinking (GLM/Kimi Style)").lineLimit(1).tag("thinking")
                            Text("enable_thinking (Qwen/SiliconFlow Style)").lineLimit(1).tag("enable_thinking")
                            Text("reasoning_split (MiniMax Style)").lineLimit(1).tag("reasoning_split")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Divider().padding(.horizontal, 8)
                    fieldRow(label: l10n.tr("Effort Param")) {
                        Picker("", selection: Binding(
                            get: { draft.chatReasoning?.effortParam ?? "none" },
                            set: { draft.chatReasoning?.effortParam = $0 }
                        )) {
                            Text("none").lineLimit(1).tag("none")
                            Text("reasoning_effort (DeepSeek Style)").lineLimit(1).tag("reasoning_effort")
                            Text("reasoning.effort (OpenRouter Style)").lineLimit(1).tag("reasoning.effort")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Divider().padding(.horizontal, 8)
                    fieldRow(label: l10n.tr("Effort Mode")) {
                        Picker("", selection: Binding(
                            get: { draft.chatReasoning?.effortValueMode },
                            set: { draft.chatReasoning?.effortValueMode = $0 }
                        )) {
                            Text("Passthrough").lineLimit(1).tag(Optional<CodexEffortValueMode>.none)
                            Text("DeepSeek").lineLimit(1).tag(Optional<CodexEffortValueMode>.some(.deepseek))
                            Text("Low/High").lineLimit(1).tag(Optional<CodexEffortValueMode>.some(.lowHigh))
                            Text("OpenRouter").lineLimit(1).tag(Optional<CodexEffortValueMode>.some(.openrouter))
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Divider().padding(.horizontal, 8)
                    fieldRow(label: l10n.tr("Output Format")) {
                        Picker("", selection: Binding(
                            get: { draft.chatReasoning?.outputFormat ?? "reasoning_content" },
                            set: { draft.chatReasoning?.outputFormat = $0 }
                        )) {
                            Text("reasoning_content (DeepSeek/GLM/Kimi/Qwen Style)").lineLimit(1).tag("reasoning_content")
                            Text("reasoning_details (MiniMax Style)").lineLimit(1).tag("reasoning_details")
                            Text("reasoning (Other Providers)").lineLimit(1).tag("reasoning")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .padding(.top, 20)
    }

    // MARK: Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private func fieldRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 120, alignment: .leading)
                .font(.body)
            content()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func markChanged() {
        guard isLoaded else { return }
        hasChanges = true
    }

    private func load(_ provider: CodexProvider) {
        isLoaded = false
        draft = provider
        testResult = nil
        testing = false
        hasChanges = false
        DispatchQueue.main.async { isLoaded = true }
    }

    private func save() {
        appState.updateProvider(draft)
        hasChanges = false
    }
}

// MARK: - Model Catalog Table

struct ModelCatalogTable: View {
    @Binding var models: [CodexCatalogModel]
    @ObservedObject private var l10n = Localization.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Text(l10n.tr("Model ID"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(l10n.tr("Display Name"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(l10n.tr("Context"))
                    .frame(width: 90, alignment: .leading)
                Color.clear.frame(width: 24)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Rows
            if models.isEmpty {
                Text(l10n.tr("No models defined"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(models.indices, id: \.self) { index in
                        HStack(spacing: 12) {
                            TextField("model-id", text: $models[index].model)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                            TextField(l10n.tr("Display Name"), text: $models[index].displayName)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                            TextField("128000", value: $models[index].contextWindow, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            Button {
                                models.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.borderless)
                            .frame(width: 24)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        if index != models.indices.last {
                            Divider().padding(.horizontal, 8)
                        }
                    }
                }
            }

            Divider()

            // Actions
            HStack(spacing: 8) {
                Button {
                    models.append(CodexCatalogModel(model: "", displayName: "", contextWindow: nil))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text(l10n.tr("Add Model"))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
            .padding(8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }
}

// MARK: - Add Provider Sheet

struct AddProviderSheet: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var l10n = Localization.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var baseURL = ""
    @State private var isAuthAccount = false

    private var canAdd: Bool {
        let nameOk = !name.trimmingCharacters(in: .whitespaces).isEmpty
        if isAuthAccount { return nameOk }
        return nameOk && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(l10n.tr("Add Provider")).font(.headline)
            Form {
                Picker(l10n.tr("Provider Type"), selection: $isAuthAccount) {
                    Text(l10n.tr("Third-party Provider")).tag(false)
                    Text(l10n.tr("Codex Auth Account")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                TextField(l10n.tr("Name"), text: $name)

                if !isAuthAccount {
                    TextField(l10n.tr("Base URL"), text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text(l10n.tr("You can paste the auth.json content after adding, in the account editor."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button(l10n.tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(l10n.tr("Add")) {
                    let provider: CodexProvider
                    if isAuthAccount {
                        provider = CodexProvider(
                            name: name.isEmpty ? l10n.tr("New Account") : name,
                            baseURL: "",
                            apiKey: "",
                            isAuthAccount: true,
                            authJSON: ""
                        )
                    } else {
                        provider = CodexProvider(
                            name: name.isEmpty ? l10n.tr("New Provider") : name,
                            baseURL: baseURL,
                            apiKey: "",
                            apiFormat: .chatCompletions,
                            modelCatalog: [],
                            chatReasoning: .default,
                            isOfficial: false
                        )
                    }
                    appState.addProvider(provider)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
