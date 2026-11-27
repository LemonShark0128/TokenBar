import AppKit
import SwiftUI

// ---------------------------------------------------------------- 首次引导：Codex 套餐、DeepSeek、硅基流动的登录页和完成页

extension OnboardingView {
    /// 套餐平台：不需要登录，点「下一步」（最后一个平台是「完成」）就添加（读本机使用记录）
    var loginPlan: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(L("ob.addTitle", current.map(ProviderRegistry.displayName) ?? ""),
                  current == .geminiPlan ? L("ob.geminiNote") : L("ob.codexNote"))
            Spacer(minLength: 0)
            HStack {
                Button(L("ob.later")) { advance() }.buttonStyle(.plain).foregroundColor(p.sub).font(.system(size: 12)).disabled(busy)
                Spacer()
                Button(busy ? L("ob.adding") : OnboardingPlan.stepButton(isLast: isLast)) {
                    guard let id = current else { return }
                    busy = true
                    Task { @MainActor in
                        await model.addPlanPlatform(id)
                        connected.insert(id)
                        advance()
                    }
                }.keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
    }

    /// 登录页底部：跳过 / 完成（或「下一步」）
    var loginFooter: some View {
        HStack {
            Button(L("ob.later")) { advance() }.buttonStyle(.plain).foregroundColor(p.sub).font(.system(size: 12)).disabled(busy)
            Spacer()
            Button(OnboardingPlan.stepButton(isLast: isLast)) { advance() }.keyboardShortcut(.defaultAction).disabled(!verified)
        }
    }

    /// 验证类任务完成时调用。进行中「以后再说」「取消」都禁用（跳过会让结果记到下一个平台上），所以 current 仍是发起任务的平台
    func markConnected(_ ok: Bool, _ msg: String) {
        message = msg; verified = ok; busy = false
        if ok, let id = current { connected.insert(id) }
    }

    var loginDeepSeek: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(L("ob.ds.title"), L("ob.ds.note"))
            SecureField("sk-…", text: $apiKey).textFieldStyle(.roundedBorder).font(.num(12, .regular))
            HStack(spacing: 10) {
                Button(busy ? L("ob.verifying") : L("ob.verifySave")) {
                    busy = true
                    Task { @MainActor in
                        let r = await model.saveApiKey(apiKey, for: .deepseek)
                        markConnected(r.ok, r.message)
                        if r.ok { apiKey = "" }
                    }
                }.disabled(apiKey.isEmpty || busy)
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundColor(verified ? Accent.green : Accent.orange)
            }
            Hairline(p: p)
            VStack(alignment: .leading, spacing: 6) {
                LT("ob.ds.consoleTitle").font(.system(size: 12.5, weight: .medium)).foregroundColor(p.text)
                LT("ob.ds.consoleNote")
                    .font(.system(size: 11)).foregroundColor(p.sub).fixedSize(horizontal: false, vertical: true)
                Button(L("action.loginConsole")) { model.openConsoleLogin() }
                    .buttonStyle(.plain).foregroundColor(Accent.blue).font(.system(size: 12)).disabled(!verified)
            }
            Spacer(minLength: 0)
            loginFooter
        }
    }

    /// Kimi：只要 API Key（国内站 platform.moonshot.cn），没有控制台登录
    var loginKimi: some View {
        apiKeyOnlyLogin(.kimi, placeholder: "sk-…", footnote: "ob.kimi.estimateNote")
    }

    /// OpenRouter：只要 API Key（普通 Key 即可；读不到账户余额时看 Key 上限）
    var loginOpenRouter: some View {
        apiKeyOnlyLogin(.openrouter, placeholder: "sk-or-v1-…", footnote: "ob.openrouter.billNote")
    }

    /// PackyAPI：用户 ID + 控制台系统访问令牌（只用 API Key 读不到账户余额，用户 11/9 选甲）
    var loginPackyAPI: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(L("ob.packyapi.title"), L("ob.packyapi.note"))
            TextField(L("ob.packyapi.userId"), text: $userId).textFieldStyle(.roundedBorder).font(.num(12, .regular))
            SecureField(L("ob.packyapi.token"), text: $apiKey).textFieldStyle(.roundedBorder).font(.num(12, .regular))
            HStack(spacing: 10) {
                Button(busy ? L("ob.verifying") : L("ob.verifySave")) {
                    busy = true
                    Task { @MainActor in
                        let r = await model.saveAccessToken(apiKey, userId: userId, for: .packyapi)
                        markConnected(r.ok, r.message)
                        if r.ok { apiKey = ""; userId = "" }
                    }
                }.disabled(apiKey.isEmpty || userId.isEmpty || busy)
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundColor(verified ? Accent.green : Accent.orange)
            }
            LT("ob.packyapi.footnote")
                .font(.system(size: 11)).foregroundColor(p.sub).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            loginFooter
        }
    }

    /// 只填一个 API Key 的登录页（标题 / 说明用 ob.<id>.title / ob.<id>.note），底部一段灰字说明
    private func apiKeyOnlyLogin(_ id: ProviderID, placeholder: String, footnote: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            title(L("ob.\(id.rawValue).title"), L("ob.\(id.rawValue).note"))
            SecureField(placeholder, text: $apiKey).textFieldStyle(.roundedBorder).font(.num(12, .regular))
            HStack(spacing: 10) {
                Button(busy ? L("ob.verifying") : L("ob.verifySave")) {
                    busy = true
                    Task { @MainActor in
                        let r = await model.saveApiKey(apiKey, for: id)
                        markConnected(r.ok, r.message)
                        if r.ok { apiKey = "" }
                    }
                }.disabled(apiKey.isEmpty || busy)
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundColor(verified ? Accent.green : Accent.orange)
            }
            LT(footnote)
                .font(.system(size: 11)).foregroundColor(p.sub).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            loginFooter
        }
    }

    var loginSiliconFlow: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(L("ob.sf.title"), L("ob.sf.note"))
            Button(busy ? L("ob.waitingLogin") : L("ob.openLogin")) {
                busy = true; message = ""
                model.openWebLogin(.siliconflow, onDone: { ok, msg in markConnected(ok, msg) },
                                   onCancel: { busy = false })
            }.disabled(busy || verified)
            if !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundColor(verified ? Accent.green : Accent.orange)
            }
            Spacer(minLength: 0)
            loginFooter
        }
    }

    var hasPlatforms: Bool { !connected.isEmpty || (!removedSome && !model.needsSetup) }

    var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            title(hasPlatforms ? L("ob.allSet") : L("ob.addAnyTime"),
                  hasPlatforms ? L("ob.allSetNote")
                                                           : L("ob.noneNote"))
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(L("ob.close")) {
                    UserDefaults.standard.set(true, forKey: "onboardingDone")
                    Hud.hide("onboarding")
                }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
