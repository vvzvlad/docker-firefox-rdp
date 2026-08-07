# Firefox via RDP/VNC

Firefox in a container, accessible via RDP (xrdp) or VNC, based on Ubuntu 20.04 with the awesome window manager. On start, Firefox opens `$URL` in kiosk mode (fullscreen, no browser UI).

## Build

```sh
docker build -t gitea.vvzvlad.xyz/projects/docker-firefox-rdp .
```

## Run

```sh
docker run -d -p 3389:3389 -p 5900:5900 -e URL=https://example.com --name firefox gitea.vvzvlad.xyz/projects/docker-firefox-rdp:latest
```

Connect with any RDP client on port 3389, or with a VNC client on port 5900 (if published).

**Security note:** the RDP session is proxied to a local x11vnc server and by default requires no password — xrdp auto-fills its built-in `rdp`/`rdp` session credentials, so any RDP client connects straight in. Do not expose port 3389 (or 5900) to untrusted networks. Set `PASSWORD` to require a password on the direct VNC port 5900 — but note that this BREAKS RDP unless `PASSWORD=rdp`, because `conf/etc/xrdp/xrdp.ini` hardcodes `password=rdp` for the VNC backend. Setting the same literal password there only restores RDP access — it does not protect it, since xrdp keeps auto-filling the credentials; to make RDP actually prompt for the password, set `[xrdp1] password=ask` (and optionally `username=ask`). The `user`/`user` pair from the Dockerfile is only the OS account inside the container, not an RDP login.

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `URL` | (empty) | URL opened in Firefox kiosk mode on start |
| `RESOLUTION` | `1366x768x24` | X screen resolution and color depth |
| `SCALE` | `1` | UI scale factor (Firefox `layout.css.devPixelsPerPx`) |
| `PASSWORD` | (empty) | VNC password; empty = no authentication |

`VNC_PASSWORD` is declared in the Dockerfile but unused (legacy).

## CI

The image is built and pushed by Gitea Actions (`.gitea/workflows/image-check-publish.yml`). The tag is determined by the branch: `main` produces `latest` + `<sha>`, any other branch produces a tag named after the branch (special characters replaced with `-`). Builds run on pushes to `main`/`develop` and on manual `workflow_dispatch` runs from any branch. The canonical repo is <https://gitea.vvzvlad.xyz/projects/docker-firefox-rdp>.
