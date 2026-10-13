FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY iptv_engine ./iptv_engine
RUN useradd -m engine && mkdir -p /data/epg && chown engine /data/epg
USER engine
# Modo servicio: consulta la cola de "Forzar sincronización" y hace revisiones programadas.
CMD ["python", "-m", "iptv_engine", "loop"]
