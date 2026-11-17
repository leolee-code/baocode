# 外联与安全策略（本仓库的硬性约束）

本仓库是 BaoCode 的公司内部分支。和上游相比，它**删掉了所有连到 BaoCode 发布方服务的代码**，以及**会让代码或对话内容离开本机的可选功能**。以后从上游合并代码、或自己加功能时，必须遵守下面的规则。

规则由 `test/policy/egress_policy_test.dart` 自动检查（PR 的 CI 会跑，本地用 `flutter test test/policy`）。**检查失败时，不要顺手放宽白名单让它通过**：先读本文件，确认改动符合规则，在本文件写明原因，经人工评审后才能把新条目加进测试的白名单。

## 规则

### 1. 不连 BaoCode 发布方的任何服务

代码里不得出现 `baocode.dev` 及其子域名。下列功能已删除，不得重新引入：

| 已删除 | 原来连到哪里 | 原路径 |
| --- | --- | --- |
| 使用统计（遥测） | `stats.baocode.dev/v1/ping` | `lib/telemetry/` |
| 自动更新、检查更新 | `dl.baocode.dev/releases/latest.json` | `lib/update/`（只保留 `version.dart`） |
| 诊断日志上传 | `stats.baocode.dev/v1/diagnostics` | `lib/diagnostics/diagnostics_upload.dart`、`diagnostics_bundle.dart` |
| 渠道版（归因、渠道账号登录） | `baocode.dev/activate`、`stats.baocode.dev/v1/attribution`、渠道商站点 | `lib/channel/`、`BAOCODE_CHANNEL` 编译开关 |
| 推荐上游列表 | `baocode.dev/featured/upstreams.json` | `lib/models/featured_upstreams*.dart` |
| 上游一键导入 | `baocode.dev/import` → `baocode://provider/import` | `lib/models/upstream_import.dart` |
| Windows 的 BaoCode Bash 下载 | `dl.baocode.dev/tools/bash-exe/` | `lib/bash_exe/` |
| 浏览器扩展的商店/下载入口 | `dl.baocode.dev`、`baocode.dev/dl/browser-extension` | `lib/browser/extension_store.dart`（现在扩展随应用资源打包，见下） |
| SSH 远程服务端的按需下载 | `dl.baocode.dev/releases/remote/` | `DownloadedServerBinaries`（现在随安装包携带，见下） |
| 发布流水线 | 发布方的 R2 存储 | `.github/workflows/` 里除 `checks.yml` 外的全部 |

要升级版本：拉代码、自己构建、自己分发。SSH 远程用的服务端由 `tool/build_remote_server.dart` 在本地构建，打包脚本把它放进安装包，应用**只用随包携带的构建，不下载**。

注意：一台机器只能构建部分平台的服务端。Linux 各架构在哪都能构建；macOS 的只能在 Mac 上构建（另一种架构要用 `--macos-<arch>-dart` 指定对应的 Dart）；Windows 的只能在 Windows 上构建。所以在 Mac 上打的包能连 Linux 主机和同架构的 Mac 主机，连不了 Windows 主机。要全平台支持，需要在各平台分别构建后汇到同一个 `build/remote/` 再打包。

浏览器扩展：仓库里的 `browser_extension/` 作为应用资源打进安装包（`pubspec.yaml` 的 assets）。用户在"设置 → 浏览器"或浏览器欢迎页点"显示文件夹"，应用把它写到数据目录的 `browser-extension/`，再由用户在 Chrome 里以"加载已解压的扩展程序"方式加载（`lib/browser/extension_folder.dart`）。**不要恢复 Chrome 应用商店的入口**：商店版本由发布方上传并自动更新，不经过我们审查，而扩展有 `debugger` 权限。扩展的 `manifest.json` 不得加 `update_url`，`background.js` 不得发起网络请求，测试会检查。

### 2. 内容不经第三方中转

下列功能会让会话内容、项目文件或指令经过本机和模型上游之外的地方，已删除，不得重新引入：

