import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mosaic_app/asset_delivery_client.dart';
import 'package:mosaic_app/main.dart';

void main() {
  test(
    'production capability envelope widens only for installed delivery kinds',
    () {
      final noDelivery = consumerCapabilitiesForAssetDelivery(null);
      expect(noDelivery.presentationTypes, <String>{'text'});

      final secure = AssetDeliveryClient(
        baseUri: Uri.parse('https://api.example.test/'),
        client: MockClient((_) async => throw StateError('unused')),
      );
      final secureCapabilities = consumerCapabilitiesForAssetDelivery(secure);
      expect(secureCapabilities.presentationTypes, <String>{
        'text',
        'canvas',
        'image',
        'video_clip',
        'audio',
      });
      secure.close();

      final local = AssetDeliveryClient(
        baseUri: Uri.parse('http://localhost:8080/'),
        allowInsecureLocalhost: true,
        client: MockClient((_) async => throw StateError('unused')),
      );
      final localCapabilities = consumerCapabilitiesForAssetDelivery(local);
      expect(localCapabilities.presentationTypes, <String>{'text', 'canvas'});
      local.close();
    },
  );
}
