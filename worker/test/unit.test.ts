import { describe, expect, it } from 'vitest';
import { encHeader, parseM3U, renderM3U } from '../src/m3u';
import { assertPublicUrl, isPrivateHost, makeToken, rateLimit, readToken, _resetRateLimits } from '../src/util';
import { hintFor, parseVariants } from '../src/probe';
import type { Payload } from '../src/types';

const payload: Payload = {
  playlist: { id: 'p', name: 'Lista', version: 7, settings: { ua: 'UA-DEFAULT/1.0 (x)', encode_headers: true } },
  output: { id: 'o', format: 'm3u', only_healthy: true },
  channels: [
    { tvg_id: 'tele5', name: 'Telemicro "5"', logo: 'https://l/x.png', group: '🇩🇴 Dominicana', epg_id: 'g5', chno: 5, lang: 'es',
      catchup: { type: 'append', source: '?utc={utc}&lutc={lutc}', days: 3 },
      source: { url: 'https://live4.telemicro.com.do/live/55/playlist.m3u8', referer: 'https://telemicro.com.do/players/5tv/', ua: null, kind: 'direct', state: 'ok' } },
    { tvg_id: 'colorv', name: 'Color Visión', logo: '', group: 'Dominicana', source: { url: 'https://old.token/sec2(x)/dm/3/x7gy059/live.m3u8', referer: 'https://geo.dailymotion.com/', kind: 'dailymotion', resolve_ref: 'dm:x7gy059', state: 'unknown' } },
    { tvg_id: 'plain', name: 'Sin headers', group: 'Otros', source: { url: 'http://h.test/a.m3u8', kind: 'direct' } },
  ],
};

describe('M3U', () => {
  it('encHeader = Python quote(safe=":/.-_~")', () => {
    expect(encHeader('Mozilla/5.0 (Windows NT 10.0; Win64; x64)')).toBe('Mozilla/5.0%20%28Windows%20NT%2010.0%3B%20Win64%3B%20x64%29');
    expect(encHeader('https://a.b/c?d=e&f')).toBe('https://a.b/c%3Fd%3De%26f');
  });
  it('formato estándar: atributos, catchup, headers en la URL, dm vía Worker', () => {
    const t = renderM3U(payload, { vlc: false, origin: 'https://play.test', epgUrl: 'https://play.test/p/T/epg.xml.gz' }).split('\n');
    expect(t[0]).toBe('#EXTM3U x-tvg-url="https://play.test/p/T/epg.xml.gz"');
    expect(t[2]).toBe(`#EXTINF:-1 tvg-id="tele5" tvg-name="Telemicro '5'" tvg-logo="https://l/x.png" tvg-chno="5" tvg-language="es" group-title="🇩🇴 Dominicana" catchup="append" catchup-source="?utc={utc}&lutc={lutc}" catchup-days="3",Telemicro '5'`);
    expect(t[3]).toBe('https://live4.telemicro.com.do/live/55/playlist.m3u8|User-Agent=UA-DEFAULT/1.0%20%28x%29&Referer=https://telemicro.com.do/players/5tv/&Origin=https://telemicro.com.do');
    expect(t[6]).toBe('https://play.test/dm/x7gy059.m3u8');                    // Dailymotion: sin token incrustado
    expect(t[9]).toBe('http://h.test/a.m3u8|User-Agent=UA-DEFAULT/1.0%20%28x%29');
  });
  it('formato VLC', () => {
    const t = renderM3U(payload, { vlc: true, origin: 'https://play.test' }).split('\n');
    expect(t[0]).toBe('#EXTM3U');
    expect(t.slice(3, 7)).toEqual(['#EXTVLCOPT:http-user-agent=UA-DEFAULT/1.0 (x)', '#EXTVLCOPT:http-referrer=https://telemicro.com.do/players/5tv/', '#EXTVLCOPT:http-reconnect=true', 'https://live4.telemicro.com.do/live/55/playlist.m3u8']);
  });
  it('ida y vuelta: el parser recupera referer y UA de ambos formatos', () => {
    for (const vlc of [false, true]) {
      const items = parseM3U(renderM3U(payload, { vlc, origin: 'https://play.test' }));
      expect(items).toHaveLength(3);
      expect(items[0]).toMatchObject({ name: "Telemicro '5'", referer: 'https://telemicro.com.do/players/5tv/', ua: 'UA-DEFAULT/1.0 (x)', epg: 'tele5' });
    }
  });
});

describe('seguridad', () => {
  it('SSRF: hosts privados y puertos peligrosos', () => {
    for (const h of ['localhost', '127.0.0.1', '10.0.0.5', '192.168.1.1', '172.20.0.1', '169.254.169.254', '[::1]', 'intranet', 'x.local']) expect(isPrivateHost(h)).toBe(true);
    for (const h of ['example.com', '8.8.8.8', 'cdn.tv.do']) expect(isPrivateHost(h)).toBe(false);
    const e = {} as any;
    expect(() => assertPublicUrl('http://127.0.0.1/x', e)).toThrow();
    expect(() => assertPublicUrl('ftp://example.com/x', e)).toThrow();
    expect(() => assertPublicUrl('https://user:pw@example.com/x', e)).toThrow();
    expect(() => assertPublicUrl('http://example.com:6379/x', e)).toThrow();
    expect(() => assertPublicUrl('https://ss5.domint.net:3176/otv/x.m3u8', e)).not.toThrow();      // puertos 3xxx de tus canales
    expect(() => assertPublicUrl('http://127.0.0.1:9/x', { ALLOW_PRIVATE_HOSTS: '1' })).not.toThrow();
  });
  it('tokens firmados: válidos, manipulados y con otra clave', async () => {
    const t = await makeToken('k1', { a: 1 });
    expect(await readToken('k1', t)).toEqual({ a: 1 });
    expect(await readToken('k2', t)).toBeNull();
    expect(await readToken('k1', t.replace(/^./, (c) => (c === 'A' ? 'B' : 'A')))).toBeNull();
  });
  it('rate limit por ventana', () => {
    _resetRateLimits();
    expect([1, 2, 3].map(() => rateLimit('k', 2, 1000).ok)).toEqual([true, true, false]);
  });
});

describe('sondeo (utilidades)', () => {
  it('parseVariants y pistas', () => {
    const { variants, uris } = parseVariants('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,CODECS="avc1"\nm.m3u8\n');
    expect(variants).toEqual([{ height: 720, bandwidth: 2500000, codecs: 'avc1' }]); expect(uris).toEqual(['m.m3u8']);
    expect(hintFor('HTTP 403', 'https://x')).toMatch(/Referer/); expect(hintFor('HTTP 404', 'https://x')).toMatch(/caducada/);
    expect(hintFor('Timeout', 'https://x')).toMatch(/Sin respuesta/);
  });
});
