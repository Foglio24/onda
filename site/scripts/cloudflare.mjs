// Finds where the website lives on the Cloudflare account the API token opens, and writes
// wrangler.deploy.jsonc from wrangler.jsonc, for the deploy workflow (.github/workflows/site.yml).
//
//   node scripts/cloudflare.mjs
//
// Reads CLOUDFLARE_API_TOKEN, and optionally CLOUDFLARE_ACCOUNT_ID (when the token opens more than one
// account), SEAGLASS_SITE_DOMAIN (the host name to use, e.g. www.example.com; otherwise
// seaglass.<the account's first active domain>, or workers.dev when it has none) and
// SEAGLASS_ACCOUNT_DOMAIN (as for the account service, to link its page). With GITHUB_OUTPUT set,
// the results (origin, account_url, account_id) are written there.
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const api = "https://api.cloudflare.com/client/v4";
const root = fileURLToPath(new URL("..", import.meta.url));
const token = process.env.CLOUDFLARE_API_TOKEN ?? "";

async function cloudflare(path) {
  const response = await fetch(api + path, { headers: { Authorization: `Bearer ${token}` } });
  const body = await response.json().catch(() => ({}));
  if (!response.ok || body.success === false) {
    const reason = (body.errors ?? []).map((error) => `${error.code}: ${error.message}`).join("; ") || response.status;
    const error = new Error(`GET ${path.split("?")[0]} failed (${reason})`);
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

const clean = (value) => (value ?? "").trim().toLowerCase().replace(/\.$/, "");

async function main() {
  if (!token) throw new Error("CLOUDFLARE_API_TOKEN is not set.");
  const account = await accountId();
  let zones = [];
  try {
    zones = (await cloudflare(`/zones?account.id=${account}&status=active&per_page=50&order=name`)).result;
  } catch (error) {
    // A token without Zone › Read: only workers.dev is possible.
    if (error.status !== 403) throw error;
    console.error("::warning::The API token can't read the account's domains (Zone › Read): using workers.dev.");
  }

  let site;
  let accountPage;
  const asked = clean(process.env.SEAGLASS_SITE_DOMAIN);
  const askedAccount = clean(process.env.SEAGLASS_ACCOUNT_DOMAIN);
  const zoneOf = (host) => zones.find((zone) => host === zone.name || host.endsWith("." + zone.name));
  if (zones.length > 0) {
    if (asked && !zoneOf(asked)) throw new Error(`${asked} isn't on an active domain of this Cloudflare account.`);
    site = { hostname: asked || `seaglass.${zones[0].name}`, customDomain: true };
    const accountHost = askedAccount && zoneOf(askedAccount) ? (zoneOf(askedAccount).name === askedAccount ? `account.${askedAccount}` : askedAccount) : `account.${zones[0].name}`;
    accountPage = `https://${accountHost}/account`;
  } else {
    const { result } = await cloudflare(`/accounts/${account}/workers/subdomain`);
    if (!result?.subdomain) throw new Error("The account has no domain and no workers.dev subdomain yet.");
    site = { hostname: `seaglass-site.${result.subdomain}.workers.dev`, customDomain: false };
    accountPage = `https://seaglass-account.${result.subdomain}.workers.dev/account`;
  }

  const origin = `https://${site.hostname}`;
  const text = readFileSync(`${root}/wrangler.jsonc`, "utf8").replace(/^\s*\/\/.*$/gm, "").replace(/,(\s*[}\]])/g, "$1");
  const config = JSON.parse(text);
  delete config.$schema;
  config.account_id = account;
  config.workers_dev = !site.customDomain;
  if (site.customDomain) config.routes = [{ pattern: site.hostname, custom_domain: true }];
  writeFileSync(`${root}/wrangler.deploy.jsonc`, JSON.stringify(config, null, 2) + "\n");

  if (process.env.GITHUB_OUTPUT) {
    appendFileSync(process.env.GITHUB_OUTPUT, `origin=${origin}\naccount_url=${accountPage}\naccount_id=${account}\n`);
  }
  console.log(`${config.name} → ${origin} (account page ${accountPage})`);
}

main().catch((error) => {
  console.error(`::error::${error.message}`);
  process.exit(1);
});
