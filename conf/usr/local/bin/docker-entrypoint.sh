#!/bin/bash
# Container entrypoint: migrate legacy on-volume config aside, set up VNC authentication,
# then hand over to supervisord (or whatever was passed as the command).
set -euo pipefail

USER_HOME="/home/user"
XRDP_INI="/etc/xrdp/xrdp.ini"
X11VNC_PASSWD_FILE="/run/x11vnc/passwd"
# Legacy docker-secret path. Must already be in x11vnc/vncpasswd format (created with
# `x11vnc -storepasswd`), not plaintext. Prefer VNC_PASSWORD_FILE, which takes plaintext and
# can therefore also be synchronised into xrdp.ini.
X11VNC_SECRET_FILE="/run/secrets/vncpasswd"
# Dropped when the x11vnc password could not be written into [xrdp1] password= of xrdp.ini.
# healthcheck.sh reports the container unhealthy while it exists, because that failure is
# otherwise invisible: every RDP session dies with "VNC password failed" while every other
# probe in the healthcheck passes (the 5900 one reads the RFB banner and closes before
# authenticating). /run is tmpfs, so the marker cannot outlive the container - only a
# `docker restart`, which is why every start removes it again first.
XRDP_DESYNC_MARKER="/run/xrdp-password-desync"
# Fixed suffix, so the backup of a given file always has one predictable name. An existing
# backup is never overwritten; it gets a timestamp appended instead (see migrate_aside).
LEGACY_SUFFIX=".legacy-2024"
# The values xrdp accepts for security_layer= and crypt_level=. Anything else is caught here
# rather than handed to xrdp, which would silently make its own choice of an unrecognised
# value. Both lists are lower case; the comparison is done on a lower-cased copy of the
# variable, matching xrdp's own case-insensitive parsing.
RDP_SECURITY_LAYERS="tls rdp negotiate"
RDP_CRYPT_LEVELS="none low medium high fips"

# Highest open-file soft limit x11vnc can cope with. LibVNCServer (0.9.14 on noble) sizes
# its poll set from RLIMIT_NOFILE, and docker's default soft limit of ~1073741816 makes it
# stop servicing its listening socket entirely: the kernel still completes the TCP
# handshake, but the server never sends the RFB greeting, so xrdp's libvnc hop hangs
# forever on "VNC tcp connected" and the RDP session shows nothing. Capping the limit here
# fixes it for supervisord and every child it spawns.
NOFILE_LIMIT=65536

log() { echo "[entrypoint] $*"; }

# Only ever lowered, so it can never exceed the hard limit.
nofile_soft="$(ulimit -Sn)"
if [[ "$nofile_soft" == "unlimited" ]] || (( nofile_soft > NOFILE_LIMIT )); then
    if ulimit -Sn "$NOFILE_LIMIT" 2>/dev/null; then
        log "open-file soft limit lowered from $nofile_soft to $NOFILE_LIMIT (x11vnc requirement)"
    else
        log "WARNING: could not lower the open-file soft limit ($nofile_soft); x11vnc may refuse to serve clients"
    fi
fi

# ---------------------------------------------------------------------------
# Stale X state
#
# `docker restart` (as opposed to recreate) keeps /tmp, so the lock file and the socket of
# the previous Xvfb survive. Xvfb only reclaims a lock whose recorded pid is dead, and
# container pids are low and readily reused, so it can decide the display is still in use and
# abort with "Server is already active for display 1". Nothing else owns these paths - the
# only X server in the container is the one supervisord is about to start.
#
# Not fatal: `rm -f` still returns 1 when the path cannot be unlinked at all (a read-only
# /tmp, or /tmp/.X11-unix bind-mounted from the host), and under `set -e` that killed the
# entrypoint before supervisord ever started. A stale lock is a maybe-problem; an entrypoint
# that exits is a certain one, and watchtower deploys :latest unattended.
# ---------------------------------------------------------------------------
if rm -f /tmp/.X1-lock /tmp/.X11-unix/X1; then
    log "cleared any stale X lock and socket for display :1"
else
    log "WARNING: could not clear /tmp/.X1-lock and /tmp/.X11-unix/X1 (read-only /tmp, or" \
        "one of them bind-mounted from the host). Startup continues; if a stale lock is" \
        "actually left over, Xvfb fails with 'Server is already active for display 1' and" \
        "the fix is to recreate the container instead of restarting it."
