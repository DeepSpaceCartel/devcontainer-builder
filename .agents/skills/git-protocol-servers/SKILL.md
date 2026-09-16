---
name: git-protocol-servers
description: Gotchas standing up minimal real git servers (git-daemon, git-http-backend over plain HTTP and real TLS, real authorized-key SSH) for testing - Alpine's missing git-daemon package, bare repo HEAD defaults, serving smart HTTP without a full webserver (and why CGIHTTPRequestHandler can't be wrapped in TLS), git's "dubious ownership" check across container UIDs, real SSH access via a `command=` forced wrapper, and Alpine's `adduser -D` locking the account it creates. Use when setting up a git-over-git/http/https/ssh test fixture, or debugging a git clone/push that fails against a fixture that looks correctly configured.
---

# Git protocol server gotchas

Concrete lessons from `charts/test-git-server` (a real, disposable git
server - git-daemon, smart HTTP, real TLS, and real SSH with clone+push -
used as a BDD test fixture instead of mocks or protocol-faking).

## Alpine's `git` package doesn't include `git-daemon`

`git daemon ...` on a plain `alpine/git` (or `alpine` + `apk add git`) image
fails with `git: 'daemon' is not a git command` - the `git-daemon` binary
ships in a **separate** Alpine package:

```sh
apk add --no-cache git git-daemon
git daemon --reuseaddr --export-all --enable=receive-pack --base-path=/repos --port=9418 /repos
```

`--enable=receive-pack` is required for push - git-daemon is read-only by
default.

## `git init --bare` defaults HEAD to `refs/heads/master`, even if you only ever push to `main`

Symptom: a real clone against a freshly-seeded bare repo "succeeds" but
checks out nothing (`warning: remote HEAD refers to nonexistent ref`, or
"You appear to have cloned an empty repository" over HTTP) - even though
`git show-ref`/`git log` run *inside* the bare repo prove the content and
`refs/heads/main` are genuinely there. The bare repo's `HEAD` symref was
never updated to point at the branch you actually populated.

Fix: create the bare repo with the branch name you intend to push, not the
default:

```sh
git init --bare --initial-branch=main /repos/some/repo.git
git -C /path/to/worktree push /repos/some/repo.git HEAD:main
```

For push over smart HTTP, also enable it per-repo (off by default, unlike
git-daemon which is gated by the daemon flag above):

```sh
git -C /repos/some/repo.git config http.receivepack true
```

## Serving git smart HTTP doesn't need a full webserver - but don't use `CGIHTTPRequestHandler` if you also need TLS

`git-http-backend` is a standard CGI program, so it's tempting to reach for
Python stdlib's `http.server --cgi` (`CGIHTTPRequestHandler`) to run it
directly with no nginx/Apache/fcgiwrap needed. That works fine for plain
HTTP, but **breaks under TLS**: `CGIHTTPRequestHandler` streams the CGI
subprocess's output by `os.dup2()`-ing the subprocess's stdout directly onto
the connection's raw socket file descriptor - which completely bypasses an
`ssl.SSLSocket` wrapper object. The client sees a successful TLS handshake
and even an HTTP 200 status line, then the CGI subprocess writes
**unencrypted** bytes onto what it believes is an encrypted stream (`curl -v`
shows this as "bad record type" / "unexpected message" right after the
headers).

Fix: don't use `CGIHTTPRequestHandler` at all. A small custom
`BaseHTTPRequestHandler` that runs the CGI program via `subprocess.run()`
(capturing output as an in-memory bytes object) and writes the body via
`self.wfile.write()` goes through the SSL wrapper correctly, and the exact
same handler class serves both plain HTTP (no wrapping) and real TLS
(`ssl.SSLContext.wrap_socket` around the server socket) - no separate
TLS-terminating proxy (e.g. `stunnel`) needed. It also lets you dispatch
*any* request path directly to `git http-backend` (setting `PATH_INFO` to
the exact request path), instead of `CGIHTTPRequestHandler`'s fixed
`/cgi-bin/<script>/` prefix requirement - keeping the URL shape consistent
with `git://` and `ssh://` (`http://host:8080/<repo-path>`, no prefix
stutter).

