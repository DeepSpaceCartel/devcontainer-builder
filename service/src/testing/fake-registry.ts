// A minimal OCI distribution registry on node:http, on localhost, for unit
// tests of registry-client.ts and the /image and /devcontainer routes. It
// implements only what registry-client.ts uses:
//
//   GET    /v2/<repo>/manifests/<tag|digest>  (Docker-Content-Digest, media type)
//   DELETE /v2/<repo>/manifests/<digest>
//   GET    /v2/<repo>/blobs/<digest>          (optionally via a 307 redirect)
//   GET    /token                             (bearer-token exchange)
//
// with no auth, Basic auth, or the Bearer challenge/exchange flow. Content
// is addressed by real sha256 digests of the bytes served. Anything else a
// test needs (a 500, a malformed body, a stall) goes through `override`.
//
// Serve it under 127.0.0.1:<port> and list that host in
// serviceConfig.insecureRegistries - the client then talks plain http.
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { createHash } from "node:crypto";
import { once } from "node:events";

export const MEDIA = {
  manifest: "application/vnd.oci.image.manifest.v1+json",
  index: "application/vnd.oci.image.index.v1+json",
  config: "application/vnd.oci.image.config.v1+json",
} as const;

export type FakeRegistryAuth =
  | { kind: "none" }
  | { kind: "basic"; username: string; password: string }
  | {
      kind: "bearer";
      // Without credentials, the token endpoint hands out tokens anonymously.
      username?: string;
      password?: string;
    };

export interface RecordedRequest {
  method: string;
  path: string;
  authorization?: string;
  accept?: string;
}

export interface OverrideResponse {
  status: number;
  headers?: Record<string, string>;
  body?: string;
}

export interface FakeImage {
  labels?: Record<string, string>;
  user?: string;
}

interface Stored {
  mediaType: string;
  body: string;
  digest: string;
}

const TOKEN = "fake-registry-token";

function digestOf(body: string): string {
  return `sha256:${createHash("sha256").update(body).digest("hex")}`;
}

export class FakeRegistry {
  readonly requests: RecordedRequest[] = [];
  auth: FakeRegistryAuth = { kind: "none" };
  // Status DELETE answers with for a manifest that exists (202 like
  // distribution/distribution; 405 for a registry that doesn't support it).
  deleteStatus = 202;
  // Serve blobs through a 307 to /redirected/<digest>, like registries that
  // hand blobs off to object storage.
  redirectBlobs = false;
  // Consulted before anything else; return undefined to fall through.
  override?: (req: IncomingMessage) => OverrideResponse | undefined;

  private readonly manifests = new Map<string, Stored>();
  private readonly blobs = new Map<string, string>();
  private server?: Server;
  private port = 0;

  // host:port, e.g. for serviceConfig.insecureRegistries
  get host(): string {
    return `127.0.0.1:${this.port}`;
  }

  async start(): Promise<this> {
    this.server = createServer((req, res) => this.handle(req, res));
    this.server.listen(0, "127.0.0.1");
    await once(this.server, "listening");
    this.port = (this.server.address() as { port: number }).port;
    return this;
  }

  async stop(): Promise<void> {
    if (!this.server) return;
    this.server.closeAllConnections();
    this.server.close();
    await once(this.server, "close");
  }

  addBlob(body: string): string {
    const digest = digestOf(body);
    this.blobs.set(digest, body);
    return digest;
  }

  // Stores `body` under its digest and, if given, a tag; returns the digest.
  putManifest(repository: string, body: object | string, mediaType: string, tag?: string): string {
    const text = typeof body === "string" ? body : JSON.stringify(body);
    const stored = { mediaType, body: text, digest: digestOf(text) };
    this.manifests.set(`${repository}@${stored.digest}`, stored);
    if (tag) this.manifests.set(`${repository}:${tag}`, stored);
    return stored.digest;
  }

  // A single-platform image: config blob (labels, user) + manifest.
  addImage(repository: string, tag: string | undefined, image: FakeImage = {}): string {
    const config = this.addBlob(
      JSON.stringify({
        architecture: "amd64",
        os: "linux",
        config: { ...(image.labels ? { Labels: image.labels } : {}), ...(image.user ? { User: image.user } : {}) },
      }),
    );
    return this.putManifest(
      repository,
      { schemaVersion: 2, mediaType: MEDIA.manifest, config: { mediaType: MEDIA.config, digest: config, size: 0 }, layers: [] },
      MEDIA.manifest,
      tag,
    );
  }

