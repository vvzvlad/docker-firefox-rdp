# docker-firefox-rdp

A container that shows exactly one web page — in practice a Grafana dashboard — on a screen
that you attach to over RDP. Firefox runs in kiosk mode (fullscreen, no browser chrome, no
tabs), so a thin client or a wall-mounted display only needs an RDP client and no browser,
no session, and no keyboard.

Based on Ubuntu 24.04 with Firefox from the official Mozilla APT repository (currently 153.x
— the distro `firefox` package is only a snap wrapper and is deliberately outranked by an
APT pin).

## How it works

```text
RDP client ──▶ xrdp :3389 ──▶ libvnc.so ──▶ x11vnc :5900 ──▶ Xvfb :1 ◀── awesome ◀── firefox --kiosk $URL
```

Everything is supervised by `supervisord` (PID 1) and logs to the container's stdout:

| Program | Runs as | Notes |
| --- | --- | --- |
| `xvfb` | `user` | the virtual screen, `$RESOLUTION` |
| `awesome` | `user` | window manager; keeps the Firefox window fullscreen |
| `firefox` | `user` | kiosk mode on `$URL`, restarted automatically if it dies |
| `x11vnc` | `user` | exports the Xvfb screen over VNC |
| `xrdp-sesman` | `root` | xrdp session manager |
| `xrdp` | `root` | the RDP listener on 3389 |
| `fatal-exit` | `root` | event listener; exits the container when any program gives up, so Docker's restart policy recovers it ([details](#how-a-dead-program-actually-recovers)) |

`awesome`, `firefox` and `x11vnc` are started through `/usr/local/bin/wait-for-x`, which
blocks until the X server answers — supervisord's `priority` only orders the spawns, it does
not wait for readiness.

## Run

```sh
docker run -d --name dashboard \
  --restart unless-stopped \
  -p 3389:3389 \
  -v dashboard-home:/home/user \
  -e URL=https://grafana.example.com/d/abc123/my-dashboard?kiosk \
  -e SCALE=0.8 \
  -e TZ=Europe/Moscow \
  gitea.vvzvlad.xyz/projects/docker-firefox-rdp:latest
```

Then point any RDP client at port 3389.

