#!/usr/bin/env python3
"""A throwaway account on the live account service, signed in as the app signs in.

    session.py <origin> create   prints an app session token (the sign-in page, then the code
                                 exchanged with the verifier, as Seaglass's sign-in sheet does)
    session.py <origin> delete <token>   deletes that account and everything with it
"""

import base64
import hashlib
import http.cookiejar
import json
import secrets
import sys
import urllib.parse
import urllib.request
import uuid


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


# Cloudflare turns away Python's own user agent.
USER_AGENT = "SeaglassMacAccountCheck/1.0"


def request(opener, origin, method, path, body=None, token=None):
    headers = {"Origin": origin, "Accept": "application/json", "User-Agent": USER_AGENT}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(origin + path, data=data, headers=headers, method=method)
    with opener.open(req, timeout=30) as response:
        text = response.read().decode()
    return json.loads(text) if text else None


def create(origin):
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    verifier = b64url(secrets.token_bytes(32))
    state = b64url(secrets.token_bytes(32))
    challenge = b64url(hashlib.sha256(verifier.encode()).digest())
    query = urllib.parse.urlencode({"challenge": challenge, "state": state})
    opener.open(urllib.request.Request(f"{origin}/v1/auth/start?{query}", headers={"User-Agent": USER_AGENT}), timeout=30).read()
    email = f"mac-check-{uuid.uuid4().hex[:10]}@example.com"
    password = "Mac-check-" + secrets.token_hex(6)
    request(opener, origin, "POST", "/v1/auth/register", {"email": email, "password": password})
    login = request(opener, origin, "POST", "/v1/auth/login", {"email": email, "password": password})
    callback = urllib.parse.urlparse(login["redirect"])
    params = urllib.parse.parse_qs(callback.query)
    if callback.scheme != "com.onda.player.auth" or params.get("state") != [state]:
        raise SystemExit("The sign-in page didn't hand back to the app")
    session = request(opener, origin, "POST", "/v1/auth/exchange", {"code": params["code"][0], "verifier": verifier})
    token = session["token"]
    request(opener, origin, "PUT", "/v1/sync/profile/profile",
            {"revision": 0, "operationId": str(uuid.uuid4()), "data": {"firstName": "Mac", "lastName": "Check"}}, token)
    print(token)


def delete(origin, token):
    opener = urllib.request.build_opener()
    request(opener, origin, "DELETE", "/v1/account", {"confirm": "ELIMINA IL MIO ACCOUNT"}, token)


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[2] == "create":
        create(sys.argv[1].rstrip("/"))
    elif len(sys.argv) == 4 and sys.argv[2] == "delete":
        delete(sys.argv[1].rstrip("/"), sys.argv[3])
    else:
        raise SystemExit(__doc__)
