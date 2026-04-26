# 1. Use the specified Azure Linux base image
FROM mcr.microsoft.com/azure-cli:azurelinux3.0

# Docker sets these automatically during buildx sessions
ARG TARGETARCH

# 2. Update and install curl, jq, gettext, and nginx using tdnf (Azure Linux package manager)
RUN tdnf check-update && \
    tdnf install -y curl jq gettext nginx && \
    tdnf clean all

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
