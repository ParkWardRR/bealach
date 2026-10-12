# Reproducible Linux environment for Bealach's local CI (ci/check.sh).
#
# Not a product image: this only exists so the same checks can run on macOS
# (natively) and on Linux (this container) without touching any hosted CI.
#
#   docker build -t bealach-ci ci
#   docker run --rm -v "$PWD":/work -w /work bealach-ci
#
# On macOS the Docker engine is expected to be OrbStack (https://orbstack.dev).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:/usr/local/go/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash \
      build-essential \
      ca-certificates \
      clang \
      curl \
      git \
      make \
      python3 \
      golang-go \
    && rm -rf /var/lib/apt/lists/*

# Cargo.lock is format v4, which needs cargo 1.78+; rustup beats the distro rustc.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain stable --no-modify-path \
    && rustup --version && cargo --version && go version

WORKDIR /work
CMD ["ci/check.sh"]
