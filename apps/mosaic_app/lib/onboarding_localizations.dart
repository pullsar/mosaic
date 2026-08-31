import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

@immutable
final class MosaicOnboardingStrings {
  const MosaicOnboardingStrings._(this._mode);

  final _MosaicOnboardingLocaleMode _mode;

  static const LocalizationsDelegate<MosaicOnboardingStrings> delegate =
      _MosaicOnboardingStringsDelegate();

  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('en', 'XA'),
    Locale('ar', 'XB'),
  ];

  static MosaicOnboardingStrings of(BuildContext context) {
    final strings = Localizations.of<MosaicOnboardingStrings>(
      context,
      MosaicOnboardingStrings,
    );
    assert(strings != null, 'MosaicOnboardingStrings delegate is missing.');
    return strings!;
  }

  String get interestsPrompt => _text('What are you into?');
  String get learningPrompt => _text('Want to learn more about?');
  String get searchHint => _text('Search topics');
  String get surpriseMe => _text('Surprise me');
  String get continueLabel => _text('Continue');
  String get skip => _text('Skip');
  String get back => _text('Back');
  String get retry => _text('Retry');
  String get noTopics => _text('Topics unavailable');
  String get noMatches => _text('No matches');
  String get saveFailed => _text('Could not save');
  String get clearSearch => _text('Clear search');

  String selectedTopic(String topic) => _text('$topic, selected');
  String unselectedTopic(String topic) => _text(topic);

  String _text(String source) => switch (_mode) {
    _MosaicOnboardingLocaleMode.english => source,
    _MosaicOnboardingLocaleMode.pseudoLtr => _pseudoExpand(source),
    _MosaicOnboardingLocaleMode.pseudoRtl => _pseudoExpand(source),
  };
}

enum _MosaicOnboardingLocaleMode { english, pseudoLtr, pseudoRtl }

final class _MosaicOnboardingStringsDelegate
    extends LocalizationsDelegate<MosaicOnboardingStrings> {
  const _MosaicOnboardingStringsDelegate();

  @override
  bool isSupported(Locale locale) =>
      MosaicOnboardingStrings.supportedLocales.any(
        (supported) =>
            supported.languageCode == locale.languageCode &&
            (supported.countryCode == null ||
                supported.countryCode == locale.countryCode),
      );

  @override
  Future<MosaicOnboardingStrings> load(Locale locale) => SynchronousFuture(
    MosaicOnboardingStrings._(
      locale.languageCode == 'ar' && locale.countryCode == 'XB'
          ? _MosaicOnboardingLocaleMode.pseudoRtl
          : locale.languageCode == 'en' && locale.countryCode == 'XA'
          ? _MosaicOnboardingLocaleMode.pseudoLtr
          : _MosaicOnboardingLocaleMode.english,
    ),
  );

  @override
  bool shouldReload(_MosaicOnboardingStringsDelegate old) => false;
}

String _pseudoExpand(String source) {
  final accented = source
      .replaceAll('a', 'á')
      .replaceAll('e', 'ë')
      .replaceAll('i', 'ï')
      .replaceAll('o', 'ø')
      .replaceAll('u', 'ü')
      .replaceAll('A', 'Á')
      .replaceAll('E', 'Ë')
      .replaceAll('I', 'Ï')
      .replaceAll('O', 'Ø')
      .replaceAll('U', 'Ü');
  final extra = source.length < 12 ? ' ···' : ' ······';
  return '⟦$accented$extra⟧';
}
