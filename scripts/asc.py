"""App Store Connect API için ortak yardımcılar. Anahtar, derleme sunucusunda gizli bilgiden yerleştirilir."""
import os
import time

import jwt
import requests

KEY_ID = os.environ["ASC_KEY_ID"]
ISSUER_ID = os.environ["ASC_ISSUER_ID"]
BUNDLE_ID = os.environ["BUNDLE_ID"]
TEAM_ID = os.environ["TEAM_ID"]
_ANAHTAR = open(os.environ["ASC_KEY_PATH"]).read()
_API = "https://api.appstoreconnect.apple.com/v1/"


def _belirtec():
    simdi = int(time.time())
    return jwt.encode(
        {"iss": ISSUER_ID, "iat": simdi, "exp": simdi + 900, "aud": "appstoreconnect-v1"},
        _ANAHTAR, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})


def api(yontem, yol, veri=None, params=None, kabul=()):
    r = requests.request(yontem, _API + yol, headers={"Authorization": "Bearer " + _belirtec()},
                         json=veri, params=params, timeout=60)
    if r.status_code >= 400 and r.status_code not in kabul:
        raise SystemExit(f"{yontem} {yol} -> {r.status_code}: {r.text[:800]}")
    return r.json() if r.text else {}


def ortama_yaz(ad, deger):
    with open(os.environ["GITHUB_ENV"], "a") as f:
        f.write(f"{ad}={deger}\n")
