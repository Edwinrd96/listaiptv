"""Cliente mínimo de PostgREST/Supabase con la clave de servicio. Todo el trabajo "inteligente" vive en SQL (record_probe, claim_job...)."""
import requests


class SupaError(Exception):
    pass


class Supa:
    def __init__(self, url: str, key: str):
        self.base = f"{url}/rest/v1"
        self.s = requests.Session()
        self.s.headers.update({"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"})

    def _check(self, r: requests.Response):
        if not r.ok:
            raise SupaError(f"{r.status_code} {r.text[:300]}")
        return r.json() if r.text else None

    def rpc(self, fn: str, args: dict | None = None):
        return self._check(self.s.post(f"{self.base}/rpc/{fn}", json=args or {}, timeout=30))

    def select(self, table: str, params: dict | None = None):
        return self._check(self.s.get(f"{self.base}/{table}", params=params or {}, timeout=30))

    def insert(self, table: str, row: dict):
        return self._check(self.s.post(f"{self.base}/{table}", json=row, headers={"Prefer": "return=representation"}, timeout=30))

    def patch(self, table: str, params: dict, row: dict):
        return self._check(self.s.patch(f"{self.base}/{table}", params=params, json=row, headers={"Prefer": "return=representation"}, timeout=30))

    def insert_many(self, table: str, rows: list[dict]):
        if rows:
            self._check(self.s.post(f"{self.base}/{table}", json=rows, headers={"Prefer": "return=minimal"}, timeout=60))

    def delete(self, table: str, params: dict):
        return self._check(self.s.delete(f"{self.base}/{table}", params=params, headers={"Prefer": "return=minimal"}, timeout=60))
