# Isolated per-LLVM test cell for the JIT. src/jit links the monolithic
# libLLVM via @[Link("LLVM")], and the binding version is picked at compile
# time from LLVM_CONFIG (same contract as tasks/build.rake), so the axis we
# need to cover locally is the LLVM version. The base image is the official
# Crystal image (noble); its Ubuntu repo only ships llvm 17/18, everything
# newer comes from apt.llvm.org.
#
# Build one cell (normally via `rake matrix:build`):
#   docker build --build-arg LLVM=21 -t lua5-matrix:llvm21 docker/matrix
#
# The repo is NOT copied into the image: specs run against a read-only bind
# mount, so images are only rebuilt when the Crystal or LLVM version changes
# and no build artifacts leak back into the working tree.

ARG CRYSTAL=crystallang/crystal:1.21
FROM ${CRYSTAL}

ARG LLVM=20

# The codename comes from the image itself: the official Crystal images ride
# different Ubuntu releases (1.21 -> noble, 1.22 -> resolute).
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates wget g++ \
 && wget -qO /etc/apt/trusted.gpg.d/llvm.asc https://apt.llvm.org/llvm-snapshot.gpg.key \
 && . /etc/os-release \
 && echo "deb http://apt.llvm.org/${VERSION_CODENAME}/ llvm-toolchain-${VERSION_CODENAME}-${LLVM} main" \
      > /etc/apt/sources.list.d/llvm.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends llvm-${LLVM}-dev \
 && rm -rf /var/lib/apt/lists/*

# Runtime lib dir is added to LD_LIBRARY_PATH so the spec/binary finds
# libLLVM-XX.so regardless of where the package put it.
ENV LLVM_CONFIG=/usr/lib/llvm-${LLVM}/bin/llvm-config \
    LIBRARY_PATH=/usr/lib/llvm-${LLVM}/lib \
    LD_LIBRARY_PATH=/usr/lib/llvm-${LLVM}/lib
