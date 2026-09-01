import 'dart:async';

import 'package:flutter/material.dart';
import 'package:play_flutter/play_flutter.dart';

import 'consumer_action_controller.dart';
import 'consumer_api_client.dart';
import 'consumer_feed.dart';
import 'consumer_local_state.dart';

typedef ConsumerShareCallback = FutureOr<void> Function(ConsumerFeedItem item);

final class ConsumerActionControls extends StatefulWidget {
  const ConsumerActionControls({
    required this.child,
    required this.item,
    required this.feedRequestId,
    required this.controller,
    required this.onAdvance,
    this.onShare,
    this.active = true,
    super.key,
  });

  final Widget child;
  final ConsumerFeedItem item;
  final String feedRequestId;
  final ConsumerActionController controller;
  final Future<bool> Function(ConsumerFeedAdvanceReason reason) onAdvance;
  final ConsumerShareCallback? onShare;
  final bool active;

  @override
  State<ConsumerActionControls> createState() => _ConsumerActionControlsState();
}

final class _ConsumerActionControlsState extends State<ConsumerActionControls> {
  static const int _maxTopicMenuItems = 8;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    if (widget.active) unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant ConsumerActionControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    if (widget.active &&
        (!oldWidget.active ||
            oldWidget.item.playId != widget.item.playId ||
            oldWidget.item.revisionId != widget.item.revisionId ||
            !identical(oldWidget.controller, widget.controller))) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  Future<void> _load() async {
    await widget.controller.load(
      playId: widget.item.playId,
      revisionId: widget.item.revisionId,
    );
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    final state = widget.controller.stateFor(widget.item.playId);
    final busy = widget.controller.isPlayBusy(widget.item.playId);
    final composition = PlayViewportScope.maybeOf(context);
    var actionAxis = Axis.horizontal;
    if (composition?.utilityPlacement == PlayUtilityPlacement.trailingRail) {
      actionAxis = Axis.vertical;
    }
    final actions = _buildActions(
      context,
      state: state,
      busy: busy,
      axis: actionAxis,
    );

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        widget.child,
        if (composition != null)
          Positioned.fromRect(
            rect: composition.utilityRect,
            child: Center(child: actions),
          )
        else
          SafeArea(
            minimum: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            child: Align(
              alignment: AlignmentDirectional.bottomCenter,
              child: actions,
            ),
          ),
      ],
    );
  }

  Widget _buildActions(
    BuildContext context, {
    required ConsumerPlayActionState? state,
    required bool busy,
    required Axis axis,
  }) => Material(
    color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.86),
    borderRadius: BorderRadius.circular(28),
    clipBehavior: Clip.antiAlias,
    child: Semantics(
      container: true,
      label: 'Play actions',
      child: Flex(
        direction: axis,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            key: const ValueKey<String>('play-action-save'),
            tooltip: state?.saved == true ? 'Unsave' : 'Save',
            onPressed: busy ? null : _toggleSave,
            icon: Icon(
              state?.saved == true
                  ? Icons.bookmark
                  : Icons.bookmark_border,
            ),
          ),
          if (widget.onShare != null)
            IconButton(
              key: const ValueKey<String>('play-action-share'),
              tooltip: 'Share',
              onPressed: _share,
              icon: const Icon(Icons.ios_share_outlined),
            ),
          PopupMenuButton<String>(
            key: const ValueKey<String>('play-action-more'),
            tooltip: 'More',
            icon: const Icon(Icons.more_horiz),
            onSelected: _handleMenuAction,
            itemBuilder: _menuItems,
          ),
        ],
      ),
    ),
  );

  Future<void> _toggleSave() async {
    await widget.controller.toggleSave(
      playId: widget.item.playId,
      revisionId: widget.item.revisionId,
      feedRequestId: widget.feedRequestId,
    );
  }

  Future<void> _moreLikeThis() async {
    await widget.controller.moreLikeThis(
      playId: widget.item.playId,
      revisionId: widget.item.revisionId,
      feedRequestId: widget.feedRequestId,
    );
  }

  Future<void> _share() async {
    final callback = widget.onShare;
    if (callback != null) await callback(widget.item);
  }

  List<PopupMenuEntry<String>> _menuItems(BuildContext context) {
    final entries = <PopupMenuEntry<String>>[];
    final state = widget.controller.stateFor(widget.item.playId);
    entries.add(
      PopupMenuItem<String>(
        value: 'more_like_this',
        enabled: state?.moreLikeThis != true,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            state?.moreLikeThis == true
                ? Icons.thumb_up
                : Icons.thumb_up_outlined,
          ),
          title: const Text('More like this'),
        ),
      ),
    );
    if (state?.notInterested != true) {
      entries.add(
        const PopupMenuItem<String>(
          value: 'not_interested',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.remove_circle_outline),
            title: Text('Not interested'),
          ),
        ),
      );
    }

    for (final topicId in _topicIds().take(_maxTopicMenuItems)) {
      final muted = widget.controller.isTopicMuted(topicId);
      entries.add(
        PopupMenuItem<String>(
          value: '${muted ? 'unmute' : 'mute'}:$topicId',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              muted ? Icons.volume_up_outlined : Icons.volume_off_outlined,
            ),
            title: Text(
              '${muted ? 'Unmute' : 'Mute'} ${_displayTopic(topicId)}',
            ),
          ),
        ),
      );
    }

    if (widget.controller.mutedTopicIds.isNotEmpty) {
      entries.add(
        const PopupMenuItem<String>(
          value: 'muted_topics',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.tune),
            title: Text('Muted topics'),
          ),
        ),
      );
    }

    entries.add(
      const PopupMenuItem<String>(
        value: 'report',
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.flag_outlined),
          title: Text('Report'),
        ),
      ),
    );
    return entries;
  }

  Future<void> _handleMenuAction(String action) async {
    if (action == 'more_like_this') {
      await _moreLikeThis();
      return;
    }
    if (action == 'not_interested') {
      final applied = await widget.controller.notInterested(
        playId: widget.item.playId,
        revisionId: widget.item.revisionId,
        feedRequestId: widget.feedRequestId,
      );
      if (applied) {
        await widget.onAdvance(ConsumerFeedAdvanceReason.notInterested);
      }
      return;
    }
    if (action == 'muted_topics') {
      await _showMutedTopics();
      return;
    }
    if (action == 'report') {
      await _showReportReasons();
      return;
    }
    final separator = action.indexOf(':');
    if (separator < 1 || separator == action.length - 1) return;
    final verb = action.substring(0, separator);
    final topicId = action.substring(separator + 1);
    if (verb != 'mute' && verb != 'unmute') return;
    final muted = verb == 'mute';
    final applied = await widget.controller.setTopicMuted(
      topicId: topicId,
      muted: muted,
      feedRequestId: widget.feedRequestId,
      playRevisionId: widget.item.revisionId,
    );
    if (applied && muted) {
      await widget.onAdvance(ConsumerFeedAdvanceReason.topicMuted);
    }
  }

  Future<void> _showMutedTopics() async {
    final topicId = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 12),
          children: <Widget>[
            const ListTile(title: Text('Muted topics')),
            for (final topicId in widget.controller.mutedTopicIds)
              ListTile(
                leading: const Icon(Icons.volume_up_outlined),
                title: Text(_displayTopic(topicId)),
                trailing: const Text('Unmute'),
                onTap: () => Navigator.of(context).pop(topicId),
              ),
          ],
        ),
      ),
    );
    if (topicId == null || !mounted) return;
    await widget.controller.setTopicMuted(
      topicId: topicId,
      muted: false,
      feedRequestId: widget.feedRequestId,
      playRevisionId: widget.item.revisionId,
    );
  }

  Future<void> _showReportReasons() async {
    final reason = await showModalBottomSheet<ConsumerReportReason>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 12),
          children: <Widget>[
            for (final reason in ConsumerReportReason.values)
              ListTile(
                title: Text(_reportLabel(reason)),
                onTap: () => Navigator.of(context).pop(reason),
              ),
          ],
        ),
      ),
    );
    if (reason == null || !mounted) return;
    final reported = await widget.controller.report(
      playId: widget.item.playId,
      revisionId: widget.item.revisionId,
      feedRequestId: widget.feedRequestId,
      reason: reason,
      dismiss: true,
    );
    if (reported) {
      await widget.onAdvance(ConsumerFeedAdvanceReason.reported);
    }
  }

  Iterable<String> _topicIds() sync* {
    final seen = <String>{};
    for (final raw in <String>[
      ...widget.item.play.topics,
      ...widget.item.play.learningTopics,
    ]) {
      final topic = raw.trim();
      if (topic.isNotEmpty && seen.add(topic)) yield topic;
    }
  }
}

String _displayTopic(String topicId) {
  final words = topicId.replaceAll(RegExp('[-_]+'), ' ').trim();
  if (words.isEmpty) return 'topic';
  return words.length == 1
      ? words.toUpperCase()
      : '${words[0].toUpperCase()}${words.substring(1)}';
}

String _reportLabel(ConsumerReportReason reason) => switch (reason) {
  ConsumerReportReason.spam => 'Spam',
  ConsumerReportReason.misleading => 'Misleading',
  ConsumerReportReason.harassment => 'Harassment',
  ConsumerReportReason.sexualContent => 'Sexual content',
  ConsumerReportReason.violenceOrDangerous => 'Violence or dangerous activity',
  ConsumerReportReason.rightsOrOwnership => 'Rights or ownership',
  ConsumerReportReason.other => 'Something else',
};
