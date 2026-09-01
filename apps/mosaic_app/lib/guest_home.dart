import 'dart:async';

import 'package:flutter/material.dart';
import 'package:play_flutter/play_flutter.dart';

import 'guest_engagement.dart';

enum _GuestPromptResult { join, dismiss }

final class GuestHome extends StatefulWidget {
  const GuestHome({
    required this.engagement,
    required this.child,
    required this.onSearch,
    this.activeSearchLabel,
    this.onClearSearch,
    this.directManipulationActive = false,
    super.key,
  }) : assert(
         (activeSearchLabel == null) == (onClearSearch == null),
         'activeSearchLabel and onClearSearch must be provided together',
       );

  final GuestEngagementController engagement;
  final Widget child;
  final VoidCallback onSearch;
  final String? activeSearchLabel;
  final VoidCallback? onClearSearch;
  final bool directManipulationActive;

  @override
  State<GuestHome> createState() => _GuestHomeState();
}

final class _GuestHomeState extends State<GuestHome> {
  bool _promptScheduled = false;
  bool _promptShownThisSession = false;

  @override
  void initState() {
    super.initState();
    widget.engagement.addListener(_schedulePromptIfEligible);
    _schedulePromptIfEligible();
  }

  @override
  void didUpdateWidget(GuestHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engagement != widget.engagement) {
      oldWidget.engagement.removeListener(_schedulePromptIfEligible);
      widget.engagement.addListener(_schedulePromptIfEligible);
    }
    _schedulePromptIfEligible();
  }

  @override
  void dispose() {
    widget.engagement.removeListener(_schedulePromptIfEligible);
    super.dispose();
  }

  void _schedulePromptIfEligible() {
    if (widget.directManipulationActive ||
        !widget.engagement.shouldPrompt ||
        _promptScheduled ||
        _promptShownThisSession) {
      return;
    }
    _promptScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _promptScheduled = false;
      if (!mounted ||
          widget.directManipulationActive ||
          !widget.engagement.shouldPrompt ||
          _promptShownThisSession) {
        return;
      }
      _promptShownThisSession = true;
      unawaited(_showGuestPrompt());
    });
  }

  Future<void> _showGuestPrompt() async {
    final result = await showModalBottomSheet<_GuestPromptResult>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: const Color(0xFF101012),
      barrierColor: Colors.black.withValues(alpha: 0.62),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => _GuestSignupSheet(
        onDisposition: widget.engagement.recordPromptDisposition,
      ),
    );
    if (!mounted) return;
    if (result == _GuestPromptResult.join) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => const _EarlyAccessPage()),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const ValueKey<String>('guest-home'),
    backgroundColor: Colors.black,
    body: LayoutBuilder(
      builder: (context, constraints) {
        final mediaQuery = MediaQuery.of(context);
        final composition = PlayViewportComposition.fromConstraints(
          constraints,
          safeInsets: mediaQuery.padding,
          textScaler: mediaQuery.textScaler,
        );
        return PlayViewportScope(
          composition: composition,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              widget.child,
              Positioned.fromRect(
                rect: composition.chromeRect,
                child: _GuestChrome(
                  onSearch: widget.onSearch,
                  activeSearchLabel: widget.activeSearchLabel,
                  onClearSearch: widget.onClearSearch,
                ),
              ),
              Positioned.fromRect(
                rect: composition.navigationRect,
                child: const _GuestNavigation(),
              ),
            ],
          ),
        );
      },
    ),
  );
}

final class _GuestChrome extends StatelessWidget {
  const _GuestChrome({
    required this.onSearch,
    this.activeSearchLabel,
    this.onClearSearch,
  });

