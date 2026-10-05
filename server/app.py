import asyncio
import json
import logging
import os
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Any

import aiosqlite
import secrets
import urllib.parse
import paho.mqtt.client as mqtt
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request, Response
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("ventra-hub")

MQTT_BROKER = os.getenv("MQTT_BROKER", "127.0.0.1")
MQTT_PORT = int(os.getenv("MQTT_PORT", 1883))
DB_PATH = os.getenv("DB_PATH", "/home/ubuntu/ventra/ventra.db" if os.path.exists("/home/ubuntu/ventra") else "ventra.db")

BRAND_CATALOG = {
    "Panasonic": {"min_temp": 16, "max_temp": 30, "fan_speeds": ["Auto", "Min", "Low", "Med", "High", "Max"], "modes": ["Cool", "Dry", "Heat", "Fan", "Auto"], "has_swing_h": True},
    "Gree": {"min_temp": 16, "max_temp": 30, "fan_speeds": ["Auto", "Low", "Med", "High"], "modes": ["Cool", "Dry", "Heat", "Fan", "Auto"], "has_swing_h": True},
    "Daikin": {"min_temp": 18, "max_temp": 32, "fan_speeds": ["Auto", "1", "2", "3", "4", "5"], "modes": ["Cool", "Dry", "Heat", "Fan", "Auto"], "has_swing_h": True},
    "Mitsubishi": {"min_temp": 16, "max_temp": 31, "fan_speeds": ["Auto", "Quiet", "1", "2", "3", "4"], "modes": ["Cool", "Dry", "Heat", "Fan", "Auto"], "has_swing_h": True},
    "LG": {"min_temp": 18, "max_temp": 30, "fan_speeds": ["Auto", "Low", "Med", "High"], "modes": ["Cool", "Dry", "Heat", "Fan"], "has_swing_h": False},
    "Samsung": {"min_temp": 16, "max_temp": 30, "fan_speeds": ["Auto", "Low", "Med", "High", "Turbo"], "modes": ["Cool", "Dry", "Heat", "Fan", "Auto"], "has_swing_h": False},
    "Carrier": {"min_temp": 17, "max_temp": 30, "fan_speeds": ["Auto", "Low", "Med", "High"], "modes": ["Cool", "Dry", "Heat", "Fan"], "has_swing_h": False},
    "Voltas": {"min_temp": 16, "max_temp": 30, "fan_speeds": ["Auto", "Low", "Med", "High"], "modes": ["Cool", "Dry", "Heat", "Fan"], "has_swing_h": False},
    "BlueStar": {"min_temp": 16, "max_temp": 30, "fan_speeds": ["Auto", "Low", "Med", "High"], "modes": ["Cool", "Dry", "Heat", "Fan"], "has_swing_h": False},
    "Hitachi": {"min_temp": 16, "max_temp": 32, "fan_speeds": ["Auto", "Low", "Med", "High"], "modes": ["Cool", "Dry", "Heat", "Fan"], "has_swing_h": False},
    "Haier": {"min_temp": 16, "max_temp": 30, "fan_speeds": ["Auto", "Low", "Med", "High"], "modes": ["Cool", "Dry", "Heat", "Fan"], "has_swing_h": False},
    "Whirlpool": {"min_temp": 16, "max_temp": 30, "fan_speeds": ["Auto", "Low", "Med", "High"], "modes": ["Cool", "Dry", "Heat", "Fan"], "has_swing_h": False}
}

device_state: dict[str, Any] = {
    "online": False,
    "last_seen": None,
    "protocol": "Panasonic",
    "power": True,
    "temp": 24,
    "mode": "Cool",
    "fan": "Auto",
    "swing_v": 0xF,
    "swing_h": 0xD,
    "timer_mins": 0,
    "smart_auto": False,
    "room_temp": 24.0,
    "room_hum": 50.0,
    "motion": False,
    "last_motion_time": 0,
    "powerful": False,
    "quiet": False,
    "clean_active": False,
    "display_state": True,
    "display": 1,
    "capacity": "AUTO",
    "turbo": False,
    "sleep": False,
    "ifeel": False,
    "x_fan": False
}

