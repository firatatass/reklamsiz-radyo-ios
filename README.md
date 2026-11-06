# Erişilebilir Reklamsız Radyo — iPhone ve iPad

Erişilebilir Reklamsız Radyo uygulamasının iPhone ve iPad sürümü.
Radyo ve TV listeleri Android sürümüyle aynı kaynaktan gelir:
https://github.com/firatatass/reklamsiz-radyo-liste

Uygulamanın içinde gömülü liste yoktur. Listeler ilk açılışta internetten indirilir,
sonraki açılışlarda internet olmasa da son indirilen liste kullanılır.

## Hazır listeyi kapatmak

Liste deposundaki `surum.json` dosyasına `"ios_aktif": false` eklenir. Android bu alanı kullanmaz.
Uygulama açılınca ya da öne gelince bunu görür ve herkeste bütün radyolar gizlenir, çalan yayın durur,
kullanıcıya link veya liste eklemesi için uyarı gösterilir. Kayıtlar silinmez, sadece gizlenir.
Alan silinir ya da `true` yapılırsa her şey sırası, favorileri ve ayarlarıyla aynen geri gelir.

Uygulama ekran okuyucu (VoiceOver) kullanıcıları düşünülerek yapılır.
