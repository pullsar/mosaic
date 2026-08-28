import 'package:flutter_test/flutter_test.dart';
import 'package:platform_contracts/runtime_diagnostics.dart';
import 'package:platform_flutter/platform_flutter.dart';

void main() {
  test('browser classifier recognizes supported families without exposing UA', () {
    expect(
      classifyBrowserUserAgent(
        'Mozilla/5.0 (iPhone) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
      ),
      MosaicBrowserFamily.safari,
    );
    expect(
      classifyBrowserUserAgent(
        'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 Chrome/140.0.0.0 Mobile Safari/537.36',
      ),
      MosaicBrowserFamily.chrome,
    );
    expect(
      classifyBrowserUserAgent(
        'Mozilla/5.0 AppleWebKit/537.36 Chrome/140.0.0.0 Safari/537.36 Edg/140.0.0.0',
      ),
      MosaicBrowserFamily.edge,
    );
    expect(
      classifyBrowserUserAgent(
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15) Gecko/20100101 Firefox/142.0',
      ),
      MosaicBrowserFamily.firefox,
    );
    expect(
      classifyBrowserUserAgent('MosaicTestAgent/1.0'),
      MosaicBrowserFamily.other,
    );
  });

  test('runtime snapshot payload is intentionally coarse', () {
    const snapshot = RuntimeDiagnosticSnapshot(
      runtime: MosaicRuntimeKind.web,
      operatingSystem: MosaicOperatingSystem.ios,
      browser: MosaicBrowserFamily.safari,
    );

    expect(snapshot.toPayload(), {
      'runtime': 'web',
      'operatingSystem': 'ios',
      'browser': 'safari',
    });
    expect(snapshot.toPayload().keys, hasLength(3));
  });

  test('native Flutter runtime never reports a browser family', () {
    const provider = FlutterRuntimeDiagnostics();
    final snapshot = provider.snapshot();

    expect(snapshot.runtime, MosaicRuntimeKind.native);
    expect(snapshot.browser, MosaicBrowserFamily.none);
  });
}
