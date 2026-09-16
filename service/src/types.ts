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
}

export interface BuildResponse {
  image: string;
  registry: string;
  name: string;
  tag: string;
  gitCloneLogId?: string;
  imageBuildLogId?: string;
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

export interface ErrorResponse {
  error: string;
  logId?: string;
}