- **手机连接**（`lib/link/`、`packages/bao_link`、`packages/bao_iroh`）：中继 `relay-*.baocode.dev`、局域网广播、手机远程读文件和下指令。
- **iPhone 推送**（`lib/link/phone_push.dart`）：会话标题和消息正文经 `push.baocode.dev` 转发。
- **机器人 Bots**（`lib/bots/`）：以 `bypassPermissions` 无人值守运行。
- **渠道版**：强制把第三方中转商作为唯一上游。

- **Gitee 和 GitCode 账号**（`lib/forge/` 里的 `GiteeApi`、`GitCodeApi`）：公司不用。代码托管账号只支持 GitHub 和 GitLab（含自建实例）。

模型上游（设置 → 模型）保留，由使用者手动配置。**只能配置公司批准的上游**；应用内不得出现任何推荐、预置或一键添加第三方上游的入口。

### 3. 提交不署名

`chat.commitAttribution` 的默认值是 `none`：agent 写的提交和 PR 默认不加任何署名行。`BaoCode <noreply@baocode.dev>` 这个选项已删除；想要 Claude Code 自己的署名可手动选 `agent`。

### 4. 新增联网必须过评审

- 每个发起连接、监听端口或加载远程图片的 Dart 文件（`HttpClient`、`Socket.connect`、`ServerSocket.bind`、`Image.network` 等）都登记在测试的白名单里，并注明它跟谁通信。扫描范围是 `lib/` 和各子包的 `lib/`、`bin/`、`hook/`。
- 代码字符串里出现的每个域名都登记在测试的白名单里，不管它是怎么写的（`https://…`、`Uri.https('…')`、`wss://…`）。
- 原生层（`macos/`、`windows/runner/`、`linux/runner/`）里用到联网 API 的文件都登记在测试的白名单里。
- `pubspec.lock` 里解析出的每个包（含各子包的依赖和间接依赖）都登记在测试的白名单里。新增依赖前要看它是否联网、是否带统计或崩溃上报。应用代码不得使用 `package:http`。
- 监听端口只能绑定 `127.0.0.1`。
- 不得加入任何统计、埋点、崩溃上报 SDK，也不得把日志、崩溃报告或使用数据发到任何地方。
- 自动下载的东西只有 Claude Code CLI（来自 `downloads.claude.ai`，校验大小和哈希），且只在用户选择使用 CLI 而本机没有时发生。

#### 目前允许的全部外联

| 对象 | 什么时候 | 发什么 |
| --- | --- | --- |
| 用户配置的模型上游 | 每次对话、生成图片、列出模型 | 对话内容和代码 |
| `api.anthropic.com` | 用 Claude Code 自己的登录查询用量 | 本机 Claude Code 的登录令牌 |
| `auth.openai.com`、`chatgpt.com`、`api.openai.com` | 用户添加了 ChatGPT（Codex）账号 | 该账号的令牌和对话内容 |
| `downloads.claude.ai` | 本机没有 Claude Code CLI 且用户选用它 | 无用户数据 |
| GitHub、GitLab（含自建） | 用户在"设置 → 账号"里添加了账号 | 令牌、相关 Issue 和 PR 的内容 |
| 用户添加的 MCP 服务器、hooks 里的地址 | 按用户配置 | 按用户配置 |
| 用户的 SSH 主机 | 打开远程项目 | 经系统的 `ssh` |
| `open-vsx.org` | 用户浏览或安装主题扩展 | 搜索词 |
| 语言服务器的下载源（GitHub Releases、npm、PyPI、Go、crates.io 等） | 用户在界面里点安装某个语言服务器 | 无用户数据；**不校验哈希**，部分通过本机的 npm、pip、go、cargo 安装 |
| 模型上游站点的图标 | 添加上游后取一次站点图标 | 无用户数据 |
| Stash 里链接的标题、Markdown 和 Stash 里的远程图片 | 内容里有链接或远程图片时 | 无用户数据，但对方能看到本机 IP |
| agent 的网页抓取和搜索工具 | agent 调用时 | agent 给出的网址和查询 |
| `www.google.com`、`www.baidu.com`、`www.youtube.com`、模型接口地址 | 用户在"设置 → 网络"里点连通性测试 | 无用户数据 |
| `cdn.jsdelivr.net` | 首次启动取一次 emoji 图集 | 无用户数据 |

