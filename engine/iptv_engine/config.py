import os, socket
from dataclasses import dataclass, field

SMART_TV_UAS = [   # formatos reales de Smart TV (Samsung Tizen, LG webOS, Sony Android TV)
    "Mozilla/5.0 (SMART-TV; LINUX; Tizen 6.5) AppleWebKit/537.36 (KHTML, like Gecko) 85.0.4183.93/6.5 TV Safari/537.36",
    "Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.128 Safari/537.36 WebAppManager",
    "Mozilla/5.0 (Linux; Android 11; BRAVIA 4K GB) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36",
]
DEFAULT_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"


@dataclass
class Config:
    supabase_url: str = ""
    service_key: str = ""
    engine_id: str = field(default_factory=lambda: os.getenv("ENGINE_ID") or socket.gethostname())
    vantage: str = "unknown"              # local-do | github | vps-xx ...
    workers: int = 32
    timeout: float = 5.0                  # segundos, TOTAL por sondeo
    channel_budget: float = 20.0          # segundos máx. por fuente (incluye rotación de User-Agents)
    poll_seconds: int = 15
    schedule_every_min: int = 30          # 0 = no hacer revisiones programadas, solo trabajos del botón
    hard_failures: str = "auto"           # auto | all | 404
    anon_key: str = ""                    # modo agente (BYON): clave pública + AGENT_TOKEN; NUNCA la service_role
    agent_token: str = ""
    telegram_token: str = ""
    telegram_chat_id: str = ""
    iptv_org_fallback: bool = True
    dm_api: str = "https://www.dailymotion.com/player/metadata/video/{id}"
    tg_api: str = "https://api.telegram.org"
    proxy_test_url: str = "https://ipinfo.io/json"   # devuelve la IP y el país de salida del proxy
    proxy_retest_hours: int = 6
    # Guía EPG: dónde se deja el epg.xml.gz. file = carpeta local (VPS/pruebas) · s3 = R2, MinIO o cualquier almacén compatible con S3
    epg_storage: str = "file"
    epg_dir: str = "./epg"
    s3_endpoint: str = ""
    s3_bucket: str = ""
    s3_key_id: str = ""
    s3_secret: str = ""
    s3_region: str = "auto"
    epg_days: int = 3                     # días hacia adelante que se conservan
    epg_every_hours: int = 12             # 0 = solo cuando el usuario pulsa el botón
    epg_max_mb: int = 200                 # tope por fuente (descargado)
    epg_index_max: int = 20000            # canales de la guía que se indexan para el autocompletar

    @property
    def hard_all(self) -> bool:
        """¿Cualquier fallo cuenta como strike? Solo si el motor está en la red donde se ven los canales."""
        if self.hard_failures == "all":
            return True
        if self.hard_failures == "404":
            return False
        return self.vantage.startswith("local")


def load() -> Config:
    e = os.getenv
    c = Config(
        supabase_url=e("SUPABASE_URL", "").rstrip("/"), service_key=e("SUPABASE_SERVICE_KEY", ""),
        vantage=e("VANTAGE", "unknown"), workers=int(e("WORKERS", "32")), timeout=float(e("TIMEOUT", "5")),
        channel_budget=float(e("CHANNEL_BUDGET", "20")), poll_seconds=int(e("POLL_SECONDS", "15")),
        schedule_every_min=int(e("SCHEDULE_EVERY_MIN", "30")), hard_failures=e("HARD_FAILURES", "auto"),
        anon_key=e("SUPABASE_ANON_KEY", ""), agent_token=e("AGENT_TOKEN", ""),
        telegram_token=e("TELEGRAM_TOKEN", ""), telegram_chat_id=e("TELEGRAM_CHAT_ID", ""),
        iptv_org_fallback=e("IPTV_ORG_FALLBACK", "true").lower() != "false",
    )
    if e("DM_API"): c.dm_api = e("DM_API")
    if e("TG_API"): c.tg_api = e("TG_API")
    if e("PROXY_TEST_URL"): c.proxy_test_url = e("PROXY_TEST_URL")
    c.epg_storage = e("EPG_STORAGE", c.epg_storage).lower(); c.epg_dir = e("EPG_DIR", c.epg_dir)
    c.s3_endpoint, c.s3_bucket = e("S3_ENDPOINT", ""), e("S3_BUCKET", "")
    c.s3_key_id, c.s3_secret, c.s3_region = e("S3_ACCESS_KEY_ID", ""), e("S3_SECRET_ACCESS_KEY", ""), e("S3_REGION", "auto")
    c.epg_days, c.epg_every_hours, c.epg_max_mb = int(e("EPG_DAYS", "3")), int(e("EPG_EVERY_HOURS", "12")), int(e("EPG_MAX_MB", "200"))
    if e("PROXY_RETEST_HOURS"): c.proxy_retest_hours = int(e("PROXY_RETEST_HOURS"))
    return c
