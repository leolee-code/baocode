/// Who the commits and pull requests an agent writes credit: the
/// `chat.commitAttribution` setting. Read as each agent starts, so a change
/// applies to the agents started after it.
enum CommitAttribution {
  /// What the agent adds of its own (Claude Code: itself), as its own
  /// settings have it.
  agent,

  /// None.
  none;

  static const settingKey = 'chat.commitAttribution';

  /// When the setting is unset, or not one of these.
  static const fallback = none;

  static CommitAttribution parse(Object? setting) =>
      values.where((value) => value.name == setting).firstOrNull ?? fallback;

  /// The setting as it is now; main() points it at settings.json.
  static CommitAttribution Function() current = () => fallback;
}
