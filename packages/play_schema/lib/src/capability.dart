import 'model.dart';

abstract final class PlaySchemaSupport {
  static const int currentVersion = 1;
  static const Set<int> supportedVersions = {1};

  static bool supports(int version) => supportedVersions.contains(version);
}

enum PlayCompatibilityStatus {
  compatible,
  unsupportedSchema,
  unsupportedPrimitive,
  malformed,
}

final class PlayCapabilityEnvelope {
  const PlayCapabilityEnvelope({
    required this.schemaVersions,
    required this.presentationTypes,
    required this.inputTypes,
    required this.validatorTypes,
    this.platformFlags = const {},
  });

  final Set<int> schemaVersions;
  final Set<String> presentationTypes;
  final Set<String> inputTypes;
  final Set<String> validatorTypes;
  final Set<String> platformFlags;

  /// Capabilities implemented by the M0 client/runtime.
  factory PlayCapabilityEnvelope.m0() => const PlayCapabilityEnvelope(
    schemaVersions: {1},
    presentationTypes: {'text', 'image', 'video_clip', 'audio'},
    inputTypes: {'tap', 'single_choice'},
    validatorTypes: {'none', 'equals'},
  );

  /// Capability envelope for the M1 declarative renderer.
  ///
  /// This extends M0 without rewriting its historical contract. Platform flags
  /// remain empty because timing-sensitive/audio-focus guarantees are advertised
  /// separately only when the production native adapter has been installed and
  /// measured on the running client.
  factory PlayCapabilityEnvelope.m1() => const PlayCapabilityEnvelope(
    schemaVersions: {1},
    presentationTypes: {'text', 'image', 'video_clip', 'audio', 'canvas'},
    inputTypes: {'tap', 'single_choice', 'piano_key', 'drag'},
    validatorTypes: {'none', 'equals', 'ordered_sequence', 'target_region'},
  );

  factory PlayCapabilityEnvelope.fromJson(Map<String, Object?> json) {
    Set<String> strings(String key) {
      final value = json[key];
      if (value is! List) throw FormatException('$key must be an array');
      return value.map((item) {
        if (item is! String) {
          throw FormatException('$key must contain strings');
        }
        return item;
      }).toSet();
    }

    final versionsRaw = json['schemaVersions'];
    if (versionsRaw is! List) {
      throw const FormatException('schemaVersions must be an array');
    }
    final versions = versionsRaw.map((item) {
      if (item is! int) {
        throw const FormatException('schemaVersions must contain integers');
      }
      return item;
    }).toSet();

    return PlayCapabilityEnvelope(
      schemaVersions: Set.unmodifiable(versions),
      presentationTypes: Set.unmodifiable(strings('presentationTypes')),
      inputTypes: Set.unmodifiable(strings('inputTypes')),
      validatorTypes: Set.unmodifiable(strings('validatorTypes')),
      platformFlags: Set.unmodifiable(strings('platformFlags')),
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersions': schemaVersions.toList()..sort(),
    'presentationTypes': presentationTypes.toList()..sort(),
    'inputTypes': inputTypes.toList()..sort(),
    'validatorTypes': validatorTypes.toList()..sort(),
    'platformFlags': platformFlags.toList()..sort(),
  };
}

final class PlayRequirements {
  const PlayRequirements({
    required this.schemaVersion,
    required this.presentationTypes,
    required this.inputTypes,
    required this.validatorTypes,
    this.platformFlags = const {},
  });

  final int schemaVersion;
  final Set<String> presentationTypes;
  final Set<String> inputTypes;
  final Set<String> validatorTypes;
  final Set<String> platformFlags;
}

final class PlayCompatibilityDecision {
  const PlayCompatibilityDecision({
    required this.status,
    this.message,
    this.missingCapabilities = const {},
  });

  final PlayCompatibilityStatus status;
  final String? message;
  final Set<String> missingCapabilities;

  bool get isCompatible => status == PlayCompatibilityStatus.compatible;
}

sealed class PlayDecodeResult {
  const PlayDecodeResult();
}

final class DecodedPlay extends PlayDecodeResult {
  const DecodedPlay(this.play);
  final PlayDocument play;
}

final class UnsupportedPlay extends PlayDecodeResult {
  const UnsupportedPlay(this.decision);
  final PlayCompatibilityDecision decision;
}

final class MalformedPlay extends PlayDecodeResult {
  const MalformedPlay(this.message);
  final String message;
}

final class PlayCompatibilityChecker {
  const PlayCompatibilityChecker();

