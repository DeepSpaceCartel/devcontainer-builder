import { BuildRequestError } from "./errors.js";

export interface ParsedGitUrl {
  // Lower-case URL scheme ("https", "ssh", ...), or "scp" for git's own
  // SCP-style `[user@]host:path` shorthand (which git clones over ssh).
  scheme: string;
  host: string;
  path: string;
}

const SCHEME_RE = /^([a-z][a-z0-9+.-]*):\/\//i;
// `[user@]host:path` with a plain DNS name/IPv4 or [IPv6] host - which
// also keeps out git's remote-helper syntax (`ext::<command>`, `fd::...`:
// a host followed by "::") and hosts ssh would read as an option ("-o...").
const SCP_RE = /^(?:[^@/:\s]+@)?([A-Za-z0-9][A-Za-z0-9.-]*|\[[0-9A-Fa-f:.]+\]):(?!\/\/)([^:].*)$/;

// Protocols a repository URL may use. git:// and http:// are unauthenticated
// and unencrypted, so they're opt-in (allowInsecureGitProtocols) - meant for
// test fixtures, not production. Everything else (file://, ext::, ftp://,
// ...) is never accepted: file:// would let a caller build any repository
// on the service's own filesystem.
const SECURE_PROTOCOLS = ["https", "ssh"];
const INSECURE_PROTOCOLS = ["http", "git"];

const CREDENTIALS_IN_URL_ERROR =
  "repository URL must not contain credentials (user:token@...) - pass them in gitCredentials instead";

// Accepts `https://host/path`, `ssh://[user@]host[:port]/path`, and git's
// own SCP-style shorthand `[user@]host:path` (not a valid `URL`).
export function parseGitUrl(repository: string): ParsedGitUrl {
  const scheme = SCHEME_RE.exec(repository)?.[1];
  if (scheme) {
    let url: URL;
    try {
      url = new URL(repository);
    } catch {
      throw new BuildRequestError(`unable to parse git repository URL: ${redactUrlCredentials(repository)}`);
    }
    return { scheme: scheme.toLowerCase(), host: url.hostname, path: url.pathname.replace(/^\//, "") };
  }

  const match = SCP_RE.exec(repository);
  if (match) {
    return { scheme: "scp", host: match[1], path: match[2] };
  }

  throw new BuildRequestError(`unable to parse git repository URL: ${redactUrlCredentials(repository)}`);
}

// Parses `repository` and rejects what the service must never clone:
// credentials embedded in the URL (they'd reach argv, error bodies, logs
// and traces - gitCredentials exists for exactly this), a scheme outside
// the allowlist.
export function checkRepositoryUrl(repository: string, allowInsecureProtocols: boolean): ParsedGitUrl {
  const parsed = parseGitUrl(repository);

  if (parsed.scheme === "scp") return parsed;

  const url = new URL(repository);
  if (url.password || (url.username && parsed.scheme !== "ssh")) {
    throw new BuildRequestError(CREDENTIALS_IN_URL_ERROR);
  }

  const allowed = allowInsecureProtocols ? [...SECURE_PROTOCOLS, ...INSECURE_PROTOCOLS] : SECURE_PROTOCOLS;
  if (!allowed.includes(parsed.scheme)) {
    const hint = INSECURE_PROTOCOLS.includes(parsed.scheme) ? " (git:// and http:// need allowInsecureGitProtocols)" : "";
    throw new BuildRequestError(
      `repository URL scheme "${parsed.scheme}://" is not allowed: use https://, ssh:// or [user@]host:path${hint}`,
    );
  }
  return parsed;
}

// GIT_ALLOW_PROTOCOL for every git child process - git itself then refuses
// anything else, including protocols a redirect or a server-supplied URL
// would otherwise switch to.
export function gitAllowProtocol(allowInsecureProtocols: boolean): string {
  return (allowInsecureProtocols ? [...SECURE_PROTOCOLS, ...INSECURE_PROTOCOLS] : SECURE_PROTOCOLS).join(":");
}

// Redacts URL userinfo anywhere in `text` (a URL, a command line, an error
// message) before it reaches a log line, an error body, Sentry or a span.
// A bare ssh user (`ssh://git@host`) is a login name, not a secret, and is
// kept; anything with a password, and any userinfo on another scheme (a
// token alone is a credential for https), is replaced.
export function redactUrlCredentials(text: string): string {
  return text.replace(/\b([a-z][a-z0-9+.-]*):\/\/([^\s/@]+)@/gi, (whole, scheme: string, userinfo: string) => {
    if (scheme.toLowerCase() === "ssh" && !userinfo.includes(":")) return whole;
    return `${scheme}://[redacted]@`;
  });
}
