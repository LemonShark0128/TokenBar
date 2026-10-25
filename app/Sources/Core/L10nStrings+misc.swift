extension L10nStrings {
    static let misc: [L10n.Entry] = [
        .init("agentDir.invalidCodex", "这个文件夹里没有 sessions 子目录，请选择 Codex 的数据目录", "This folder has no sessions subfolder. Choose the Codex data folder"),
        .init("agentDir.invalidClaude", "这个文件夹里没有 projects 子目录或 settings.json，请选择 Claude 的数据目录", "This folder has no projects subfolder or settings.json. Choose the Claude data folder"),
        .init("action.dataDir", "数据目录…", "Data Folder…"),
        .init("action.resetDataDir", "恢复默认数据目录", "Use Default Data Folder"),
        .init("acct.dataDir", "数据目录 {0}", "Data folder {0}"),
        .init("claude.nothingInstalled", "没找到 Claude 桌面 App，也没找到 Claude Code 命令行：装好其中一个并登录、用过一次后再看", "Neither the Claude desktop app nor the Claude Code CLI was found. Install one, sign in and use it once, then check back"),
        .init("webLoad.failed", "登录页没打开：{0}", "Could not open the sign-in page: {0}"),
        .init("webLoad.offline", "没有网络连接", "No network connection"),
        .init("webLoad.timeout", "连接超时", "Connection timed out"),
        .init("webLoad.host", "连不上 {0}，检查网络或代理", "Cannot connect to {0}. Check your network or proxy"),
        .init("webLoad.thisSite", "这个网站", "this website"),
        .init("webLoad.secure", "安全连接失败，检查代理或系统时间", "Secure connection failed. Check your proxy or system time"),
        .init("webLoad.restricted", "当前网络不允许连接（数据漫游等）", "The current network does not allow this connection (for example, data roaming)"),
        .init("webLoad.other", "页面加载失败（错误码 {0}）", "Page failed to load (error code {0})"),
        .init("webLoad.retry", "重试", "Retry"),
    ]
}
