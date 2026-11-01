"""Derleme sunucusunda dağıtım sertifikası ve App Store profili hazırlar.

Mac olmadığı için sertifikanın gizli anahtarı her derlemede sunucuda yeniden üretilir.
Apple bireysel hesaplarda en fazla birkaç dağıtım sertifikasına izin verdiği için,
sınır dolunca en eskisi iptal edilir. Bu, yayınlanmış ya da TestFlight'taki sürümleri etkilemez.
"""
import base64
import os
import plistlib
import secrets
import subprocess

from asc import BUNDLE_ID, TEAM_ID, api, ortama_yaz

PROFIL_ADI = "Reklamsiz Radyo App Store"
OPENSSL = "/usr/bin/openssl"
os.makedirs("build", exist_ok=True)


def calistir(*komut):
    subprocess.run(komut, check=True)


bundle = [b for b in api("GET", "bundleIds", params={"filter[identifier]": BUNDLE_ID})["data"]
          if b["attributes"]["identifier"] == BUNDLE_ID][0]

# Sertifika sınırı dolmasın: 2 ve fazlası varsa en eskileri iptal et
mevcut = api("GET", "certificates", params={"filter[certificateType]": "DISTRIBUTION", "limit": 200})["data"]
mevcut.sort(key=lambda c: c["attributes"].get("expirationDate") or "")
for c in mevcut[:max(0, len(mevcut) - 1)]:
    api("DELETE", "certificates/" + c["id"], kabul=(404, 409))

calistir(OPENSSL, "genrsa", "-out", "build/dagitim.key", "2048")
calistir(OPENSSL, "req", "-new", "-key", "build/dagitim.key", "-out", "build/dagitim.csr",
         "-subj", "/CN=Reklamsiz Radyo CI/C=TR")
csr = open("build/dagitim.csr").read()
sertifika = api("POST", "certificates", {"data": {"type": "certificates", "attributes": {
    "certificateType": "DISTRIBUTION", "csrContent": csr}}})["data"]
open("build/dagitim.cer", "wb").write(base64.b64decode(sertifika["attributes"]["certificateContent"]))
calistir(OPENSSL, "x509", "-inform", "DER", "-in", "build/dagitim.cer", "-out", "build/dagitim.pem")

sifre = secrets.token_hex(16)
calistir(OPENSSL, "pkcs12", "-export", "-inkey", "build/dagitim.key", "-in", "build/dagitim.pem",
         "-out", "build/dagitim.p12", "-passout", "pass:" + sifre)
anahtarlik = os.path.expanduser("~/Library/Keychains/derleme.keychain-db")
calistir("security", "create-keychain", "-p", sifre, anahtarlik)
calistir("security", "set-keychain-settings", "-lut", "21600", anahtarlik)
calistir("security", "unlock-keychain", "-p", sifre, anahtarlik)
calistir("security", "import", "build/dagitim.p12", "-k", anahtarlik, "-P", sifre,
         "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
calistir("security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", sifre, anahtarlik)
eski = subprocess.run(["security", "list-keychains", "-d", "user"], capture_output=True, text=True).stdout
calistir("security", "list-keychains", "-d", "user", "-s", anahtarlik,
         *[s.strip().strip('"') for s in eski.split() if s.strip()])
os.remove("build/dagitim.key")
os.remove("build/dagitim.p12")

# Eski profili sil, yeni sertifikayla yeniden oluştur
for p in api("GET", "profiles", params={"filter[name]": PROFIL_ADI})["data"]:
    api("DELETE", "profiles/" + p["id"], kabul=(404, 409))
profil = api("POST", "profiles", {"data": {"type": "profiles",
    "attributes": {"name": PROFIL_ADI, "profileType": "IOS_APP_STORE"},
    "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                      "certificates": {"data": [{"type": "certificates", "id": sertifika["id"]}]}}}})["data"]
icerik = base64.b64decode(profil["attributes"]["profileContent"])
uuid = profil["attributes"]["uuid"]
for klasor in ("~/Library/MobileDevice/Provisioning Profiles",
               "~/Library/Developer/Xcode/UserData/Provisioning Profiles"):
    k = os.path.expanduser(klasor)
    os.makedirs(k, exist_ok=True)
    open(os.path.join(k, uuid + ".mobileprovision"), "wb").write(icerik)

plistlib.dump({
    "method": "app-store-connect",
    "destination": "upload",
    "teamID": TEAM_ID,
    "signingStyle": "manual",
    "signingCertificate": "Apple Distribution",
    "provisioningProfiles": {BUNDLE_ID: PROFIL_ADI},
    "uploadSymbols": True,
    "manageAppVersionAndBuildNumber": False,
}, open("build/ExportOptions.plist", "wb"))

ortama_yaz("PROFIL_ADI", PROFIL_ADI)
ortama_yaz("KEYCHAIN", anahtarlik)
print("İmzalama hazır. Profil:", PROFIL_ADI, uuid)
