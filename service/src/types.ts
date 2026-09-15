export interface GitCredentials {
  username: string;
  token: string;
}

export interface RegistryCredentials {
  registry: string;
  username: string;
  password: string;
}

export interface ImageTarget {
  registry?: string;
  name?: string;
  tag?: string;
}

export interface BuildOptions {
  noCache?: boolean;
  cacheFrom?: string;
  cacheTo?: string;
  mode?: "auto" | "never";
}

export interface BuildRequest {
  repository: string;
  branch?: string;
  gitCredentials?: GitCredentials;
  image?: ImageTarget;
  registryCredentials?: RegistryCredentials;
  platforms?: string[];
  buildOptions?: BuildOptions;
}

export interface BuildResponse {
  image: string;
  registry: string;
  name: string;
  tag: string;
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
}
