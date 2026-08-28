import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:platform_contracts/platform_contracts.dart';

typedef PermissionStatusOperation =
    Future<PermissionStatus> Function(Permission permission);

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

Future<PermissionStatus> _checkPermission(Permission permission) =>
    permission.status;

Future<PermissionStatus> _requestPermission(Permission permission) =>
    permission.request();

final class FlutterPermissionGateway implements PermissionGateway {
  FlutterPermissionGateway({
    PermissionStatusOperation? checkStatus,
    PermissionStatusOperation? requestStatus,
  }) : _checkStatus = checkStatus ?? _checkPermission,
       _requestStatus = requestStatus ?? _requestPermission;

  final PermissionStatusOperation _checkStatus;
  final PermissionStatusOperation _requestStatus;

  @override
  Future<MosaicPermissionState> check(MosaicPermission permission) =>
      _resolve(_checkStatus, permission);

  @override
  Future<MosaicPermissionState> request(MosaicPermission permission) =>
      _resolve(_requestStatus, permission);

  Future<MosaicPermissionState> _resolve(
    PermissionStatusOperation operation,
    MosaicPermission permission,
  ) async {
    try {
      final status = await operation(permissionFor(permission));
      return mapPermissionStatus(status);
    } on MissingPluginException {
      return MosaicPermissionState.unsupported;
    } on UnsupportedError {
      return MosaicPermissionState.unsupported;
    }
  }
}
