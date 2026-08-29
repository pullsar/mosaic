FROM debian:13.1-slim

ARG FLUTTER_VERSION=3.44.7
ARG FLUTTER_SHA256=a0edd646c159c0e816788c0e46a4f071199c1320495898f5a679599b583a05a4
ARG ANDROID_CMDLINE_TOOLS_VERSION=15859902
ARG ANDROID_CMDLINE_TOOLS_SHA256=4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      chromium \
      curl \
      git \
      openjdk-21-jdk-headless \
      unzip \
      xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN install -d /opt/android-sdk/cmdline-tools \
    && curl --fail --show-error --location \
      --retry 5 --retry-all-errors --retry-delay 2 --continue-at - \
      --output /tmp/android-command-line-tools.zip \
      "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_VERSION}_latest.zip" \
    && printf '%s  %s\n' "$ANDROID_CMDLINE_TOOLS_SHA256" /tmp/android-command-line-tools.zip | sha256sum -c - \
    && unzip -q /tmp/android-command-line-tools.zip -d /opt/android-sdk/cmdline-tools \
    && mv /opt/android-sdk/cmdline-tools/cmdline-tools /opt/android-sdk/cmdline-tools/latest \
    && rm /tmp/android-command-line-tools.zip

# Chrome cannot create a nested namespace sandbox inside the rootless CI engine.
# The non-root container, rootless daemon, and hardened systemd unit are the CI boundary.
RUN printf '%s\n' '#!/bin/sh' 'exec /usr/bin/chromium --no-sandbox "$@"' \
      >/usr/local/bin/chromium-ci \
    && chmod 0755 /usr/local/bin/chromium-ci

ENV ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 \
    CHROME_EXECUTABLE=/usr/local/bin/chromium-ci

RUN yes | /opt/android-sdk/cmdline-tools/latest/bin/android \
      --sdk=/opt/android-sdk \
      sdk install \
      'platform-tools' \
      'platforms/android-35' \
      'platforms/android-36' \
      'platforms/android-37.0' \
      'build-tools/36.0.0' \
      'build-tools/37.0.0' \
      'cmake/3.22.1' \
      'ndk/28.2.13676358'

RUN curl --fail --show-error --location \
      --retry 5 --retry-all-errors --retry-delay 2 --continue-at - \
      --output /tmp/flutter.tar.xz \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    && printf '%s  %s\n' "$FLUTTER_SHA256" /tmp/flutter.tar.xz | sha256sum -c - \
    && tar -xJf /tmp/flutter.tar.xz -C /opt \
    && rm /tmp/flutter.tar.xz \
    && useradd --create-home --uid 1000 --shell /bin/bash flutter \
    && chown -R flutter:flutter /opt/flutter \
    && git config --system --add safe.directory /opt/flutter

ENV HOME=/home/flutter \
    PUB_CACHE=/home/flutter/.pub-cache \
    PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/home/flutter/.pub-cache/bin:${PATH}

USER flutter

RUN flutter config --no-analytics --enable-web --enable-android \
    && flutter precache --web --android

WORKDIR /dependency-seed

COPY --chown=flutter:flutter pubspec.yaml pubspec.lock ./
COPY --chown=flutter:flutter apps/mosaic_app/pubspec.yaml apps/mosaic_app/pubspec.yaml
COPY --chown=flutter:flutter packages/play_schema/pubspec.yaml packages/play_schema/pubspec.yaml
COPY --chown=flutter:flutter packages/play_engine/pubspec.yaml packages/play_engine/pubspec.yaml
COPY --chown=flutter:flutter packages/play_flutter/pubspec.yaml packages/play_flutter/pubspec.yaml
COPY --chown=flutter:flutter packages/analytics_contract/pubspec.yaml packages/analytics_contract/pubspec.yaml
COPY --chown=flutter:flutter packages/event_delivery/pubspec.yaml packages/event_delivery/pubspec.yaml
COPY --chown=flutter:flutter packages/platform_contracts/pubspec.yaml packages/platform_contracts/pubspec.yaml
COPY --chown=flutter:flutter packages/platform_flutter/pubspec.yaml packages/platform_flutter/pubspec.yaml
COPY --chown=flutter:flutter packages/local_state/pubspec.yaml packages/local_state/pubspec.yaml

RUN set -eu; \
    for attempt in 1 2 3 4 5; do \
      if flutter pub get --enforce-lockfile; then exit 0; fi; \
      test "$attempt" -lt 5 || exit 1; \
      sleep "$((attempt * 3))"; \
    done

WORKDIR /workspace

CMD ["flutter", "--version"]
