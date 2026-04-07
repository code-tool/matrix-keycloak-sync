FROM ghcr.io/element-hq/matrix-authentication-service:1.10.0 AS mas-cli

FROM debian:bookworm-slim

RUN apt update && \
    apt install curl jq -y

WORKDIR /opt/sync

COPY --chmod=755 keycloak_matrix_sync.sh .
#COPY keycloak_matrix_sync.conf .
#COPY mas-config.yaml .

COPY --from=mas-cli /usr/local/bin/mas-cli /usr/local/bin/mas-cli
