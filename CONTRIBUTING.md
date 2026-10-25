# 参与开发

欢迎提 issue 和 PR。下面是在本机编译、测试、调试 Token Bar 需要知道的事。

## 目录

```
app/
  Sources/Core/   业务逻辑：各平台取数、额度、采样库、提醒、文案（不依赖 AppKit / SwiftUI）
  Sources/App/    界面：菜单栏、面板、小组件、设置、网页登录（SwiftUI + AppKit）
  Tests/          测试（只编译 Core + Tests）；Fixtures/ 是各平台接口的样本响应
  tools/post.swift  发调试通知的小工具（见下面「调试钩子」）
  build.sh  test.sh  sdk.sh  package-dmg.sh
```

没有 Xcode 工程，也不用 SwiftPM：脚本直接调 `swiftc`。

## 编译

需要 macOS 14+，以及 Xcode 或 Command Line Tools（`xcode-select --install`）。

```bash
bash app/build.sh --no-install
```

- 产物在 `app/build/TokenBar.app`。
- 不加 `--no-install`：编译后装到 `~/Applications/TokenBar.app`（ad-hoc 签名；钥匙串会把每次新编译的版本当成新程序，重装后会再问一次授权）。想重装后不再问，可以建一个自签名「代码签名」证书，用 `TOKENBAR_SIGN_IDENTITY="证书名" bash app/build.sh`，详见 `build.sh` 里的注释。
- `--universal`：同时编 arm64 和 x86_64（打包用，慢一倍）。
- SDK 选择在 `app/sdk.sh`：先看 `SDKROOT` 环境变量，再看作者本机的特殊情况，最后用 `xcrun --sdk macosx --show-sdk-path`。编不过时可以先试 `SDKROOT=$(xcrun --sdk macosx --show-sdk-path) bash app/build.sh --no-install`。

## 测试

```bash
bash app/test.sh
```

最后一行是 `N/N passed`，有失败时退出码非 0。`test.sh` 只编译 `Sources/Core` 和 `Tests`——**Core 里如果引用了界面代码，这里会直接编译失败**，这是有意的：Core 必须保持和界面无关。

### 手写的测试框架

本项目不用 XCTest（只装 Command Line Tools 的机器上没有），测试编译成一个普通可执行文件，框架在 `app/Tests/TestHarness.swift`，只有几个函数：

```swift
func registerFooTests() {
    test("名字") {                       // 同步测试
        try check(1 + 1 == 2, "说明")     // 条件不成立就失败
        try checkEqual(foo(), "bar")      // 不相等就失败，并打印两边的值
    }
    testAsync("异步的") {                 // async 测试
        let r = await something()
        try check(r != nil)
    }
}
```

新增测试文件后，**记得在 `app/Tests/AllTests.swift` 的 `registerAllTests()` 里加一行 `registerFooTests()`**，否则不会跑。

- 联网的地方用假的 `HTTPClient`（`FixtureHTTPClient`、`RoutedFixtureHTTPClient`、`InlineHTTPClient`），样本放 `app/Tests/Fixtures/<平台>/`。测试不访问网络。
- 时间、时区、目录都由调用方传入，测试里用固定时间和临时目录，不读你本机的 `~/.claude`、`~/.codex`。
- 默认**不跑**会写真实钥匙串的 `CredentialStoreTests`。要跑：`TOKENBAR_KEYCHAIN_TESTS=1 bash app/test.sh`（会在你的登录钥匙串里建、删测试条目）。

## 调试钩子

App 里有一组「调试钩子」：通过本机广播通知让正在运行的 App 打开面板 / 设置 / 小组件、切换主题、导出数据快照、把菜单栏尺寸写进日志等，方便截图和排查。因为任何本机进程都能发这个广播，**发布版默认不注册**，开发时要手动打开：

```bash
defaults write com.lemon.deepseek-tokenbar debugHooks -bool true
```

然后退出并重新打开 App，日志里会出现「调试钩子已打开（debugHooks）」。发通知用 `app/tools/post.swift`：

```bash
swiftc -O -o app/build/post app/tools/post.swift
```

```bash
app/build/post panel,settings
```

参数是逗号分隔的动作，能用的名字见 `app/Sources/App/AppMain.swift` 里 `debugHooks` 那一段（如 `panel`、`settings`、`widget`、`theme:dark`、`dumpstore`）。用完记得关掉：

```bash
defaults delete com.lemon.deepseek-tokenbar debugHooks
```

此外还有两个开发工具入口，发布版里没有，要先用 `bash app/build.sh --no-install --devtools` 编：

- `app/build/TokenBar.app/Contents/MacOS/TokenBar --render-check <基准目录> --out <目录>`：用固定的示例数据和固定设置离屏渲染各个界面的预览图，并和基准目录逐张对比，改界面时用来前后对比（`--render --out <目录>` 只渲染不对比）。
- 在 `app/` 下跑 `./build/TokenBar.app/Contents/MacOS/TokenBar --icon`：用示例数据重新生成 `Icon.iconset` 和 `AppIcon.icns`。

日志在 `~/Library/Logs/TokenBar/app.log`。

## 不要提交凭据

- **任何真实的 API Key、cookie、网页登录 token、账号编号都不能进仓库**——包括测试夹具、截图、日志片段、issue 里贴的内容。
- 测试和夹具里一律用明显是假的值（如 `sk-test000000000000abcd`、`tok-test`），录下来的接口响应要先把 key、token、手机号、邮箱、账号编号换掉。
- App 自己把凭据只存在钥匙串里，日志和「复制诊断信息」都会先打码（`Diagnostics.redact`）；新增日志时也别把凭据原文写进去。

## 提交 PR 前

- `bash app/test.sh` 全部通过；改了逻辑请先补测试（Core 里的逻辑基本都能测）。
- `bash app/build.sh --no-install` 能编过。
- 改了联网地址、读写的本机文件、钥匙串内容，请同步更新 README 的「隐私」一节。
- 不要改 bundle id（`com.lemon.deepseek-tokenbar`）、launchd 标签、钥匙串 service 名：改了会让老用户丢失设置和登录。
