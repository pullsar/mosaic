@JS()
library;

import 'dart:js_interop';

import 'package:platform_contracts/runtime_diagnostics.dart';

import 'runtime_browser_classifier.dart';

@JS('navigator.userAgent')
external JSString get _userAgent;

MosaicBrowserFamily currentBrowserFamily() =>
    classifyBrowserUserAgent(_userAgent.toDart);