fi

# Same class of problem for xrdp, and /run survives `docker restart` too. Verified on this
# image: with -nodaemon/--nodaemon neither xrdp nor xrdp-sesman ever writes a pid file, so
# there is normally nothing here to go stale. But if one does appear - somebody debugging
# with a plain `xrdp` inside the container, or a future config change that drops -nodaemon -
# both refuse to start for good: they only check that the file exists, not whether the pid
# in it is still alive ("xrdp-sesman is already running", exit 1, verified with a dead pid).
# That would strand port 3389 permanently, and with [eventlistener:fatal-exit] in place it
# would turn into an endless container restart loop. Nothing else in this container owns
# these two paths, so clearing them is free insurance.
#
# Non-fatal for the same reason as the X paths above: free insurance must not be able to cost
# the whole container when /run is read-only or mounted from outside.
if ! rm -f /run/xrdp/xrdp.pid /run/xrdp/xrdp-sesman.pid; then
    log "WARNING: could not clear the xrdp pid files under /run/xrdp (read-only /run?)." \
        "Startup continues; if one of them is stale, xrdp or xrdp-sesman refuses to start" \
        "('already running') and port 3389 stays dead until the container is recreated."
fi

# ---------------------------------------------------------------------------
# Legacy volume migration
#
# /home/user is a volume in production and still holds the 2024 layout: a ~/firefox launch
# script and a ~/.config/awesome/rc.lua that starts Firefox itself via os.execute. A user
# rc.lua shadows the image's /etc/xdg/awesome/rc.lua, so leaving it in place would spawn a
# second Firefox next to the supervised one and deadlock on the profile lock.
#
# Migration is driven by a signature, not by "the file exists": an operator may legitimately
# have put their own rc.lua in the volume, and renaming that away on every start would
# silently discard their customisation.
# ---------------------------------------------------------------------------
#
# A failed migration is never fatal. `mv` cannot rename a path that is itself a bind mount
# (EBUSY: `-v ./rc.lua:/home/user/.config/awesome/rc.lua` is a perfectly reasonable way to
# ship a config), and a read-only volume fails the same way. Under `set -e` that used to kill
# the entrypoint before supervisord ever started - a total outage caused by a config detail,
# on hosts where watchtower deploys unattended. Returns non-zero so the caller can explain
# what the consequence of the failure is for that particular file.
migrate_aside() {
    local path="$1" backup="$1$LEGACY_SUFFIX"

    [[ -e "$path" ]] || return 0

    # Never overwrite and never delete an existing backup: it may be the only copy of
    # something the operator still wants. Park it under a timestamp instead.
    if [[ -e "$backup" ]]; then
        local dated
        dated="$backup.$(date +%Y%m%d-%H%M%S)"
        log "backup $backup already exists, moving it to $dated"
        if ! mv -- "$backup" "$dated"; then
            log "WARNING: could not move $backup out of the way, so $path was left alone"
            return 1
        fi
    fi

    log "migrating legacy file $path -> $backup"
    if ! mv -- "$path" "$backup"; then
        log "WARNING: could not migrate $path aside. A path that is itself a bind mount" \
            "cannot be renamed (EBUSY), and neither can anything on a read-only volume." \
            "Startup continues with the file still in place."
        return 1
    fi
}

