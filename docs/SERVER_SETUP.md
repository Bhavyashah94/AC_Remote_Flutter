# Ventra Universal AC Hub - Server & Backend Architecture

This document describes the production server architecture, migration from Docker to native Python, systemd service configuration, and reverse proxy setup for **`ventra.bhavyashah.me`**.

---

## 1. Architecture Overview

```
                      [ Physical ESP32 Hub ]
                      (WiFi: 192.168.29.89)
                                |
               MQTT (TCP 1883)  |  Telemetry / State: ventra/hub/state
               Sub: ventra/hub/command
                                v
+-------------------------------------------------------------------+
| Oracle Cloud VM (80.225.251.140 - Ubuntu 24.04 LTS)                |
|                                                                   |
|  [ Mosquitto MQTT Broker ]                                        |
|  Container: ventra_mosquitto (ports 1883:1883)                    |
|                               ^                                   |
|                               | (127.0.0.1:1883)                  |
|                               v                                   |
|  [ Ventra API - Native Python Service ]                           |
|  Runtime: Python 3.12 (venv) + Uvicorn + FastAPI                  |
|  systemd unit: ventra-api.service (listening on 0.0.0.0:8000)      |
|  Database: SQLite (/home/ubuntu/ventra/data/ventra.db)            |
|  Memory footprint: ~15 MB                                         |
|                               ^                                   |
|                               | HTTP (172.19.0.1:8000)            |
|                               v                                   |
|  [ Caddy Reverse Proxy ]                                          |
|  Container: labstudio_caddy (ports 80, 443)                       |
|  Automatic Let's Encrypt TLS Certificate                          |
+-------------------------------------------------------------------+
                                ^
                                | HTTPS (port 443)
                                v
              [ Flutter Mobile App / Web / Curl ]
                  https://ventra.bhavyashah.me
```

---

## 2. Why Native Python instead of Docker for API?

1. **Lightweight Footprint**: Memory usage dropped to **~15 MB** (compared to containerized layer overhead).
2. **Instant Hot Reboots**: Systemd manages graceful reloads with `Restart=always` and sub-second startup.
3. **Simpler File Management**: Direct access to SQLite database and Python logs without docker volume permission conflicts.
4. **Clean Decoupling**: Docker is preserved only for standard daemon infrastructure (Mosquitto & Caddy), while application code runs natively.

---

## 3. Server Specifications & File Paths

* **Host**: `80.225.251.140`
* **SSH Key**: `~/.ssh/ssh-key-2026-05-29.key`
* **User**: `ubuntu`
* **Application Directory**: `/home/ubuntu/ventra/`
* **Virtualenv**: `/home/ubuntu/ventra/venv/`
* **SQLite Database**: `/home/ubuntu/ventra/data/ventra.db`
* **systemd Service**: `/etc/systemd/system/ventra-api.service`
* **Caddyfile**: `/home/ubuntu/Experments/Caddyfile`

---

## 4. systemd Service Configuration

The service is managed by systemd:
`/etc/systemd/system/ventra-api.service`

```ini
[Unit]
Description=Ventra Universal AC Hub Backend API (Native Python)
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/home/ubuntu/ventra
Environment=PYTHONUNBUFFERED=1
Environment=DB_PATH=/home/ubuntu/ventra/data/ventra.db
Environment=MQTT_BROKER=127.0.0.1
Environment=MQTT_PORT=1883
ExecStart=/home/ubuntu/ventra/venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

### Useful Server Commands

```bash
# Check service status
sudo systemctl status ventra-api

# View live logs
sudo journalctl -u ventra-api -f

# Restart API
sudo systemctl restart ventra-api
```

---

## 5. Caddy Reverse Proxy Configuration

In `/home/ubuntu/Experments/Caddyfile`:

```caddy
ventra.bhavyashah.me {
    header {
        Access-Control-Allow-Origin *
    }
    reverse_proxy 172.19.0.1:8000
}
```

*Note: `172.19.0.1` is the Docker bridge gateway pointing from the Caddy container to the host machine where Uvicorn listens on port 8000.*

To reload Caddy after configuration changes:
```bash
docker exec labstudio_caddy caddy reload --config /etc/caddy/Caddyfile
```

---

## 6. API Endpoints Reference

Base URL: `https://ventra.bhavyashah.me`

### 1. Health & Server Info
* **Endpoint**: `GET /`
* **Response**:
```json
{
  "status": "ok",
  "app": "Ventra 2.0 Universal Hub",
  "runtime": "native-python",
  "online": true,
  "protocol": "PANASONIC_AC"
}
```

### 2. Live AC & Room State
* **Endpoint**: `GET /api/state`
* **Response**:
```json
{
  "online": true,
  "protocol": "PANASONIC_AC",
  "power": true,
  "temp": 24,
  "mode": "Cool",
  "fan": "Auto",
  "swing_v": 1,
  "swing_h": 0,
  "timer_mins": 0,
  "timer_target_timestamp": 0,
  "smart_auto": false,
  "powerful": false,
  "quiet": false,
  "turbo": false,
  "sleep": false,
  "ifeel": false,
  "x_fan": false,
  "display": 1,
  "display_state": true,
  "capacity": "auto",
  "clean_active": false,
  "room_temp": 27.1,
  "room_hum": 53.8,
  "motion": false,
  "last_motion_time": 1791146062,
  "last_seen": "2026-10-04T20:35:02.227550+00:00"
}
```

### 3. Send AC Command
* **Endpoint**: `POST /api/ac`
* **Payload Examples**:
  * Set 24°C Cool Auto Fan:
    ```json
    { "power": true, "temp": 24, "mode": "Cool", "fan": "Auto" }
    ```
  * Set 80% Capacity (converti7):
    ```json
    { "capacity": "80" }
    ```
  * Toggle Display LED:
    ```json
    { "display_toggle": true }
    ```
  * Turn AC Off:
    ```json
    { "power": false }
    ```

### 4. Brand Catalog
* **Endpoint**: `GET /api/brands`
* Returns 20+ supported AC manufacturer protocols (Panasonic, Daikin, Voltas, LG, Samsung, Mitsubishi, Gree, Blue Star, Carrier, Whirlpool, Hitachi, etc.).

### 5. Historical Telemetry & Analytics
* **Endpoint**: `GET /api/analytics?hours=24`
* Returns temperature and humidity history recorded by the DHT22 sensor.
