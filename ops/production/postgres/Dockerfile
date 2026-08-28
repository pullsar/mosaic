FROM postgres:18.3-bookworm

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      pgbackrest \
    && rm -rf /var/lib/apt/lists/* \
    && install -d -o postgres -g postgres -m 0750 \
      /var/lib/pgbackrest \
      /var/log/pgbackrest \
      /var/spool/pgbackrest \
      /etc/pgbackrest

COPY --chown=postgres:postgres --chmod=0644 postgresql.conf /etc/postgresql/postgresql.conf
COPY --chown=postgres:postgres --chmod=0640 pgbackrest.conf.example /etc/pgbackrest/pgbackrest.conf

ENV PGDATA=/var/lib/postgresql/18/docker

CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
