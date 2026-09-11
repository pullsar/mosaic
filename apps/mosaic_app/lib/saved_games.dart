import 'package:flutter/material.dart';

import 'consumer_api_client.dart';

/// A retained, playable revision selected from the local Saved collection.
final class SavedGameEntry {
  const SavedGameEntry({required this.item, required this.updatedAt});

  final ConsumerFeedItem item;
  final DateTime updatedAt;
}

typedef SavedGameEntriesLoader = Future<List<SavedGameEntry>> Function();
typedef SavedGameOpenCallback = Future<void> Function(ConsumerFeedItem item);
typedef SavedGameUnsaveCallback = Future<bool> Function(SavedGameEntry entry);

/// A local-first view of Saved games.
///
/// The owner supplies retained, validated revisions so this surface never
/// creates another renderer or bypasses the shared Play route.
final class SavedGamesPage extends StatefulWidget {
  const SavedGamesPage({
    required this.loadEntries,
    this.onOpen,
    this.onUnsave,
    super.key,
  });

  final SavedGameEntriesLoader loadEntries;
  final SavedGameOpenCallback? onOpen;
  final SavedGameUnsaveCallback? onUnsave;

  @override
  State<SavedGamesPage> createState() => _SavedGamesPageState();
}

final class _SavedGamesPageState extends State<SavedGamesPage> {
  late Future<List<SavedGameEntry>> _entries = widget.loadEntries();

  void _retry() => setState(() {
    _entries = widget.loadEntries();
  });

  Future<void> _open(ConsumerFeedItem item) async {
    final callback = widget.onOpen;
    if (callback != null) await callback(item);
  }

  Future<void> _unsave(SavedGameEntry entry) async {
    final callback = widget.onUnsave;
    if (callback == null) return;
    if (await callback(entry) && mounted) _retry();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Saved')),
    body: FutureBuilder<List<SavedGameEntry>>(
      future: _entries,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        if (snapshot.hasError) {
          return Center(
            child: FilledButton(onPressed: _retry, child: const Text('Retry')),
          );
        }
        final entries = snapshot.data ?? const <SavedGameEntry>[];
        if (entries.isEmpty) {
          return const Center(child: Text('No saved games'));
        }
        return GridView.builder(
          key: const ValueKey<String>('saved-games-grid'),
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.15,
          ),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            final prompt = _promptFor(entry.item);
            return Semantics(
              button: true,
              label: prompt,
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(20),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: InkWell(
                        key: ValueKey<String>(
                          'saved-game:${entry.item.playId}',
                        ),
                        onTap: () => _open(entry.item),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Align(
                            alignment: AlignmentDirectional.bottomStart,
                            child: Text(
                              prompt,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (widget.onUnsave != null)
                      PositionedDirectional(
                        top: 4,
                        end: 4,
                        child: IconButton(
                          key: ValueKey<String>(
                            'saved-game-unsave:${entry.item.playId}',
                          ),
                          tooltip: 'Unsave',
                          onPressed: () => _unsave(entry),
                          icon: const Icon(Icons.bookmark_remove_outlined),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ),
  );
}

String _promptFor(ConsumerFeedItem item) {
  final state = item.play.states[item.play.entryState];
  if (state == null) return item.playId;
  for (final layer in state.presentation) {
    if (layer.role == 'prompt' && layer.value?.trim().isNotEmpty == true) {
      return layer.value!.trim();
    }
  }
  return item.playId;
}