  final VoidCallback onSearch;
  final String? activeSearchLabel;
  final VoidCallback? onClearSearch;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Stack(
      alignment: Alignment.center,
      children: <Widget>[
        if (activeSearchLabel != null)
          PositionedDirectional(
            start: 8,
            end: 52,
            top: 0,
            bottom: 0,
            child: Align(
              alignment: Alignment.center,
              child: InputChip(
                key: const ValueKey<String>('search-scope'),
                label: Text(
                  activeSearchLabel!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onDeleted: onClearSearch,
                deleteButtonTooltipMessage: 'Clear search',
                deleteIcon: Semantics(
                  label: 'Clear search',
                  excludeSemantics: true,
                  child: const Icon(Icons.cancel_outlined),
                ),
                materialTapTargetSize: MaterialTapTargetSize.padded,
                visualDensity: VisualDensity.compact,
              ),
            ),
          )
        else
          const Text(
            'For You',
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Tooltip(
            message: 'Search Mixli',
            excludeFromSemantics: true,
            child: Semantics(
              label: 'Search Mixli',
              button: true,
              child: IconButton(
                key: const ValueKey<String>('open-search'),
                onPressed: onSearch,
                icon: const Icon(Icons.search_rounded),
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

final class _GuestNavigation extends StatelessWidget {
  const _GuestNavigation();

  static const _items = <_GuestNavigationItem>[
    _GuestNavigationItem('play', 'Play', Icons.play_circle_outline_rounded),
    _GuestNavigationItem('saved', 'Saved', Icons.bookmark_border_rounded),
    _GuestNavigationItem('create', 'Create', Icons.add_circle_outline_rounded),
    _GuestNavigationItem('me', 'Me', Icons.person_outline_rounded),
  ];

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: 0.88),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final item in _items)
          Expanded(
            child: Semantics(
              selected: item.id == 'play',
              child: TextButton(
                key: ValueKey<String>('guest-nav-${item.id}'),
                onPressed: () {
                  if (item.id == 'play') return;
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      SnackBar(content: Text('${item.label} is coming soon.')),
                    );
                },
                style: TextButton.styleFrom(
                  foregroundColor: item.id == 'play'
                      ? Colors.white
                      : const Color(0xFFB9B9C0),
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  shape: const RoundedRectangleBorder(),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(item.icon, size: 20),
                    const SizedBox(height: 2),
                    Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

final class _GuestNavigationItem {
  const _GuestNavigationItem(this.id, this.label, this.icon);

  final String id;
  final String label;
  final IconData icon;
}

final class _GuestSignupSheet extends StatefulWidget {
  const _GuestSignupSheet({required this.onDisposition});

  final Future<void> Function() onDisposition;

  @override
  State<_GuestSignupSheet> createState() => _GuestSignupSheetState();
}

final class _GuestSignupSheetState extends State<_GuestSignupSheet> {
  bool _submitting = false;

  Future<void> _submit(_GuestPromptResult result) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      await widget.onDisposition();
    } on Object {
      if (mounted) setState(() => _submitting = false);
      rethrow;
    }
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) => PopScope<_GuestPromptResult>(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_submit(_GuestPromptResult.dismiss));
    },
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        12,
        24,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Your Mixli is getting good',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Keep this feed and your progress.',
            style: TextStyle(color: Color(0xFFB9B9C0), fontSize: 16),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: _submitting
                  ? null
                  : () => _submit(_GuestPromptResult.join),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
              ),
              child: const Text('Get early access'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            child: TextButton(
              onPressed: _submitting
                  ? null
                  : () => _submit(_GuestPromptResult.dismiss),
              child: const Text(
                'Not now',
                style: TextStyle(color: Color(0xFFD7D7DC)),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

final class _EarlyAccessPage extends StatelessWidget {
  const _EarlyAccessPage();

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF08080A),
    body: SafeArea(
      minimum: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: IconButton(
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded),
              color: Colors.white,
            ),
          ),
          const Spacer(),
          const Icon(Icons.auto_awesome_rounded, size: 48, color: Colors.white),
          const SizedBox(height: 24),
          const Text(
            'Accounts are opening soon',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: -1,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Your guest feed stays right here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFFB9B9C0), fontSize: 17),
          ),
          const Spacer(),
          SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Back to exploring'),
            ),
          ),
        ],
      ),
    ),
  );
}
