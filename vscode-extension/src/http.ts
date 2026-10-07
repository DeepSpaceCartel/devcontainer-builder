// Calls to the Coder API, shared by the clone command and Rebuild. Every
// call has a deadline: a deployment that stops answering mustn't leave a
// progress notification spinning forever.

export const REQUEST_TIMEOUT_MS = 30_000;

// Coder answered with an error status.
export class CoderApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

// Coder didn't answer: DNS, connection refused, TLS, or the deadline.
export class CoderUnreachable extends Error {}

// Worth retrying: the network, or Coder itself having a bad moment.
export function isTransient(e: unknown): boolean {
  return e instanceof CoderUnreachable || (e instanceof CoderApiError && (e.status >= 500 || e.status === 429));
}

export async function coderRequest<T>(
  fetchImpl: typeof fetch,
  baseUrl: string,
  token: string,
  path: string,
  init?: RequestInit,
  timeoutMs = REQUEST_TIMEOUT_MS,
): Promise<T> {
  let res: Response;
  let text: string;
  try {
    res = await fetchImpl(`${baseUrl}/api/v2${path}`, {
      ...init,
      signal: AbortSignal.timeout(timeoutMs),
      headers: { "Coder-Session-Token": token, "Content-Type": "application/json", Accept: "application/json" },
    });
    // Read inside the deadline too: a body can stall as well as the headers.
    text = await res.text();
  } catch (e) {
    const err = e as Error & { cause?: { message?: string } };
    if (err.name === "TimeoutError" || err.name === "AbortError") {
      throw new CoderUnreachable(`Coder at ${baseUrl} didn't answer within ${timeoutMs / 1000}s.`);
    }
    throw new CoderUnreachable(`Couldn't reach Coder at ${baseUrl}: ${err.cause?.message ?? err.message}`);
  }
  let body: any = {};
  try {
    body = text ? JSON.parse(text) : {};
  } catch {
    // Not JSON (e.g. a proxy's error page): the status says enough.
  }
  if (!res.ok) {
    const detail = [body.message, body.detail, ...(body.validations ?? []).map((v: any) => `${v.field}: ${v.detail}`)];
    throw new CoderApiError(`Coder API ${res.status}: ${detail.filter(Boolean).join(" - ") || res.statusText}`, res.status);
  }
  return body as T;
}
