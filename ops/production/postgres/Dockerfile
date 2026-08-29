FROM postgres:18.3-bookworm

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      pgbackrest \
    && rm -rf /var/lib/apt/lists/* \
    && install -d -o postgres -g postgres -m 0750 \
      /var/lib/pgbackrest \
      /var/log/pgbackrest \
      /var/spool/pgbackrest \
      /etc/pgbackrest \
    && install -d -o root -g root -m 0700 /run/mixli-secrets \
    && install -d -o root -g root -m 0755 /usr/local/share/mixli

COPY --chown=postgres:postgres --chmod=0644 postgresql.conf /etc/postgresql/postgresql.conf
COPY --chown=root:root --chmod=0644 pgbackrest.conf.example /usr/local/share/mixli/pgbackrest.conf.example
COPY --chown=root:root --chmod=0755 docker-entrypoint-mixli.sh /usr/local/bin/docker-entrypoint-mixli.sh

ENV PGDATA=/var/lib/postgresql/18/docker

ENTRYPOINT ["/usr/local/bin/docker-entrypoint-mixli.sh"]
CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
