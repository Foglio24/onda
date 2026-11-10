// Finds where the account service lives on the Cloudflare account the API token opens, for the
// deploy workflow and the app's build.
//
//   node scripts/cloudflare.mjs origin    prints the service's address (https://account.<domain>)
//   node scripts/cloudflare.mjs prepare   also finds or creates the D1 database and writes
//                                         wrangler.deploy.jsonc from wrangler.jsonc
//
// Reads CLOUDFLARE_API_TOKEN, and optionally CLOUDFLARE_ACCOUNT_ID (when the token opens more
// than one account), SEAGLASS_ACCOUNT_DOMAIN (the host name to use, e.g. account.example.com;
// otherwise account.<the account's first active domain>, or workers.dev when it has none),
// SEAGLASS_EMAIL_FROM (the sender, e.g. "Seaglass <no-reply@example.com>", on a domain verified
// on Resend, or onboarded to Cloudflare Email Service when there is no RESEND_API_KEY),
// PATREON_URL (Seaglass's page on Patreon) and PREMIUM_MIN_CENTS (the least a Patreon membership
// pays a month to be Premium). With GITHUB_OUTPUT set, the results are written there.

import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const api = "https://api.cloudflare.com/client/v4";
const workerName = "seaglass-account";
const databaseName = "seaglass-account";
const root = fileURLToPath(new URL("..", import.meta.url));
const token = process.env.CLOUDFLARE_API_TOKEN ?? "";

async function cloudflare(path, init = {}) {
  const response = await fetch(api + path, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...init.headers },
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok || body.success === false) {
    const reason = (body.errors ?? []).map((error) => `${error.code}: ${error.message}`).join("; ") || response.status;
    const error = new Error(`${init.method ?? "GET"} ${path.split("?")[0]} failed (${reason})`);
    error.status = response.status;
    throw error;
  }
  return body;
}

async function accountId() {
  if (process.env.CLOUDFLARE_ACCOUNT_ID) return process.env.CLOUDFLARE_ACCOUNT_ID;
  const { result } = await cloudflare("/accounts?per_page=50");
  if (result.length === 0) throw new Error("The API token doesn't open any Cloudflare account.");
  if (result.length > 1) {
    throw new Error("The API token opens more than one account: set the CLOUDFLARE_ACCOUNT_ID repository variable to " +
      result.map((account) => `${account.id} (${account.name})`).join(" or ") + ".");
  }
  return result[0].id;
}

/** The host name: the one asked for, account.<first active domain>, or the workers.dev one. */
async function host(account) {
  const asked = (process.env.SEAGLASS_ACCOUNT_DOMAIN ?? "").trim().toLowerCase().replace(/\.$/, "");
  let zones = [];
  try {
    zones = (await cloudflare(`/zones?account.id=${account}&status=active&per_page=50&order=name`)).result;
  } catch (error) {
    // A token without Zone › Read: only workers.dev is possible.
    if (error.status !== 403) throw error;
    console.error("::warning::The API token can't read the account's domains (Zone › Read): using workers.dev.");
  }
  if (asked) {
    const zone = zones.find((candidate) => asked === candidate.name || asked.endsWith("." + candidate.name));
    if (!zone) throw new Error(`${asked} isn't on an active domain of this Cloudflare account.`);
    return { hostname: asked === zone.name ? `account.${zone.name}` : asked, customDomain: true };
  }
  if (zones.length > 0) {
    if (zones.length > 1) {
      console.error(`::notice::More than one domain: using ${zones[0].name}. Set SEAGLASS_ACCOUNT_DOMAIN to choose.`);
    }
    return { hostname: `account.${zones[0].name}`, customDomain: true };
  }
  const { result } = await cloudflare(`/accounts/${account}/workers/subdomain`);
  if (!result?.subdomain) throw new Error("The account has no domain and no workers.dev subdomain yet.");
  return { hostname: `${workerName}.${result.subdomain}.workers.dev`, customDomain: false };
}

async function database(account) {
  const { result } = await cloudflare(`/accounts/${account}/d1/database?name=${databaseName}&per_page=50`);
  const existing = result.find((candidate) => candidate.name === databaseName);
  if (existing) return existing.uuid;
  const created = await cloudflare(`/accounts/${account}/d1/database`, {
    method: "POST",
    body: JSON.stringify({ name: databaseName }),
  });
  console.error(`::notice::Created the D1 database ${databaseName}.`);
  return created.result.uuid;
}

function output(values) {
  for (const [key, value] of Object.entries(values)) {
    if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `${key}=${value}\n`);
  }
}

/** wrangler.jsonc without its comments (none of its strings hold "//" or "/*"). */
function readConfig() {
  const text = readFileSync(`${root}/wrangler.jsonc`, "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/^\s*\/\/.*$/gm, "")
    .replace(/,(\s*[}\]])/g, "$1");
  return JSON.parse(text);
}

async function main() {
  const command = process.argv[2];
  if (!["origin", "prepare"].includes(command)) throw new Error("Usage: cloudflare.mjs origin|prepare");
  if (!token) throw new Error("CLOUDFLARE_API_TOKEN is not set.");
  const account = await accountId();
  const { hostname, customDomain } = await host(account);
  const origin = `https://${hostname}`;
  output({ origin, account_id: account });
  if (command === "origin") {
    console.log(origin);
    return;
  }

  const config = readConfig();
  delete config.$schema;
  config.account_id = account;
  config.d1_databases[0].database_id = await database(account);
  config.workers_dev = !customDomain;
  if (customDomain) config.routes = [{ pattern: hostname, custom_domain: true }];
  const sender = (process.env.SEAGLASS_EMAIL_FROM ?? "").trim();
  const address = sender.match(/<([^<>]+)>$/)?.[1] ?? sender;
  if (sender && !/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(address)) throw new Error("SEAGLASS_EMAIL_FROM isn't an email address.");
  // Resend (free) when its key is there; otherwise Cloudflare's Email Service (Workers Paid).
  const resend = Boolean(process.env.RESEND_API_KEY);
  if (sender && !resend) config.send_email = [{ name: "EMAIL", allowed_sender_addresses: [address] }];
  config.vars = {
    ...config.vars,
    PUBLIC_ORIGIN: origin,
    AUTH_EMAIL_READY: sender ? "true" : "false",
    AUTH_EMAIL_FROM: sender,
    PATREON_URL: (process.env.PATREON_URL ?? "").trim(),
    ...(process.env.PREMIUM_MIN_CENTS ? { PREMIUM_MIN_CENTS: process.env.PREMIUM_MIN_CENTS.trim() } : {}),
  };
  writeFileSync(`${root}/wrangler.deploy.jsonc`, JSON.stringify(config, null, 2) + "\n");
  console.log(`${workerName} → ${origin} (database ${databaseName}, email ${sender ? (resend ? "Resend" : "Cloudflare") : "off"})`);
}

main().catch((error) => {
  console.error(`::error::${error.message}`);
  process.exit(1);
});
