import 'dart:io';

import 'package:local_state/local_state.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test(
    'migration failure preserves a verified database without quarantine',
    () {
      final temp = Directory.systemTemp.createTempSync(
        'mosaic-migration-failure-',
      );
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

        expect(
          temp.listSync().whereType<File>().where(
            (file) => file.path.contains('.corrupt.'),
          ),
          isEmpty,
        );

        final reopened = sqlite3.open(path);
        try {
          final persistedVersion =
              reopened.select('pragma user_version').first.values.first as int;
          expect(persistedVersion, 1);

          final cacheRows = reopened.select(
            'select marker from recent_feed_cache',
          );
          expect(cacheRows.single['marker'], 'preserve_me');

          final feedResumeColumns = reopened
              .select('pragma table_info(feed_resume)')
              .map((row) => row['name'] as String)
              .toSet();
          expect(feedResumeColumns, isNot(contains('request_id')));
          expect(feedResumeColumns, isNot(contains('visible_revision_id')));
          expect(feedResumeColumns, isNot(contains('visible_position')));
        } finally {
          reopened.close();
        }
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
  );
}
