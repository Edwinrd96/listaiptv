# Motor en un VPS gratuito (reemplaza a GitHub Actions)

**Por qué:** un repositorio privado de GitHub solo da 2 000 minutos gratis al mes; un motor programado los agota. Un VPS gratuito corre el motor **24/7 sin límite de minutos**, atiende el botón «Forzar sincronización» en ≤ 15 s (sin token de GitHub) y puede guardar la guía EPG. Regla del proyecto: **solo servidores gratuitos**.

> Datos de las capas gratis verificados en agosto de 2026 ([mrplanb](https://www.mrplanb.com/datacenter/free-vps-tiers), [klymentiev](https://klymentiev.com/blog/free-vps)). Cambian sin aviso: confírmalos en la página oficial de cada proveedor antes de crear la cuenta.

---

## 1. La limitación que ningún VPS gratis resuelve: el país

Los VPS gratuitos están en EE. UU. (u otras regiones lejanas), **no en República Dominicana**. Un canal que solo se ve dentro de RD parecerá caído desde allí. El proyecto lo maneja así:

| Dónde corre | `VANTAGE` | Qué cuenta como strike |
|---|---|---|
| VPS en EE. UU. | `vps-eeuu` | Solo 404/410 (un fallo de red no condena un canal) |
| Tu PC en RD (agente) | `local-do` (automático, por el país del agente) | Cualquier fallo |

**Solución híbrida (recomendada):**
1. El VPS verifica todo lo que se ve desde cualquier país.
2. Para los canales solo-RD: en el editor del canal → *Opciones avanzadas* → **«¿Desde dónde se valida este canal?» → «Solo desde República Dominicana»**. El VPS los **omite**.
3. En tu PC de casa corre el **agente** (panel → **Conexiones** → crear agente, país `DO`; ver `docs/` y la sección Agente de la guía). Solo el agente (`local-do`) valida esos canales.

Si todos tus canales se ven desde fuera de RD, no necesitas el agente.

---

## 2. Elegir proveedor (todos piden tarjeta solo para verificar identidad)

| | **Oracle Cloud Always Free** (recomendado) | **Google Cloud e2-micro** |
|---|---|---|
| Recursos | Arm Ampere A1: 2 CPU + 12 GB RAM; o 2 VM AMD micro (1 GB) | 1 VM e2-micro (2 vCPU compartidas, 1 GB RAM), 30 GB disco |
| Duración | Siempre gratis | Siempre gratis |
| Regiones gratis | La que elijas al registrarte (**no se puede cambiar**) | Solo `us-west1`, `us-central1`, `us-east1` |
| Catches | Capacidad Arm agotada a veces («Out of host capacity»); **recupera instancias ociosas**; Oracle recortó el nivel Arm en junio de 2026 sin avisar | Solo 1 GB de salida de red al mes gratis (el motor sube muy poco); 1 GB de RAM es justo |
| Para el motor | Sobra | Alcanza con `WORKERS=8` |

Mi recomendación: **Oracle Arm 2 CPU / 12 GB** (si no hay capacidad, la VM AMD micro de 1 GB sirve igual para este motor). Plan B: **Google e2-micro**.

### ⚠️ Oracle y las instancias «ociosas»
Oracle puede recuperar una instancia gratuita cuyo uso de CPU (percentil 95) y red sea menor al 20 % durante 7 días (en Arm también la memoria). **Un motor de verificación pasa mucho tiempo en reposo y podría caer en esa regla.** Opciones honestas:
- **Pasar la cuenta a «Pay As You Go»** y quedarte dentro de los límites gratuitos: según reportes de usuarios, así Oracle no recupera la instancia y no pagas nada. Hazlo solo si aceptas tener tarjeta ligada, y crea una **alerta de presupuesto de 1 USD** (Billing → Budgets). *No he podido confirmarlo en la documentación oficial: compruébalo allí antes.*
- O aceptar el riesgo: el panel y el monitor externo (`/health` en UptimeRobot) te avisan; si pierdes la instancia, vuelves a crearla y ejecutas `install.sh` (tardas ~15 min; la base de datos no se pierde porque está en Supabase).
- O usar Google e2-micro, que no tiene esta regla.

---

## 3. Crear el servidor

### Oracle Cloud
1. https://cloud.oracle.com → **Sign up** (elige bien la *Home region*: la más cercana de las disponibles, p. ej. US East – Ashburn).
2. Menú → **Compute → Instances → Create instance**:
   - **Image:** Canonical Ubuntu 24.04.
   - **Shape:** *Change shape* → **Ampere** → `VM.Standard.A1.Flex`, 2 OCPU, 12 GB. (Si da «Out of host capacity»: reintenta más tarde/otro *Availability domain*, o elige `VM.Standard.E2.1.Micro`.)
   - **Networking:** red pública con IP pública asignada.
   - **SSH keys:** *Generate a key pair* y **descarga la clave privada** (guárdala; sin ella no entras).
   - **Boot volume:** 50 GB.
3. **Create.** Anota la **IP pública**.
4. **Firewall:** deja abierto **solo el puerto 22 (SSH)**. El motor solo hace conexiones de salida: **no abras ningún otro puerto**.

### Google Cloud (alternativa)
1. https://console.cloud.google.com → crea proyecto → **Compute Engine → VM instances → Create**.
2. Tipo `e2-micro`, región `us-central1` (o `us-west1`/`us-east1`), disco *Standard persistent* de 30 GB, Ubuntu 24.04 LTS.
3. Sin tráfico HTTP/HTTPS permitido. Conéctate con el botón **SSH** del navegador o con `gcloud compute ssh`.

---

## 4. Conectarte y copiar el motor

Desde tu computadora (PowerShell en Windows; `ssh`/`scp` ya vienen incluidos):
```bash
ssh -i RUTA/a/tu-clave.key ubuntu@IP_PUBLICA        # en GCP el usuario es el tuyo de Google
```
Si SSH protesta por permisos de la clave (Mac/Linux): `chmod 600 tu-clave.key`.

En **otra** ventana, desde la raíz de tu proyecto, copia la carpeta del motor:
```bash
scp -i RUTA/a/tu-clave.key -r engine ubuntu@IP_PUBLICA:~/engine
```
(Incluye `deploy/`. Si ya generaste `engine/.env` con el asistente, se copia también.)

---

## 5. Configurar y arrancar

En el servidor:
```bash
cd ~/engine
nano .env          # si aún no existe: cp .env.example .env
```
Mínimo imprescindible:
```
SUPABASE_URL=https://TU-PROYECTO.supabase.co
SUPABASE_SERVICE_KEY=<la service_role>
ENGINE_ID=motor-vps
VANTAGE=vps-eeuu
WORKERS=16                 # en e2-micro de 1 GB usa 8
SCHEDULE_EVERY_MIN=30
```
Guía EPG (el Worker de Cloudflare no puede leer el disco del VPS, así que **usa almacenamiento S3**: ver paso 8 de la guía principal):
```
EPG_STORAGE=s3
S3_ENDPOINT=...   S3_BUCKET=...   S3_ACCESS_KEY_ID=...   S3_SECRET_ACCESS_KEY=...   S3_REGION=auto
EPG_MAX_MB=100
```
Instala y arranca (valida el `.env`, instala Docker si falta, crea swap en servidores de poca RAM, construye y prueba):
```bash
sudo sh deploy/install.sh
```
Debe terminar con **«✔ Motor funcionando»**. Si algo falta en el `.env`, el script lo dice con una frase clara y no instala nada a medias. (`sh deploy/install.sh --check-only` solo valida el `.env`.)

En Oracle Arm (12 GB) puedes dar más aire al contenedor: añade al `.env` `ENGINE_MEM_LIMIT=2g` y `ENGINE_CPUS=2`.

---

## 6. Comprobaciones
1. En el panel, el punto **Motor** se pone verde (hasta 1 minuto).
2. **Forzar sincronización** → la consola muestra «Auditando N fuentes…» y la tira de salud se llena.
3. En el servidor: `docker compose -f deploy/docker-compose.vps.yml ps` → estado `healthy`; `docker compose -f deploy/docker-compose.vps.yml logs -f --tail 50`.
4. Reinicia el servidor (`sudo reboot`), espera 2 minutos y confirma que el motor vuelve solo (`restart: unless-stopped`).

---

## 7. Apagar GitHub Actions
El workflow `engine.yml` **ya no se ejecuta solo** (quedó solo manual como plan B). Puedes borrar de Cloudflare (si los cargaste) `GITHUB_DISPATCH_TOKEN` y las variables `GITHUB_REPO` / `GITHUB_WORKFLOW`: con el motor en modo servicio ya no hacen falta.
Mantén el workflow `backup.yml` (semanal, gasta ~1 minuto).

---

## 8. Seguridad del servidor (10 minutos, una vez)
```bash
sudo apt-get update && sudo apt-get -y upgrade
sudo apt-get -y install unattended-upgrades ufw
sudo ufw allow OpenSSH && sudo ufw --force enable
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && sudo systemctl restart ssh
```
- Entra **solo con clave SSH** (sin contraseñas). Esto último hazlo **después** de comprobar que tu clave funciona.
- Tu `.env` en el VPS contiene la **service_role**: queda con permisos `600` (el script lo hace); no lo copies a ningún otro sitio.
- El contenedor corre sin privilegios, con sistema de archivos de solo lectura, sin capacidades extra y con límite de memoria.

---

## 9. Actualizar el motor
Cuando recibas una versión nueva, desde tu computadora:
```bash
scp -i clave.key -r engine/iptv_engine engine/requirements.txt engine/Dockerfile engine/deploy ubuntu@IP:~/engine/
```
(no sobrescribe tu `.env`). En el servidor: `sh ~/engine/deploy/redeploy.sh`.

---

## 10. Si pierdes el servidor
La base de datos y tus listas viven en Supabase; el servidor no guarda nada importante. Crea otro, copia `engine/` con tu `.env`, ejecuta `sudo sh deploy/install.sh`. Mientras tanto, **Actions → Motor IPTV → Run workflow** hace una revisión manual desde GitHub.

---

## Qué no he podido probar
No tengo acceso a Oracle, Google ni a un Docker en funcionamiento aquí. Verifiqué: la sintaxis de los scripts, la validación del `.env` (casos buenos y malos), que el archivo compose es válido y que el motor no escribe fuera de `/tmp` y `/data/epg`. **No** verifiqué la construcción de la imagen ni la instalación en un servidor real: por eso el paso 6 (comprobaciones) es obligatorio, y si `install.sh` falla pégame la salida completa.