last_telemetry_ts: float = 0.0

class ConnectionManager:
    def __init__(self):
        self.active_connections: set[WebSocket] = set()

    async def connect(self, websocket: WebSocket):
        await websocket.accept()
        self.active_connections.add(websocket)
        # 1. Send Hub Status snapshot
        try:
            await websocket.send_json({
                "type": "hub_status",
                "data": {
                    "online": device_state.get("online", False),
                    "last_seen": device_state.get("last_seen")
                }
            })
            # 2. Send Telemetry snapshot
            await websocket.send_json({
                "type": "telemetry",
                "data": {
                    "room_temp": device_state.get("room_temp"),
                    "room_hum": device_state.get("room_hum"),
                    "motion": device_state.get("motion", False),
                    "last_seen": device_state.get("last_seen")
                }
            })
            # 3. Send AC Control state snapshot
            await websocket.send_json({"type": "ac_state", "data": device_state})
            # 4. Monolithic state for backward compatibility
            await websocket.send_json({"type": "state", "data": device_state})
        except Exception as e:
            logger.warning(f"Error sending initial snapshots: {e}")

    def disconnect(self, websocket: WebSocket):
        self.active_connections.discard(websocket)

    async def broadcast(self, message: dict):
        dead = []
        for conn in list(self.active_connections):
            try:
                await conn.send_json(message)
            except Exception:
                dead.append(conn)
        for d in dead:
            self.active_connections.discard(d)

manager = ConnectionManager()
mqtt_client: mqtt.Client = None
loop: asyncio.AbstractEventLoop = None

async def init_db():
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("PRAGMA journal_mode = WAL;")
        await db.execute("PRAGMA synchronous = NORMAL;")
        await db.execute("""
            CREATE TABLE IF NOT EXISTS telemetry (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
                room_temp REAL,
                room_hum REAL,
                motion INTEGER,
                ac_power INTEGER,
                target_temp INTEGER
            )
        """)
        await db.execute("CREATE INDEX IF NOT EXISTS idx_telemetry_timestamp ON telemetry(timestamp);")
        await db.execute("""
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT
            )
        """)
        async with db.execute("SELECT key, value FROM settings") as cursor:
            async for row in cursor:
                k, v = row
                try:
                    device_state[k] = json.loads(v)
                except Exception:
                    device_state[k] = v
        await db.commit()

async def persist_setting(key: str, value: Any):
    try:
        async with aiosqlite.connect(DB_PATH) as db:
            await db.execute(
                "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                (key, json.dumps(value))
            )
            await db.commit()
    except Exception as e:
        logger.error(f"Failed to persist setting {key}: {e}")

def on_mqtt_connect(client, userdata, flags, rc, properties=None):
    logger.info(f"Connected to Mosquitto Broker rc={rc}")
    client.subscribe("ventra/telemetry")
    client.subscribe("ventra/status")
    client.subscribe("ventra/detected")
    client.subscribe("ventra/ack")

def on_mqtt_message(client, userdata, msg):
    # Discard retained status messages on topic ventra/status to prevent stale online poisoning
    if msg.topic == "ventra/status" and getattr(msg, "retain", False):
        logger.info("Ignoring stale retained status packet")
        return

    try:
        payload = json.loads(msg.payload.decode())
    except Exception:
        payload = msg.payload.decode()

    if loop and loop.is_running():
        asyncio.run_coroutine_threadsafe(handle_mqtt_event(msg.topic, payload), loop)

