#!/bin/bash
# Container healthcheck: X is up, Firefox is alive, and both hops of the RDP path - xrdp
# itself and the x11vnc server it proxies to - accept connections.
set -uo pipefail

DISPLAY="${DISPLAY:-:1}"
RDP_PORT="${RDP_PORT:-3389}"
VNC_PORT="${VNC_PORT:-5900}"
# Written by the entrypoint when it could not synchronise [xrdp1] password= in xrdp.ini with
# the password it gave x11vnc. Its content is a plain-language reason; it never holds the
# password itself.
XRDP_DESYNC_MARKER="/run/xrdp-password-desync"
status=0

fail() { echo "healthcheck: $*" >&2; status=1; }

# Every probe is individually bounded, and the sum of the bounds stays inside the HEALTHCHECK
# --timeout (20s). This matters precisely in the case the probes exist for: when both hops are
# down, each probe burns its full timeout, and if the total exceeds the docker timeout the
# probe is killed - `docker inspect` then records an empty Output instead of the fail lines
# below, losing the one diagnosis that was worth having.
X_TIMEOUT=5
TCP_TIMEOUT=4
RFB_TIMEOUT=4

# In both probes the port is passed as an argument rather than interpolated into the code
# string, so its value can never be evaluated as shell code.
tcp_accepts() {
    timeout "$TCP_TIMEOUT" bash -c 'exec 3<>/dev/tcp/127.0.0.1/"$1"' _ "$1" 2>/dev/null
}

# Connect and require the RFB protocol banner, not just a completed handshake. Under the
# RLIMIT_NOFILE bug described in the entrypoint, LibVNCServer lets the kernel finish the TCP
# handshake but never services the socket, so it never sends "RFB 003.00x" - an accept()-only
# check cannot tell that apart from a working server.
speaks_rfb() {
    timeout "$RFB_TIMEOUT" bash -c '
        exec 3<>/dev/tcp/127.0.0.1/"$1" || exit 1
        IFS= read -r -n 4 -u 3 banner || exit 1
        [[ "$banner" == "RFB " ]]
    ' _ "$1" 2>/dev/null
}

# xdpyinfo has no timeout of its own, and a half-dead X server can leave it blocked on the
# socket for as long as it likes.
timeout "$X_TIMEOUT" xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 ||
    fail "X server on $DISPLAY is not answering"

# Scan /proc directly instead of pulling in pgrep semantics. The parent process reports
# comm "firefox-bin" (argv[0] is still "firefox"); its children rename themselves to
# "Web Content", "Socket Process" and friends, so they do not produce false positives.
firefox_alive() {
    local proc comm
    for proc in /proc/[0-9]*; do
        [[ -r "$proc/comm" ]] || continue
        comm="$(<"$proc/comm")"
        [[ "$comm" == "firefox" || "$comm" == "firefox-bin" ]] && return 0
    done
    return 1
}

firefox_alive || fail "no firefox process is running"

tcp_accepts "$RDP_PORT" || fail "TCP port $RDP_PORT (xrdp) is not accepting connections"

# x11vnc is checked separately: xrdp keeps listening on 3389 even when the VNC server behind
# it is gone, so without this probe a dead or wedged x11vnc leaves the container "healthy"
# while every RDP session shows a black screen.
speaks_rfb "$VNC_PORT" || fail "x11vnc on port $VNC_PORT is not serving the RFB protocol"

# None of the probes above can see a password mismatch between xrdp.ini and x11vnc: the RFB
# probe reads the 4-byte banner and closes before authenticating, so xrdp keeps answering on
# 3389, x11vnc keeps speaking RFB, and every actual RDP session still dies with "VNC password
# failed". Without this the only trace is a single entrypoint WARNING, gone from `docker logs`
# within a day, on a display nobody looks at until somebody complains.
if [[ -e "$XRDP_DESYNC_MARKER" ]]; then
    # First line only, and only if it is readable - the marker existing is the signal, its
    # content is a convenience. `read` returns non-zero on a file with no final newline.
    reason=""
    IFS= read -r reason < "$XRDP_DESYNC_MARKER" 2>/dev/null || true
    fail "RDP password mismatch: ${reason:-see the entrypoint warnings in 'docker logs'}"
fi

exit "$status"