LEGACY_RC_LUA="$USER_HOME/.config/awesome/rc.lua"
if [[ -e "$LEGACY_RC_LUA" ]]; then
    if [[ -d "$LEGACY_RC_LUA" ]]; then
        # grep would print "Is a directory" and exit non-zero here, which used to look
        # exactly like "no legacy launcher in it" and take the custom-rc.lua branch.
        log "WARNING: $LEGACY_RC_LUA is a directory, not a Lua file. awesome cannot load it" \
            "and falls back to the image's /etc/xdg/awesome/rc.lua. Nothing was migrated;" \
            "remove the directory to silence this."
    # The only thing that makes the on-volume rc.lua actively harmful is the self-launch:
    # os.execute() starting the 2024 ~/firefox script, which would give us a second,
    # unsupervised Firefox fighting the supervised one over the profile lock.
    elif grep -Eq 'os\.execute[^)]*/home/user/firefox' "$LEGACY_RC_LUA"; then
        log "legacy self-launching rc.lua detected (os.execute of /home/user/firefox)"
        if ! migrate_aside "$LEGACY_RC_LUA"; then
            log "WARNING: the legacy rc.lua is still in place and still shadows" \
                "/etc/xdg/awesome/rc.lua, so awesome will start a second, unsupervised" \
                "Firefox. Expect a modal 'Firefox is already running' dialog over the" \
                "dashboard. Remove or rename $LEGACY_RC_LUA on the volume by hand."
        fi
    elif grep -qi firefox "$LEGACY_RC_LUA"; then
        # Matches the known 2024 signature? No. Mentions Firefox at all? Yes - so it very
        # possibly launches one by a route this check does not recognise (awful.spawn,
        # awful.util.spawn, a different path, a launch split across lines). Keeping the file
        # is still the right call - it is the operator's, on the operator's volume - but it
        # must not be kept silently.
        log "WARNING: $LEGACY_RC_LUA is not the known legacy launcher, but it does mention" \
            "'firefox'. It shadows the image's /etc/xdg/awesome/rc.lua and was KEPT as-is."
        log "WARNING: if it starts Firefox itself (os.execute, awful.spawn, ...) there will" \
            "be two Firefox instances: the supervised one and an unsupervised one fighting" \
            "over the same profile lock, which shows up as a modal 'Firefox is already" \
            "running' dialog that nobody can dismiss on a wall display."
        log "WARNING: check it, and if it does launch Firefox, delete that launch (the image" \
            "starts Firefox under supervisord) or move the whole file aside:" \
            "mv $LEGACY_RC_LUA $LEGACY_RC_LUA$LEGACY_SUFFIX"
    else
        log "custom rc.lua detected at $LEGACY_RC_LUA and kept as-is (no legacy" \
            "os.execute launcher in it, no mention of firefox); note it shadows the image's" \
            "/etc/xdg/awesome/rc.lua"
    fi
fi

# ~/firefox is inert once rc.lua no longer executes it, so it is only ever moved aside for
# tidiness - never deleted, because it is on the operator's volume and may have been edited.
# Failing to move it is therefore not even a degradation, just noise in the log.
if [[ -e "$USER_HOME/firefox" ]]; then
    migrate_aside "$USER_HOME/firefox" || true
fi

