# Build-once container image shared by the runner_binary molecule
# scenarios (default + remove). Lives at the parent of both scenario
# directories rather than duplicated inside each, so the image
# definition has a single source of truth.
#
# Why a custom Dockerfile instead of plain `docker.io/library/ubuntu:24.04`:
# the ubuntu:24.04 base image as of 2026-06 no longer ships /usr/bin/python3
# in its default layer. Ansible modules execute on the managed host via a
# Python interpreter, so the first ansible.builtin.* task fails at
#   /bin/sh: 1: /usr/bin/python3: not found
# before prepare.yml gets a chance to apt-install anything. Baking python3
# (plus the tar/gzip/sudo set the role's register direction depends on)
# into the image at build time gives a working interpreter from container
# create onward.
#
# Why these four packages:
#   python3  - Ansible AnsiballZ interpreter on the managed host.
#   sudo     - The role's `become: true` / `become_user:` tasks rely on
#              sudo being present on the target.
#   tar      - ansible.builtin.unarchive shells out to the gtar/tar
#              binary; the bare image ships without it under
#              --no-install-recommends.
#   gzip     - community.general.archive (used by the shared fixture
#              fileserver include to build the fake tarball) needs gzip
#              when format=gz.
#
# Build once via:
#   docker build \
#       -t common-ansible/runner-binary-base:24.04 \
#       -f Tests/molecule/runner_binary/Dockerfile \
#       Tests/molecule/runner_binary
# Both scenarios consume the resulting tag via `pre_build_image: true`.
FROM docker.io/library/ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      python3 sudo tar gzip \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
