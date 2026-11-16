/// The web has no local debugger to find.
abstract final class LldbDapLocator {
  static Future<String?> locate({String? configured}) async => null;
}
