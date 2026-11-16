// Runs the script Seaglass injects into Spotify's web player (SpotifyHook.script) against a fake
// page: the player's fetch and XMLHttpRequest calls must reach the real ones unchanged, and the
// "pathfinder" ones must be reported to the app, with headers in whatever form the player used.
import { readFileSync } from "node:fs";
import vm from "node:vm";

const swift = readFileSync(new URL("../../Seaglass/Services/SpotifyHook.swift", import.meta.url), "utf8");
const script = /static let script = #"""\n([\s\S]*?)\n\s*"""#/.exec(swift)?.[1];
if (!script) { console.log("FAIL could not find the script in SpotifyHook.swift"); process.exit(1); }

let failures = 0;
function expect(condition, message) {
  if (condition) console.log("ok   " + message);
  else { failures += 1; console.log("FAIL " + message); }
}

function makePage() {
  const posted = [], fetched = [], opened = [];
  class FakeHeaders {
    constructor(init = {}) { this.map = new Map(Object.entries(init)); }
    forEach(callback) { this.map.forEach((value, key) => callback(value, key)); }
  }
  class FakeRequest {
    constructor(url, init = {}) { this.url = url; this.method = init.method || "GET"; this.headers = new FakeHeaders(init.headers); }
  }
  class FakeXHR {
    open(method, url) { opened.push(["open", method, url]); }
    setRequestHeader(name, value) { opened.push(["header", name, value]); }
    send(body) { opened.push(["send", body]); return "sent"; }
  }
  const window = {
    webkit: { messageHandlers: { seaglassSpotify: { postMessage: (message) => posted.push(message) } } },
    fetch: (...args) => { fetched.push(args); return Promise.resolve("response"); },
    XMLHttpRequest: FakeXHR,
  };
  window.window = window;
  window.Headers = FakeHeaders;
  window.Request = FakeRequest;
  vm.createContext(window);
  vm.runInContext(script, window);
  return { window, posted, fetched, opened, FakeHeaders, FakeRequest, FakeXHR };
}

{
  const { window, posted, fetched } = makePage();
  const url = "https://api-partner.spotify.com/pathfinder/v2/query";
  const body = '{"operationName":"libraryV3"}';
  const answer = await window.fetch(url, { method: "post", headers: { Authorization: "Bearer t", "Client-Token": "c" }, body });
  expect(answer === "response" && fetched.length === 1 && fetched[0][0] === url && fetched[0][1].body === body, "fetch reaches the real one unchanged");
  expect(posted.length === 1 && posted[0].url === url && posted[0].method === "POST" && posted[0].body === body, "a pathfinder POST is reported");
  expect(posted[0].headers.authorization === "Bearer t" && posted[0].headers["client-token"] === "c", "plain-object headers are read, names lowercased");
}
{
  const { window, posted, FakeHeaders } = makePage();
  await window.fetch("https://api-partner.spotify.com/pathfinder/v1/query?operationName=x", { headers: new FakeHeaders({ Authorization: "Bearer h" }) });
  await window.fetch("https://api-partner.spotify.com/pathfinder/v1/query?operationName=y", { headers: [["Authorization", "Bearer a"], ["App-Platform", "WebPlayer"]] });
  expect(posted[0].headers.authorization === "Bearer h" && posted[0].method === "GET" && posted[0].body === null, "a Headers object and a GET are read");
  expect(posted[1].headers.authorization === "Bearer a" && posted[1].headers["app-platform"] === "WebPlayer", "an array of pairs is read");
}
{
  const { window, posted, FakeRequest } = makePage();
  const request = new FakeRequest("https://api-partner.spotify.com/pathfinder/v2/query", { method: "POST", headers: { Authorization: "Bearer r" } });
  await window.fetch(request);
  expect(posted.length === 1 && posted[0].headers.authorization === "Bearer r" && posted[0].method === "POST", "a Request object is read");
  await window.fetch(request, { headers: { "Client-Token": "z" } });
  expect(posted[1].headers.authorization === "Bearer r" && posted[1].headers["client-token"] === "z", "a Request's headers and the call's own add up");
}
{
  const { window, posted, fetched } = makePage();
  await window.fetch("https://open.spotify.com/some/other/call", { headers: { Authorization: "Bearer no" } });
  expect(posted.length === 0 && fetched.length === 1, "calls that aren't the player's queries are not reported");
}
{
  const { window, posted, opened, FakeXHR } = makePage();
  const xhr = new window.XMLHttpRequest();
  xhr.open("POST", "https://api-partner.spotify.com/pathfinder/v2/query");
  xhr.setRequestHeader("Authorization", "Bearer x");
  const result = xhr.send('{"operationName":"fetchPlaylist"}');
  expect(result === "sent" && opened.length === 3, "XMLHttpRequest still reaches the real one");
  expect(posted.length === 1 && posted[0].headers.authorization === "Bearer x" && posted[0].body === '{"operationName":"fetchPlaylist"}', "an XMLHttpRequest query is reported");
}
{
  const { window, posted } = makePage();
  window.webkit = undefined;
  let threw = false;
  try { await window.fetch("https://api-partner.spotify.com/pathfinder/v2/query", {}); } catch { threw = true; }
  expect(!threw && posted.length === 0, "without the app's handler the page still works");
  const second = vm.runInContext(script, window) === undefined;
  expect(second, "running it twice is harmless");
}

{
  // The script that sends a query from inside the page: it runs as the body of an async function with `request`.
  const send = /static let sendScript = #"""\n([\s\S]*?)\n\s*"""#/.exec(swift)?.[1];
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push([url, init]);
    return { status: 429, headers: { get: (name) => (name === "retry-after" ? "3" : null) }, text: async () => "slow down" };
  };
  const answer = await new AsyncFunction("request", send)({ method: "POST", url: "https://x/pathfinder/v2/query", headers: { authorization: "Bearer t" }, body: "{}" });
  expect(answer.status === 429 && answer.retryAfter === 3 && answer.body === "slow down", "a query sent from the page answers with status, retry-after and body");
  expect(calls[0][1].method === "POST" && calls[0][1].body === "{}" && calls[0][1].headers.authorization === "Bearer t", "it sends what it was given");
  const get = await new AsyncFunction("request", send)({ method: "GET", url: "https://x/pathfinder/v1/query", headers: {}, body: null });
  expect(calls[1][1].body === undefined && get.retryAfter === 3, "a GET has no body");
}

if (failures > 0) { console.log(failures + " check(s) failed"); process.exit(1); }
console.log("All page hook checks passed");