# Rewrite `key=value` in xrdp.ini in place.
#
# The file is re-secured after every rewrite: `mv` of a temp file replaces the inode, so the
# packaged permissions are gone and the default umask would leave it 0644 - world-readable.
# That matters because [xrdp1] password= holds the VNC password in plaintext, and every
# process in the container (Firefox under uid 1000 included) could read it. root:xrdp 0640
# follows the package convention for xrdp's own config; xrdp and xrdp-sesman run as root
# under supervisord, so they can read it either way.
#
# Matching is deliberately narrow (`key=` at the very start of a line), so it is counted
# first: a key that is absent, commented out, or written as `key = value` would otherwise be
# rewritten into nothing at all while the caller happily logged success. These variables
# exist to recover a display that cannot connect, so a silent no-op is the worst outcome.
#
# Returns non-zero when the value was NOT written, so no caller can claim otherwise. Never
# fatal: every failure here leaves a working (if differently configured) xrdp behind, and a
# container that starts is worth more than one that is exactly right.
set_xrdp_ini() {
    local key="$1" value="$2" matches original_lines new_lines

    matches="$(XRDP_KEY="$key" awk '
        BEGIN { key = ENVIRON["XRDP_KEY"] }
        index($0, key "=") == 1 { n++ }
        END { print n + 0 }
    ' "$XRDP_INI")"

    if (( matches == 0 )); then
        log "WARNING: $XRDP_INI has no line starting with '$key=', so that setting was NOT" \
            "applied and xrdp keeps whatever value is in the file. Note that only" \
            "'$key=value' is recognised, not '$key = value' with spaces. Fix the file in the" \
            "image, or set the value there directly."
        return 1
    fi

    original_lines="$(wc -l < "$XRDP_INI")"

    # umask in a subshell, because the redirection below creates the temp file with the
    # process umask (0022 -> 0644) and it already contains the plaintext password. Without
    # this the password is world-readable for the short window between awk writing the file
    # and the chmod after `mv`. `mv` carries the 0600 over, so the file is never 0644.
    #
    # The subshell's status is checked, and errexit cannot be relied on to do it: every caller
    # invokes this function from an `if` condition, which suppresses errexit for the whole
    # dynamic extent of the call. A short write - the writable layer out of space (the
    # container log grows without bound under docker's default json-file driver), a quota, awk
    # OOM-killed - leaves a PARTIAL config in the temp file, and `mv` is a rename within one
    # filesystem, so it needs no space at all and would install it happily. That is the worst
    # failure this image has: an xrdp.ini that lost its [xrdp1] section still leaves xrdp
    # listening on 3389 (the port in the file is xrdp's own default), so every healthcheck
    # probe passes and the container reports running + healthy while no RDP session can start -
    # and the truncated file sits in the writable layer, surviving every `docker restart`
    # until the container is recreated. Nothing that failed validation may reach $XRDP_INI.
    if ! (
        umask 0077
        XRDP_KEY="$key" XRDP_VALUE="$value" awk '
            BEGIN { key = ENVIRON["XRDP_KEY"]; value = ENVIRON["XRDP_VALUE"] }
            index($0, key "=") == 1 { print key "=" value; next }
            { print }
        ' "$XRDP_INI" > "$XRDP_INI.tmp"
    ); then
        rm -f "$XRDP_INI.tmp"
        log "WARNING: could not write $XRDP_INI.tmp, so '$key' was NOT applied (no space left" \
            "on the writable layer, a quota, or awk was killed). $XRDP_INI was left exactly" \
            "as it was and startup continues."
        return 1
    fi

    # Second line of defence against the same failure, for the case where awk exits 0 but the
    # tail of its output was lost when the file was closed. The rewrite is strictly
    # line-for-line, so the line count is an exact invariant - unlike the byte size, which a
    # shorter value legitimately shrinks. awk terminates its last line even when the input did
    # not, so the result may be one newline longer than the original; anything else means the
    # file is not a complete copy and must not be installed.
    new_lines="$(wc -l < "$XRDP_INI.tmp")"
    if (( new_lines != original_lines && new_lines != original_lines + 1 )); then
        rm -f "$XRDP_INI.tmp"
        log "WARNING: the rewritten $XRDP_INI came out with $new_lines lines instead of" \
            "$original_lines, so it was DISCARDED and '$key' was NOT applied. $XRDP_INI is" \
            "untouched. This means the write was cut short - check free space on the" \
            "container's writable layer."
        return 1
    fi

    # Replacing the file by rename fails with EBUSY when xrdp.ini is itself a bind mount
    # (`-v ./xrdp.ini:/etc/xrdp/xrdp.ini`), and mv only falls back to copying across
    # filesystems (EXDEV), not for EBUSY. Under `set -e` that killed the entrypoint before
    # supervisord ever started - the whole dashboard down because one file was mounted. Warn
    # and carry on instead, and take the temp file with its plaintext copy of the password
    # away again.
    if ! mv "$XRDP_INI.tmp" "$XRDP_INI"; then
        rm -f "$XRDP_INI.tmp"
        log "WARNING: could not replace $XRDP_INI, so '$key' was NOT applied (a file that is" \
            "itself a bind mount cannot be replaced by rename, and neither can anything on a" \
            "read-only filesystem). Startup continues with the file as it is."
        return 1
    fi

    # Past this point the new content IS installed, so the function has done what it says on
    # the tin and must report success: returning the status of the last chmod would make the
    # caller print "xrdp.ini could NOT be updated ... RDP will fail" about a file that was
    # updated and works. These two only re-secure the fresh inode, so they warn on their own
    # and warn about what actually degrades - the plaintext password becoming readable by
    # uid 1000, the user Firefox runs as.
    if ! chown root:xrdp "$XRDP_INI" 2>/dev/null && ! chown root:root "$XRDP_INI"; then
        log "WARNING: could not chown $XRDP_INI after rewriting it; '$key' WAS applied, but" \
            "check the file's ownership - it holds the VNC password in plaintext."
    fi
    if ! chmod 0640 "$XRDP_INI"; then
        log "WARNING: could not chmod 0640 $XRDP_INI after rewriting it; '$key' WAS applied," \
            "but the file may now be world-readable and it holds the VNC password in" \
            "plaintext, so uid 1000 (the user Firefox runs as) can read it."
    fi

    return 0
}

