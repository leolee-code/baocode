# Contributing to BaoCode

[English](#english) · [简体中文](#简体中文)

## English

Issues and pull requests are both welcome.

- One pull request does one thing. Unrelated fixes, renames and reformatting
  go into pull requests of their own.

### Before you open it

- Match the code around your change: its naming, comment density and idiom.
  UI uses BaoCode's own components, not stock Material or Cupertino widgets.
- Run `dart format` and `flutter analyze`, and the tests for what you changed,
  for example `flutter test test/update`. The full suite is slow; you do not
  need to run all of it.
- Add or update tests for what you fixed or added.
- Commit messages follow `type(scope): summary`, for example
  `fix(ide): ...`; see `git log` for more.
- You understand and can explain every line, including any written with an
  AI tool.
- Your contribution is licensed under the license of the files it changes:
  [GPL-3.0-only](LICENSE) for the app, MIT for `packages/bao_editor`,
  `packages/bao_xterm` and `packages/bao_pty`.

## 简体中文

欢迎提交 Issue 和 Pull Request。

- 一个 PR 只做一件事。无关的修复、重命名、格式调整另开 PR。

### 提交之前

- 跟周围代码保持一致：命名、注释密度、写法。界面用 BaoCode 自己的组件，
  不用 Flutter 自带的 Material / Cupertino 控件。
- 运行 `dart format`、`flutter analyze`，以及与改动相关的测试，例如
  `flutter test test/update`。完整测试很慢，不需要全部跑。
- 修复或新增的功能要补上或更新测试。
- 提交信息格式为 `type(scope): summary`，例如 `fix(ide): ...`，可参考 `git log`。
- 每一行你都理解、能解释，包括用 AI 工具写的部分。
- 你的贡献沿用所改文件的许可证：应用本体为 [GPL-3.0-only](LICENSE)，
  `packages/bao_editor`、`packages/bao_xterm`、`packages/bao_pty` 为 MIT。
