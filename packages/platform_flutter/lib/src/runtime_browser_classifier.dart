import 'package:platform_contracts/runtime_diagnostics.dart';

MosaicBrowserFamily classifyBrowserUserAgent(String userAgent) {
  final value = userAgent.toLowerCase();
  if (value.contains('edg/') ||
      value.contains('edgios/') ||
      value.contains('edga/')) {
    return MosaicBrowserFamily.edge;
  }
  if (value.contains('crios/') ||
      value.contains('chrome/') ||
      value.contains('chromium/')) {
    return MosaicBrowserFamily.chrome;
  }
  if (value.contains('fxios/') || value.contains('firefox/')) {
    return MosaicBrowserFamily.firefox;
  }
  if (value.contains('safari/') && value.contains('version/')) {
    return MosaicBrowserFamily.safari;
  }
  return MosaicBrowserFamily.other;
}