`--restart unless-stopped` is **not optional**: when a program gives up for good the container
exits on purpose so that the restart policy recovers it, and with the default `--restart no`
that first failure makes the container disappear instead
([details](#how-a-dead-program-actually-recovers)).

### Compose

```yaml
services:
  dashboard:
    image: gitea.vvzvlad.xyz/projects/docker-firefox-rdp:latest
    restart: unless-stopped
    ports:
      - "3389:3389"
    volumes:
      - dashboard-home:/home/user
    environment:
      URL: "https://grafana.example.com/d/abc123/my-dashboard?kiosk"
      SCALE: "0.8"
      RESOLUTION: "1366x768x24"
      TZ: "Europe/Moscow"

volumes:
  dashboard-home:
```

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `URL` | `about:blank` | page opened in Firefox kiosk mode; a warning is logged if left at the default |
| `RESOLUTION` | `1366x768x24` | Xvfb screen geometry and colour depth |
| `SCALE` | `1` | UI scale factor (Firefox `layout.css.devPixelsPerPx`), e.g. `0.8` to fit more on screen |
| `TZ` | (unset) | container time zone, e.g. `Europe/Moscow` |
| `VNC_PASSWORD` | (empty) | VNC/RDP password; see below |
| `VNC_PASSWORD_FILE` | (unset) | path to a file whose first line is the **plaintext** password; treated exactly like `VNC_PASSWORD`, so it also syncs `xrdp.ini`. Use this with docker secrets instead of putting the password in the environment |
| `PASSWORD` | (empty) | **deprecated** alias for `VNC_PASSWORD`; logs a warning when used |
| `RDP_SECURITY_LAYER` | `negotiate` | `security_layer=` written into `/etc/xrdp/xrdp.ini`. One of `negotiate`, `tls`, `rdp`. Set it to `rdp` if a client cannot cope with the self-signed TLS certificate (see [Breaking changes](#breaking-changes-vs-the-2024-image)) |
| `RDP_CRYPT_LEVEL` | `high` | `crypt_level=` written into `/etc/xrdp/xrdp.ini`. One of `none`, `low`, `medium`, `high`, `fips`. Lower it for a thin client whose RDP stack cannot negotiate `high` |
| `X11VNC_QUIET` | `-q` | verbosity flag passed to x11vnc. Set it to empty (`-e X11VNC_QUIET=`) to get x11vnc's full logging back — the **first step when x11vnc misbehaves**, because `-q` silences non-fatal errors too (see [Healthcheck](#healthcheck)) |

Both RDP variables are matched **case-insensitively** (`TLS` works, as it does in xrdp
itself), and an unrecognised value is **not** fatal: the entrypoint logs a loud warning and
falls back to the default. These get edited by hand while somebody is trying to get a dead
display back, and watchtower deploys `:latest` unattended — a typo must not turn into a
container that refuses to start.

Password sources are tried in this order, and the entrypoint logs which one it used plus a
warning naming every lower-ranked one that was also set:

`VNC_PASSWORD` → `VNC_PASSWORD_FILE` → `PASSWORD` (deprecated) → `/run/secrets/vncpasswd`
(legacy) → no password

`PASSWORD` sits **below** `VNC_PASSWORD_FILE` on purpose: it is the deprecated spelling and
does not outrank the `_FILE` convention that replaced it.

`VNC_PASSWORD_FILE` is fatal when it is set but unusable: if the file does not exist, cannot
be read, or its first line is empty, the entrypoint logs `FATAL` and the **container does not
start**. That is deliberate — a password was explicitly asked for, and quietly starting
without one is worse than not starting — but it means a typo'd path or an empty secret shows up
as a container that will not come up (`docker logs` says which of the two it was), not as an
unprotected dashboard.

`VNC_PASSWORD_FILE` takes the **first line** of the file as plaintext. A trailing `\r` is
stripped, so a secrets file written on Windows or pasted through a web UI (Portainer, a k8s
secret editor) does not silently give you the password `secret\r` — which authenticates as
neither `secret` nor anything a human would type. Leading/trailing whitespace and
non-printable bytes are kept as-is but warned about (never echoed); non-printable bytes
usually mean the file is an `x11vnc -storepasswd` blob, which belongs at
`/run/secrets/vncpasswd` instead. The entrypoint also warns when the file is readable by uid
1000, since Firefox — which renders untrusted content — runs as that user and only root needs
to read the file; a compose `secrets:` mount is 0444 by default, so mount it `0400` root.

`/run/secrets/vncpasswd` is the legacy docker-secret path. It expects a file already in
x11vnc's obfuscated `-storepasswd` format, so its plaintext is unknown and `[xrdp1]
password=` **cannot** be synchronised — RDP then only works if you edit that value yourself.
Here readability by uid 1000 is a *requirement*, not a warning (x11vnc itself reads the
file), and the entrypoint aborts with an actionable message if it is not readable, because a
default `secrets:` mount (mode 0400 root) would otherwise send x11vnc into an endless
restart. Prefer `VNC_PASSWORD_FILE`.

`VNC_PASSWORD` and `PASSWORD` are unset before `exec`, so the plaintext is not in the
environment of supervisord or any of its children — notably not Firefox, which renders
untrusted content. That is *only* about process environments: a password passed as
`-e VNC_PASSWORD=…` still lives in the container's `Config.Env`, so it remains visible in
`docker inspect`, in every later `docker exec`, and in the environment of the HEALTHCHECK
process (dockerd spawns that one, not supervisord). Use `VNC_PASSWORD_FILE` if that matters.

### `VNC_PASSWORD` and network exposure

There is no authentication on the RDP path itself — xrdp logs into x11vnc with the
credentials in `/etc/xrdp/xrdp.ini`, so whoever reaches port 3389 gets the session.
`VNC_PASSWORD` controls the VNC hop only, and it changes how x11vnc is exposed:

- **`VNC_PASSWORD` empty (default):** x11vnc runs with `-nopw` and is bound to
  **localhost only** (`-localhost`), so the VNC port is unreachable from outside the
  container. xrdp still reaches it over 127.0.0.1.
- **`VNC_PASSWORD` set:** x11vnc stores the password with `x11vnc -storepasswd` into
  `/run/x11vnc/passwd` (mode 0600, owned by `user`) and uses `-rfbauth`, so the
  **long-running x11vnc process carries no password in its argv** — only
  `-rfbauth /run/x11vnc/passwd`. (The one-off `x11vnc -storepasswd` call in the entrypoint
  does put it in argv for the fraction of a second it lives; it is the persistent process
  that matters.) In this mode x11vnc listens on **all interfaces**, so publishing port 5900
  gives you password-protected direct VNC access.

  Because xrdp's `libvnc.so` has to log into x11vnc, the entrypoint rewrites `password=` in
  `[xrdp1]` of `/etc/xrdp/xrdp.ini` to the same value at startup — otherwise RDP would break
  with `VNC password failed`. This necessarily keeps the password in plaintext inside the
  container filesystem; it is how the libvnc module authenticates and there is no other
  channel. `/etc/xrdp` is image-only, never a volume, so nothing leaks outside — and the
  entrypoint leaves `xrdp.ini` as `root:xrdp` mode `0640`, so processes running as uid 1000
  (Firefox included) cannot read it.

  If that rewrite **fails** (`xrdp.ini` bind-mounted as a single file, a read-only
  `/etc/xrdp`, no space left on the writable layer), the two passwords no longer agree and
  every RDP session dies with `VNC password failed`. The entrypoint says so, and it also drops
  `/run/xrdp-password-desync`, which makes the **healthcheck fail** with that reason — a
  mismatch is invisible to every other probe, since xrdp keeps listening and x11vnc keeps
  answering the RFB banner. The marker is removed again on the next start that succeeds, so a
  `docker restart` does not keep reporting a fixed problem.

  A failure *before* that — the password could not be stored for x11vnc at all — is different:
  x11vnc then starts with `-nopw` and `-localhost` (never pointed at a passwd file it cannot
  read, which would be an endless restart loop), `xrdp.ini` is left alone so RDP keeps working,
  and the log says that the configured password is not in effect.

  Note that classic VNC authentication only uses the first 8 characters of the password.

In every case: **do not expose port 3389 to an untrusted network.** Put it behind a VPN or a
firewall. The `user`/`user` account inside the container is only the OS account used by the
xrdp/sesman login path, not an RDP credential, and it should be treated as a default to
override.

## Ports

| Port | Purpose |
| --- | --- |
| 3389 | RDP (publish this one) |
| 5900 | VNC — only reachable from outside the container when `VNC_PASSWORD` / `VNC_PASSWORD_FILE` is set |

Both are declared with `EXPOSE`, so `docker run -P` publishes both. Production publishes only
3389.

## Volume

`/home/user` (uid/gid 1000) holds the Firefox profile. Mounting it as a named volume is
recommended so the profile — and with it the browser cache, cookies and any Grafana session
— survives container recreation. What lives there:

- `.mozilla/firefox/profiles.ini` and the `<salt>.main` profile directory
- `.cache/`, `Crash Reports/`, `Pending Pings/`

Nothing that the container needs to *run* lives under `/home/user`: the launch scripts are
in `/usr/local/bin`, the window manager config in `/etc/xdg/awesome/rc.lua`, and the Firefox
policies in `/etc/firefox/policies/policies.json`. An empty volume is therefore enough to
start.

There is exactly **one** file in the volume that does shadow the image's configuration:
`~/.config/awesome/rc.lua`. awesome prefers it over `/etc/xdg/awesome/rc.lua`, so a leftover
2024-era rc.lua there starts a *second*, unsupervised Firefox — the entrypoint checks for it
on every start and logs what it found. If a dashboard shows a modal "Firefox is already
running" dialog, that file is the first place to look; see
[Upgrading from the 2024 image](#upgrading-from-the-2024-image).

The profile is created on first start if it does not exist (`firefox -CreateProfile main`),
and `user.js` is rewritten on every start from `SCALE` plus a handful of kiosk-reliability
preferences (no session restore after a crash, no default-browser check, no fullscreen
warning).

## Upgrading from the 2024 image

The upgrade is designed to be a drop-in image swap; existing volumes are reused.

- **uid/gid 1000 is preserved.** The base image's own `ubuntu` user (which also claims uid
  1000 on Ubuntu 24.04) is deleted at build time and `user` is created with explicit
  `-u 1000 -g 1000`, so existing volumes stay readable.
- **Legacy on-volume config is migrated aside automatically.** The 2024 layout kept a
  `~/firefox` launch script and a `~/.config/awesome/rc.lua` in the volume, and that rc.lua
  started Firefox itself. Since a user rc.lua shadows the image's
  `/etc/xdg/awesome/rc.lua`, leaving it in place would start a *second*, unsupervised
  Firefox that fights the first one over the profile lock. On startup the entrypoint renames
  both files to `*.legacy-2024` and logs what it did. Delete them once you are happy with the
  upgrade. Nothing is ever deleted for you:
  - `rc.lua` is migrated **only if it contains the legacy `os.execute` launcher** for
    `/home/user/firefox`. Your own custom `rc.lua` is kept as-is, and the entrypoint logs
    that it found one (and that it shadows `/etc/xdg/awesome/rc.lua`).
  - If your `rc.lua` does not match that signature but **does mention `firefox`**, it is also
    kept — but with a prominent `WARNING`. The signature only recognises the 2024 file; a
    launch written as `awful.spawn`, or pointing at a different path, or split across lines,
    would still start a *second* unsupervised Firefox behind the supervised one, and the
    symptom is a modal "Firefox is already running" dialog that nobody can dismiss on a wall
    display. If your `rc.lua` does launch Firefox, delete that launch (the image starts
    Firefox under supervisord) or move the file aside yourself.
  - `~/firefox` is inert once that rc.lua is gone, so it is moved aside for tidiness and
    never removed.
  - If a `*.legacy-2024` backup already exists, it is moved to
    `*.legacy-2024.<YYYYmmdd-HHMMSS>` rather than overwritten or deleted.
  - A migration that **cannot** happen is a warning, not a failure. `rc.lua` bind-mounted as a
    single file cannot be renamed (`EBUSY`), and neither can anything on a read-only volume;
    the container starts anyway and the log says what is still in place and why it matters.
- **The existing Firefox profile is reused.** `profiles.ini` is read as-is, so a profile
  directory such as `l12mv1bp.main` keeps being used; Firefox 153 migrates a 121-era profile
  in place on first start.
- **`PASSWORD` still works** but logs a deprecation warning — switch to `VNC_PASSWORD`.
- The pre-baked Firefox profile that used to be committed to this repository is gone;
  profiles are created at runtime instead.

### Breaking changes vs the 2024 image

1. **x11vnc is bound to localhost unless a password is set.** With no `VNC_PASSWORD` /
   `VNC_PASSWORD_FILE`, x11vnc now runs `-localhost`, so **connecting straight to port 5900
   without a password no longer works** — previously it was reachable unauthenticated.
   Production publishes only 3389, so it is unaffected. If you do want direct VNC, set a
   password: that switches x11vnc back to listening on all interfaces.
2. **RDP really negotiates TLS now, with a self-signed certificate.** The 2024 image had
   `security_layer=negotiate` but no `certificate=`/`key_file=`, so xrdp silently fell back
   to plain RDP. Both are now set, TLS actually gets selected, and clients that validate the
   certificate show a **one-time trust prompt** they never used to show:
   - `mstsc`: "The identity of the remote computer cannot be verified" → tick *Don't ask me
     again* once per host.
   - FreeRDP / Remmina: pass `/cert-ignore` (FreeRDP) or accept the certificate once.
   - If a client cannot be made to accept it at all — a thin client with no way to dismiss
     the dialog, for instance — set **`RDP_SECURITY_LAYER=rdp`** and redeploy. No rebuild
     needed. A modal dialog on a wall display is a blank screen nobody will dismiss.
3. **`crypt_level` is now `high`** (it was `none`, the fallback the missing certificate
   forced). Very old thin-client RDP stacks may not negotiate it. Two escape hatches, neither
   needing a rebuild: **`RDP_CRYPT_LEVEL`** (`none`/`low`/`medium`/`high`/`fips`) sets
   `crypt_level` directly, and `RDP_SECURITY_LAYER=rdp` drops back to plain RDP security.

### Rollback

Rolling back to the 2024 image is **not** a plain image swap, and it fails silently: port
3389 keeps answering and the container looks fine, but **Firefox never launches at all**. Two
reasons, both caused by the first start of the new image:

- The legacy `~/.config/awesome/rc.lua` — the thing that actually started Firefox in the 2024
  image — has been renamed to `rc.lua.legacy-2024`, and the old image has no
  `[program:firefox]` in its supervisord config to take over.
- The Firefox profile has been **upgraded in place** to 153. Pointing the older Firefox at it
  triggers profile-downgrade protection, which is a modal dialog ("create a new profile") in
  front of the dashboard.

So take a profile backup **before** the first start of the new image — that is the only clean
route back:

```sh
# BEFORE upgrading: snapshot the volume.
docker run --rm -v dashboard-home:/home/user -v "$PWD":/backup alpine \
  tar czf /backup/dashboard-home-pre-2026.tgz -C /home/user .
```

To roll back with that snapshot:

```sh
docker rm -f dashboard
docker volume rm dashboard-home && docker volume create dashboard-home
docker run --rm -v dashboard-home:/home/user -v "$PWD":/backup alpine \
  sh -c 'tar xzf /backup/dashboard-home-pre-2026.tgz -C /home/user && chown -R 1000:1000 /home/user'
# ...then start the old image as before.
```

Without a snapshot, restore the launcher by hand and accept that the profile stays on 153:

```sh
# Put the 2024 window-manager config (which starts Firefox) back.
docker run --rm -v dashboard-home:/home/user alpine sh -c '
  cd /home/user/.config/awesome &&
  cp -a rc.lua.legacy-2024 rc.lua &&
  chown 1000:1000 rc.lua'
# ~/firefox is still there too; it is only ever moved aside, never deleted.
docker run --rm -v dashboard-home:/home/user alpine ls -l /home/user/firefox.legacy-2024
```

The old Firefox will then hit profile-downgrade protection. Either delete the profile and
start clean (`rm -rf /home/user/.mozilla/firefox`, losing cookies and any Grafana session),
or stay on the new image.

> The entrypoint never deletes anything on the volume: `rc.lua` is only migrated aside when it
> actually contains the legacy `os.execute("bash /home/user/firefox")` launcher, a custom
> `rc.lua` is left untouched, and an existing `*.legacy-2024` backup is moved to a timestamped
> name rather than overwritten.

## Healthcheck

`/usr/local/bin/healthcheck.sh` fails unless all five hold:

1. X answers on `:1`,
2. a Firefox process is alive,
3. TCP 3389 (xrdp) accepts a connection,
4. x11vnc on 5900 answers with the `RFB` protocol banner,
5. `/run/xrdp-password-desync` does not exist.

(4) matters because xrdp keeps listening on 3389 even when the VNC server behind it is dead or
wedged — checking only 3389 reports `healthy` while every RDP session shows a black screen. The
banner is required rather than just a completed TCP handshake, because under the
`RLIMIT_NOFILE` bug below LibVNCServer accepts the connection and then never speaks.

(5) covers the one failure the four probes above structurally cannot see: the entrypoint
could not synchronise `[xrdp1] password=` with the password it gave x11vnc. Both hops then look
perfectly healthy — the RFB probe reads the banner and closes *before* authenticating — while
every real RDP session fails with `VNC password failed`. The marker holds the reason (never the
password) and the healthcheck output repeats it.

`docker inspect` reports the result; the start period is 60s to allow for a cold profile.

Every probe carries its own `timeout` (5s for X, 4s each for the two ports) and the
`HEALTHCHECK --timeout` is 20s, comfortably above their sum. That budget matters in exactly
the case the probes exist for: when both hops are down each probe burns its full timeout, and
a probe that docker kills for running long is recorded in `docker inspect` as **empty output**
— throwing away the `healthcheck: …` lines that say what broke.

Because the RFB probe connects and disconnects every 30s, x11vnc runs with `-q` by default. At
its default verbosity each probe logs `Got connection from client 127.0.0.1` plus
`rfbClientConnectionGone`, i.e. ~3000 lines per instance per day in the only diagnostic channel
there is, growing without bound under docker's default json-file driver.

`-q` does **not** only hide chatter: x11vnc routes nearly everything through the same `rfbLog`,
non-fatal failures included — `X11 MIT Shared Memory Attach failed` / `BadAccess`, the message
that diagnosed this image's shm/uid problem, is one of them. That is why the flag is the
`X11VNC_QUIET` environment variable rather than a hard-coded argument: **`-e X11VNC_QUIET=` and
a restart give the full log back**, with no rebuild, and that is the first thing to do when
x11vnc misbehaves (a blank or frozen RDP session with everything reporting `running`).

## Recovering a stopped program

supervisord exposes its control socket at `/var/run/supervisor.sock`, so individual programs
can be inspected and restarted without recreating the container:

```sh
docker exec dashboard supervisorctl -c /etc/supervisor/conf.d/supervisord.conf status
docker exec dashboard supervisorctl -c /etc/supervisor/conf.d/supervisord.conf restart firefox
```

Passing `-c` is the robust form. Without it, `supervisorctl` reads the **packaged**
`/etc/supervisor/supervisord.conf` — its client config reader does not process `[include]`, so
it never sees this image's config — and takes the `serverurl` from there. That works only
because both files spell the socket path the same way; the bare `supervisorctl status` is
therefore fine in practice, but `-c` does not depend on the two staying in agreement.

Only `status`, `start`, `stop` and `restart` are useful here. `supervisorctl tail <program>`
cannot work: every program logs to `stdout_logfile=/dev/stdout`, and that is not a seekable
file. Use `docker logs` — it is the only diagnostic channel in this image (supervisord's own
`logfile` is `/dev/null` and no program writes log files).

`restart firefox` is safe with respect to leftover processes: `[program:firefox]` sets
`stopasgroup`/`killasgroup` with `stopwaitsecs=5`, so the `Web Content` and `Socket Process`
children are signalled along with the parent, and the whole group is SIGKILLed if the parent
ignores SIGTERM. Without that, only the parent would be killed and the children would keep
holding the profile lock — invisible to `healthcheck.sh`, which matches `comm`
`firefox`/`firefox-bin` while the children rename themselves.

5s rather than something longer because supervisord shuts its groups down **sequentially** in
descending priority (`xrdp` → `xrdp-sesman` → `x11vnc` → `firefox`), so this wait is additive
and has to fit inside the 10s stop grace period that `docker stop`, compose and watchtower all
default to. Measured on this image with a Firefox that cannot handle SIGTERM, ~1.8s goes on the
three groups ahead of it plus the daemon's own latency and ~0.4s on `awesome`, `xvfb` and
supervisord's own exit: at `stopwaitsecs=8` the teardown ran to 9.8–10.3s and docker SIGKILLed
the container (exit 137) instead of letting it finish; at 5s it completes in ~7s with exit 0. A
longer wait does not buy a cleaner shutdown, it only guarantees the container is killed in the
middle of one. (Raising compose's `stop_grace_period` would not help the path that matters —
watchtower stops the container with its own 10s timeout and never reads it.)

> `supervisorctl start <program>` on a program that is genuinely broken will **take the
> container down** under you: it gets `startretries=50` attempts with a growing backoff, and
> when they run out — roughly 21 minutes later — `PROCESS_STATE_FATAL` fires and the container
> restarts (see below). `stop` is safe: a deliberate stop transitions to `STOPPED`, not
> `FATAL`, so it never triggers the listener.

### How a dead program actually recovers

Every program has `startretries=50` — including `xrdp` and `xrdp-sesman`, which own port 3389,
the only port production publishes. `autorestart=true` only takes effect after a program has
stayed up for `startsecs`; a program that dies faster than that is retried `startretries`
times (default **3**) and then parked in `FATAL` forever, while the container keeps reporting
`running`. Docker does not restart a container for a failed healthcheck, so `restart:
unless-stopped` does not rescue it either.

50 rather than something enormous, because supervisord's `BACKOFF` delay grows by one second
per retry and is reset only once a program has stayed up for `startsecs`. `startretries=1000`
therefore degrades into ~16-minute retry intervals (and takes ~5.8 days to exhaust): a
dashboard whose cause of failure clears on day two would sit black for a quarter of an hour
before anything tried again.

Instead, `[eventlistener:fatal-exit]` (`/usr/local/bin/supervisor-fatal-exit`) subscribes to
`PROCESS_STATE_FATAL`, logs which program gave up, and sends `SIGTERM` to supervisord (PID 1).
The container exits cleanly and **Docker's restart policy** brings it back, which puts every
program on a fresh 1-second retry interval and makes recovery identical no matter which
program died. It also shows up as a restart count in `docker ps` instead of hiding as `FATAL`
inside a "running" container.

The listener logs one `[fatal-exit] armed: ...` line at startup. That line is the only evidence
that the component handling every other component's failure is itself alive: if it exhausted
its own retries and went `FATAL`, nothing would act on `PROCESS_STATE_FATAL` any more, and
supervisord reports listener-state and protocol problems at `debug` level, which the default
`info` level throws away. Expect it exactly once per container start — seeing it repeatedly
means the listener itself is being restarted.

> This needs a restart policy on the container: `restart: unless-stopped` (what production
> uses) or `always`. supervisord exits **0** on SIGTERM, so `on-failure` would not restart it.

## Build

```sh
docker build -t gitea.vvzvlad.xyz/projects/docker-firefox-rdp .
```

The build fetches the Mozilla APT signing keyring and **fails** unless it contains *exactly
one* key whose fingerprint is `35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3`. Everything in a
`signed-by` keyring is trusted by apt, so an extra key spliced in alongside the genuine one
has to fail the build too — checking only the first fingerprint would not catch that. The
expected value is a literal inside the `RUN` script, not a build arg, so `--build-arg` cannot
weaken the check.

## CI

Built by Gitea Actions (`.gitea/workflows/image-check-publish.yml`), amd64 only.
Pull requests build without pushing. Every non-PR build gets an immutable `sha-<commit>` tag
plus a tag named after its branch. Pushes to `main` additionally publish `latest` and a
`YYYYMMDD-HHmmss` timestamp tag. Canonical repo:
<https://gitea.vvzvlad.xyz/projects/docker-firefox-rdp>.

> **Merging to `main` deploys to production.** Watchtower watches `:latest` on the production
> hosts and pulls it automatically, so a merge rolls the new image out to the wall-mounted
> dashboards with no human in the loop. Use `sha-<commit>` or a timestamp tag to pin a known
> good image while testing.

## Known environment requirement

x11vnc on Ubuntu 24.04 (LibVNCServer 0.9.14) sizes its poll set from `RLIMIT_NOFILE`. With
docker's default soft limit (~1073741816) it stops servicing its listening socket
altogether: the TCP handshake still completes, but the server never sends the RFB greeting,
so xrdp hangs on `VNC tcp connected` and the RDP session stays blank. The entrypoint lowers
the soft limit to 65536 before starting supervisord, which is why the container must be
started through its own entrypoint.
