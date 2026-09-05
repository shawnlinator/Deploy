FROM debian:bookworm-slim

# The standard openbao/openbao Docker Hub image is built without PKCS#11
# support ("this build of OpenBao has PKCS#11 disabled" — confirmed against
# a live 2.6.2 container). That's compiled into the binary, not a config
# flag: PKCS#11 requires the separate "-hsm" release build, which is glibc
# cgo-linked (confirmed via ldd) and won't run on the standard image's Alpine
# (musl) base. Hence a from-scratch Debian image with that binary instead.
RUN apt-get update && apt-get install -y --no-install-recommends \
      tpm2-tools softhsm2 opensc ca-certificates dumb-init \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 1000 openbao \
    && useradd --uid 1000 --gid openbao --home-dir /openbao --shell /usr/sbin/nologin openbao \
    && mkdir -p /openbao/config /openbao/file /openbao/logs \
    && chown -R openbao:openbao /openbao \
    # Pre-create with correct ownership so Docker seeds the (empty) named
    # volume mounted over this path with the same ownership, instead of
    # root:root.
    && mkdir -p /var/lib/softhsm/tokens \
    && chown -R openbao:openbao /var/lib/softhsm

COPY softhsm2.conf /etc/softhsm2.conf
COPY bao-hsm /bin/bao
RUN chmod +x /bin/bao

COPY entrypoint-tpm.sh /entrypoint-tpm.sh
RUN chmod +x /entrypoint-tpm.sh

EXPOSE 8200 8201
WORKDIR /openbao
# Device/tpmrm access comes from supplementary groups (see docker-compose.yml
# group_add), not root — this never needs to run as root.
USER openbao
ENTRYPOINT ["/usr/bin/dumb-init", "/entrypoint-tpm.sh"]
