# IPTV Edwin RD

Edita solo `channels.yaml`. Todo lo demás se genera.

```
pip install -r requirements.txt
python iptv.py check      # valida y autorepara URLs
python iptv.py build      # dist/iptv.m3u (TiviMate/Kodi/OTT/Smarters), iptv_vlc.m3u (VLC), caidos.m3u
python iptv.py epg        # dist/epg.xml.gz solo con tus canales
python iptv.py add URL --name "Canal" --group "🇩🇴 Dominicana"
python iptv.py import https://iptv-org.github.io/iptv/countries/do.m3u --group "🇩🇴 Dominicana"
```

Automatización: sube la carpeta a GitHub; el workflow corre cada 6 h.
Pon `epg_public_url` en channels.yaml con la URL raw de dist/epg.xml.gz.
Opcional: secrets TELEGRAM_TOKEN y TELEGRAM_CHAT_ID para avisos de canales caídos.