# healthcheck.sh fails while the marker exists, so that an xrdp.ini that no longer agrees with
# the password x11vnc was given cannot hide behind a healthy container for days. Neither
# function may ever be fatal, and neither may echo the password.
mark_password_desync() {
    if printf '%s\n' "$*" > "$XRDP_DESYNC_MARKER" 2>/dev/null; then
        chmod 0644 "$XRDP_DESYNC_MARKER" 2>/dev/null || true
    else
        log "WARNING: could not create $XRDP_DESYNC_MARKER, so the healthcheck cannot report" \
            "the password mismatch below. It stays visible only in this log."
    fi
}

# Called on every start before the password is set up: a marker left by a previous start is
# stale as soon as this one gets it right, and /run survives `docker restart`.
clear_password_desync() {
    if ! rm -f "$XRDP_DESYNC_MARKER"; then
        log "WARNING: could not remove $XRDP_DESYNC_MARKER (read-only /run?). If a previous" \
            "start left it there, the healthcheck keeps reporting a password mismatch that" \
            "may already be fixed."
    fi
}

# ---------------------------------------------------------------------------
# RDP security layer and encryption level
#
# `negotiate` now genuinely selects TLS (the image ships a certificate and key_file), and
# that certificate is self-signed, so some clients - mstsc among them - show a one-time
# "identity cannot be verified" prompt, and very old thin-client stacks may not cope with
# crypt_level=high at all. On an unattended wall display a modal dialog is a blank screen
# that nobody dismisses, so both settings must be switchable without rebuilding the image.
# ---------------------------------------------------------------------------

# Lower-case an xrdp enum variable and check it against the values xrdp accepts, leaving the
# result in $normalised (a global, because logging from a command substitution would send the
# warning to the caller instead of the container log).
#
# xrdp compares these with g_strcasecmp, so TLS and tls are the same thing to it and must be
# to us too. An unexpected value is a loud warning and a fallback to the default, never an
# exit: these variables get edited by hand while somebody is trying to get a dead display
# back, and with watchtower deploying :latest unattended, an entrypoint that exits means the
# dashboard does not come up at all. A default-secure setting beats a black screen.
normalise_choice() {
    local name="$1" raw="$2" default="$3" allowed="$4"

    normalised="${raw,,}"
    if [[ " $allowed " != *" $normalised "* ]]; then
        log "WARNING: $name='$raw' is not one of: ${allowed// /, }. Falling back to" \
            "$name='$default'. Nothing else is affected."
        normalised="$default"
    fi
}

normalise_choice RDP_SECURITY_LAYER "${RDP_SECURITY_LAYER:-negotiate}" negotiate "$RDP_SECURITY_LAYERS"
RDP_SECURITY_LAYER="$normalised"
if set_xrdp_ini security_layer "$RDP_SECURITY_LAYER"; then
    log "RDP security layer set to '$RDP_SECURITY_LAYER'"
fi

normalise_choice RDP_CRYPT_LEVEL "${RDP_CRYPT_LEVEL:-high}" high "$RDP_CRYPT_LEVELS"
RDP_CRYPT_LEVEL="$normalised"
if set_xrdp_ini crypt_level "$RDP_CRYPT_LEVEL"; then
    log "RDP encryption level set to '$RDP_CRYPT_LEVEL'"
fi

# ---------------------------------------------------------------------------
# VNC authentication
#
# x11vnc is what the RDP session is actually proxied to (xrdp -> libvnc.so -> x11vnc).
# The password is taken from the first source that is set, in this order:
#   VNC_PASSWORD > VNC_PASSWORD_FILE > PASSWORD (deprecated)
#                > /run/secrets/vncpasswd (legacy) > no password
#
# PASSWORD sits below VNC_PASSWORD_FILE, not above it: it is the deprecated spelling and must
# not outrank the *_FILE convention that replaced it. Whichever source wins is named in the
# log, and every lower-ranked source that was also set is reported as ignored - naming the
# winner, so the message can never blame a variable the operator never set.
# ---------------------------------------------------------------------------

# Whatever a previous start of this container decided is about to be decided again from
# scratch, so its verdict must not survive into this one.
clear_password_desync

if [[ -n "${PASSWORD:-}" ]]; then
    log "WARNING: PASSWORD is deprecated, use VNC_PASSWORD or VNC_PASSWORD_FILE instead"
fi

vnc_password=""
vnc_password_src=""

