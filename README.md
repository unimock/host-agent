# host-agent

A minimal host command agent for Docker containers. It lets a container run a
small, explicitly defined set of commands on the host via a Unix socket —
without mounting the Docker socket or granting any broad host access.

## How it works

```
container                        host
─────────                        ────────────────────────────────────────
echo "backup db1" ──socket──▶ socat ──▶ agent.sh ──▶ /root/.host-agent/backup db1
                  ◀──────────  "0" (exit code)
```

1. A systemd unit ([host-agent.service](host-agent.service)) uses `socat` to
   listen on the Unix socket `/run/host-agent/agent.sock` and spawns
   [agent.sh](agent.sh) per connection.
2. The container mounts the socket directory (see
   [docker-compose.yml](docker-compose.yml)) and writes a single line to the
   socket: the first token is a command name, the rest are parameters.
3. `agent.sh` treats the first token as the name of a **hook script** in
   `/root/.host-agent/`. If an executable script with that name exists, it is
   executed with the remaining tokens as arguments; otherwise the request is
   denied.

There is no regex whitelist: **the set of allowed commands is exactly the set
of executable scripts in the hook directory.** Adding a capability means
dropping a script into `/root/.host-agent/`; removing it means deleting the
script.

## Security properties

- Hook names must match `^[A-Za-z0-9_-]+$` — no path traversal, no `/`, no
  leading dots.
- Parameters are split into an argv array and passed without shell
  interpretation (no `eval`, no word-splitting surprises beyond whitespace).
- Connections that send nothing time out after 5 seconds.
- Every request — allowed or denied — is audit-logged to journald:
  `journalctl -t host-agent`.
- Socket access is limited to the `docker` group (`mode=0660`); the container
  user needs a matching GID.

## Files

| File | Purpose |
|---|---|
| [agent.sh](agent.sh) | Request handler: maps the first token to a hook script and runs it |
| [host-agent.service](host-agent.service) | systemd unit that exposes the socket via `socat` |
| [docker-compose.yml](docker-compose.yml) | Snippet showing how to mount the socket directory |
| [nfpm.yaml](nfpm.yaml) | Package definition; `packaging/` holds the systemd maintainer scripts |

## Install from package (Debian/Ubuntu)

Pick a version from the
[releases page](https://github.com/unimock/host-agent/releases) and install it
with `curl`:

```bash
VER=0.2.4
curl -fsSL "https://github.com/unimock/host-agent/releases/download/v${VER}/host-agent_${VER}_all.deb" \
  | sudo tee /tmp/host-agent.deb >/dev/null && sudo apt install -y /tmp/host-agent.deb
```

This pulls in `socat`, installs `agent.sh` and the systemd unit, creates the
empty hook directory `/root/.host-agent/`, and enables and starts the service.
The only remaining step is creating hook scripts (step 1 of the quick start).

To build the package locally: `VERSION=0.2.4 nfpm package -p deb`
(requires [nfpm](https://nfpm.goreleaser.com)). CI builds and attaches the
package to a GitHub release on every `v*` tag.

## Quick start

On the host:

```bash
# 1. create a hook script — this defines what containers may run
sudo mkdir -p /root/.host-agent
sudo tee /root/.host-agent/command >/dev/null <<'EOF'
#!/usr/bin/env bash
echo "host received: $*"
EOF
sudo chmod 750 /root/.host-agent/command

# 2. test
echo "command param1 param2" | socat -t 60 - UNIX-CONNECT:/run/host-agent/agent.sock
```

From inside a container that mounts `/run/host-agent`:

```bash
echo "command param1 param2" | socat -t 60 - UNIX-CONNECT:/run/host-agent/agent.sock
# or: echo "command param1 param2" | nc -U -q 60 /run/host-agent/agent.sock
```

The agent waits until the hook script has finished completely and then replies
with the hook's exit code as a string (e.g. `0` on success, `1`..`255` on
failure), or `DENIED: <reason>` if the request was rejected. The hook's STDOUT
and STDERR are not returned to the client; they are visible on the host via
`journalctl -t host-agent`.

> **Important — client-side timeout:** `echo` closes its end of the connection
> as soon as the line is sent (EOF). By default `socat` then waits only `-t 0.5`
> seconds for the reply before tearing down the connection, so for any hook that
> runs longer than that you must raise the half-close timeout with `-t <seconds>`
> (with `nc`, use `-q <seconds>`). Pick a value at least as large as your
> longest-running hook (e.g. `-t 300` for a backup). Without it, the client
> disconnects before the agent sends back the exit code.

## Requirements

- `socat` on the host (and `socat` or OpenBSD `nc` in the container)
- systemd
- A `docker` group whose GID is shared with the container user

## Licence

[MIT](LICENCE)
