final class IndexedDbEventStore {
  IndexedDbEventStore._();

  static Future<IndexedDbEventStore> open({String? databaseName}) {
    throw UnsupportedError('IndexedDB event storage is available only on web.');
  }
}
