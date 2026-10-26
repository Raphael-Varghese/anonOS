FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install Buildroot host dependencies, compilation tools, and QEMU
RUN apt-get update && apt-get install -y \
    build-essential \
    libncurses-dev \
    bc \
    cpio \
    rsync \
    unzip \
    wget \
    file \
    git \
    qemu-system-x86 \
    flex \
    bison \
    libssl-dev \
    tmux \
    sudo \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root user (Buildroot fails if compiled directly as root)
ARG USERNAME=builder
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m $USERNAME \
    && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

# Set up working directory structures
WORKDIR /workspace
RUN chown -R $USERNAME:$USERNAME /workspace

USER $USERNAME

# Default command to drop into a bash shell
CMD ["/bin/bash"]
