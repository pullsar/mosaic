final class SqliteEventOutbox {
  SqliteEventOutbox(Object store, {bool closeStoreOnClose = false}) {
    throw UnsupportedError('SQLite event outbox is unavailable on web.');
  }
}