async def handle_mqtt_event(topic: str, payload: Any):
    global last_telemetry_ts
    now_str = datetime.now(timezone.utc).isoformat()

    if topic == "ventra/status":
        status = str(payload).strip().lower()
        is_online = (status == "online")
        device_state["online"] = is_online
        device_state["last_seen"] = now_str
        if is_online:
            last_telemetry_ts = time.time()
        logger.info(f"Hub Status Event: {status} -> online={is_online}")
        await manager.broadcast({
            "type": "hub_status",
            "data": {"online": is_online, "last_seen": now_str}
        })

    elif topic == "ventra/telemetry" and isinstance(payload, dict):
        last_telemetry_ts = time.time()
        device_state["online"] = True
        device_state["last_seen"] = now_str
        if "room_temp" in payload and payload["room_temp"] is not None:
            device_state["room_temp"] = round(float(payload["room_temp"]), 1)
        if "room_hum" in payload and payload["room_hum"] is not None:
            device_state["room_hum"] = round(float(payload["room_hum"]), 1)
        if "motion" in payload:
            is_motion = bool(payload["motion"])
            device_state["motion"] = is_motion
            if is_motion:
                device_state["last_motion_time"] = int(time.time())
        if "protocol" in payload and payload["protocol"]:
            device_state["protocol"] = payload["protocol"]

        # Insert into sqlite telemetry table
        try:
            async with aiosqlite.connect(DB_PATH) as db:
                await db.execute(
                    "INSERT INTO telemetry (room_temp, room_hum, motion, ac_power, target_temp) VALUES (?, ?, ?, ?, ?)",
                    (
                        device_state.get("room_temp"),
                        device_state.get("room_hum"),
                        1 if device_state.get("motion") else 0,
                        1 if device_state.get("power") else 0,
                        int(device_state.get("temp", 24))
                    )
                )
                await db.commit()
        except Exception as e:
            logger.warning(f"Failed to record telemetry row: {e}")

        # Broadcast decoupled telemetry & status events
        await manager.broadcast({
            "type": "telemetry",
            "data": {
                "room_temp": device_state.get("room_temp"),
                "room_hum": device_state.get("room_hum"),
                "motion": device_state.get("motion", False),
                "last_seen": now_str
            }
        })
        await manager.broadcast({
            "type": "hub_status",
            "data": {"online": True, "last_seen": now_str}
        })
        # Backward compatibility
        await manager.broadcast({"type": "state", "data": device_state})

    elif topic == "ventra/detected" and isinstance(payload, dict):
        device_state["last_seen"] = now_str
        brand = payload.get("brand", "")
        success = bool(payload.get("success", True if brand else False))
        if brand and success:
            logger.info(f"Physical remote detected! Matched Brand: {brand}")
            device_state["protocol"] = brand
            await persist_setting("protocol", brand)
            await manager.broadcast({"type": "brand_detected", "brand": brand, "success": True})
        else:
            await manager.broadcast({"type": "brand_detected", "brand": None, "success": False})

    elif topic == "ventra/ack":
        device_state["last_seen"] = now_str
        device_state["online"] = True
        last_telemetry_ts = time.time()
        logger.info(f"ESP32 Command ACK: {payload}")
        await manager.broadcast({"type": "ac_ack", "data": payload})
        await manager.broadcast({
            "type": "hub_status",
            "data": {"online": True, "last_seen": now_str}
        })

def send_mqtt_command(cmd: dict):
    if mqtt_client and mqtt_client.is_connected():
        payload = json.dumps(cmd)
        logger.info(f"Dispatching MQTT command to ventra/cmd (QoS 1): {payload}")
        mqtt_client.publish("ventra/cmd", payload, qos=1)
    else:
        logger.error(f"Cannot dispatch MQTT command: broker disconnected! (client={mqtt_client})")

async def liveness_watchdog():
    global last_telemetry_ts
    while True:
        await asyncio.sleep(5)
        # Threshold: 35s (3.5x the 10s telemetry interval)
        if last_telemetry_ts > 0 and (time.time() - last_telemetry_ts > 35):
            if device_state.get("online", False):
                logger.warning("Hub heartbeat expired (>35s silence). Marking hub offline.")
                device_state["online"] = False
                await manager.broadcast({
                    "type": "hub_status",
                    "data": {"online": False, "reason": "heartbeat_timeout"}
                })
                await manager.broadcast({"type": "state", "data": device_state})

