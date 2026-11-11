// A small static server for the website, used by `npm run dev` and by the tests. It sends the same
// headers as the deployed site (the `/*` and `/assets/*` blocks of _headers), so a script or style
// the content security policy would refuse fails here too.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import path from "node:path";

const types = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".webp": "image/webp",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".txt": "text/plain; charset=utf-8",
  ".xml": "application/xml; charset=utf-8",
};

/** The blocks of a _headers file: [{ pattern, headers }]. */
export function parseHeaders(text) {
  const blocks = [];
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim() || line.trim().startsWith("#")) continue;
    if (!/^\s/.test(line)) { blocks.push({ pattern: line.trim(), headers: {} }); continue; }
    const at = line.indexOf(":");
    if (at > 0 && blocks.length) blocks[blocks.length - 1].headers[line.slice(0, at).trim()] = line.slice(at + 1).trim();
  }
  return blocks;
}

const matches = (pattern, pathname) => (pattern.endsWith("*") ? pathname.startsWith(pattern.slice(0, -1)) : pathname === pattern);

export async function serve(directory, port = 0) {
  const root = path.resolve(directory);
  const rules = parseHeaders(await readFile(path.join(root, "_headers"), "utf8").catch(() => ""));
  const server = createServer(async (request, response) => {
    const url = new URL(request.url, "http://localhost");
    let pathname = decodeURIComponent(url.pathname);
    if (pathname.endsWith("/")) pathname += "index.html";
    const file = path.join(root, path.normalize(pathname));
    let status = 200;
    let body;
    if (!file.startsWith(root + path.sep) || path.basename(file).startsWith("_")) {
      body = null;
    } else {
      body = await readFile(file).catch(() => null);
    }
    if (body === null) {
      status = 404;
      body = await readFile(path.join(root, "404.html")).catch(() => Buffer.from("Not found"));
    }
    const headers = { "Content-Type": types[path.extname(status === 404 ? "404.html" : file)] ?? "application/octet-stream" };
    for (const rule of rules) if (matches(rule.pattern, url.pathname)) Object.assign(headers, rule.headers);
    response.writeHead(status, headers).end(body);
  });
  await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));
  const { port: bound } = server.address();
  return { url: `http://127.0.0.1:${bound}`, close: () => new Promise((resolve) => server.close(resolve)) };
}