```python
class Handler(http.server.BaseHTTPRequestHandler):
    def _run_cgi(self):
        env = os.environ.copy()
        env["GIT_PROJECT_ROOT"] = "/repos"
        env["GIT_HTTP_EXPORT_ALL"] = "1"
        env["REQUEST_METHOD"] = self.command
        path, _, query = self.path.partition("?")
        env["PATH_INFO"] = path
        env["QUERY_STRING"] = query
        env["CONTENT_LENGTH"] = self.headers.get("Content-Length", "0")
        length = int(env["CONTENT_LENGTH"] or 0)
        body = self.rfile.read(length) if length else b""
        proc = subprocess.run(["git", "http-backend"], input=body, capture_output=True, env=env)
        headers_part, _, body_part = proc.stdout.partition(b"\r\n\r\n")
        # parse Status:/other CGI headers out of headers_part, send_response, then:
        self.wfile.write(body_part)

    do_GET = do_POST = _run_cgi
```

### A TLS-wrapped `http.server` also needs a proper shutdown, or git rejects an otherwise-complete response

Symptom: the full response body genuinely arrives (`curl -v` shows it,
`Content-Length` matches), but git still fails the clone with `GnuTLS recv
error (-110): The TLS connection was non-properly terminated` (or OpenSSL's
equivalent `unexpected eof while reading`). `HTTPServer`'s default
`shutdown_request()` closes the raw socket directly - for an SSL-wrapped
socket this skips the TLS `close_notify` alert. curl merely warns and still
returns the body it already received; git's smart-HTTP client treats the
missing `close_notify` as a hard error and aborts the whole clone.

Fix: override `shutdown_request` to perform a real TLS-level shutdown first:

```python
class Server(http.server.HTTPServer):
    def shutdown_request(self, request):
        if isinstance(request, ssl.SSLSocket):
            try:
                request = request.unwrap()
            except OSError:
                pass
        super().shutdown_request(request)
```

## git's "dubious ownership" check blocks cross-UID access, and `git config --global` may not be visible to it

If the repo directory was created by a different container/UID than the one
now trying to read (or write) it (common when an initContainer seeds a
shared volume that a different container later serves), git refuses with
`fatal: detected dubious ownership in repository at '...'`. The documented
fix (`git config --global --add safe.directory '*'`) writes to
`$HOME/.gitconfig` - but if the process invoking git doesn't reliably carry
`HOME` through (e.g. a CGI subprocess, or an SSH forced-command wrapper),
that global config is invisible to it and the error persists despite being
"fixed."

More robust fix - git's environment-variable config override, which
doesn't depend on `HOME` or any file at all:

```sh
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0=*
```

Set this directly in whatever script actually invokes git (the CGI/HTTP
handler, the SSH wrapper, the daemon's own startup script) - not just once
at container startup - since it's the invoking process's own environment
that matters, not an ancestor's.

## Real SSH clone *and push*, via a `command=` forced-command wrapper (the same technique GitHub/GitLab use)

A real `authorized_keys` entry with a forced command normalizes whatever
path shape the client sent - absolute (`ssh://host/path`) or relative/SCP
style (`git@host:path`, no leading `/`) - to the actual on-disk location,
and rejects everything except the three git SSH subcommands:

```
command="/usr/local/bin/git-ssh-wrapper.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA...
```

```sh
#!/bin/sh
cmd=$(printf '%s' "$SSH_ORIGINAL_COMMAND" | awk '{print $1}')
path=$(printf '%s' "$SSH_ORIGINAL_COMMAND" | sed -E "s/^[a-z-]+ '(.*)'\$/\1/")
path="${path#/}"
case "$cmd" in
  git-upload-pack|git-receive-pack|git-upload-archive) exec "$cmd" "/repos/$path" ;;
  *) exit 1 ;;
esac
```

This makes push work automatically (`git-receive-pack` is allowed same as
the read-only commands) with no separate flag to enable, unlike git-daemon
or smart HTTP.

### Alpine's `adduser -D` creates a *locked* account - sshd refuses pubkey auth too, not just password auth

Symptom: a correctly-generated, correctly-installed `authorized_keys` entry
still gets `Permission denied (publickey,password,keyboard-interactive)`,
and `kubectl logs` on the sshd container shows `User <name> not allowed
because account is locked`. `adduser -D` (no password given) sets the
shadow password field to `!`, which Alpine's sshd treats as "account
disabled" - a check that blocks **all** authentication methods, not just
password, so a valid public key still gets rejected before pubkey auth is
even evaluated.

Fix: unlock the account after creating it (this does not enable password
login - that's controlled separately by `PasswordAuthentication` in
`sshd_config`, and its default `PermitEmptyPasswords no` still blocks an
empty/unset password):

```sh
adduser -D -h /home/git -s /bin/sh git
passwd -u git
```

Use a real `git` user (not root) for this - git's own SSH URL convention is
`git@host:...`, and giving that account (not root) exactly one forced
command via `authorized_keys` mirrors exactly how GitHub/GitLab/Gitea do
their own SSH access.
