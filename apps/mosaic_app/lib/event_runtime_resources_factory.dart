import 'event_runtime_resources.dart';
import 'event_runtime_resources_native.dart'
    if (dart.library.js_interop) 'event_runtime_resources_web.dart'
    as platform;

typedef AppEventResourceErrorReporter =
    void Function(Object error, StackTrace stackTrace);

Future<AppEventResources> openAppEventResources({
  AppEventResourceErrorReporter? onError,
}) async {
  try {
    return await platform.openPlatformEventResources();
  } on Object catch (error, stackTrace) {
    onError?.call(error, stackTrace);
    return AppEventResources.disabled();
  }
}
