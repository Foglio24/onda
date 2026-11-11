// Builds dist/, the files the Worker serves: the page and what it loads, and nothing else (no tests,
// scripts or tooling). With SITE_ORIGIN (https://seaglass.example.com) the page gets its canonical
// address, the social preview's full address and a sitemap; with ACCOUNT_URL the "Open the account
// page" button points there (without it the button stays hidden).
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("..", import.meta.url));
const dist = path.join(root, "dist");
const origin = (process.env.SITE_ORIGIN ?? "").replace(/\/$/, "");
const account = process.env.ACCOUNT_URL ?? "";

await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });
for (const name of ["index.html", "404.html", "style.css", "main.js", "boot.js", "i18n.js", "_headers", "assets"]) {
  await cp(path.join(root, name), path.join(dist, name), { recursive: true });
}

function replaceOnce(text, from, to) {
  if (!text.includes(from)) throw new Error(`The page no longer has ${from}`);
  return text.replace(from, to);
}

let page = await readFile(path.join(dist, "index.html"), "utf8");
if (origin) {
  page = replaceOnce(page, 'content="assets/social.jpg"', `content="${origin}/assets/social.jpg"`);
  page = replaceOnce(page, '<meta name="twitter:card"', `<meta property="og:url" content="${origin}/">\n  <link rel="canonical" href="${origin}/">\n  <meta name="twitter:card"`);
  await writeFile(path.join(dist, "robots.txt"), `User-agent: *\nAllow: /\nSitemap: ${origin}/sitemap.xml\n`);
  await writeFile(path.join(dist, "sitemap.xml"), `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>${origin}/</loc></url></urlset>\n`);
} else {
  await cp(path.join(root, "robots.txt"), path.join(dist, "robots.txt"));
}
if (account) {
  if (!/^https:\/\/[a-z0-9.-]+(\/[\w./-]*)?$/i.test(account)) throw new Error("ACCOUNT_URL isn't an https address.");
  page = replaceOnce(page, 'href="#premium" data-stamp="account" hidden>', `href="${account}" data-stamp="account">`);
}
await writeFile(path.join(dist, "index.html"), page);
console.log(`dist/ built${origin ? ` for ${origin}` : ""}${account ? `, account page ${account}` : ""}`);
