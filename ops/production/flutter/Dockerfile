FROM debian:13.1-slim

ARG FLUTTER_VERSION=3.44.7
ARG FLUTTER_SHA256=a0edd646c159c0e816788c0e46a4f071199c1320495898f5a679599b583a05a4

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      git \
      unzip \
      xz-utils \
    && rm -rf /var/lib/apt/lists/*

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
    PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:/home/flutter/.pub-cache/bin:${PATH}

USER flutter

RUN flutter config --no-analytics --enable-web \
    && flutter precache --web

WORKDIR /dependency-seed

COPY --chown=flutter:flutter pubspec.yaml pubspec.lock ./
COPY --chown=flutter:flutter apps/mosaic_app/pubspec.yaml apps/mosaic_app/pubspec.yaml
COPY --chown=flutter:flutter packages/play_schema/pubspec.yaml packages/play_schema/pubspec.yaml
COPY --chown=flutter:flutter packages/play_engine/pubspec.yaml packages/play_engine/pubspec.yaml
COPY --chown=flutter:flutter packages/play_flutter/pubspec.yaml packages/play_flutter/pubspec.yaml
COPY --chown=flutter:flutter packages/analytics_contract/pubspec.yaml packages/analytics_contract/pubspec.yaml
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
