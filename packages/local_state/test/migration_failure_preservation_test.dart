import 'dart:io';

import 'package:local_state/local_state.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('migration failure does not quarantine verified data', () {
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

      expect(
        () => MosaicLocalStore.open(path),
        throwsA(isA<SqliteException>()),
      );

      final quarantined = <File>[];
      for (final entity in temp.listSync()) {
        if (entity is File && entity.path.contains('.corrupt.')) {
          quarantined.add(entity);
        }
      }
      expect(quarantined, isEmpty);

      final reopened = sqlite3.open(path);
      try {
        final versionRows = reopened.select('pragma user_version');
        expect(versionRows.first.values.first, 1);

        final cacheRows = reopened.select(
          'select marker from recent_feed_cache',
        );
        expect(cacheRows.single['marker'], 'preserve_me');

        final schemaRows = reopened.select('pragma table_info(feed_resume)');
        final names = <String>{};
        for (final row in schemaRows) {
          names.add(row['name'] as String);
        }
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
