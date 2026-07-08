import Foundation
import Combine

/// Supported UI languages. The raw value is persisted to UserDefaults and is
/// also suitable as a BCP-47 language tag.
enum AppLanguage: String, CaseIterable, Codable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    /// Label shown in the language picker (each language names itself natively).
    var displayName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

/// In-app localization manager. Unlike Apple's `.lproj`-based localization,
/// this is a runtime `ObservableObject`: changing `language` instantly
/// re-renders any SwiftUI view that observes it, with no app restart.
///
/// Translation keys are the **English UI strings themselves**. English needs no
/// table (a missing key falls through to itself); only the Simplified Chinese
/// table is maintained. Interpolated strings use `String(format:)` with `%@` /
/// `%d` placeholders.
final class Localization: ObservableObject {
    static let shared = Localization()

    @Published var language: AppLanguage {
        didSet {
            AppEnvironment.shared.set(language.rawValue, forKey: "appLanguage")
        }
    }

    /// English UI string → Simplified Chinese translation. Missing keys fall
    /// back to the English key.
    private static let zhTable: [String: String] = [
        // MARK: Generic
        "Language": "语言",
        "General": "通用",
        "Cancel": "取消",
        "Add": "添加",
        "Save": "保存",
        "Delete": "删除",
        "Start": "启动",
        "Stop": "停止",

        // MARK: DetailView (tabs + logs)
        "Status": "状态",
        "Providers": "提供商",
        "Settings": "设置",
        "Logs": "日志",
        "Request Logs": "请求日志",
        "Clear request log": "清空请求日志",
        "No requests yet": "暂无请求",

        // MARK: MenuBarMenu
        "Stop Proxy": "停止代理",
        "Show Window": "显示窗口",
        "Quit": "退出",
        "CodexSwitch proxy running": "CodexSwitch 代理运行中",
        "CodexSwitch proxy stopped": "CodexSwitch 代理已停止",

        // MARK: SettingsView
        "Proxy": "代理",
        "Port:": "端口：",
        "Auto-start on launch": "启动时自动开启代理",
        "Gateway Token": "网关令牌",
        "Regenerate": "重新生成",
        "Codex CLI": "Codex CLI",
        "Config Directory:": "配置目录：",
        "Preserve ChatGPT login": "保留 ChatGPT 登录",
        "When on, switching to a third-party provider authenticates via experimental_bearer_token in config.toml and leaves auth.json untouched, so your cached ChatGPT login survives switches.": "开启后，切换到第三方提供商时通过 config.toml 中的 experimental_bearer_token 进行认证，auth.json 保持不变，从而保留已缓存的 ChatGPT 登录。",
        "Inject prompt cache key": "注入提示缓存键",
        "When on, injects a stable prompt_cache_key into upstream Responses-API requests that omit one, so OpenAI affinity-routes to a consistent backend and prefix caching hits across turns. Responses-only; Chat Completions upstreams are unaffected.": "开启后，对缺失 prompt_cache_key 的上游 Responses API 请求注入一个稳定的 prompt_cache_key，使 OpenAI 将流量亲和路由到同一后端，从而跨轮次命中前缀缓存。仅对 Responses API 生效，不影响 Chat Completions 上游。",
        "Outbound Proxy": "出站代理",
        "Address:": "地址：",
        "Used by CodexSwitch outbound requests. Leave empty for direct connection.": "供 CodexSwitch 出站请求使用。留空则直连。",
        "Invalid proxy address. Include a scheme, such as http:// or socks5://.": "代理地址无效。请包含协议，例如 http:// 或 socks5://。",
        "Unsupported proxy scheme. Use http, https, socks, socks5, or socks5h.": "不支持的代理协议。请使用 http、https、socks、socks5 或 socks5h。",
        "Invalid proxy address. Include a host, such as 127.0.0.1.": "代理地址无效。请包含主机，例如 127.0.0.1。",
        "Invalid proxy port. Use a value between 1 and 65535.": "代理端口无效。请使用 1 到 65535 之间的值。",
        "Invalid proxy address format.": "代理地址格式无效。",

        // MARK: ConnectionStatusView
        "Proxy Mode": "代理模式",
        "Direct Mode": "直连模式",
        "Proxy Server": "代理服务器",
        "Active Provider:": "当前提供商：",
        "Proxy Running": "代理运行中",
        "Stopped": "已停止",

        // MARK: ProviderListView
        "Duplicate": "复制",
        "Set Active": "设为当前",
        "Add provider": "添加提供商",
        "Set as active provider": "设为当前提供商",
        "Remove provider": "移除提供商",
        "Select a provider": "选择一个提供商",
        "Test Connection": "测试连接",
        "Failed: %@": "失败：%@",
        "OpenAI Official": "OpenAI 官方",
        "Uses your ChatGPT login for authentication. Select this provider to restore the official Codex CLI configuration.": "使用你的 ChatGPT 登录进行认证。选择此提供商可恢复 Codex CLI 的官方配置。",
        "Sign in with ChatGPT": "使用 ChatGPT 登录",
        "Sign out": "退出登录",
        "Try again": "重试",
        "Restore Official Login": "恢复官方登录",
        "Name": "名称",
        "Base URL": "基础 URL",
        "API Key": "API 密钥",
        "API Format": "API 格式",
        "Review Model": "评审模型",
        "Goal Mode": "目标模式",
        "Model Catalog": "模型目录",
        "Model ID is what Codex CLI sees. Display Name appears in Codex; both are sent to the provider as available models.": "Model ID 是 Codex CLI 实际使用的标识；Display Name 显示在 Codex 中；两者都会作为可用模型发送给提供商。",
        "Chat Reasoning": "聊天推理",
        "Enable Thinking": "启用思考",
        "Enable Effort": "启用 Effort",
        "Thinking Param": "Thinking 参数",
        "Effort Param": "Effort 参数",
        "Effort Mode": "Effort 模式",
        "Output Format": "输出格式",
        "Model ID": "模型 ID",
        "Display Name": "显示名称",
        "Context": "上下文",
        "No models defined": "尚未定义模型",
        "Add Model": "添加模型",
        "Add Provider": "添加提供商",
        "New Provider": "新建提供商",

        // MARK: OAuthLoginView
        "Not signed in": "未登录",
        "Exchanging code for tokens…": "正在换取令牌…",
        "Signed in": "已登录",
        "Account: %@…": "账户：%@…",
        "Sign-in failed": "登录失败",
        "Enter this code at OpenAI": "在 OpenAI 输入此代码",
        "Open verification page": "打开验证页面",
        "Expires %@. Waiting for approval…": "将于 %@ 过期。等待批准中…",

        // MARK: CodexProvider displayNames
        "Responses API (Direct)": "Responses API（直连）",
        "Chat Completions (Proxy)": "Chat Completions（代理）",

        // MARK: AppState errors / alerts / test-connection messages
        "Select a provider before starting": "启动前请先选择一个提供商",
        "Port must be between 1 and 65535": "端口必须在 1 到 65535 之间",
        "Port %d is already in use by %@": "端口 %d 已被 %@ 占用",
        "Active provider has an invalid Base URL": "当前提供商的 Base URL 无效",
        "Active provider API key is empty": "当前提供商的 API 密钥为空",
        "Active provider has no models in catalog": "当前提供商的模型目录为空",
        "Every model needs an actual model ID": "每个模型都需要一个实际的模型 ID",
        "Codex config directory is not writable: %@": "Codex 配置目录不可写：%@",
        "Failed to apply Codex config: %@": "应用 Codex 配置失败：%@",
        "Failed to start proxy: %@": "启动代理失败：%@",
        "Failed to restore Codex official config: %@": "恢复 Codex 官方配置失败：%@",
        "Codex CLI Restart Required": "需要重启 Codex CLI",
        "Restart Codex CLI for changes to take effect.": "重启 Codex CLI 以使更改生效。",
        "OpenAI Official uses ChatGPT login authentication": "OpenAI 官方使用 ChatGPT 登录认证",
        "Connection successful (HTTP 200)": "连接成功（HTTP 200）",
        "API key rejected (HTTP %d)": "API 密钥被拒绝（HTTP %d）",
        "Server reachable (HTTP %d)": "服务器可达（HTTP %d）",
        "Unexpected response (HTTP %d)": "意外的响应（HTTP %d）",
        "Invalid URL": "URL 无效",

        // MARK: Codex auth-account (multi-account switching)
        "Provider Type": "账号类型",
        "Third-party Provider": "第三方服务商",
        "Codex Auth Account": "Codex 账号",
        "New Account": "新建账号",
        "Account %d": "账号 %d",
        "Switches the Codex CLI account by overwriting ~/.codex/auth.json with the content below. Both the API-key schema and the ChatGPT-login schema are supported.": "通过用下方内容覆盖 ~/.codex/auth.json 来切换 Codex CLI 账号。API 密钥格式与 ChatGPT 登录格式均支持。",
        "Paste the full content of ~/.codex/auth.json here.": "在此粘贴 ~/.codex/auth.json 的完整内容。",
        "Import from ~/.codex/auth.json": "从 ~/.codex/auth.json 导入",
        "Save Current Login as Account": "将当前登录保存为账号",
        "You can paste the auth.json content after adding, in the account editor.": "添加后可在账号编辑器中粘贴 auth.json 内容。",
        "Invalid JSON": "JSON 格式无效",
        "auth.json content is empty": "auth.json 内容为空",
    ]

    private init() {
        if let stored = AppEnvironment.shared.string(forKey: "appLanguage"),
           let lang = AppLanguage(rawValue: stored) {
            self.language = lang
        } else {
            // Auto-detect from system preferred languages on first launch.
            let preferred = Locale.preferredLanguages.first ?? "en"
            self.language = preferred.hasPrefix("zh") ? .simplifiedChinese : .english
        }
    }

    /// Translate a key. English keys fall through to themselves; Simplified
    /// Chinese looks up the table and falls back to the English key if missing.
    func tr(_ key: String) -> String {
        switch language {
        case .english:
            return key
        case .simplifiedChinese:
            return Self.zhTable[key] ?? key
        }
    }
}

/// Shorthand for `Localization.shared.tr(...)` for use outside SwiftUI views
/// (e.g. in models, AppState, validation code). Views should observe
/// `Localization.shared` directly via `@ObservedObject` and call `l10n.tr(...)`
/// so changing the language triggers a re-render.
enum L10n {
    static func tr(_ key: String) -> String { Localization.shared.tr(key) }
}
