"""TestFlight'ta iç test grubunu hazırlar; hesap sahibini gruba ekler.

Grup "tüm derlemelere erişim" açık kurulduğu için her yeni derleme, Apple işlemeyi bitirince
iPad'deki TestFlight uygulamasına kendiliğinden gelir. Tekrar çalıştırmak zararsızdır.
"""
from asc import BUNDLE_ID, api

uygulama = api("GET", "apps", params={"filter[bundleId]": BUNDLE_ID})["data"][0]["id"]

gruplar = [g for g in api("GET", f"apps/{uygulama}/betaGroups")["data"] if g["attributes"]["isInternalGroup"]]
if gruplar:
    grup = gruplar[0]
else:
    grup = api("POST", "betaGroups", {"data": {"type": "betaGroups",
        "attributes": {"name": "Deneme", "isInternalGroup": True, "hasAccessToAllBuilds": True},
        "relationships": {"app": {"data": {"type": "apps", "id": uygulama}}}}})["data"]
print("İç test grubu:", grup["attributes"]["name"])

for kullanici in api("GET", "users")["data"]:
    a = kullanici["attributes"]
    api("POST", "betaTesters", {"data": {"type": "betaTesters",
        "attributes": {"email": a["username"], "firstName": a.get("firstName") or "", "lastName": a.get("lastName") or ""},
        "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": grup["id"]}]}}}}, kabul=(409,))
    print("Test eden eklendi:", a.get("firstName"), a.get("lastName"))
