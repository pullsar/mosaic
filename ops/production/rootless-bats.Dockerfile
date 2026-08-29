FROM debian:13.1-slim

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash \
      bats \
      coreutils \
      findutils \
      gawk \
      grep \
      sed \
      sudo \
      util-linux \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

ENTRYPOINT ["bats"]
