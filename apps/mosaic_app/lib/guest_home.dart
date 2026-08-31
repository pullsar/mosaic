import 'dart:async';

import 'package:flutter/material.dart';

import 'guest_engagement.dart';

enum _GuestPromptResult { join, dismiss }

final class GuestHome extends StatefulWidget {
  const GuestHome({
    required this.engagement,
    required this.child,
    required this.onSearch,
    super.key,
  });

  final GuestEngagementController engagement;
  final Widget child;
  final VoidCallback onSearch;

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
    if (oldWidget.engagement == widget.engagement) return;
    oldWidget.engagement.removeListener(_schedulePromptIfEligible);
    widget.engagement.addListener(_schedulePromptIfEligible);
    _schedulePromptIfEligible();
  }

  @override
  void dispose() {
    widget.engagement.removeListener(_schedulePromptIfEligible);
    super.dispose();
  }

  void _schedulePromptIfEligible() {
    if (!widget.engagement.shouldPrompt ||
        _promptScheduled ||
        _promptShownThisSession) {
      return;
    }
    _promptScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _promptScheduled = false;
      if (!mounted ||
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
      backgroundColor: const Color(0xFF101012),
      barrierColor: Colors.black.withValues(alpha: 0.62),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => _GuestSignupSheet(
        onJoin: () => Navigator.of(sheetContext).pop(_GuestPromptResult.join),
        onDismiss: () =>
            Navigator.of(sheetContext).pop(_GuestPromptResult.dismiss),
      ),
    );
    if (!mounted) return;
    if (result == _GuestPromptResult.join) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => const _EarlyAccessPage()),
      );
    } else {
      await widget.engagement.dismissPrompt();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        key: const ValueKey<String>('guest-home'),
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            widget.child,
            SafeArea(
              minimum: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 0),
              child: Align(
                alignment: AlignmentDirectional.topCenter,
                child: SizedBox(
                  height: 48,
                  child: Stack(
                    alignment: Alignment.center,
                    children: <Widget>[
                      const Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          'mixli',
                          maxLines: 1,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1,
                          ),
                        ),
                      ),
                      const Text(
                        'For You',
                        maxLines: 1,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: Semantics(
                          button: true,
                          label: 'Search Mixli',
                          excludeSemantics: true,
                          child: IconButton(
                            key: const ValueKey<String>('open-search'),
                            tooltip: 'Search Mixli',
                            onPressed: widget.onSearch,
                            icon: const Icon(Icons.search_rounded),
                            color: Colors.white,
                          ),
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

final class _GuestSignupSheet extends StatelessWidget {
  const _GuestSignupSheet({required this.onJoin, required this.onDismiss});

  final VoidCallback onJoin;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Padding(
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
                onPressed: onJoin,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                ),
                child: const Text('Join Mixli'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 48,
              child: TextButton(
                onPressed: onDismiss,
                child: const Text(
                  'Not now',
                  style: TextStyle(color: Color(0xFFD7D7DC)),
                ),
              ),
            ),
          ],
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
              const Icon(
                Icons.auto_awesome_rounded,
                size: 48,
                color: Colors.white,
              ),
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
