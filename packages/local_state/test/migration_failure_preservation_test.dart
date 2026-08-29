import 'dart:io';

import 'package:local_state/local_state.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('migration failure preserves verified database without quarantine', () {
    final temp = Directory.systemTemp.createTempSync('mosaic-migrate-');
    final path = '${temp.path}/mosaic.db';

    try {
      final raw = sqlite3.open(path);
      raw.execute('''
        create table feed_resume (
          singleton integer primary key check(singleton = 1),
          cursor text,
          window_json text not null,
          updated_at text not null
        )
      ''');
      raw.execute('create table recent_feed_cache (marker text not null)');
      raw.execute(
        'insert into recent_feed_cache (marker) values (?)',
        ['preserve_me'],
      );
      raw.execute('pragma user_version = 1');
      raw.close();

      final openStore = () => MosaicLocalStore.open(path);
      expect(openStore, throwsA(isA<SqliteException>()));

      final quarantined = temp.listSync().whereType<File>().where(
        (file) => file.path.contains('.corrupt.'),
      );
      expect(quarantined, isEmpty);

      final reopened = sqlite3.open(path);
      try {
        final versionRows = reopened.select('pragma user_version');
        expect(versionRows.first.values.first, 1);

        const markerQuery = 'select marker from recent_feed_cache';
        final cacheRows = reopened.select(markerQuery);
        expect(cacheRows.single['marker'], 'preserve_me');

        const feedResumeSchema = 'pragma table_info(feed_resume)';
        final schemaRows = reopened.select(feedResumeSchema);
        final names = schemaRows.map((row) => row['name'] as String).toSet();
        expect(names, isNot(contains('request_id')));
        expect(names, isNot(contains('visible_revision_id')));
        expect(names, isNot(contains('visible_position')));
      } finally {
        reopened.close();
      }
    } finally {
      temp.deleteSync(recursive: true);
    }
  });
}
