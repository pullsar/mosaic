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

WORKDIR /workspace

CMD ["flutter", "--version"]
