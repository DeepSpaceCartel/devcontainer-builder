import { BuildRequestError } from "./errors.js";

// OCI distribution-spec / Docker reference grammar, as anchored regex
// sources - shared by schemas.ts's request validation and the image name
// derivation below, so both agree on what a valid reference is.
const NAME_COMPONENT = "[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*";
const DOMAIN_COMPONENT = "[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?";

// `name` - one or more lower-case path components (`app`, `team/app`).
export const IMAGE_NAME_PATTERN = `^${NAME_COMPONENT}(?:/${NAME_COMPONENT})*$`;
// `tag` - up to 128 of [A-Za-z0-9_.-], not starting with `.` or `-`.
export const IMAGE_TAG_PATTERN = "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$";
// `registry` - a host (DNS name or [IPv6]) with an optional port and an
// optional namespace path (`ghcr.io/org`). No scheme: plain-HTTP registries
// are a server-side setting (insecureRegistries), never a request choice.
export const IMAGE_REGISTRY_PATTERN =
  `^(?:${DOMAIN_COMPONENT}(?:\\.${DOMAIN_COMPONENT})*|\\[[0-9A-Fa-f:.]+\\])(?::[0-9]{1,5})?(?:/${NAME_COMPONENT})*$`;
// `os/arch[/variant]`, e.g. linux/amd64, linux/arm/v7.
export const PLATFORM_PATTERN = "^[a-z0-9]+/[a-z0-9_]+(?:/[a-z0-9]+)?$";

const NAME_RE = new RegExp(IMAGE_NAME_PATTERN);

// The default image name: the repository path's last segment, minus a
// trailing .git, lower-cased and squeezed into the OCI name grammar -
// `github.com/Org/My_Repo..x` becomes `my_repo-x`. Anything left unusable
// (nothing alphanumeric at all) is a 400 asking for image.name.
export function deriveImageName(repositoryPath: string): string {
  const segments = repositoryPath.replace(/\.git\/?$/, "").split("/").filter(Boolean);
  const last = (segments[segments.length - 1] ?? "").toLowerCase();
  const name = last
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/[._-]{2,}/g, (run) => (/^(__|-+)$/.test(run) ? run : "-"))
    .replace(/^[._-]+|[._-]+$/g, "");
  if (!NAME_RE.test(name)) {
    throw new BuildRequestError(`unable to derive an image name from repository path "${repositoryPath}": provide image.name`);
  }
  return name;
}

// Cache backends a caller may pick for buildOptions.cacheFrom/cacheTo.
// Others are refused: `local` reads/writes a path on the service's own
// filesystem, `s3`/`azblob` reach storage with the service's ambient
// credentials.
const ALLOWED_CACHE_TYPES = ["registry", "gha", "inline"];

// A buildx --cache-from/--cache-to value is either a bare image reference
// (buildx's shorthand for type=registry,ref=<value>) or CSV key=value
// pairs naming a `type`. Quoted CSV is rejected outright rather than
// re-implementing buildx's CSV parsing to see what's inside the quotes.
export function checkCacheOption(field: string, value: string): void {
  if (!value.includes("=") && !value.includes(",") && !value.includes('"')) return;
  if (value.includes('"')) {
    throw new BuildRequestError(`${field} must not contain quotes`);
  }
  const types = value
    .split(",")
    .map((pair) => pair.trim())
    .filter((pair) => pair.toLowerCase().startsWith("type="))
    .map((pair) => pair.slice("type=".length).trim().toLowerCase());
  if (types.length === 0) {
    throw new BuildRequestError(`${field} must name a cache type (type=${ALLOWED_CACHE_TYPES.join("|")}) or be a plain image reference`);
  }
  const refused = types.find((type) => !ALLOWED_CACHE_TYPES.includes(type));
  if (refused !== undefined) {
    throw new BuildRequestError(`${field}: cache type "${refused}" is not allowed (allowed: ${ALLOWED_CACHE_TYPES.join(", ")})`);
  }
}