if [[ -n "${VNC_PASSWORD:-}" ]]; then
    vnc_password="$VNC_PASSWORD"
    vnc_password_src="VNC_PASSWORD"
elif [[ -n "${VNC_PASSWORD_FILE:-}" ]]; then
    vnc_password_src="VNC_PASSWORD_FILE"
    if [[ ! -r "$VNC_PASSWORD_FILE" ]]; then
        log "FATAL: VNC_PASSWORD_FILE=$VNC_PASSWORD_FILE does not exist or is not readable"
        exit 1
    fi

    # A compose `secrets:` mount is mode 0444, so the plaintext is readable by uid 1000 -
    # the user Firefox runs as, rendering untrusted web content. This is the exact mirror
    # image of the legacy /run/secrets/vncpasswd path below, where readability by uid 1000 is
    # a hard requirement because x11vnc itself reads that file; here only the entrypoint
    # (root) ever reads it, so 0400 root:root is the right mode.
    if ! command -v runuser >/dev/null 2>&1; then
        log "WARNING: runuser is not installed, skipping the check of whether" \
            "$VNC_PASSWORD_FILE is readable by uid 1000"
    elif runuser -u user -- test -r "$VNC_PASSWORD_FILE" 2>/dev/null; then
        log "WARNING: $VNC_PASSWORD_FILE is readable by uid 1000, which is the user Firefox" \
            "runs as. Only root needs to read it (docker compose 'secrets:' mounts it 0444" \
            "by default); mount it mode 0400 owned by root to keep the plaintext away from" \
            "the browser."
    fi

    # First line only, newline stripped: `echo secret > file` is the obvious way to produce
    # one of these and must not yield a password with a trailing newline in it. `read`
    # reports failure on a file without a final newline, which is perfectly valid here.
    IFS= read -r vnc_password < "$VNC_PASSWORD_FILE" || true

    # `read` strips \n but not \r, so a file written on Windows or pasted through a web UI
    # (Portainer, a k8s secret editor) yields the password "secret\r": -storepasswd and
    # xrdp.ini both get the CR, the operator types "secret", and RDP fails with
    # "VNC password failed" while the log claims the password was read successfully.
    if [[ "$vnc_password" == *$'\r' ]]; then
        vnc_password="${vnc_password%$'\r'}"
        log "note: $VNC_PASSWORD_FILE has CRLF line endings; the trailing CR was stripped" \
            "from the password (it is not part of it)"
    fi

    if [[ -z "$vnc_password" ]]; then
        log "FATAL: VNC_PASSWORD_FILE=$VNC_PASSWORD_FILE is empty"
        exit 1
    fi

    # Neither of these is ever a reason to refuse to start, and neither may echo the value.
    if [[ "$vnc_password" != "${vnc_password#[[:space:]]}" ||
          "$vnc_password" != "${vnc_password%[[:space:]]}" ]]; then
        log "WARNING: the password in $VNC_PASSWORD_FILE has leading or trailing whitespace." \
            "It is used verbatim, so the client has to type that whitespace too. Check the" \
            "file if RDP reports 'VNC password failed'."
    fi
    if [[ "$vnc_password" == *[![:print:]]* ]]; then
        log "WARNING: the password in $VNC_PASSWORD_FILE contains non-printable bytes." \
            "VNC_PASSWORD_FILE expects PLAINTEXT; if you pointed it at a file produced by" \
            "'x11vnc -storepasswd' (an obfuscated blob), mount that file at" \
            "$X11VNC_SECRET_FILE instead and leave VNC_PASSWORD_FILE unset."
    fi

    log "VNC password read from VNC_PASSWORD_FILE=$VNC_PASSWORD_FILE"
elif [[ -n "${PASSWORD:-}" ]]; then
    vnc_password="$PASSWORD"
    vnc_password_src="PASSWORD"
fi

