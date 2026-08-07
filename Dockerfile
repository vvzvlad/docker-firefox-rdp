FROM ubuntu:24.04

LABEL org.opencontainers.image.title="docker-firefox-rdp" \
      org.opencontainers.image.description="Single web page (e.g. a Grafana dashboard) shown by Firefox in kiosk mode, exposed over RDP" \
      org.opencontainers.image.source="https://gitea.vvzvlad.xyz/projects/docker-firefox-rdp" \
      org.opencontainers.image.licenses="MIT"

# Build-time only: must not leak into the runtime environment of the container.
ARG DEBIAN_FRONTEND=noninteractive

ENV LANG="en_US.UTF-8" \
    LANGUAGE="en_US.UTF-8" \
    LC_ALL="en_US.UTF-8" \
    RESOLUTION="1366x768x24" \
    SCALE="1" \
    URL="about:blank" \
    VNC_PASSWORD="" \
    RDP_SECURITY_LAYER="negotiate" \
    RDP_CRYPT_LEVEL="high" \
    X11VNC_QUIET="-q"

# Everything in one layer: apt-get clean / rm -rf of the lists only shrinks the image if
# it happens in the same layer that created them.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates gpg wget; \
    \
    # Mozilla APT repository: the distro "firefox" package is only a snap wrapper.
    install -d -m 0755 /etc/apt/keyrings; \
    wget -qO /etc/apt/keyrings/packages.mozilla.org.asc \
        https://packages.mozilla.org/apt/repo-signing-key.gpg; \
    # The whole keyring is validated, not just its first key: everything in a signed-by file
    # is trusted by apt, so a tampered response carrying the genuine key plus an extra one
    # would otherwise pass and make apt trust the attacker's key too. One fingerprint is
    # collected per primary ("pub") key and the resulting set must equal exactly the one
    # expected fingerprint - a spliced-in extra key, or none at all, fails the build.
    #
    # The expected fingerprint is a shell literal here and deliberately NOT an ARG:
    # --build-arg would let a build weaken its own supply-chain check.
    expected_fpr=35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3; \
    fprs="$(gpg --show-keys --with-colons --fingerprint \
        /etc/apt/keyrings/packages.mozilla.org.asc \
        | awk -F: '/^pub:/ { primary = 1; next } /^fpr:/ && primary { print $10; primary = 0 }')"; \
    if [ "$fprs" != "$expected_fpr" ]; then \
        echo "FATAL: unexpected key set in the Mozilla APT keyring" >&2; \
        echo "  expected exactly one key: $expected_fpr" >&2; \
        echo "  got:" >&2; echo "$fprs" | sed 's/^/    /' >&2; \
        exit 1; \
    fi; \
    echo "Mozilla signing keyring verified: exactly one key, $expected_fpr"; \
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list; \
    # Outrank the distro snap wrapper (1:1snap1-0ubuntu5) with the real Mozilla build.
    printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
        > /etc/apt/preferences.d/mozilla; \
    \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        awesome \
        dbus-x11 \
        firefox \
        fonts-dejavu-core \
        fonts-liberation \
        fonts-noto-color-emoji \
        locales \
        supervisor \
        tzdata \
        x11-utils \
        x11vnc \
        xrdp \
        xvfb; \
    \
    # LANG=en_US.UTF-8 is only usable once the locale has actually been generated.
    locale-gen en_US.UTF-8; \
    \
    # gpg was only needed to verify the repository key above.
    apt-get purge -y --auto-remove gpg; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /var/log/apt/* /tmp/* /var/tmp/*

# uid/gid 1000 must be preserved: existing production volumes at /home/user are owned by
# 1000:1000 and would become unreadable otherwise. The base image already hands uid 1000 to
# its own "ubuntu" user, so that user has to go first.
RUN set -eux; \
    userdel -r ubuntu 2>/dev/null || true; \
    groupadd -g 1000 user; \
    useradd -m -u 1000 -g 1000 -s /bin/bash user; \
    # Needed by the xrdp/sesman login path. This is a well-known default and should be
    # overridden (or the port kept off untrusted networks) in any real deployment.
    { echo "user"; echo "user"; } | passwd user

COPY conf/ /

RUN set -eux; \
    chmod 0755 \
        /usr/local/bin/docker-entrypoint.sh \
        /usr/local/bin/healthcheck.sh \
        /usr/local/bin/start-firefox \
        /usr/local/bin/supervisor-fatal-exit \
        /usr/local/bin/wait-for-x \
        /etc/xrdp/startwm.sh; \
    # security_layer=negotiate needs a certificate. The package normally symlinks the
    # snakeoil pair (ssl-cert is a hard dependency of xrdp), so this branch is not expected
    # to fire; only generate - and set permissions - when it did not, so the packaged files
    # keep their own ownership.
    #
    # root:xrdp 0440 on the key follows the convention xrdp's own packaging uses
    # (snakeoil is root:ssl-cert 0640) rather than root:root 0600, which only works because
    # supervisord happens to run xrdp as root. Under any unprivileged xrdp an unreadable key
    # makes TLS silently degrade to plain RDP - exactly the failure this change fixes.
    if [ ! -s /etc/xrdp/cert.pem ] || [ ! -s /etc/xrdp/key.pem ]; then \
        rm -f /etc/xrdp/cert.pem /etc/xrdp/key.pem; \
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=docker-firefox-rdp" \
            -keyout /etc/xrdp/key.pem -out /etc/xrdp/cert.pem; \
        chown root:xrdp /etc/xrdp/key.pem /etc/xrdp/cert.pem \
            || chown root:root /etc/xrdp/key.pem /etc/xrdp/cert.pem; \
        chmod 0440 /etc/xrdp/key.pem; \
        chmod 0444 /etc/xrdp/cert.pem; \
    fi; \
    test -s /etc/xrdp/cert.pem && test -s /etc/xrdp/key.pem

# 5900 is only reachable from outside the container when VNC_PASSWORD (or VNC_PASSWORD_FILE)
# is set; without one x11vnc is bound to localhost. Declared so `docker run -P` publishes it
# in the documented direct-VNC scenario.
EXPOSE 3389 5900

# Firefox on a cold profile plus the xrdp/x11vnc chain need a while before the first probe.
#
# --timeout is 20s, comfortably above the sum of the probe timeouts inside the script (5s for
# X, 4s for 3389, 4s for 5900). When docker kills a probe for taking too long it records an
# empty Output in `docker inspect`, so a too-tight timeout would throw away the diagnosis in
# exactly the situation where the healthcheck finally has something to say.
HEALTHCHECK --interval=30s --timeout=20s --start-period=60s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
