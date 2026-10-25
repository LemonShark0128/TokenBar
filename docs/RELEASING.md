# 发版流程

Token Bar 的安装包是 ad-hoc 签名的通用版 dmg（没有 Developer ID、不公证），发布在 GitHub Releases。

**一律在公开仓库里打包**：构建号 `CFBundleVersion` 取的是当前仓库的提交数（`git rev-list --count HEAD`），只有一直在同一个仓库打包，构建号才会每次递增（以后做「检查更新」要靠它）。

## 0. 第一次：生成公开仓库

在私有工作仓库里（`app/`、README 等都已提交）：

```bash
bash tools/make-public-repo.sh ~/Projects/TokenBar
```

它会复制要公开的文件、`git init` 并做一个初始提交（不带私有仓库的历史）。然后自己：

1. 在 GitHub 建一个**空**仓库（不要勾「添加 README / LICENSE」）。
2. 把截图放进 `docs/images/`，去掉 README 里截图那几行的注释，提交。
3. 关联并推送：

```bash
git -C ~/Projects/TokenBar remote add origin git@github.com:LemonShark0128/TokenBar.git
```

```bash
git -C ~/Projects/TokenBar push -u origin main
```

推上去后到 Actions 页面看 CI（`.github/workflows/ci.yml`）是否通过。

### 以后每次同步

`make-public-repo.sh` 只用来生成全新目录（目标已存在会报错）。以后同步时先生成到临时目录，再拷进公开仓库的工作区：

```bash
bash tools/make-public-repo.sh /tmp/tokenbar-sync
```

```bash
rsync -a --delete --exclude .git --exclude docs/images /tmp/tokenbar-sync/ ~/Projects/TokenBar/
```

然后在公开仓库里 `git diff` 看一遍、提交、push，再删掉 `/tmp/tokenbar-sync`。

## 1. 准备版本

1. 改 `app/Info.plist` 的 `CFBundleShortVersionString`（如 `1.0.1`）。`CFBundleVersion` 不用改，打包时自动设。
2. 在 `CHANGELOG.md` 顶部加一段新版本：日期、能做什么 / 修了什么，底部加上对应的 tag 链接。
3. `bash app/test.sh` 全过，提交。

## 2. 打 tag

```bash
git tag -a v1.0.1 -m "Token Bar 1.0.1"
```

```bash
git push origin main v1.0.1
```

## 3. 打包

```bash
bash app/package-dmg.sh
```

- 从 `git archive HEAD` 的干净副本编译通用版（arm64 + x86_64），工作区里没提交的改动不会进安装包。
- 产物：`dist/TokenBar-<版本号>.dmg`；脚本最后会打出构建号和 dmg 的 SHA-256，**把这一行记下来**。
- 自己装一遍试试：挂载 dmg、拖进「应用程序」、打开，确认功能正常，设置 → 通用 → 复制诊断信息里的版本号对。

## 4. 发 GitHub Release

1. GitHub 仓库 → Releases → Draft a new release，选刚推的 tag `v1.0.1`，标题 `Token Bar 1.0.1`。
2. 发布说明：从 `CHANGELOG.md` 抄这个版本那一段，末尾加上：
   - `SHA-256: <上一步打出的那串> TokenBar-1.0.1.dmg`
   - 一句提醒：第一次打开被拦 / 升级后钥匙串再问一次的处理办法见 README。
3. 上传 `dist/TokenBar-1.0.1.dmg`。
4. Publish。

## 以后有 Developer ID 时

`TOKENBAR_SIGN_IDENTITY="Developer ID Application: …" bash app/package-dmg.sh` 会改用证书签名（带 hardened runtime 和时间戳）。公证（`xcrun notarytool submit … --wait` 和 `xcrun stapler staple`）要 Apple ID 凭据，自己在终端里跑，脚本不做。签了 Developer ID 之后，README 里「仍要打开」和「升级后再问钥匙串」两段就可以删了。
