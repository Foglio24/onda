// Lyrics translated for the Windows app, which has no translator of its own (the iPhone and
// Android apps translate on the device, with Apple's and Google's). Workers AI's m2m100 model
// translates each different line once; the song's language is recognised here, from its script
// and its commonest words. A Premium feature, as on the iPhone: when Premium can be bought, only
// members (and the creator's lifetime account) get translations. Each song's translation is kept
// in Cloudflare's cache for a week, so a song translated again costs nothing.

import { HttpError, json, readJson } from "./http.mjs";
import { membership, patreonConfigured } from "./patreon.mjs";

const MODEL = "@cf/meta/m2m100-1.2b";
/** The languages lyrics can be translated into: the apps' "Traduci in" list. */
const TARGETS = new Set(["it", "en", "es", "fr", "de", "pt", "nl", "pl", "ru", "uk", "tr", "ar", "hi", "id", "th", "vi", "ja", "ko", "zh"]);
const MAX_LINES = 400;
const MAX_LINE = 500;
const MAX_CHARACTERS = 24_000;
/** Lines translated at the same time. */
const PARALLEL = 6;
const CACHE_SECONDS = 7 * 24 * 3600;

// The commonest short words of each language written in Latin letters (the ones lyrics are full
// of), and letters only one of them uses.
const WORDS = {
  en: "the you and i to a my me it in of is that your on all be love we for this don't i'm it's no oh with just know what can when so like baby",
  it: "il la di che e non un una per mi ti sei io tu è sono come ma più nel della ci se mio mia ho anche sempre cosa quando ancora amore",
  es: "el la de que y en no me te un una lo mi por es para con tu yo como pero más se si ya cuando quiero amor todo nada eres estoy",
  fr: "le la les de et je tu un une que pas ne il elle est mon ma moi toi dans pour sur on des qui avec c'est j'ai mais tout plus",
  de: "der die das und ich du nicht ein eine ist mit mich dich mir dir sie es zu wir auf für wie was noch nur auch so liebe kein",
  pt: "o a de que e não um uma eu você me te do da em no na meu minha é com por pra para mais tudo quando amor sem só ao",
  nl: "de het een en ik je niet is van dat die op te mijn jij we zijn met voor maar als wat nog naar ook alles",
  pl: "i nie się w na to jest że ja ty mnie cię mi z do co jak tak ale już tylko jeszcze moja mój",
  tr: "ve bir bu ben sen ne de da mi için çok gibi ama yok var beni seni bana sana her daha kadar şey",
  id: "aku kau kamu dan yang di ini itu tak tidak dengan untuk ke ada cinta dia kita akan bisa hanya",
  vi: "anh em và là có không một những của cho người yêu đã sẽ thì mình ta này đi được",
  sv: "jag du och det att en är inte som på med för mig dig vi har kan så men",
  ro: "și în nu să eu tu ce de la pe mă te că este mai cu un o pentru",
};
const WORD_SETS = Object.fromEntries(Object.entries(WORDS).map(([language, words]) => [language, new Set(words.split(" "))]));
const LETTERS = [
  [/ñ/, "es"], [/[ãõ]/, "pt"], [/ß/, "de"], [/[şğı]/, "tr"], [/[łąęśźżń]/, "pl"], [/[đơưạảấầẩẫậắằẳẵặẹẻẽếềểễệịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ]/, "vi"], [/[ăîâșț]/, "ro"],
];

