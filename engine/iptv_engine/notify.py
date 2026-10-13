import requests
from .config import Config


def telegram(cfg: Config, text: str) -> bool:
    if not (cfg.telegram_token and cfg.telegram_chat_id):
        return False
    try:
        j = requests.post(f"{cfg.tg_api}/bot{cfg.telegram_token}/sendMessage", data={"chat_id": cfg.telegram_chat_id, "text": text[:4000]}, timeout=15).json()
        return bool(j.get("ok"))
    except Exception:
        return False
