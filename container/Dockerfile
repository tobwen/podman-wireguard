FROM alpine:3

COPY container/entrypoint.sh /entrypoint.sh

RUN set -eux \
    && apk add --no-cache wireguard-tools-wg iptables \
    && chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