if [[ -n "$vnc_password" ]]; then
    if [[ "$vnc_password_src" != "VNC_PASSWORD_FILE" && -n "${VNC_PASSWORD_FILE:-}" ]]; then
        log "WARNING: VNC_PASSWORD_FILE is also set, but $vnc_password_src takes precedence;" \
            "ignoring VNC_PASSWORD_FILE"
    fi
    if [[ "$vnc_password_src" != "PASSWORD" && -n "${PASSWORD:-}" ]]; then
        log "WARNING: PASSWORD is also set, but $vnc_password_src takes precedence;" \
            "ignoring PASSWORD"
    fi
    if [[ -f "$X11VNC_SECRET_FILE" ]]; then
        log "WARNING: $vnc_password_src is set, ignoring the legacy $X11VNC_SECRET_FILE"
    fi

    # -storepasswd does put the password in argv, but only for this one short-lived call.
    # What matters is that the long-running x11vnc that supervisord starts carries no
    # password in argv at all, just `-rfbauth <file>`.
    #
    # Every step is checked explicitly instead of being left to errexit. This block used to
    # sit in the body of an `if`, where errexit IS live, so a read-only /run or a full
    # writable layer exited the entrypoint with no explanation at all - under a restart policy
    # that is a permanent restart loop and a dashboard that never comes up. It also must not
    # end with x11vnc pointed at a passwd file that does not exist or that uid 1000 cannot
    # read: x11vnc would exit immediately, be retried until FATAL, and take the container down
    # with it every ~21 minutes, forever.
    vnc_password_stored=1
    x11vnc_passwd_dir="$(dirname "$X11VNC_PASSWD_FILE")"
    if ! install -d -m 0700 -o user -g user "$x11vnc_passwd_dir"; then
        log "WARNING: could not create $x11vnc_passwd_dir (read-only /run?)"
        vnc_password_stored=0
    elif ! x11vnc -storepasswd "$vnc_password" "$X11VNC_PASSWD_FILE" >/dev/null; then
        log "WARNING: 'x11vnc -storepasswd' could not write $X11VNC_PASSWD_FILE"
        vnc_password_stored=0
    elif ! chown user:user "$X11VNC_PASSWD_FILE"; then
        log "WARNING: could not chown $X11VNC_PASSWD_FILE to uid 1000, the user x11vnc runs" \
            "as, so x11vnc could never read it"
        vnc_password_stored=0
    elif ! chmod 0600 "$X11VNC_PASSWD_FILE"; then
        # The content is in place, so the password path is fine; only the belt-and-braces
        # re-assertion of the mode -storepasswd already sets failed.
        log "WARNING: could not chmod 0600 $X11VNC_PASSWD_FILE; check its mode by hand"
    fi

    if (( vnc_password_stored )); then
        export X11VNC_AUTH="-rfbauth $X11VNC_PASSWD_FILE"
        # With a password set, VNC is reachable from outside the container as well.
        export X11VNC_LISTEN=""

        # xrdp's libvnc backend logs into x11vnc with the credentials hard-coded in xrdp.ini,
        # so that password has to follow the configured one or RDP stops working. This
        # necessarily keeps the password in plaintext inside the container filesystem - it is
        # how the libvnc module authenticates, there is no other channel. /etc/xrdp is
        # image-only (never a volume) and set_xrdp_ini keeps the file at 0640, so nothing leaks
        # outside the container and uid 1000 cannot read it either.
        if set_xrdp_ini password "$vnc_password"; then
            log "VNC password set; xrdp.ini libvnc credentials synchronised"
        else
            log "WARNING: the password was stored for x11vnc, but xrdp.ini could NOT be updated" \
                "(see the warning above), so the two no longer agree: RDP will fail with 'VNC" \
                "password failed' until [xrdp1] password= in $XRDP_INI is set to the same value."
            # One warning in a log that rolls over within a day is not enough for a failure
            # whose only other symptom is "every RDP session dies while the container is
            # healthy". The marker makes the healthcheck say it, for as long as it is true.
            mark_password_desync "[xrdp1] password= in $XRDP_INI does not match the password" \
                "x11vnc was given: the entrypoint could not rewrite the file (the reason is in" \
                "the entrypoint WARNING in 'docker logs'). Every RDP session fails with 'VNC" \
                "password failed'. Recreate the container, or set [xrdp1] password= by hand."
        fi
    else
        # Falling back to no password at all, rather than pointing x11vnc at a file it cannot
        # use. -localhost comes with it: an unauthenticated VNC server must not be reachable
        # from outside the container. xrdp.ini is deliberately NOT given the password either -
        # x11vnc would not be asking for one, and writing it there would only put a plaintext
        # password in the image for nothing.
        log "WARNING: $vnc_password_src is set, but the password could NOT be stored for" \
            "x11vnc (see the warning above). x11vnc is starting UNAUTHENTICATED and bound to" \
            "localhost only, so RDP through 3389 keeps working but port 5900 is not exposed" \
            "and the password you configured is not in effect. Recreate the container once" \
            "the cause is fixed."
        export X11VNC_AUTH="-nopw"
        export X11VNC_LISTEN="-localhost"
    fi
