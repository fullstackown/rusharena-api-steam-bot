# steam-relay

API mínima de **solo lectura** que hace consultas públicas a `steamcommunity.com` (precios del mercado e
inventarios públicos) desde la IP del servidor donde corre. Sirve para repartir consultas entre varios servidores,
porque Steam limita por IP.

- Sin dependencias (Node ≥ 20.12).
- No es un proxy abierto: solo acepta una lista cerrada de URLs de Steam.
- Toda consulta exige `Authorization: Bearer <RELAY_TOKEN>`.
- El repo no tiene ningún dato sensible: todo va en `.env` (que nunca se sube).

## Instalar

```bash
curl -fsSL https://raw.githubusercontent.com/fullstackown/rusharena-api-steam-bot/main/install.sh -o /tmp/steam-relay-install.sh
bash /tmp/steam-relay-install.sh < mi.env      # el .env entra por stdin
```

El instalador revisa git, curl, Node (lo instala con nvm si falta) y PM2, descarga el código en `~/steam-relay`,
escribe el `.env` con permisos 600, lo deja corriendo en PM2 (`steam-relay`) y muestra el estado.

- Actualizar sin tocar el `.env`: `bash ~/steam-relay/install.sh`
- Ver el estado: `bash ~/steam-relay/install.sh --status`

Variables: ver [.env.example](.env.example).

## Exponerlo

Por defecto escucha solo en `127.0.0.1:4870`. Con Cloudflare Tunnel: *Public hostname* → servicio
`http://localhost:4870`.

## API

| Ruta | Auth | |
|---|---|---|
| `GET /health` | no | `{ ok, version }` |
| `GET /status` | sí | versión, Node, carga, memoria, disco, estadísticas y pausa de Steam |
| `GET /v1/steam?url=<url de Steam>` | sí | devuelve la respuesta de Steam tal cual (código y cuerpo), con `x-relay-steam: 1` |

URLs permitidas: `/market/search/render/`, `/market/priceoverview/`, `/inventory/<steamid>/<appid>/<contextid>`,
`/profiles/<steamid>/inventory/`, `/id/<vanity>/inventory/`.

Si Steam responde 429, el relay deja de consultar un rato (`STEAM_PAUSE_MS`) y responde 429 con
`x-relay-paused-until`.
