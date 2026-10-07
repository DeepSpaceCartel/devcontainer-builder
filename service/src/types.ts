export interface GitCredentials {
  username: string;
  token: string;
}

export interface RegistryCredentials {
  registry: string;
  username: string;
  password: string;
}

// registry/name/tag/cacheFrom/cacheTo/branch each accept `null` on the wire
// as "not provided" (rejected only as an empty string, see schemas.ts's
// OptionalNonEmptyString) - the type says so explicitly rather than callers
// relying on `??`'s null/undefined equivalence to paper over it.
export interface ImageTarget {
  registry?: string | null;
  name?: string | null;
  tag?: string | null;
}

export interface BuildOptions {
  noCache?: boolean;
  cacheFrom?: string | null;
  cacheTo?: string | null;
  mode?: "auto" | "never";
}

export interface BuildRequest {
  repository: string;
  branch?: string | null;
  gitCredentials?: GitCredentials;
  image?: ImageTarget | null;
  registryCredentials?: RegistryCredentials;
  platforms?: string[];
  buildOptions?: BuildOptions;
  /** Build only these items (ids from the response's `images[].id`); omitted or null: all. */
  instances?: string[] | null;
  /** Clone, discover and name only - no build, no push. */
  dryRun?: boolean;
}

// One devcontainer.json's image (ADR-0016).
export interface BuildImage {
  id: string;
  configPath: string;
  image: string;
  registry: string;
  name: string;
  tag: string;
  imageBuildLogId?: string;
}

// The top-level image/registry/name/tag/imageBuildLogId describe images[0],
// the shape every 1.x caller already reads.
export interface BuildResponse {
  image: string;
  registry: string;
  name: string;
  tag: string;
  branch: string;
  commit: string;
  gitCloneLogId?: string;
  imageBuildLogId?: string;
  images: BuildImage[];
}

export interface ImageExistsResponse {
  image: string;
  exists: boolean;
}

export interface ImageDeleteResponse {
  image: string;
  deleted: boolean;
  reason?: string;
}

export type { DevcontainerMetadata } from "./devcontainer-metadata.js";

export interface ErrorResponse {
  error: string;
  logId?: string;
}
