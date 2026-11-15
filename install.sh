#!/usr/bin/env bash
# Instala (o actualiza) steam-relay en este servidor y lo deja corriendo en PM2.
#
#   Instalar / actualizar:   bash install.sh < archivo.env     (el .env entra por stdin: nunca queda en la línea de comandos)
#   Actualizar sin tocar .env: bash install.sh
#   Solo ver el estado:      bash install.sh --status
#
# Revisa lo que hace falta (git, curl, Node >= 20.12, PM2) e instala lo que falte. Node se instala con nvm en el
# usuario actual (no necesita root). Al final imprime una línea "STEAM_RELAY_STATUS {json}" con el estado.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/fullstackown/rusharena-api-steam-bot.git}"
BRANCH="${BRANCH:-main}"
DIR="${DIR:-$HOME/steam-relay}"
APP="steam-relay"
NODE_VERSION="${NODE_VERSION:-24}"
MODE="${1:-install}"

log() { echo "[steam-relay] $*"; }
fail() { echo "[steam-relay] ERROR: $*" >&2; exit 1; }

# El .env llega por stdin (si hay algo). Se lee antes que nada para que ningún comando lo consuma.
ENV_CONTENT=""
if [ "$MODE" != "--status" ] && [ ! -t 0 ]; then ENV_CONTENT="$(cat || true)"; fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then SUDO="sudo -n"; else SUDO="__none__"; fi
fi
as_root() {
  if [ "$SUDO" = "__none__" ]; then return 1; fi
  if [ -n "$SUDO" ]; then $SUDO "$@"; else "$@"; fi
}

load_node() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
}
node_ok() {
  command -v node >/dev/null 2>&1 && node -e 'process.exit(typeof process.loadEnvFile==="function"?0:1)' 2>/dev/null
}

status_json() {
  load_node
  local port health
  port="$(grep -E '^PORT=' "$DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"' \r')"
  port="${port:-4870}"
  health="$(curl -fsS -m 5 "http://127.0.0.1:${port}/health" 2>/dev/null || echo 'null')"
  # pm2 jlist puede ser enorme (incluye el entorno de cada app): va por stdin y solo se toma steam-relay.
  { pm2 jlist 2>/dev/null || echo '[]'; } | PORT_="$port" HEALTH_="$health" node -e '
    const os = require("os");
    let raw = ""; process.stdin.on("data", (d) => (raw += d)).on("end", () => {
      let pm = []; try { pm = JSON.parse(raw.slice(raw.indexOf("["))); } catch {}
      const a = pm.find((p) => p.name === "steam-relay");
      let health = null; try { health = JSON.parse(process.env.HEALTH_); } catch {}
      console.log("STEAM_RELAY_STATUS " + JSON.stringify({
        installed: !!a,
        pm2: a ? { status: a.pm2_env.status, restarts: a.pm2_env.restart_time, uptimeSince: a.pm2_env.pm_uptime, memory: a.monit && a.monit.memory, cpu: a.monit && a.monit.cpu } : null,
        health, port: Number(process.env.PORT_), node: process.version,
        host: { hostname: os.hostname(), platform: os.type() + " " + os.release(), cpus: os.cpus().length, loadavg: os.loadavg(), memTotal: os.totalmem(), memFree: os.freemem(), uptimeSec: Math.round(os.uptime()) },
      }));
    });
  ' || echo 'STEAM_RELAY_STATUS {"installed":false,"error":"Node no disponible"}'
}

if [ "$MODE" = "--status" ]; then status_json; exit 0; fi

# 1) Paquetes del sistema
missing=()
for c in git curl; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
if [ ${#missing[@]} -gt 0 ]; then
  log "Faltan: ${missing[*]} — instalando…"
  if command -v apt-get >/dev/null 2>&1; then
    as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq && as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" ca-certificates \
      || fail "No pude instalar ${missing[*]} (hace falta root o sudo sin contraseña)."
  elif command -v dnf >/dev/null 2>&1; then
    as_root dnf install -y -q "${missing[@]}" || fail "No pude instalar ${missing[*]}."
  elif command -v yum >/dev/null 2>&1; then
    as_root yum install -y -q "${missing[@]}" || fail "No pude instalar ${missing[*]}."
  else
    fail "Instalá a mano: ${missing[*]}"
  fi
fi
log "git y curl: OK"

# 2) Node (nvm en el usuario: no necesita root)
load_node
if node_ok; then
  log "Node $(node -v): OK"
else
  log "Instalando Node $NODE_VERSION con nvm…"
  if [ ! -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | PROFILE=/dev/null bash >/dev/null
  fi
  load_node
  nvm install "$NODE_VERSION" >/dev/null
  nvm alias default "$NODE_VERSION" >/dev/null
  load_node
  node_ok || fail "Node no quedó instalado"
  log "Node $(node -v): instalado"
fi

# 3) PM2
if command -v pm2 >/dev/null 2>&1; then
  log "PM2 $(pm2 -v 2>/dev/null | tail -1): OK"
else
  log "Instalando PM2…"
  npm install -g pm2 >/dev/null 2>&1 || fail "No pude instalar PM2"
  log "PM2 $(pm2 -v | tail -1): instalado"
fi

# 4) Código
if [ -d "$DIR/.git" ]; then
  log "Actualizando código en $DIR…"
  git -C "$DIR" fetch -q origin "$BRANCH"
  git -C "$DIR" reset -q --hard "origin/$BRANCH"
else
  log "Descargando código en $DIR…"
  git clone -q --branch "$BRANCH" "$REPO_URL" "$DIR"
fi
log "Versión $(node -p "require('$DIR/package.json').version")"

# 5) .env (permisos 600; nunca se imprime)
if [ -n "$ENV_CONTENT" ]; then
  ( umask 077; printf '%s\n' "$ENV_CONTENT" > "$DIR/.env" )
  chmod 600 "$DIR/.env"
  log ".env escrito ($(grep -cE '^[A-Z_][A-Z0-9_]*=' "$DIR/.env") variables)"
fi
[ -f "$DIR/.env" ] || fail "Falta $DIR/.env: pasalo por stdin (bash install.sh < archivo.env)"

# 6) PM2: arranca o reinicia, y queda guardado para que vuelva solo
if pm2 describe "$APP" >/dev/null 2>&1; then
  pm2 restart "$APP" --update-env >/dev/null
  log "Reiniciado en PM2"
else
  pm2 start "$DIR/server.js" --name "$APP" --cwd "$DIR" --max-memory-restart 300M >/dev/null
  log "Iniciado en PM2"
fi
pm2 save >/dev/null 2>&1 || true

if [ "${SKIP_STARTUP:-0}" = "1" ]; then
  log "Arranque automático de PM2: omitido (SKIP_STARTUP=1)"
elif command -v systemctl >/dev/null 2>&1 && [ "$SUDO" != "__none__" ]; then
  unit="pm2-$(id -un)"
  if ! systemctl is-enabled "$unit" >/dev/null 2>&1; then
    as_root env PATH="$PATH:$(dirname "$(command -v node)")" "$(command -v pm2)" startup systemd -u "$(id -un)" --hp "$HOME" >/dev/null 2>&1 \
      && log "PM2 arranca solo al reiniciar el servidor" || log "Aviso: no pude configurar el arranque automático de PM2"
  fi
else
  log "Aviso: sin root/sudo no se configura el arranque automático de PM2 al reiniciar el servidor"
fi

sleep 2
status_json
