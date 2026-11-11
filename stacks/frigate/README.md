# Frigate NVR Stack

Network video recorder with object detection (people and dogs) for the
UniFi Protect cameras.

## Layout

- `docker-compose.yml`: the Frigate container. go2rtc runs embedded inside it.
- `config/config.yml`: the live config. The container reads and writes this
  file directly (`CONFIG_FILE=/repo-config/config.yml`), so edits made in the
  Frigate UI (config editor, masks, zones) show up here as a `git diff`.
- `.env`: secrets (MQTT credentials, camera stream URLs). See `.env.example`.
- `frigate_config` volume: database, model cache and other runtime state.
- `frigate_media` volume: recordings and snapshots.

## Deploy

1. Copy `.env.example` to `.env` and fill it in.
2. `docker compose up -d`

After editing `config/config.yml` on the host: `docker compose restart frigate`.

## Access

- UI (authenticated): port 8971, or via Traefik at the Frigate hostname.
- Port 5000 (unauthenticated API) is only reachable on the Docker networks.
- Port 8555: WebRTC for live view.

## Hardware

Intel NUC (11th gen, Iris Xe). Detection runs on the GPU through OpenVINO and
video decode uses VAAPI, both through `/dev/dri/renderD128`. No Coral needed.
