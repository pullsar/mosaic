import 'consumer_api_client.dart';

final class ConsumerFeedResume {
  ConsumerFeedResume({
    required this.cursor,
    required List<String> windowRevisionIds,
    required this.updatedAt,
  }) : windowRevisionIds = List<String>.unmodifiable(windowRevisionIds);

  final String? cursor;
  final List<String> windowRevisionIds;
  final DateTime updatedAt;

  bool get isEmpty => cursor == null && windowRevisionIds.isEmpty;
}

abstract interface class ConsumerLocalState {
  Future<ConsumerPreferences> readPreferences();

  Future<void> writePreferences(ConsumerPreferences preferences);

  Future<ConsumerFeedResume?> readFeedResume();

  Future<void> writeFeedResume(ConsumerFeedResume state);

  Future<void> clearFeedResume();
}

final class DisabledConsumerLocalState implements ConsumerLocalState {
  const DisabledConsumerLocalState();

  @override
  Future<ConsumerPreferences> readPreferences() async => ConsumerPreferences();

  @override
  Future<void> writePreferences(ConsumerPreferences preferences) async {}

  @override
  Future<ConsumerFeedResume?> readFeedResume() async => null;

  @override
  Future<void> writeFeedResume(ConsumerFeedResume state) async {}

  @override
  Future<void> clearFeedResume() async {}
}
