# Ventra Backend Server

The Ventra Cloud Backend is a high-performance, asynchronous FastAPI and MQTT bridge service that connects the physical ESP32 hub, Flutter mobile client, and Google Assistant Smart Home ecosystem.

---

## Features

- **Asynchronous MQTT Bridge**: Bridges TCP/TLS MQTT topics (`ventra/cmd`, `ventra/telemetry`, `ventra/status`, `ventra/ack`) to the REST and WebSocket endpoints.
- **Bi-directional WebSockets (`/ws`)**: Delivers sub-50ms climate control commands and continuous sensor telemetry streaming to the Flutter mobile app.
- **Hub Liveness Watchdog**: 35-second periodic watchdog detects hardware disconnects and network drops, automatically marking hub status as offline and updating clients.
- **Delta Command Synthesizer**: Blends partial user commands with last-known device state to formulate complete, protocol-compliant frames for multi-brand AC units (Panasonic, Gree, Daikin, etc.).
- **Google Home Graph Integration (`/google/fulfillment`)**: Native Smart Home Action fulfillment supporting `action.devices.types.AC_UNIT` with `action.devices.traits.TemperatureSetting` and `action.devices.traits.OnOff`.
- **OAuth2 Server**: Built-in authorization code and token endpoints for Google Assistant account linking (`/oauth/auth`, `/oauth/token`).
- **Timeseries Sensor Logging**: Asynchronous SQLite logging (`aiosqlite`) recording room temperature, humidity, and PIR motion history for 24-hour analytics.

---

## Setup & Local Run

### 1. Prerequisites
- Python 3.10+
- Mosquitto or any standard MQTT 3.1.1/5.0 broker

### 2. Installation
```bash
cd server
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### 3. Environment Variables
| Variable | Default | Description |
|---|---|---|
| `MQTT_BROKER` | `127.0.0.1` | Hostname or IP of the MQTT broker |
| `MQTT_PORT` | `1883` | Port of the MQTT broker |
| `DB_PATH` | `ventra.db` | Path to SQLite database file |

### 4. Running the Server
```bash
uvicorn app:app --host 0.0.0.0 --port 8000 --reload
```

---

## Production Deployment (systemd + Caddy)

1. Copy `ventra-api.service` to `/etc/systemd/system/ventra-api.service`.
2. Reload and enable systemd:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now ventra-api
   ```
3. Reverse proxy port 8000 using Caddy or Nginx with TLS termination and WebSocket upgrades (`reverse_proxy 127.0.0.1:8000`).
