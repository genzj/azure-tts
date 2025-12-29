# 1. Use the specified Azure Linux base image
FROM mcr.microsoft.com/azure-cli:azurelinux3.0

# 2. Update and install curl and jq using tdnf (Azure Linux package manager)
RUN tdnf check-update && \
    tdnf install -y curl jq && \
    tdnf clean all

# 3. Set the working directory and copy all .sh files
WORKDIR /app
COPY *.sh ./

# Ensure scripts have execution permissions
RUN chmod +x /app/*.sh

VOLUME [ "/input" ]

# 4 & 5. Use ENTRYPOINT with a default CMD
# This allows the container to run recreate-azure-tts.sh by default,
# but lets users override it by providing a different script name.
ENTRYPOINT ["/bin/bash"]
CMD ["/app/tts-recreate.sh"]