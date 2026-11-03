"""TestFlight herkese açık bağlantı: test bilgileri, dış grup, derlemeyi beta incelemesine gönderme.

Tekrar çalıştırmak zararsızdır; var olanı günceller. İletişim telefonu ve e-postası gizli bilgiden gelir.
"""
import os
import sys

from asc import BUNDLE_ID, api

GIZLILIK = "https://docs.google.com/document/d/1s3Zy--ZsukAUdrutJhnYgRQ92vbCI7LlF1AcAa7jCao/edit?usp=drivesdk"
ACIKLAMA = ("Erişilebilir Reklamsız Radyo; Türkiye'nin radyo ve TV yayınlarını reklamsız dinlemenizi sağlar. "
            "VoiceOver ile tam uyumludur. Sesli asistanla radyo açabilir, yayınları kaydedebilir, "
            "favorilerinizi düzenleyebilir ve uyku zamanlayıcısı kurabilirsiniz.")
YENILIKLER = ("Radyo ve TV yayınlarını dinleyin, sesli asistanı, kaydı (MP3, M4A, WAV), favorileri, "
              "uyku zamanlayıcısını ve ayarları deneyin. Sorunları TestFlight üzerinden bildirebilirsiniz.")
NOT = ("Uygulama hesap gerektirmez. Mikrofon yalnızca sesli asistan için, kullanıcı asistanı açınca kullanılır. "
       "Radyo ve TV listeleri GitHub'daki açık listeden gelir.")
GRUP_ADI = "Herkese Açık"

eposta = os.environ["BETA_EPOSTA"].strip()
telefon = os.environ["BETA_TELEFON"].strip()
derleme_no = sys.argv[1] if len(sys.argv) > 1 else None

uygulama = api("GET", "apps", params={"filter[bundleId]": BUNDLE_ID})["data"][0]["id"]

# 1) Test bilgileri (Türkçe)
yerel = {"description": ACIKLAMA, "feedbackEmail": eposta, "privacyPolicyUrl": GIZLILIK}
mevcut = [l for l in api("GET", f"apps/{uygulama}/betaAppLocalizations")["data"] if l["attributes"]["locale"] == "tr"]
if mevcut:
    api("PATCH", f"betaAppLocalizations/{mevcut[0]['id']}", {"data": {"type": "betaAppLocalizations",
        "id": mevcut[0]["id"], "attributes": yerel}})
else:
    api("POST", "betaAppLocalizations", {"data": {"type": "betaAppLocalizations",
        "attributes": dict(yerel, locale="tr"),
        "relationships": {"app": {"data": {"type": "apps", "id": uygulama}}}}})
print("Test bilgileri yazıldı")

# 2) Beta incelemesi iletişim bilgileri
api("PATCH", f"betaAppReviewDetails/{uygulama}", {"data": {"type": "betaAppReviewDetails", "id": uygulama,
    "attributes": {"contactFirstName": "Fırat", "contactLastName": "Ataş", "contactEmail": eposta,
                   "contactPhone": telefon, "demoAccountRequired": False, "notes": NOT}}})
print("İnceleme iletişim bilgileri yazıldı")

# 3) Derleme
filtre = {"filter[app]": uygulama, "sort": "-uploadedDate", "limit": 1}
if derleme_no:
    filtre["filter[version]"] = derleme_no
derleme = api("GET", "builds", params=filtre)["data"][0]
print("Derleme:", derleme["attributes"]["version"], derleme["attributes"]["processingState"])
if derleme["attributes"]["processingState"] != "VALID":
    raise SystemExit("Derleme henüz işlenmedi")

yb = [l for l in api("GET", f"builds/{derleme['id']}/betaBuildLocalizations")["data"] if l["attributes"]["locale"] == "tr"]
if yb:
    api("PATCH", f"betaBuildLocalizations/{yb[0]['id']}", {"data": {"type": "betaBuildLocalizations",
        "id": yb[0]["id"], "attributes": {"whatsNew": YENILIKLER}}})
else:
    api("POST", "betaBuildLocalizations", {"data": {"type": "betaBuildLocalizations",
        "attributes": {"locale": "tr", "whatsNew": YENILIKLER},
        "relationships": {"build": {"data": {"type": "builds", "id": derleme["id"]}}}}})
print("Test edilecekler yazıldı")

# 4) Dış grup, herkese açık bağlantı
gruplar = [g for g in api("GET", f"apps/{uygulama}/betaGroups")["data"]
           if not g["attributes"]["isInternalGroup"] and g["attributes"]["name"] == GRUP_ADI]
if gruplar:
    grup = gruplar[0]
else:
    grup = api("POST", "betaGroups", {"data": {"type": "betaGroups",
        "attributes": {"name": GRUP_ADI, "publicLinkEnabled": True, "publicLinkLimitEnabled": False,
                       "feedbackEnabled": True},
        "relationships": {"app": {"data": {"type": "apps", "id": uygulama}}}}})["data"]
if not grup["attributes"].get("publicLinkEnabled"):
    grup = api("PATCH", f"betaGroups/{grup['id']}", {"data": {"type": "betaGroups", "id": grup["id"],
        "attributes": {"publicLinkEnabled": True, "publicLinkLimitEnabled": False}}})["data"]
api("POST", f"betaGroups/{grup['id']}/relationships/builds",
    {"data": [{"type": "builds", "id": derleme["id"]}]}, kabul=(409,))
print("Dış grup hazır, derleme eklendi")

# 5) Beta incelemesine gönder
r = api("POST", "betaAppReviewSubmissions", {"data": {"type": "betaAppReviewSubmissions",
    "relationships": {"build": {"data": {"type": "builds", "id": derleme["id"]}}}}}, kabul=(409, 422))
print("İnceleme gönderimi:", r.get("data", {}).get("attributes") or r.get("errors", [{}])[0].get("detail"))

grup = api("GET", f"betaGroups/{grup['id']}")["data"]
print("HERKESE AÇIK BAĞLANTI:", grup["attributes"].get("publicLink"))
