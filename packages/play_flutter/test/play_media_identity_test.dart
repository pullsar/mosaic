import 'package:play_flutter/play_flutter.dart';
import 'package:test/test.dart';

void main() {
  test('media ownership identity includes both Play and revision identity', () {
    expect(playMediaOwnerIdFor('play_a', 'rev_1'), isNot('rev_1'));
    expect(
      playMediaOwnerIdFor('play_a', 'rev_1'),
      isNot(playMediaOwnerIdFor('play_b', 'rev_1')),
    );
    expect(
      playMediaOwnerIdFor('play_a', 'rev_1'),
      isNot(playMediaOwnerIdFor('play_a', 'rev_2')),
    );
  });

  test('length-prefixing prevents delimiter-shaped identity collisions', () {
    expect(
      playMediaOwnerIdFor('a:1', 'b'),
      isNot(playMediaOwnerIdFor('a', '1:b')),
    );
  });

  test('empty identities fail closed', () {
    expect(() => playMediaOwnerIdFor(' ', 'rev_1'), throwsArgumentError);
    expect(() => playMediaOwnerIdFor('play_a', ' '), throwsArgumentError);
  });
}