  // A multi-platform index over one image per `os/arch[/variant]`, plus an
  // attestation entry (`unknown/unknown`) like BuildKit pushes.
  addIndex(repository: string, tag: string, platforms: Record<string, FakeImage>): string {
    const manifests = Object.entries(platforms).map(([platform, image]) => {
      const [os, architecture, variant] = platform.split("/");
      return {
        mediaType: MEDIA.manifest,
        digest: this.addImage(repository, undefined, image),
        size: 0,
        platform: { os, architecture, ...(variant ? { variant } : {}) },
      };
    });
    manifests.push({
      mediaType: MEDIA.manifest,
      digest: `sha256:${"0".repeat(64)}`,
      size: 0,
      platform: { os: "unknown", architecture: "unknown" },
    });
    return this.putManifest(repository, { schemaVersion: 2, mediaType: MEDIA.index, manifests }, MEDIA.index, tag);
  }

  hasManifest(repository: string, ref: string): boolean {
    return this.manifests.has(ref.startsWith("sha256:") ? `${repository}@${ref}` : `${repository}:${ref}`);
  }

  private handle(req: IncomingMessage, res: ServerResponse): void {
    const url = new URL(req.url ?? "/", `http://${this.host}`);
    this.requests.push({
      method: req.method ?? "GET",
      path: url.pathname + url.search,
      authorization: req.headers.authorization,
      accept: req.headers.accept,
    });

    const send = (status: number, body = "", headers: Record<string, string> = {}) => {
      res.writeHead(status, { "content-length": String(Buffer.byteLength(body)), ...headers });
      res.end(req.method === "HEAD" ? undefined : body);
    };

    const custom = this.override?.(req);
    if (custom) return send(custom.status, custom.body, custom.headers);

    if (url.pathname === "/token") return this.token(req, url, send);

    const redirected = /^\/redirected\/(sha256:[0-9a-f]{64})$/.exec(url.pathname);
    if (redirected) {
      const blob = this.blobs.get(redirected[1]);
      return blob === undefined ? send(404) : send(200, blob, { "content-type": "application/octet-stream" });
    }

    if (!this.authorized(req)) return send(401, JSON.stringify({ errors: [{ code: "UNAUTHORIZED" }] }), this.challenge(url));

    const match = /^\/v2\/(.+)\/(manifests|blobs)\/([^/]+)$/.exec(url.pathname);
    if (!match) return send(404, JSON.stringify({ errors: [{ code: "NAME_UNKNOWN" }] }));
    const [, repository, kind, ref] = match;

    if (kind === "blobs") {
      const blob = this.blobs.get(ref);
      if (blob === undefined) return send(404);
      if (this.redirectBlobs) return send(307, "", { location: `http://${this.host}/redirected/${ref}` });
      return send(200, blob, { "content-type": "application/octet-stream", "docker-content-digest": ref });
    }

    const key = ref.startsWith("sha256:") ? `${repository}@${ref}` : `${repository}:${ref}`;
    const stored = this.manifests.get(key);
    if (req.method === "DELETE") {
      if (!ref.startsWith("sha256:")) return send(400, JSON.stringify({ errors: [{ code: "UNSUPPORTED" }] }));
      if (!stored) return send(404);
      if (this.deleteStatus === 202) {
        for (const [k, v] of this.manifests) {
          if (v.digest === stored.digest && (k.startsWith(`${repository}:`) || k.startsWith(`${repository}@`))) this.manifests.delete(k);
        }
      }
      return send(this.deleteStatus);
    }
    if (!stored) return send(404, JSON.stringify({ errors: [{ code: "MANIFEST_UNKNOWN" }] }));
    return send(200, stored.body, { "content-type": stored.mediaType, "docker-content-digest": stored.digest });
  }

  private authorized(req: IncomingMessage): boolean {
    const header = req.headers.authorization;
    switch (this.auth.kind) {
      case "none":
        return true;
      case "basic":
        return header === `Basic ${Buffer.from(`${this.auth.username}:${this.auth.password}`).toString("base64")}`;
      case "bearer":
        return header === `Bearer ${TOKEN}`;
    }
  }

  private challenge(url: URL): Record<string, string> {
    if (this.auth.kind === "basic") return { "www-authenticate": 'Basic realm="fake-registry"' };
    const repository = /^\/v2\/(.+)\/(?:manifests|blobs)\//.exec(url.pathname)?.[1] ?? "";
    return {
      "www-authenticate": `Bearer realm="http://${this.host}/token",service="fake-registry",scope="repository:${repository}:pull,delete"`,
    };
  }

  private token(req: IncomingMessage, url: URL, send: (status: number, body?: string, headers?: Record<string, string>) => void): void {
    if (this.auth.kind !== "bearer" || url.searchParams.get("service") !== "fake-registry") return send(400);
    const { username, password } = this.auth;
    if (username !== undefined && req.headers.authorization !== `Basic ${Buffer.from(`${username}:${password}`).toString("base64")}`) {
      return send(401);
    }
    send(200, JSON.stringify({ token: TOKEN }), { "content-type": "application/json" });
  }
}

export async function startFakeRegistry(): Promise<FakeRegistry> {
  return new FakeRegistry().start();
}
