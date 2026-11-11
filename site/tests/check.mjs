// The website's checks: the page's text and files first (no browser), then the page itself in
// Chromium, on a computer and on a phone, served with the headers it is deployed with.
//
//   npm test                      from site/ (needs `npx playwright install chromium` the first time)
//   SHOTS=/some/dir npm test      also saves screenshots there
import { createRequire } from "node:module";
import { existsSync, mkdirSync, readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import vm from "node:vm";
import { serve } from "../scripts/serve-lib.mjs";

const root = fileURLToPath(new URL("..", import.meta.url));
const shots = process.env.SHOTS || path.join(root, "tests", "out");
let failures = 0;
let checks = 0;

function check(ok, message) {
  checks++;
  if (!ok) {
    failures++;
    console.error(`  ✗ ${message}`);
  }
}
const section = (name) => console.log(`\n${name}`);

// ---------------------------------------------------------------------------------------------
section("Text and files");
const html = readFileSync(path.join(root, "index.html"), "utf8");
const css = readFileSync(path.join(root, "style.css"), "utf8");
const window = {};
vm.runInNewContext(readFileSync(path.join(root, "i18n.js"), "utf8"), { window });
const dictionary = window.SEAGLASS_I18N;
const decode = (text) => text.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/\s+/g, " ").trim();

check(Object.keys(dictionary).sort().join() === "en,it", "the page has English and Italian");
const used = new Set();
const kinds = [
  ["data-i18n", /<([a-z0-9]+)\b[^>]*?\sdata-i18n="([^"]+)"[^>]*>([\s\S]*?)<\/\1>/g, 3],
  ["data-i18n-html", /<([a-z0-9]+)\b[^>]*?\sdata-i18n-html="([^"]+)"[^>]*>([\s\S]*?)<\/\1>/g, 3],
];
for (const [, pattern] of kinds) {
  for (const match of html.matchAll(pattern)) {
    const key = match[2];
    used.add(key);
    // English is written in the page too, so it reads the same without JavaScript.
    check(decode(match[3]) === decode(dictionary.en[key] ?? "\u0000"), `index.html's text for ${key} differs from i18n.js's English`);
  }
}
for (const attribute of ["alt", "aria-label"]) {
  const name = attribute === "alt" ? "data-i18n-alt" : "data-i18n-aria";
  for (const match of html.matchAll(new RegExp(`<[^>]*?\\s${name}="([^"]+)"[^>]*>`, "g"))) {
    const key = match[1];
    used.add(key);
    const value = match[0].match(new RegExp(`\\s${attribute}="([^"]*)"`));
    check(value && decode(value[1]) === decode(dictionary.en[key] ?? "\u0000"), `index.html's ${attribute} for ${key} differs from i18n.js's English`);
  }
}
for (const lang of ["en", "it"]) {
  for (const key of used) check(key in dictionary[lang], `${lang} lacks ${key}`);
  for (const key of Object.keys(dictionary[lang])) {
    if (!used.has(key)) check(key === "meta.title" || key === "lang.label" || key === "nav.menu" || key === "tabs.label" || key === "install.alt.copied", `${lang} has ${key}, which the page doesn't use`);
  }
}
for (const key of Object.keys(dictionary.en)) {
  check(Object.keys(dictionary.it).includes(key), `it lacks ${key}`);
  const same = dictionary.en[key] === dictionary.it[key];
  if (same && dictionary.en[key].length > 24 && !key.startsWith("lyrics.l") && key !== "hero.eyebrow") check(false, `${key} isn't translated to Italian`);
  check((dictionary.en[key].match(/<em>/g) ?? []).length === (dictionary.it[key].match(/<em>/g) ?? []).length, `${key} keeps its <em> in both languages`);
}
check(/not affiliated/i.test(dictionary.en["footer.disclaimer"]) && /non affiliato/i.test(dictionary.it["footer.disclaimer"]), "the footer says Seaglass isn't affiliated, in both languages");
check(html.includes('data-i18n="footer.disclaimer"') && html.includes('data-i18n="hero.note"'), "the non-affiliation notice is in the hero and the footer");