elif [[ -f "$X11VNC_SECRET_FILE" ]]; then
    # Legacy path, kept working but not recommended: the file is already in x11vnc's
    # obfuscated format, so its plaintext is unknown and [xrdp1] password= cannot be
    # synchronised - RDP only works if the operator sets the same password there by hand.
    # VNC_PASSWORD_FILE takes plaintext and has none of these problems.
    #
    # A compose `secrets:` mount defaults to mode 0400 root:root, which x11vnc (uid 1000)
    # cannot read: it would exit immediately and be retried forever. Fail here instead, with
    # a message that says what to change.
    #
    # The runuser test is guarded: without the guard a missing binary makes `if ! runuser`
    # true (exit 127) and produces a confident FATAL about file permissions for a problem
    # that is nothing of the sort.
    if ! command -v runuser >/dev/null 2>&1; then
        log "WARNING: runuser is not installed, so it cannot be verified that" \
            "$X11VNC_SECRET_FILE is readable by uid 1000. If x11vnc keeps restarting, that" \
            "is the first thing to check."
    elif ! runuser -u user -- test -r "$X11VNC_SECRET_FILE"; then
        log "FATAL: $X11VNC_SECRET_FILE is not readable by uid 1000, the user x11vnc runs" \
            "as, so x11vnc could never start. Mount the secret with uid=1000 or mode 0444," \
            "or switch to VNC_PASSWORD_FILE (plaintext, and it also syncs xrdp.ini)."
        exit 1
    fi
    export X11VNC_AUTH="-rfbauth $X11VNC_SECRET_FILE"
    export X11VNC_LISTEN=""
    log "using legacy VNC password file $X11VNC_SECRET_FILE"
    log "WARNING: its plaintext is unknown, so xrdp.ini was NOT updated - set the same" \
        "password in [xrdp1] of $XRDP_INI manually or RDP will fail to log in"
else
    export X11VNC_AUTH="-nopw"
    # No password means no authentication at all, so do not accept connections from
    # outside the container. xrdp reaches x11vnc over 127.0.0.1 regardless.
    export X11VNC_LISTEN="-localhost"
    log "no VNC password set: x11vnc runs unauthenticated and bound to localhost only"
fi

# ---------------------------------------------------------------------------
# x11vnc verbosity
#
# Default `-q`, because healthcheck.sh connects to 5900 every 30s and x11vnc logs two lines
# per connection at its default verbosity - ~3000 lines per instance per day in the only
# diagnostic channel this image has.
#
# But `-q` is not free: x11vnc routes almost everything through rfbLog, including non-fatal
# failures like "X11 MIT Shared Memory Attach failed" / BadAccess - the exact message that
# diagnosed the shm/uid problem this image has already had once. So the flag has to be
# switchable at runtime, without a rebuild: `-e X11VNC_QUIET=` restores full verbosity.
#
# Exported unconditionally (and with ${VAR-default}, not ${VAR:-default}, so that an
# explicitly empty value survives): supervisord fails to even parse a config whose
# %(ENV_...)s names a variable that is not set.
# ---------------------------------------------------------------------------
export X11VNC_QUIET="${X11VNC_QUIET--q}"
if [[ -z "$X11VNC_QUIET" ]]; then
    log "X11VNC_QUIET is empty: x11vnc runs at full verbosity (every healthcheck probe logs" \
        "a connect and a disconnect line)"
fi

# The plaintext must not be inherited by supervisord and every process it spawns: Firefox
# renders untrusted web content, and /proc/<pid>/environ would otherwise hand the password
# to anything that can read it.
#
# This only cleans the *process* environment. A value passed as `-e VNC_PASSWORD=...` still
# lives in the container's Config.Env, so it shows up in `docker inspect`, in the environment
# of every later `docker exec`, and in the HEALTHCHECK process (dockerd spawns that one, not
# supervisord). VNC_PASSWORD_FILE is the way to avoid that entirely.
unset VNC_PASSWORD PASSWORD
vnc_password=""

exec "$@"
