import 'package:permission_handler/permission_handler.dart';
import 'package:platform_contracts/platform_contracts.dart';

Permission permissionFor(MosaicPermission permission) => switch (permission) {
  MosaicPermission.camera => Permission.camera,
  MosaicPermission.microphone => Permission.microphone,
  MosaicPermission.notifications => Permission.notification,
};

MosaicPermissionState mapPermissionStatus(PermissionStatus status) =>
    switch (status) {
      PermissionStatus.granted ||
      PermissionStatus.limited ||
      PermissionStatus.provisional => MosaicPermissionState.granted,
      PermissionStatus.denied => MosaicPermissionState.denied,
      PermissionStatus.restricted => MosaicPermissionState.restricted,
      PermissionStatus.permanentlyDenied =>
        MosaicPermissionState.permanentlyDenied,
    };

final class FlutterPermissionGateway implements PermissionGateway {
  const FlutterPermissionGateway();

  @override
  Future<MosaicPermissionState> check(MosaicPermission permission) async {
    final status = await permissionFor(permission).status;
    return mapPermissionStatus(status);
  }

  @override
  Future<MosaicPermissionState> request(MosaicPermission permission) async {
    final status = await permissionFor(permission).request();
    return mapPermissionStatus(status);
  }
}
