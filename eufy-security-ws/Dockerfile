ARG BUILD_FROM
FROM $BUILD_FROM

ARG EUFY_SECURITY_WS_VERSION

WORKDIR /usr/src/app
RUN \
    set -x \
    && apk add --no-cache \
    nodejs \
    npm \
    jq \
    && npm install --force \
    "eufy-security-ws@${EUFY_SECURITY_WS_VERSION}"

# Apply P2P session.js patch for malformed packet handling
COPY patch-eufy-client.sh /tmp/
RUN chmod +x /tmp/patch-eufy-client.sh && /tmp/patch-eufy-client.sh && rm /tmp/patch-eufy-client.sh

COPY run.sh /
RUN chmod a+x /run.sh
WORKDIR /data

CMD [ "/run.sh" ]