@asynccontextmanager
async def lifespan(app: FastAPI):
    global loop, mqtt_client
    loop = asyncio.get_running_loop()
    await init_db()

    mqtt_client = mqtt.Client(client_id="ventra_cloud_backend", callback_api_version=mqtt.CallbackAPIVersion.VERSION2)
    mqtt_client.on_connect = on_mqtt_connect
    mqtt_client.on_message = on_mqtt_message
    try:
        mqtt_client.connect_async(MQTT_BROKER, MQTT_PORT, 60)
        mqtt_client.loop_start()
    except Exception as e:
        logger.error(f"Failed to start MQTT loop: {e}")

    watchdog_task = asyncio.create_task(liveness_watchdog())

    yield

    watchdog_task.cancel()
    if mqtt_client:
        mqtt_client.loop_stop()
        mqtt_client.disconnect()

app = FastAPI(title="Ventra Universal AC Hub", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/")
def health():
    return {
        "status": "ok",
        "app": "Ventra 2.0 Universal Hub",
        "runtime": "native-python",
        "online": device_state.get("online", False),
        "protocol": device_state.get("protocol", "Panasonic")
    }

@app.get("/api/health")
def api_health():
    return {
        "status": "ok",
        "online": device_state.get("online", False),
        "last_seen": device_state.get("last_seen"),
        "protocol": device_state.get("protocol", "Panasonic"),
        "room_temp": device_state.get("room_temp"),
        "room_hum": device_state.get("room_hum")
    }

@app.get("/api/state")
def get_state():
    return device_state

@app.get("/api/brands")
def get_brands():
    return BRAND_CATALOG

@app.post("/api/device/learn")
def arm_learning_mode():
    if mqtt_client and mqtt_client.is_connected():
        mqtt_client.publish("ventra/learn", "start", qos=1)
        return {"status": "armed", "message": "Waiting for physical remote press on GPIO 15"}
    return {"status": "error", "message": "Broker not connected"}

class ACCommand(BaseModel):
    power: bool | None = None
    protocol: str | None = None
    temp: int | None = None
    mode: str | None = None
    fan: str | None = None
    swing_v: int | None = None
    swing_h: int | None = None
    timer_mins: int | None = None
    smart_auto: bool | None = None
    powerful: bool | None = None
    quiet: bool | None = None
    turbo: bool | None = None
    sleep: bool | None = None
    ifeel: bool | None = None
    x_fan: bool | None = None
    display: int | None = None
    display_temp: int | None = None
    model: str | None = None
    capacity: str | int | None = None
    converti7: int | None = None
    clean: bool | None = None
    display_toggle: bool | None = None
    powerful_toggle: bool | None = None
    cmd: str | None = None

@app.post("/api/ac")
async def set_ac_command(cmd: ACCommand):
    data = cmd.model_dump(exclude_unset=True)

    # 1. Handle Display LED Toggle (Isolated One-Shot Command)
    if cmd.display_toggle or (cmd.cmd and "display" in str(cmd.cmd).lower()):
        device_state["display_state"] = not device_state.get("display_state", True)
        device_state["display"] = 1 if device_state["display_state"] else 0
        await persist_setting("display_state", device_state["display_state"])
        await persist_setting("display", device_state["display"])
        send_mqtt_command({"display_toggle": True})
        await manager.broadcast({"type": "ac_state", "data": device_state})
        await manager.broadcast({"type": "state", "data": device_state})
        return {"status": "success", "data": device_state}

    # 1b. Handle Powerful Mode Toggle (Isolated One-Shot Command)
    if cmd.powerful_toggle or (cmd.powerful is not None and not any(k in data for k in ["temp", "mode", "fan", "swing_v", "swing_h"])) or (cmd.cmd and "powerful" in str(cmd.cmd).lower()):
        if cmd.powerful is not None:
            device_state["powerful"] = bool(cmd.powerful)
        else:
            device_state["powerful"] = not device_state.get("powerful", False)
        await persist_setting("powerful", device_state["powerful"])
        send_mqtt_command({"powerful_toggle": True})
        await manager.broadcast({"type": "ac_state", "data": device_state})
        await manager.broadcast({"type": "state", "data": device_state})
        return {"status": "success", "data": device_state}

    # 2. Handle CLEAN Cycle (Isolated One-Shot Command)
    if cmd.clean is not None or (cmd.cmd and "clean" in str(cmd.cmd).lower()):
        if cmd.clean is not None:
            device_state["clean_active"] = bool(cmd.clean)
        else:
            device_state["clean_active"] = not device_state.get("clean_active", False)
        await persist_setting("clean_active", device_state["clean_active"])
        send_mqtt_command({"clean": device_state["clean_active"]})
        await manager.broadcast({"type": "ac_state", "data": device_state})
        await manager.broadcast({"type": "state", "data": device_state})
        return {"status": "success", "data": device_state}

    # If clean was active and user sends a regular temperature/mode/power command, reset clean
    if device_state.get("clean_active", False) and (cmd.temp is not None or cmd.mode is not None or cmd.power is not None):
        device_state["clean_active"] = False
        await persist_setting("clean_active", False)

    climate_keys = {"temp", "mode", "fan", "swing_v", "swing_h", "powerful", "quiet", "turbo", "sleep", "ifeel", "x_fan"}
    has_climate_keys = any(k in data for k in climate_keys)

    # 3. Standalone Convertible Capacity (converti7) (Isolated One-Shot Command)
    if cmd.capacity is not None or cmd.converti7 is not None:
        cap_val = str(cmd.capacity if cmd.capacity is not None else cmd.converti7).upper()
        device_state["capacity"] = cap_val
        await persist_setting("capacity", cap_val)
        if not has_climate_keys:
            send_mqtt_command({"capacity": cap_val})
            await manager.broadcast({"type": "ac_state", "data": device_state})
            await manager.broadcast({"type": "state", "data": device_state})
            return {"status": "success", "data": device_state}

    # 4. Standard Climate Command (Synthesize full protocol-agnostic payload)
    for k, v in data.items():
        if v is not None:
            device_state[k] = v
            await persist_setting(k, v)

    full_payload = {
        "protocol": device_state.get("protocol", "Panasonic"),
        "model": device_state.get("model", "YAW1F"),
        "power": device_state.get("power", True),
        "temp": device_state.get("temp", 24),
        "mode": device_state.get("mode", "Cool"),
        "fan": device_state.get("fan", "Auto"),
        "swing_v": device_state.get("swing_v", 0xF),
        "swing_h": device_state.get("swing_h", 0xD),
        "timer_mins": device_state.get("timer_mins", 0),
        # Panasonic specific
        "quiet": device_state.get("quiet", False),
        "powerful": device_state.get("powerful", False),
        # Gree specific
        "turbo": device_state.get("turbo", False),
        "sleep": device_state.get("sleep", False),
        "ifeel": device_state.get("ifeel", False),
        "x_fan": device_state.get("x_fan", False),
        "display": device_state.get("display", 1),
        "display_temp": device_state.get("display_temp", 1)
    }

    send_mqtt_command(full_payload)
    await manager.broadcast({"type": "ac_state", "data": device_state})
    await manager.broadcast({"type": "state", "data": device_state})
    return {"status": "success", "data": device_state}

@app.get("/api/analytics")
async def get_analytics(hours: int = 24):
    temps: list[float] = []
    hums: list[float] = []
    motion_hits: list[int] = []

    try:
        async with aiosqlite.connect(DB_PATH) as db:
            async with db.execute(
                "SELECT room_temp, room_hum, motion FROM telemetry WHERE timestamp >= datetime('now', ?) ORDER BY timestamp ASC",
                (f"-{hours} hours",)
            ) as cursor:
                async for row in cursor:
                    t, h, m = row
                    if t is not None:
                        temps.append(float(t))
                    if h is not None:
                        hums.append(float(h))
                    motion_hits.append(int(m or 0))
    except Exception as e:
        logger.warning(f"Error reading analytics: {e}")

    # Fallback to current memory if table has sparse entries
    if not temps:
        temps = [float(device_state.get("room_temp", 24.0))]
        hums = [float(device_state.get("room_hum", 50.0))]
        motion_hits = [1 if device_state.get("motion", False) else 0]

    return {
        "temperatures": temps,
        "humidities": hums,
        "motion_hits": motion_hits
    }

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await manager.connect(websocket)
    try:
        while True:
            data = await websocket.receive_text()
            try:
                raw = json.loads(data)
                # Unwrap envelope {"action": "command", "data": {...}} or accept flat payload
                payload = raw.get("data", raw) if (isinstance(raw, dict) and raw.get("action") == "command") else raw
                cmd = ACCommand(**payload)
                await set_ac_command(cmd)
            except Exception as e:
                logger.error(f"WS message error: {e}")
    except WebSocketDisconnect:
        manager.disconnect(websocket)

# -------------------------------------------------------------
# Google Assistant & Smart Home OAuth 2.0 + Webhook
# -------------------------------------------------------------
oauth_auth_codes: dict[str, dict[str, Any]] = {}
VALID_TOKENS = set()

async def parse_request_data(request: Request) -> dict:
    content_type = request.headers.get("content-type", "")
    body_bytes = await request.body()
    if not body_bytes:
        return {}
    if "application/json" in content_type:
        try:
            return json.loads(body_bytes.decode("utf-8"))
        except Exception:
            return {}
    try:
        parsed = urllib.parse.parse_qs(body_bytes.decode("utf-8"))
        return {k: v[0] if len(v) == 1 else v for k, v in parsed.items()}
    except Exception:
        return {}

@app.get("/oauth/authorize", response_class=HTMLResponse)
async def oauth_authorize(
    client_id: str = "ventra_google",
    redirect_uri: str = "",
    state: str = "",
    response_type: str = "code",
    scope: str = "smarthome"
):
    auth_code = f"code_{secrets.token_hex(16)}"
    oauth_auth_codes[auth_code] = {
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "state": state,
        "expires": time.time() + 600
    }

    html = f"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Link Ventra with Google Assistant</title>
      <style>
        body {{
          background-color: #0A0C14;
          color: #E2E8F0;
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
          display: flex;
          align-items: center;
          justify-content: center;
          min-height: 100vh;
          margin: 0;
          padding: 20px;
        }}
        .card {{
          background: #141724;
          border: 1px solid rgba(0, 229, 255, 0.2);
          box-shadow: 0 12px 40px rgba(0, 0, 0, 0.6), 0 0 20px rgba(0, 229, 255, 0.1);
          border-radius: 28px;
          padding: 36px 28px;
          max-width: 400px;
          width: 100%;
          text-align: center;
        }}
        .icon-circle {{
          width: 72px;
          height: 72px;
          margin: 0 auto 20px;
          background: rgba(0, 229, 255, 0.15);
          border: 1.5px solid #00E5FF;
          border-radius: 50%;
          display: flex;
          align-items: center;
          justify-content: center;
          font-size: 32px;
        }}
        h1 {{
          font-size: 22px;
          font-weight: 700;
          margin: 0 0 10px;
          color: #FFFFFF;
        }}
        p {{
          font-size: 14px;
          color: #94A3B8;
          line-height: 1.5;
          margin: 0 0 24px;
        }}
        .permissions {{
          background: rgba(255, 255, 255, 0.03);
          border-radius: 16px;
          padding: 16px;
          margin-bottom: 28px;
          text-align: left;
          font-size: 13px;
        }}
        .permissions div {{
          margin-bottom: 8px;
          display: flex;
          align-items: center;
        }}
        .permissions div:last-child {{ margin-bottom: 0; }}
        .btn {{
          display: block;
          width: 100%;
          padding: 16px;
          background: linear-gradient(135deg, #00E5FF, #00B0FF);
          color: #0A0C14;
          font-weight: 700;
          font-size: 16px;
          border: none;
          border-radius: 18px;
          cursor: pointer;
          text-decoration: none;
          box-sizing: border-box;
          transition: transform 0.1s, opacity 0.2s;
        }}
        .btn:hover {{ opacity: 0.9; }}
        .btn:active {{ transform: scale(0.98); }}
      </style>
    </head>
    <body>
      <div class="card">
        <div class="icon-circle">❄️</div>
        <h1>Link with Google Home</h1>
        <p>Google Assistant will be able to control your Air Conditioner and read live DHT22 temperature & humidity sensors.</p>
        <div class="permissions">
          <div>✓ Voice control (Power, Temp, Mode, Fan)</div>
          <div>✓ Live DHT22 temperature & humidity queries</div>
          <div>✓ Fast, sub-second IR hardware control</div>
        </div>
        <form method="POST" action="/oauth/approve">
          <input type="hidden" name="auth_code" value="{auth_code}">
          <input type="hidden" name="redirect_uri" value="{redirect_uri}">
          <input type="hidden" name="state" value="{state}">
          <button type="submit" class="btn">Authorize & Connect</button>
        </form>
      </div>
    </body>
    </html>
    """
    return HTMLResponse(content=html)

@app.post("/oauth/approve")
async def oauth_approve(request: Request):
    data = await parse_request_data(request)
    auth_code = data.get("auth_code", "")
    redirect_uri = data.get("redirect_uri", "")
    state = data.get("state", "")
    if not redirect_uri:
        return HTMLResponse("Missing redirect_uri", status_code=400)
    delimiter = "&" if "?" in redirect_uri else "?"
    target = f"{redirect_uri}{delimiter}code={auth_code}&state={state}"
    return RedirectResponse(url=target, status_code=302)

@app.post("/oauth/token")
async def oauth_token(request: Request):
    data = await parse_request_data(request)
    access_token = f"ventra_access_{secrets.token_hex(24)}"
    refresh_token = f"ventra_refresh_{secrets.token_hex(24)}"

    VALID_TOKENS.add(access_token)
    await persist_setting("google_token", access_token)

    return {
        "token_type": "Bearer",
        "access_token": access_token,
        "refresh_token": refresh_token,
        "expires_in": 31536000
    }

def map_to_google_mode(mode: str, power: bool) -> str:
    if not power:
        return "off"
    m = str(mode).lower()
    if m == "cool": return "cool"
    if m == "heat": return "heat"
    if m == "dry": return "dry"
    if m == "fan": return "fan-only"
    if m == "auto": return "auto"
    return "cool"

def map_from_google_mode(gmode: str) -> tuple[bool, str]:
    g = str(gmode).lower()
    if g == "off":
        return (False, device_state.get("mode", "Cool"))
    elif g == "cool":
        return (True, "Cool")
    elif g == "heat":
        return (True, "Heat")
    elif g == "dry":
        return (True, "Dry")
    elif g == "fan-only":
        return (True, "Fan")
    elif g == "auto":
        return (True, "Auto")
    return (True, "Cool")

@app.post("/api/smarthome")
async def smarthome_fulfillment(request: Request):
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "invalid json"}, status_code=400)

    req_id = body.get("requestId", "req-1")
    inputs = body.get("inputs", [])

    for inp in inputs:
        intent = inp.get("intent")

        # 1. Device Discovery
        if intent == "action.devices.SYNC":
            return {
                "requestId": req_id,
                "payload": {
                    "agentUserId": "ventra_user_bhavya",
                    "devices": [{
                        "id": "ventra_ac_01",
                        "type": "action.devices.types.AC_UNIT",
                        "traits": [
                            "action.devices.traits.OnOff",
                            "action.devices.traits.TemperatureSetting",
                            "action.devices.traits.FanSpeed"
                        ],
                        "name": {
                            "name": "AC",
                            "nicknames": ["Air Conditioner", "Room AC", "Blue Star AC", "Ventra AC", "Cooler", "Classroom AC"]
                        },
                        "willReportState": False,
                        "attributes": {
                            "availableThermostatModes": "off,cool,heat,dry,fan-only,auto",
                            "thermostatTemperatureUnit": "C",
                            "thermostatTemperatureRange": {
                                "minThresholdCelsius": 16,
                                "maxThresholdCelsius": 30
                            },
                            "availableFanSpeeds": {
                                "speeds": [
                                    {"speed_name": "Auto", "speed_values": [{"speed_synonym": ["auto", "automatic"], "lang": "en"}]},
                                    {"speed_name": "Low", "speed_values": [{"speed_synonym": ["low", "quiet", "min", "1"], "lang": "en"}]},
                                    {"speed_name": "Med", "speed_values": [{"speed_synonym": ["medium", "med", "normal", "2"], "lang": "en"}]},
                                    {"speed_name": "High", "speed_values": [{"speed_synonym": ["high", "max", "maximum", "3"], "lang": "en"}]}
                                ],
                                "ordered": True
                            }
                        },
                        "deviceInfo": {
                            "manufacturer": "Ventra Labs",
                            "model": "Universal-AC-Hub-2.0",
                            "hwVersion": "ESP32",
                            "swVersion": "2.1.0"
                        }
                    }]
                }
            }

        # 2. Live State & Sensor Telemetry Query
        elif intent == "action.devices.QUERY":
            power = device_state.get("power", True)
            mode = device_state.get("mode", "Cool")
            g_mode = map_to_google_mode(mode, power)
            set_temp = float(device_state.get("temp", 24))
            room_temp = float(device_state.get("room_temp", 25.0))
            room_hum = float(device_state.get("room_hum", 50.0))
            fan = device_state.get("fan", "Auto")

            return {
                "requestId": req_id,
                "payload": {
                    "devices": {
                        "ventra_ac_01": {
                            "status": "SUCCESS",
                            "online": device_state.get("online", True),
                            "on": power,
                            "thermostatMode": g_mode,
                            "thermostatTemperatureSetpoint": set_temp,
                            "thermostatTemperatureAmbient": room_temp,
                            "thermostatHumidityAmbient": room_hum,
                            "currentFanSpeedSetting": fan
                        }
                    }
                }
            }

        # 3. Voice Command Execution
        elif intent == "action.devices.EXECUTE":
            commands_payload = inp.get("payload", {}).get("commands", [])
            for cmd_entry in commands_payload:
                for execution in cmd_entry.get("execution", []):
                    command_type = execution.get("command")
                    params = execution.get("params", {})

                    if command_type == "action.devices.commands.OnOff":
                        on_val = params.get("on", True)
                        await set_ac_command(ACCommand(power=on_val))

                    elif command_type == "action.devices.commands.ThermostatTemperatureSetpoint":
                        target_c = int(round(params.get("thermostatTemperatureSetpoint", 24)))
                        await set_ac_command(ACCommand(temp=target_c, power=True))

                    elif command_type == "action.devices.commands.ThermostatSetMode":
                        g_mode = params.get("thermostatMode", "cool")
                        new_power, new_mode = map_from_google_mode(g_mode)
                        await set_ac_command(ACCommand(power=new_power, mode=new_mode))

                    elif command_type == "action.devices.commands.SetFanSpeed":
                        speed = str(params.get("fanSpeed", "Auto")).capitalize()
                        if speed in ["Low", "Med", "High", "Auto"]:
                            await set_ac_command(ACCommand(fan=speed))

            power = device_state.get("power", True)
            g_mode = map_to_google_mode(device_state.get("mode", "Cool"), power)
            return {
                "requestId": req_id,
                "payload": {
                    "commands": [{
                        "ids": ["ventra_ac_01"],
                        "status": "SUCCESS",
                        "states": {
                            "on": power,
                            "thermostatMode": g_mode,
                            "thermostatTemperatureSetpoint": float(device_state.get("temp", 24)),
                            "thermostatTemperatureAmbient": float(device_state.get("room_temp", 25.0)),
                            "thermostatHumidityAmbient": float(device_state.get("room_hum", 50.0)),
                            "currentFanSpeedSetting": device_state.get("fan", "Auto")
                        }
                    }]
                }
            }

        # 4. Account Disconnect / Unlink
        elif intent == "action.devices.DISCONNECT":
            return {"requestId": req_id, "payload": {}}

    return {"requestId": req_id, "payload": {}}