构建时（不是应用运行时）打包脚本还会下载：Windows 的 OpenSSH（GitHub Releases）、Inno Setup、WebView2 的 nuget 包。

#### 测试查不到的情况

`test/policy` 是静态文本检查，下面这些它发现不了，合并上游代码时要靠人看：

- 通过子进程联网（代码里调用 `git`、`npm`、`curl`、`ssh` 等命令）。
- 域名被拆成三段以上、用变量拼接，或从配置、环境变量、服务端返回的数据里读出来。
- 依赖包内部的联网行为：白名单只管"多了哪个包"，不管包升级后做了什么。
- 原生代码里没有列在检查关键字中的联网方式。
- `tool/` 下的构建脚本、`site/`、`web/` 不在扫描范围内。

## 从上游合并代码时

1. 合并后先跑 `flutter analyze` 和 `flutter test test/policy`。
2. 冲突里凡是涉及上表路径的，**一律保留删除**。上游在别处新增了对这些模块的调用，就把调用点删掉，不要把模块加回来。
3. 上游新增的功能，逐个看它是否联网、连到哪里、发什么。连 `baocode.dev` 的删掉；让内容经第三方中转的删掉；其余的按规则 4 登记。
4. 测试的白名单有任何改动，都要在 PR 描述里单独列出并说明原因。

## 待评审的白名单条目

合并上游 2.0.1（分支 `merge/upstream-2.0.1`）后，`test/policy` 报出下面两条。两条都**没有新增外联对象**，说明写在这里，评审通过后再加进 `test/policy/egress_policy_test.dart` 的白名单：

| 条目 | 来自 | 实际做什么 | 连到哪里 |
| --- | --- | --- | --- |
| 联网文件 `packages/bao_agent/lib/src/engine/isolate.dart` | 上游 #1048（信任本机证书） | 内置核心的 isolate 里用 `HttpOverrides` 让它建的 `HttpClient` 额外信任本机的根证书（公司 CA、代理的证书）。证书由主进程读本机证书库后传进来（macOS 调 `/usr/bin/security`，Windows 调 `powershell.exe`，Linux 读系统证书文件），不经网络。 | 不变：仍是用户配置的模型上游 |
| 域名 `arc.app` | 上游 #1072（区分不同浏览器） | `lib/browser/browser_bridge.dart` 里按可执行文件路径认浏览器名字的规则，匹配 `/Applications/Arc.app/...`，不是网址。 | 无 |

同一次合并里，Claude Code CLI 新增了环境变量 `NODE_EXTRA_CA_CERTS`（指向数据目录里导出的本机证书 PEM），作用同上，也不连新地址。

## 已知未处理

- **macOS 公证未验证。** 安装包里现在带有 macOS 版的远程服务端可执行文件（`Contents/Resources/remote/`），`tool/build_macos.dart` 的签名步骤没有单独签它们，提交苹果公证时可能被拒。本机自用（临时签名）不受影响。
- `ClaudeLaunch` 构造函数里署名参数的默认值仍是 `agent`。应用里发起会话的地方都显式传了设置值，所以默认不署名成立；新增调用点时要记得传。

- 原生层里渠道版登录窗口的代码还在（`macos/Runner/LoginWindow.swift`、`windows/runner/login_window.cpp`、`linux/runner/login_window.cc`）。Dart 侧已无人调用，属于死代码；删除它要改各平台工程文件，需在对应平台上构建验证。
- `lib/l10n/*.arb` 里还留有已删功能的文案（更新、手机、渠道等），不影响行为。
- `site/`、`site-worker/`、`wrangler.jsonc`、`release-notes/` 是上游官网的源码，不进应用，未改动。
- `README*.md` 仍是上游的介绍，里面提到的自动更新、手机连接等在本分支不存在。
