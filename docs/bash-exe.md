# BaoCode Bash（third_party/bash-exe）

Windows 上 agent 跑命令用的 `bash.exe`：Rust 写的 bash 5.3，内置 `rg`、`grep`、`sed`、`awk`、`find`、`jq`、`tar` 等 80 多个工具，`C:\x`、`C:/x`、`/c/x` 都能当路径用，不需要 Git for Windows 或 MSYS2。

上游版本由发布方的 CI 构建，放在 `dl.baocode.dev` 上，由应用下载（上游的 `lib/bash_exe/`）。本仓库不下载：源码随仓库，构建时编出来，安装包带上。

## 来源

| 项 | 值 |
| --- | --- |
| 上游仓库 | https://github.com/baocode-dev/bash-exe |
| 当前版本 | 0.3.0，commit `b649c538a09ca54da11ea3e646852b8089d54314`（2026-11-16） |
| 引入方式 | `git subtree`（保留上游提交历史），目录 `third_party/bash-exe/` |
| 许可证 | GPL-3.0-or-later（整体）；它移植的部分（oh-my-pi 的 shell、uutils coreutils、ripgrep、jaq 等）的 MIT 等许可证和版权声明随源码保留，构建时一并拷进 `licenses/` |
| 审计 | 引入前做过静态审计：没有遥测、自动更新、崩溃上报或后台联网。会联网的命令见 `docs/egress-policy.md` 的“随包携带的 BaoCode Bash”一节 |

本地改动（升级时注意保留）：

- `Cargo.toml` 的 `homepage` 从 `https://baocode.dev/` 改成上游仓库地址（规则 1：代码里不出现发布方的域名）。

## 构建

```
dart run tool/build_bash_exe.dart                 # 输出到 build/bash/
dart run tool/build_bash_exe.dart --arch arm64    # Windows 上指定架构
```

- 需要 rustup。工具链由 `third_party/bash-exe/rust-toolchain.toml` 固定（nightly），rustup 第一次会自动安装；cargo 按 `Cargo.lock` 从 crates.io 拉 crate（`--locked`，不会改锁文件）。cargo 的中间文件在 `build/bash-exe-target/`。
- Windows 上还需要 Flutter 构建本来就要的 Visual Studio C++ 生成工具（cargo 用它链接，pcre2、oniguruma、zstd 的 C 代码也用它编）。
- 在 macOS、Linux 上编出本机能跑的 `bash`，只用来试；应用只在 Windows 上用它。

`dart run tool/build_windows.dart` 会自动调用它，把结果放进安装目录的 `bash\`（`--bash-built` 复用 `build\bash\` 里已编好的）。

## 应用怎么用它

见 `lib/platform/windows_shell.dart`：

- 找 `bash.exe` 的顺序：应用 exe 旁边的 `bash\bash.exe`（安装包），然后是检出目录的 `build\bash\bash.exe`（开发时）。
- 设置 → 通用 → 命令行（Windows）里列为 “BaoCode Bash”，找到时才列出；settings.json 里存为 `"baoBash"`，和上游一致。
- 没选 shell 时默认用它（排在 Git Bash 前）。用户自己设了 `CLAUDE_CODE_GIT_BASH_PATH` 时，以用户的为准。
- 两个内核都用它：内置核心通过 `BAOCODE_BASH`；Claude Code CLI 通过 `CLAUDE_CODE_GIT_BASH_PATH`，并在系统提示里说明它内置了哪些工具（`Shell.baoBashNote`）。

## 升级

1. 在上游仓库挑好要升级到的 commit，先看它和当前版本的 diff：
   `git -C <bash-exe 的克隆> diff b649c538..<新 commit>`。重点看联网相关代码、新增依赖（`Cargo.lock`）、构建脚本（`build.rs`）。
2. 合进来：
   `git subtree pull --prefix=third_party/bash-exe https://github.com/baocode-dev/bash-exe <新 commit>`。
   若 `Cargo.toml` 的 `homepage` 冲突，保留本地改动。
3. 跑 `flutter test test/policy`：新增的 crate 或新用到联网 API 的源码文件会让测试失败。先在 `docs/egress-policy.md` 写明原因，经人工评审后，再加进 `test/policy/bash_exe_crates.txt` 或测试里的文件清单。
4. 更新本文的“当前版本”。
