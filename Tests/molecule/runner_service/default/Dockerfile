# Build-once container image for the runner_service molecule scenarios.
#
# Why a custom Dockerfile instead of plain `docker.io/library/ubuntu:24.04`:
# the ubuntu:24.04 base image no longer ships systemd or any init binary
# at `/sbin/init` / `/usr/sbin/init`, so a `command: /sbin/init` against
# the bare base fails container create with
#   stat /sbin/init: no such file or directory
# before molecule's prepare step gets a chance to apt-install anything.
# Installing systemd at image-build time gives a working PID-1 entrypoint
# the scenario can rely on from container create onward.
#
# Why these four packages:
#   systemd       - the init implementation; ships /lib/systemd/systemd
#                   plus the journald / logind units the runner unit
#                   files depend on.
#   systemd-sysv  - provides the /sbin/init symlink that molecule's
#                   container `command:` targets. Without sysv the init
#                   binary lives only at /lib/systemd/systemd and the
#                   conventional /sbin/init path is absent.
#   sudo          - the role's become: true tasks rely on it being
#                   present on the target.
#   python3       - Ansible modules execute on the target via a Python
#                   interpreter. ubuntu:24.04 ships without python3 in
#                   --no-install-recommends mode, so the first
#                   ansible.builtin.user task fails at /usr/bin/python3
#                   not found unless python is baked in here.
#
# STOPSIGNAL SIGRTMIN+3 is the systemd-as-PID-1 contract: docker stop
# delivers this signal so systemd shuts down units cleanly instead of
# being killed mid-run.
FROM docker.io/library/ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      systemd systemd-sysv sudo python3 \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
