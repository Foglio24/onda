import { HttpError, json } from "./http.mjs";

// An artist's upcoming concerts, for "Eventi dal vivo" under the classic player. They come from
// Ticketmaster's Discovery API with the service's key (a Worker secret, never in the app), and
// Cloudflare's edge keeps each answer for six hours, so every user shares the lookups. Only the
// artist's name comes in: the app works out on the device which concerts are near, so its
// location never leaves it. Anyone may ask (the app needn't be signed in), a few times a minute
// per address.

const defaultEndpoint = "https://app.ticketmaster.com/discovery/v2";
const cacheSeconds = 6 * 3600;
const maxEvents = 100;

/** "Beyoncé", "BEYONCE" and "beyonce!" are the same artist. */
function nameKey(text) {
  return String(text ?? "").normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");
}

function text(value, limit = 200) {
  return typeof value === "string" && value.trim() ? value.trim().slice(0, limit) : null;
}

function coordinate(value, limit) {
  const number = Number(value);
  return Number.isFinite(number) && Math.abs(number) <= limit && value !== "" && value !== null ? number : null;
}

function ticketLink(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" ? url.href : null;
  } catch {
    return null;
  }
}

/** Only what the app shows; a concert without a day or a link to its tickets is left out. */
export function trimEvent(event) {
  const start = event?.dates?.start ?? {};
  const date = /^\d{4}-\d{2}-\d{2}$/.test(start.localDate ?? "") ? start.localDate : null;
  const url = ticketLink(event?.url);
  const status = event?.dates?.status?.code;
  if (!date || !url || status === "cancelled" || status === "canceled") return null;
  const venue = Array.isArray(event?._embedded?.venues) ? event._embedded.venues[0] ?? {} : {};
  return {
    id: text(event.id, 64) ?? url,
    name: text(event.name) ?? "",
    date,
    time: /^\d{2}:\d{2}(:\d{2})?$/.test(start.localTime ?? "") ? start.localTime.slice(0, 5) : null,
    venue: text(venue.name),
    city: text(venue.city?.name, 100),
    country: /^[A-Z]{2}$/.test(venue.country?.countryCode ?? "") ? venue.country.countryCode : null,
    latitude: coordinate(venue.location?.latitude, 90),
    longitude: coordinate(venue.location?.longitude, 180),
    url,
    postponed: status === "postponed" || status === "rescheduled",
  };
}

async function discovery(env, path, params) {
  const base = (env.TICKETMASTER_ENDPOINT || defaultEndpoint).replace(/\/+$/, "");
  const url = new URL(`${base}/${path}`);
  for (const [name, value] of Object.entries({ ...params, apikey: env.TICKETMASTER_API_KEY })) url.searchParams.set(name, value);
  let response;
  try {
    response = await fetch(url, { headers: { Accept: "application/json" }, signal: AbortSignal.timeout(8000) });
  } catch {
    throw new HttpError(502, "events_unavailable");
  }
  if (!response.ok) throw new HttpError(response.status === 429 ? 503 : 502, "events_unavailable");
  try {
    return await response.json();
  } catch {
    throw new HttpError(502, "events_unavailable");
  }
}

/** The artist called exactly that (tribute bands and "X & Friends" are other names), with the most concerts. */
async function findAttraction(env, artist) {
  const data = await discovery(env, "attractions.json", { keyword: artist, classificationName: "music", size: "20", locale: "*" });
  const wanted = nameKey(artist);
  const found = (Array.isArray(data?._embedded?.attractions) ? data._embedded.attractions : [])
    .filter((item) => typeof item?.id === "string" && nameKey(item.name) === wanted)
    .sort((a, b) => (Number(b.upcomingEvents?._total) || 0) - (Number(a.upcomingEvents?._total) || 0));
  return found[0] ?? null;
}

async function lookUp(env, artist) {
  const attraction = await findAttraction(env, artist);
  if (!attraction || Number(attraction.upcomingEvents?._total) === 0) return [];
  const data = await discovery(env, "events.json", {
    attractionId: attraction.id, sort: "date,asc", size: String(maxEvents), locale: "*",
  });
  const events = Array.isArray(data?._embedded?.events) ? data._embedded.events : [];
  const seen = new Set();
  return events.map(trimEvent).filter((event) => event && !seen.has(event.id) && seen.add(event.id));
}

export async function artistEvents(request, url, env, context) {
  const artist = (url.searchParams.get("artist") ?? "").trim();
  if (!artist || artist.length > 100 || !nameKey(artist)) throw new HttpError(400, "invalid_artist");
  if (!env.TICKETMASTER_API_KEY) return json({ enabled: false, events: [] });

  const cache = globalThis.caches?.default;
  const key = new Request(`https://events.cache.invalid/v1/${encodeURIComponent(nameKey(artist))}`);
  const hit = await cache?.match(key).catch(() => null);
  if (hit) return hit;

  const ip = request.headers.get("CF-Connecting-IP");
  if (env.EVENTS_RATE_LIMITER && ip && !(await env.EVENTS_RATE_LIMITER.limit({ key: ip })).success) {
    throw new HttpError(429, "events_rate_limited");
  }
  const events = await lookUp(env, artist);
  const response = json({ enabled: true, events }, 200, { "Cache-Control": `public, max-age=${cacheSeconds}` });
  if (cache) {
    const write = cache.put(key, response.clone()).catch(() => {});
    if (context?.waitUntil) context.waitUntil(write); else await write;
  }
  return response;
}
