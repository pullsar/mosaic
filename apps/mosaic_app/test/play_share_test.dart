import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/play_share.dart';

void main() {
  final origin = Uri(scheme: 'https', host: 'mixli.app');

  test('builds a canonical exact-round share URL', () {
    expect(
      PlayShareLink.build(
        origin: origin,
        playId: 'mixli_starter_quiet_switch',
        revisionId: 'rev_1',
      ),
      Uri.parse('https://mixli.app/p/mixli_starter_quiet_switch/rev_1'),
    );
  });

  test('parses only the exact canonical share route', () {
    expect(
      PlayShareLink.parse(
        Uri.parse('https://mixli.app/p/quiet_switch/rev_1'),
        origin: origin,
      ),
      const PlayShareTarget(playId: 'quiet_switch', revisionId: 'rev_1'),
    );
    expect(
      PlayShareLink.parse(
        Uri.parse(
          'https://mixli.app/p/quiet_switch/rev_1?next=https://bad.example',
        ),
        origin: origin,
      ),
      isNull,
    );
    expect(
      PlayShareLink.parse(
        Uri.parse('https://example.com/p/quiet_switch/rev_1'),
        origin: origin,
      ),
      isNull,
    );
    expect(
      PlayShareLink.parse(
        Uri.parse('https://mixli.app/p/quiet%2Fswitch/rev_1'),
        origin: origin,
      ),
      isNull,
    );
  });

  test('parses an exact share route delivered without an origin', () {
    expect(
      PlayShareLink.parsePath('/p/quiet_switch/rev_1'),
      const PlayShareTarget(playId: 'quiet_switch', revisionId: 'rev_1'),
    );
    expect(
      PlayShareLink.parsePath('https://mixli.app/p/quiet_switch/rev_1'),
      isNull,
    );
  });
}