  PlayCompatibilityDecision checkRaw(
    Map<String, Object?> json,
    PlayCapabilityEnvelope capabilities,
  ) {
    final requirements = _requirementsFromRaw(json);
    if (requirements == null) {
      return const PlayCompatibilityDecision(
        status: PlayCompatibilityStatus.malformed,
        message: 'Play capability requirements could not be read.',
      );
    }

    if (!capabilities.schemaVersions.contains(requirements.schemaVersion)) {
      return PlayCompatibilityDecision(
        status: PlayCompatibilityStatus.unsupportedSchema,
        message: 'schemaVersion ${requirements.schemaVersion} is unsupported.',
        missingCapabilities: {'schema:${requirements.schemaVersion}'},
      );
    }

    final missing = <String>{};
    for (final type in requirements.presentationTypes) {
      if (!capabilities.presentationTypes.contains(type)) {
        missing.add('presentation:$type');
      }
    }
    for (final type in requirements.inputTypes) {
      if (!capabilities.inputTypes.contains(type)) {
        missing.add('input:$type');
      }
    }
    for (final type in requirements.validatorTypes) {
      if (!capabilities.validatorTypes.contains(type)) {
        missing.add('validator:$type');
      }
    }
    for (final flag in requirements.platformFlags) {
      if (!capabilities.platformFlags.contains(flag)) {
        missing.add('platform:$flag');
      }
    }

    if (missing.isNotEmpty) {
      return PlayCompatibilityDecision(
        status: PlayCompatibilityStatus.unsupportedPrimitive,
        message: 'Play requires unsupported runtime capabilities.',
        missingCapabilities: Set.unmodifiable(missing),
      );
    }

    return const PlayCompatibilityDecision(
      status: PlayCompatibilityStatus.compatible,
    );
  }

  /// Inspects raw requirements before typed decoding so future primitives fail
  /// closed as unsupported rather than throwing from enum parsing.
  PlayDecodeResult decode(
    Map<String, Object?> json,
    PlayCapabilityEnvelope capabilities,
  ) {
    final compatibility = checkRaw(json, capabilities);
    if (!compatibility.isCompatible) {
      return compatibility.status == PlayCompatibilityStatus.malformed
          ? MalformedPlay(compatibility.message ?? 'Malformed Play.')
          : UnsupportedPlay(compatibility);
    }

    try {
      return DecodedPlay(PlayDocument.fromJson(json));
    } on Object catch (error) {
      return MalformedPlay(error.toString());
    }
  }

  PlayRequirements? _requirementsFromRaw(Map<String, Object?> json) {
    final schemaVersion = json['schemaVersion'];
    final statesRaw = json['states'];
    if (schemaVersion is! int || statesRaw is! Map) return null;

    final presentationTypes = <String>{};
    final inputTypes = <String>{};
    final validatorTypes = <String>{};
    final platformFlags = <String>{};

    final flagsRaw = json['requiredPlatformFlags'];
    if (flagsRaw != null) {
      if (flagsRaw is! List) return null;
      for (final value in flagsRaw) {
        if (value is! String || value.isEmpty) return null;
        platformFlags.add(value);
      }
    }

    for (final stateValue in statesRaw.values) {
      if (stateValue is! Map) return null;
      final state = Map<String, Object?>.from(stateValue);

      final presentationRaw = state['presentation'];
      final inputRaw = state['input'];
      final validationRaw = state['validation'];
      if (presentationRaw is! Map ||
          inputRaw is! Map ||
          validationRaw is! Map) {
        return null;
      }

      final presentation = Map<String, Object?>.from(presentationRaw);
      final layers = presentation['layers'];
      if (layers is! List) return null;
      for (final layerValue in layers) {
        if (layerValue is! Map) return null;
        final type = layerValue['type'];
        if (type is! String || type.isEmpty) return null;
        presentationTypes.add(type);
      }

      final inputType = inputRaw['type'];
      final validatorType = validationRaw['type'];
      if (inputType is! String || validatorType is! String) return null;
      inputTypes.add(inputType);
      validatorTypes.add(validatorType);
    }

    return PlayRequirements(
      schemaVersion: schemaVersion,
      presentationTypes: Set.unmodifiable(presentationTypes),
      inputTypes: Set.unmodifiable(inputTypes),
      validatorTypes: Set.unmodifiable(validatorTypes),
      platformFlags: Set.unmodifiable(platformFlags),
    );
  }
}