check((html.match(/<h1[\s>]/g) ?? []).length === 1, "one h1");
check(/<html lang="en"/.test(html), "the page declares its language");
check(/<meta name="description" content="[^"]{60,}/.test(html), "a meta description");
check(!/\sstyle="/.test(html), "no inline style attributes (the content security policy forbids them)");
check(!/<script(?![^>]*\ssrc=)[^>]*>/.test(html), "no inline scripts");
for (const image of html.matchAll(/<img\b[^>]*>/g)) check(/\salt="/.test(image[0]), `an image has no alt: ${image[0].slice(0, 60)}`);

const allowedHosts = new Set(["github.com", "raw.githubusercontent.com", "altdirect.app", "buymeacoffee.com"]);
for (const match of html.matchAll(/(?:href|src|content)="(https?:\/\/[^"]+)"/g)) {
  check(allowedHosts.has(new URL(match[1].replace(/&amp;/g, "&")).hostname), `an address outside the allowed list: ${match[1]}`);
}
for (const match of html.matchAll(/(?:href|src)="([^"#:]+)"/g)) {
  check(existsSync(path.join(root, match[1].replace(/\?.*$/, ""))), `${match[1]} is referenced but missing`);
}
check(!/url\(\s*["']?https?:/.test(css) && !/@import/.test(css), "the stylesheet loads nothing from elsewhere");
for (const id of html.matchAll(/\sid="([^"]+)"/g)) check(html.split(`id="${id[1]}"`).length === 2, `id ${id[1]} is used twice`);
for (const target of html.matchAll(/href="#([^"]+)"/g)) check(html.includes(`id="${target[1]}"`), `#${target[1]} has no target`);
const assetBytes = readdirSync(path.join(root, "assets"), { recursive: true }).reduce((sum, name) => {
  try { return sum + readFileSync(path.join(root, "assets", name)).length; } catch { return sum; }
}, 0);
check(assetBytes < 1_500_000, `the images weigh ${(assetBytes / 1e6).toFixed(1)} MB`);

// ---------------------------------------------------------------------------------------------
section("The page in a browser");
let playwright;
for (const base of [import.meta.url, "/opt/node22/lib/node_modules/", process.env.PLAYWRIGHT_PATH ? process.env.PLAYWRIGHT_PATH + "/" : null]) {
  if (!base) continue;
  try { playwright = createRequire(base.startsWith("file:") ? base : `file://${base}`)("playwright"); break; } catch { /* try the next place */ }
}
if (!playwright) {
  console.error("  ✗ Playwright isn't installed (npm ci, then npx playwright install chromium).");
  process.exit(1);
}

mkdirSync(shots, { recursive: true });
const server = await serve(path.join(root));
const browser = await playwright.chromium.launch();

async function scrollThrough(page) {
  const height = await page.evaluate(() => document.documentElement.scrollHeight);
  for (let y = 0; y < height; y += 500) {
    await page.evaluate((top) => window.scrollTo(0, top), y);
    await page.waitForTimeout(60);
  }
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(300);
}

async function open(options, label) {
  const context = await browser.newContext({ ...options, locale: "en-GB" });
  const page = await context.newPage();
  const problems = [];
  page.on("console", (message) => { if (["error", "warning"].includes(message.type())) problems.push(`${message.type()}: ${message.text()}`); });
  page.on("pageerror", (error) => problems.push(`exception: ${error.message}`));
  page.on("requestfailed", (request) => problems.push(`request failed: ${request.url()}`));
  page.on("response", (response) => { if (response.status() >= 400) problems.push(`${response.status()}: ${response.url()}`); });
  await page.goto(server.url + "/", { waitUntil: "load" });
  return { context, page, problems, label };
}

for (const [label, options] of [
  ["computer", { viewport: { width: 1440, height: 900 } }],
  ["phone", { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }],
]) {
  section(`  ${label}`);
  const { context, page, problems } = await open(options, label);
  await page.waitForTimeout(500);
  check(await page.locator("h1").innerText() === "Make every playlist flow.", "the title reads in English");
  await page.screenshot({ path: path.join(shots, `${label}-top.png`) });

  await scrollThrough(page);
  check(await page.evaluate((width) => document.documentElement.scrollWidth <= width && window.innerWidth === width, options.viewport.width), "nothing makes the page scroll sideways");
  check(await page.locator(".reveal:not(.in)").count() === 0, "everything has appeared after scrolling");
  const broken = async () => {
    // The screenshots in a reel load as it scrolls to them: scroll each one that shows, to its end.
    for (const reel of await page.locator(".reel:visible").all()) {
      await reel.scrollIntoViewIfNeeded();
      for (const share of [0.35, 0.7, 1, 0]) {
        await reel.evaluate((el, at) => { el.scrollLeft = (el.scrollWidth - el.clientWidth) * at; }, share);
        await page.waitForTimeout(150);
      }
    }
    await page.waitForTimeout(250);
    return page.evaluate(() => Array.from(document.images)
      .filter((image) => image.offsetParent !== null && (!image.complete || image.naturalWidth === 0)).map((image) => image.getAttribute("src")));
  };
  check((await broken()).length === 0, `images that didn't load: ${(await broken()).join(", ")}`);

  // The mix animation draws, and moves.
  const frame = () => page.evaluate(() => {
    const canvas = document.querySelector("#mixCanvas");
    const copy = document.createElement("canvas");
    copy.width = canvas.width;
    copy.height = canvas.height;
    const reader = copy.getContext("2d", { willReadFrequently: true });
    reader.drawImage(canvas, 0, 0);
    const data = reader.getImageData(0, 0, copy.width, copy.height).data;
    let sum = 0, lit = 0;
    for (let i = 0; i < data.length; i += 16) { sum = (sum + data[i] * 3 + data[i + 1] * 5 + data[i + 2] * 7 + data[i + 3]) % 1e9; if (data[i + 3] > 0) lit++; }
    return { sum, lit };
  });
  await page.locator("#mixStage").scrollIntoViewIfNeeded();
  await page.waitForTimeout(900);
  const first = await frame();
  await page.waitForTimeout(1200);
  const second = await frame();
  check(first.lit > 2000, "the mix animation draws something");
  check(first.sum !== second.sum, "the mix animation moves");
  check(/BPM$/.test(await page.locator("#mixReadout").innerText()), "the mix shows a tempo");
  await page.locator("#mixStage").screenshot({ path: path.join(shots, `${label}-mix.png`) });

  // Language.
  await page.locator('[data-lang="it"]').click();
  check(await page.locator("h1").innerText() === "Fai fluire ogni playlist.", "Italian: the title");
  check(await page.evaluate(() => document.documentElement.lang) === "it", "Italian: the page's language");
  check((await page.title()).includes("Fai fluire"), "Italian: the tab's title");
  check((await page.locator(".disclaimer").innerText()).includes("non affiliato"), "Italian: the notice");
  await page.locator("#tempo").scrollIntoViewIfNeeded();
  await page.waitForTimeout(500);
  await page.screenshot({ path: path.join(shots, `${label}-tempo-it.png`) });
  await page.locator('[data-lang="en"]').click();
  check(await page.locator("h1").innerText() === "Make every playlist flow.", "English again");

  // Tempo: ±15 % and the key lock.
  await page.locator("#tRange").evaluate((input) => { input.value = "15"; input.dispatchEvent(new Event("input", { bubbles: true })); });
  check(await page.locator("#tBpm").innerText() === "142.6", "tempo +15 % of 124 BPM is 142.6");
  check(await page.locator("#tSpeed").innerText() === "+15%", "tempo shows +15%");
  check(await page.locator("#tPitch").innerText() === "original key", "the key stays with the lock on");
  await page.locator("label.switch").click();
  check(/^\+2\.42 st$/.test(await page.locator("#tPitch").innerText()), "the pitch moves with the lock off");
  await page.locator("#tRange").evaluate((input) => { input.value = "-8"; input.dispatchEvent(new Event("input", { bubbles: true })); });
  check(await page.locator("#tBpm").innerText() === "114.1", "tempo −8 % of 124 BPM is 114.1");

  // Equaliser.
  await page.locator("#eq").scrollIntoViewIfNeeded();
  await page.locator('[data-eq="bass"]').click();
  check(await page.locator('[data-eq="bass"]').getAttribute("aria-pressed") === "true", "the bass preset is selected");
  await page.waitForTimeout(900);
  const bars = await page.locator("#eq .rail i").evaluateAll((bars) => bars.map((bar) => bar.getBoundingClientRect().height));
  check(bars[0] > bars[5] + 20, "the bass preset raises the low band above the high one");
  await page.screenshot({ path: path.join(shots, `${label}-eq.png`) });

  // Devices.
  await page.locator("#tabs").scrollIntoViewIfNeeded();
  await page.locator("#tab-mac").click();
  check(await page.locator("#panel-mac").isVisible() && !(await page.locator("#panel-ios").isVisible()), "the Mac tab shows the Mac");
  await page.locator("#panel-mac").scrollIntoViewIfNeeded();
  await page.waitForTimeout(500);
  check((await broken()).length === 0, `Mac images that didn't load: ${(await broken()).join(", ")}`);
  await page.screenshot({ path: path.join(shots, `${label}-mac.png`) });
  await page.locator("#tab-mac").press("ArrowRight");
  check(await page.locator("#panel-android").isVisible(), "the arrow key moves to Android");
  check(await page.locator("#tab-android").getAttribute("aria-selected") === "true", "the Android tab is selected");
  await page.locator("#panel-android").scrollIntoViewIfNeeded();
  await page.waitForTimeout(500);
  check((await broken()).length === 0, `Android images that didn't load: ${(await broken()).join(", ")}`);
  await page.locator("#tab-ios").click();

  // The AltStore address.
  await context.grantPermissions(["clipboard-read", "clipboard-write"]).catch(() => {});
  await page.locator("#copyAlt").scrollIntoViewIfNeeded();
  await page.locator("#copyAlt").click();
  await page.waitForTimeout(200);
  check((await page.locator("#copied").innerText()) === "Copied", "copying the source address says so");

  // FAQ.
  await page.locator("#faq summary").first().click();
  check(await page.locator("#faq details").first().evaluate((details) => details.open), "a question opens");

  if (label === "phone") {
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.locator("#burger").click();
    check(await page.locator("#links").isVisible(), "the menu opens on a phone");
    await page.locator("#links a").first().click();
    await page.waitForTimeout(300);
    check(!(await page.locator("#links").isVisible()), "the menu closes after a choice");
  }

  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(400);
  await page.screenshot({ path: path.join(shots, `${label}-full.png`), fullPage: true });
  check(problems.length === 0, `the browser reported: ${problems.join(" | ")}`);
  await context.close();
}

section("  reduced motion");
{
  const { context, page, problems } = await open({ viewport: { width: 1280, height: 800 }, reducedMotion: "reduce" }, "reduced");
  await page.waitForTimeout(400);
  check(await page.locator(".reveal:not(.in)").count() === 0, "everything is shown at once");
  const moving = await page.evaluate(() => Array.from(document.querySelectorAll(".bars i, .note, .aurora i")).filter((el) => getComputedStyle(el).animationName !== "none").length);
  check(moving === 0, "nothing keeps animating");
  const a = await page.evaluate(() => document.querySelector("#mixReadout").textContent);
  await page.waitForTimeout(800);
  check(a === await page.evaluate(() => document.querySelector("#mixReadout").textContent), "the mix animation stays still");
  check(problems.length === 0, `the browser reported: ${problems.join(" | ")}`);
  await context.close();
}

section("  without JavaScript");
{
  const context = await browser.newContext({ javaScriptEnabled: false, viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();
  await page.goto(server.url + "/");
  check(await page.locator("h1").innerText() === "Make every playlist flow.", "the title is there");
  check(await page.locator(".reveal").first().evaluate((el) => getComputedStyle(el).opacity) === "1", "nothing is hidden waiting for a script");
  check(await page.locator("#install .btn").count() >= 4, "the downloads are there");
  await context.close();
}

section("  a page that doesn't exist");
{
  const context = await browser.newContext();
  const page = await context.newPage();
  const response = await page.goto(server.url + "/nothing-here");
  check(response.status() === 404 && (await page.locator("h1").innerText()) === "404", "a 404 page");
  await context.close();
}

await browser.close();
await server.close();
console.log(`\n${checks - failures}/${checks} checks passed${failures ? `, ${failures} failed` : ""}.`);
process.exit(failures ? 1 : 0);
