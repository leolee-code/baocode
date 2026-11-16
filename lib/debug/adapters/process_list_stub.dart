import 'process_list.dart';

/// The web has no processes to list.
abstract final class DebugProcesses {
  static Future<List<DebugProcess>> list() async => [];
}
