export class HttpError extends Error {
  constructor(status, code) {
    super(code);
    this.status = status;
    this.code = code;
  }
}

/** `headers` is an object or a Headers (which a spread would empty, losing Location and cookies). */
export function respond(body, status = 200, headers = {}) {
  const all = new Headers({
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
  });
  const given = headers instanceof Headers ? headers : new Headers(headers);
  for (const [name, value] of given) {
    if (name === "set-cookie") continue;
    all.set(name, value);
  }
  for (const cookie of given.getSetCookie()) all.append("Set-Cookie", cookie);
  return new Response(body, { status, headers: all });
}

export function json(data, status = 200, headers = {}) {
  return respond(JSON.stringify(data), status, { "Content-Type": "application/json; charset=utf-8", ...headers });
}

export async function readText(request, maxBytes) {
  if (Number(request.headers.get("Content-Length")) > maxBytes) {
    throw new HttpError(413, "body_too_large");
  }
  if (!request.body) return "";
  const reader = request.body.getReader();
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let size = 0;
  let text = "";
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) return text + decoder.decode();
      size += value.byteLength;
      if (size > maxBytes) throw new HttpError(413, "body_too_large");
      text += decoder.decode(value, { stream: true });
    }
  } catch (error) {
    await reader.cancel().catch(() => {});
    if (error instanceof HttpError) throw error;
    throw new HttpError(400, "invalid_body");
  } finally {
    reader.releaseLock();
  }
}

export async function readJson(request, maxBytes = 16_384) {
  const type = request.headers.get("Content-Type")?.split(";")[0].trim().toLowerCase();
  if (type !== "application/json") throw new HttpError(415, "expected_json");
  const text = await readText(request, maxBytes);
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    throw new HttpError(400, "invalid_json");
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new HttpError(400, "expected_object");
  }
  return body;
}

export function unix() {
  return Math.floor(Date.now() / 1000);
}

export function httpsUrl(value, code = "service_unconfigured") {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new HttpError(503, code);
  }
  if (url.protocol !== "https:" || url.username || url.password || url.hash) {
    throw new HttpError(503, code);
  }
  return url;
}
