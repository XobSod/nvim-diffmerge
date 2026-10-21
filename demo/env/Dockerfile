# VHS (ttyd, ffmpeg, Chromium) with git, Neovim and gifsicle: demo/render.sh renders the tapes with it.
FROM ghcr.io/charmbracelet/vhs:v0.12.1
ARG NVIM_VERSION=v0.12.6
ARG TARGETARCH
RUN case "$TARGETARCH" in arm64) arch=arm64 ;; *) arch=x86_64 ;; esac \
  && apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl gifsicle git \
  && rm -rf /var/lib/apt/lists/* \
  && curl -fsSL "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-${arch}.tar.gz" \
    | tar -xz -C /opt \
  && ln -s "/opt/nvim-linux-${arch}/bin/nvim" /usr/local/bin/nvim
