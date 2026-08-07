# Reproducible HOST-level build environment for NebulaOS firmware.
#
# What this is NOT: the actual cross-compilation toolchain. The Buildroot/
# kernel cross-compile runs inside pellcorp/k1-bash-build (a MIPS toolchain
# image, invoked by scripts/build/02-*.sh through 05-*.sh) and GuppyScreen
# builds inside ghcr.io/coreflake1/guppydev (invoked by
# scripts/build/04-cross-compile-app-stack.sh) - both pulled automatically,
# pinned by tag in the scripts that use them. This image exists one level
# up: it's what runs the numbered build scripts THEMSELVES, so a developer
# never has to manually apt-get/brew install git, curl, or a matching
# coreutils version on their own machine to get a working `./build.sh`.
#
# Talks to the HOST's Docker daemon via a mounted socket (see the `docker
# run` invocation documented in ../build.sh's own header) - it does not run
# Docker-in-Docker, and does not itself contain a MIPS toolchain.
FROM debian:bookworm-slim

# Exact host-level tool list this build actually invokes outside of the
# nested pellcorp/k1-bash-build and guppydev containers - verified by
# grepping scripts/build/*.sh and scripts/firmware/*.sh for tool names, not
# guessed. `docker.io` installs the `docker` client binary this image uses
# to talk to the mounted host socket below - its bundled dockerd is simply
# never started, no daemon runs inside this container.
RUN apt-get update && apt-get install -y --no-install-recommends \
		git \
		docker.io \
		curl \
		ca-certificates \
		tar \
		gzip \
		unzip \
		coreutils \
		openssh-client \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /work

ENTRYPOINT ["sh", "-c"]
