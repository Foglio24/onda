/// The script SpotifySession injects into Spotify's web player (at document start, in the page's own
/// world). It wraps `fetch` and `XMLHttpRequest` and tells the app about the player's "pathfinder"
/// calls: their URL, the headers the player set (its token, its client token) and the body (which
/// query, with which hash). Nothing else leaves the page, and the player's calls go on unchanged.
/// Tools/SpotifyImportCheck/hook.mjs runs this very text against a fake page.
enum SpotifyHook {
    static let handlerName = "seaglassSpotify"

    static let script = #"""
    (function () {
      if (window.__seaglassSpotifyHook) return;
      window.__seaglassSpotifyHook = true;
      var HANDLER = "seaglassSpotify";

      function post(message) {
        try { window.webkit.messageHandlers[HANDLER].postMessage(message); } catch (e) {}
      }

      // Headers arrive as a Headers object, an array of pairs or a plain object.
      function headersOf(value) {
        var out = {};
        if (!value) return out;
        try {
          if (typeof Headers !== "undefined" && value instanceof Headers) {
            value.forEach(function (v, k) { out[String(k).toLowerCase()] = String(v); });
          } else if (Array.isArray(value)) {
            value.forEach(function (pair) {
              if (pair && pair.length >= 2) out[String(pair[0]).toLowerCase()] = String(pair[1]);
            });
          } else if (typeof value === "object") {
            Object.keys(value).forEach(function (k) { out[k.toLowerCase()] = String(value[k]); });
          }
        } catch (e) {}
        return out;
      }

      function report(url, method, headers, body) {
        url = String(url);
        if (url.indexOf("/pathfinder/") < 0) return;
        post({ url: url, method: String(method || "GET").toUpperCase(), headers: headers, body: typeof body === "string" ? body : null });
      }

      var realFetch = window.fetch;
      if (typeof realFetch === "function") {
        window.fetch = function (input, init) {
          try {
            var isRequest = typeof Request !== "undefined" && input instanceof Request;
            var url = isRequest ? input.url : (input && input.url ? input.url : input);
            var method = (init && init.method) || (isRequest ? input.method : "GET");
            var headers = {};
            if (isRequest) Object.assign(headers, headersOf(input.headers));
            Object.assign(headers, headersOf(init && init.headers));
            report(url, method, headers, init && init.body);
          } catch (e) {}
          return realFetch.apply(this, arguments);
        };
      }

      var proto = window.XMLHttpRequest && window.XMLHttpRequest.prototype;
      if (proto) {
        var realOpen = proto.open, realSet = proto.setRequestHeader, realSend = proto.send;
        proto.open = function (method, url) {
          this.__seaglass = { method: method, url: url, headers: {} };
          return realOpen.apply(this, arguments);
        };
        proto.setRequestHeader = function (name, value) {
          try { if (this.__seaglass) this.__seaglass.headers[String(name).toLowerCase()] = String(value); } catch (e) {}
          return realSet.apply(this, arguments);
        };
        proto.send = function (body) {
          try {
            var note = this.__seaglass;
            if (note) report(note.url, note.method, note.headers, body);
          } catch (e) {}
          return realSend.apply(this, arguments);
        };
      }
    })();
    """#

    /// Runs one request from inside the page (the player's own origin) and answers with
    /// `{status, retryAfter, body}`. `request` is `{method, url, headers, body}`.
    static let sendScript = #"""
    const response = await fetch(request.url, {
      method: request.method,
      headers: request.headers,
      body: request.body === null ? undefined : request.body
    });
    const retryAfter = parseFloat(response.headers.get("retry-after"));
    return { status: response.status, retryAfter: isNaN(retryAfter) ? null : retryAfter, body: await response.text() };
    """#
}
