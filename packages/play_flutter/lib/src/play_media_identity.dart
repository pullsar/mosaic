import 'package:play_schema/play_schema.dart';

/// Stable in-process owner identity for native media attached to one Play
/// revision.
///
/// Length-prefixing avoids delimiter collisions while keeping the identifier
/// deterministic and allocation-only; it is not a persisted/public Play ID.
String playMediaOwnerId(PlayDocument play) =>
    playMediaOwnerIdFor(play.id, play.revisionId);

String playMediaOwnerIdFor(String playId, String revisionId) {
  if (playId.trim().isEmpty) {
    throw ArgumentError.value(playId, 'playId', 'must not be empty');
  }
  if (revisionId.trim().isEmpty) {
    throw ArgumentError.value(revisionId, 'revisionId', 'must not be empty');
  }
  return '${playId.length}:$playId${revisionId.length}:$revisionId';
}
