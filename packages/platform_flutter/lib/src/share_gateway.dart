import 'package:platform_contracts/platform_contracts.dart';
import 'package:share_plus/share_plus.dart';

typedef SharePlusCall = Future<ShareResult> Function(ShareParams params);

/// Opens the platform share sheet for a canonical public Play URL.
final class SharePlusGateway implements ShareGateway {
  SharePlusGateway({SharePlusCall? share})
    : _share = share ?? SharePlus.instance.share;

  final SharePlusCall _share;

  @override
  Future<ShareDisposition> share(
    Uri canonicalPlayUri, {
    String? message,
  }) async {
    final result = await _share(
      ShareParams(uri: canonicalPlayUri, text: message),
    );
    return switch (result.status) {
      ShareResultStatus.success => ShareDisposition.shared,
      ShareResultStatus.dismissed => ShareDisposition.dismissed,
      ShareResultStatus.unavailable => ShareDisposition.unavailable,
    };
  }
}
