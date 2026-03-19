# 1. Use the specified Azure Linux base image
FROM mcr.microsoft.com/azure-cli:azurelinux3.0

# Docker sets these automatically during buildx sessions
ARG TARGETARCH

# 2. Update and install curl and jq using tdnf (Azure Linux package manager)
RUN tdnf check-update && \
    tdnf install -y curl jq gettext && \
    tdnf clean all

# 3. Install Caddy
# Map Docker arch names to Caddy's release naming convention
# x86_64 -> amd64 | arm64 -> arm64
RUN if [ "$TARGETARCH" = "amd64" ]; then \
    export CADDY_ARCH="amd64"; \
    elif [ "$TARGETARCH" = "arm64" ]; then \
    export CADDY_ARCH="arm64"; \
    fi && \
    echo "ARCH: $TARGETARCH" && \
    curl -L "https://caddyserver.com/api/download?os=linux&arch=${CADDY_ARCH}" -o /usr/bin/caddy && \
    chmod +x /usr/bin/caddy && \
    /usr/bin/caddy version

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=300s --retries=3 \
    CMD curl -f http://localhost/healthz || exit 1

# 4. Set the working directory and copy all .sh files
WORKDIR /app
COPY *.sh ./
COPY *.template ./
COPY data/ ./data/

# Ensure scripts have execution permissions
RUN chmod +x /app/*.sh

VOLUME [ "/input" ]

# 4 & 5. Use ENTRYPOINT with a default CMD
# This allows the container to run recreate-azure-tts.sh by default,
# but lets users override it by providing a different script name.
ENTRYPOINT ["/bin/bash"]
CMD ["/app/tts-recreate.sh"]