/** The language of [text] (an m2m100 code), or null when it can't be told. */
export function detectLanguage(text) {
  const counts = { kana: 0, han: 0, hangul: 0, cyrillic: 0, ukrainian: 0, arabic: 0, devanagari: 0, thai: 0, greek: 0, hebrew: 0, latin: 0 };
  for (const character of text) {
    const code = character.codePointAt(0);
    if (code >= 0x3040 && code <= 0x30ff) counts.kana++;
    else if ((code >= 0x4e00 && code <= 0x9fff) || (code >= 0x3400 && code <= 0x4dbf)) counts.han++;
    else if (code >= 0xac00 && code <= 0xd7af) counts.hangul++;
    else if (code >= 0x0400 && code <= 0x04ff) {
      counts.cyrillic++;
      if ("іїєґІЇЄҐ".includes(character)) counts.ukrainian++;
    } else if (code >= 0x0600 && code <= 0x06ff) counts.arabic++;
    else if (code >= 0x0900 && code <= 0x097f) counts.devanagari++;
    else if (code >= 0x0e00 && code <= 0x0e7f) counts.thai++;
    else if (code >= 0x0370 && code <= 0x03ff) counts.greek++;
    else if (code >= 0x0590 && code <= 0x05ff) counts.hebrew++;
    else if (/\p{Script=Latin}/u.test(character)) counts.latin++;
  }
  const letters = Object.values(counts).reduce((sum, value) => sum + value, 0) - counts.ukrainian;
  if (letters < 12) return null;
  // Japanese is written with kana among its kanji; Chinese with no kana at all.
  if (counts.kana >= letters * 0.1) return "ja";
  const scripts = [["han", "zh"], ["hangul", "ko"], ["arabic", "ar"], ["devanagari", "hi"], ["thai", "th"], ["greek", "el"], ["hebrew", "he"]];
  for (const [script, language] of scripts) if (counts[script] >= letters * 0.4) return language;
  if (counts.cyrillic >= letters * 0.4) return counts.ukrainian >= 3 ? "uk" : "ru";
  if (counts.latin < letters * 0.5) return null;
  const lower = text.toLowerCase();
  const scores = Object.fromEntries(Object.keys(WORD_SETS).map((language) => [language, 0]));
  for (const word of lower.match(/[\p{L}']+/gu) ?? []) {
    for (const [language, set] of Object.entries(WORD_SETS)) if (set.has(word)) scores[language]++;
  }
  for (const [pattern, language] of LETTERS) if (pattern.test(lower)) scores[language] += 3;
  const ranked = Object.entries(scores).sort((a, b) => b[1] - a[1]);
  const [best, second] = ranked;
  // Enough of its words, and clearly more than the next language's.
  return best[1] >= 4 && best[1] >= second[1] * 1.25 ? best[0] : null;
}

async function cacheKey(target, lines) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(target + "\n" + lines.join("\n")));
  return `https://translations.seaglass.invalid/${[...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

/** One line through the model (or, in the tests, through a stand-in for it). */
async function translateLine(env, text, source, target) {
  if (env.TRANSLATE_ENDPOINT) {
    const response = await fetch(env.TRANSLATE_ENDPOINT, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text, source_lang: source, target_lang: target }),
    });
    if (!response.ok) throw new Error(`translation ${response.status}`);
    return (await response.json()).translated_text;
  }
  const result = await env.AI.run(MODEL, { text, source_lang: source, target_lang: target });
  return result?.translated_text;
}

/** POST /v1/translate {lines, target}: {source, target, lines} with one translation per line. */
export async function translateLyrics(request, env, session) {
  // Premium only when Premium can be bought (as /v1/status's premiumEnabled says to the apps).
  if (patreonConfigured(env) && env.PATREON_URL && !(await membership(env, session.accountId)).premium) {
    throw new HttpError(403, "premium_required");
  }
  const body = await readJson(request, 64_000);
  const target = String(body.target ?? "");
  if (!TARGETS.has(target)) throw new HttpError(400, "unsupported_language");
  const lines = body.lines;
  if (!Array.isArray(lines) || lines.length === 0 || lines.length > MAX_LINES ||
    lines.some((line) => typeof line !== "string" || line.length > MAX_LINE) ||
    lines.reduce((sum, line) => sum + line.length, 0) > MAX_CHARACTERS) {
    throw new HttpError(400, "invalid_lines");
  }
  const source = detectLanguage(lines.join("\n"));
  if (!source) throw new HttpError(422, "language_unknown");
  if (source === target) return json({ error: "same_language", source }, 409);
  if (!env.AI && !env.TRANSLATE_ENDPOINT) throw new HttpError(503, "translation_unavailable");

  const key = await cacheKey(target, lines);
  const cache = globalThis.caches?.default;
  const cached = await cache?.match(key).catch(() => null);
  if (cached) return json(await cached.json());

  // Each different line once (a chorus comes back many times), a few at a time.
  const unique = [...new Set(lines.map((line) => line.trim()).filter(Boolean))];
  const translated = new Map();
  let next = 0;
  async function worker() {
    while (next < unique.length) {
      const text = unique[next++];
      const result = await translateLine(env, text, source, target);
      if (typeof result !== "string") throw new Error("no translation");
      translated.set(text, result.trim());
    }
  }
  try {
    await Promise.all(Array.from({ length: Math.min(PARALLEL, unique.length) }, worker));
  } catch (error) {
    console.error("translation failed", error);
    throw new HttpError(502, "translation_unavailable");
  }
  const result = { source, target, lines: lines.map((line) => translated.get(line.trim()) ?? "") };
  await cache?.put(key, new Response(JSON.stringify(result), {
    headers: { "Content-Type": "application/json", "Cache-Control": `public, max-age=${CACHE_SECONDS}` },
  })).catch(() => {});
  return json(result);
}
