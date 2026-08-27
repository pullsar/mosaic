import 'package:image_picker/image_picker.dart';
import 'package:platform_contracts/platform_contracts.dart';

final class FlutterMediaPickerGateway implements MediaPickerGateway {
  FlutterMediaPickerGateway({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<PickedMedia?> pickExistingImage() async {
    final file = await _picker.pickImage(source: ImageSource.gallery);
    return file == null ? null : _fromFile(file, PickedMediaKind.image);
  }

  @override
  Future<PickedMedia?> pickExistingVideo() async {
    final file = await _picker.pickVideo(source: ImageSource.gallery);
    return file == null ? null : _fromFile(file, PickedMediaKind.video);
  }

  @override
  Future<List<PickedMedia>> recoverLostMedia() async {
    final response = await _picker.retrieveLostData();
    if (response.isEmpty) return const [];
    if (response.exception != null) throw response.exception!;

    final files = response.files ?? (response.file == null ? const <XFile>[] : [response.file!]);
    final kind = response.type == RetrieveType.video
        ? PickedMediaKind.video
        : PickedMediaKind.image;
    return files.map((file) => _fromFile(file, kind)).toList(growable: false);
  }

  PickedMedia _fromFile(XFile file, PickedMediaKind kind) => PickedMedia(
    path: file.path,
    kind: kind,
    name: file.name,
    mimeType: file.mimeType,
  );
}
