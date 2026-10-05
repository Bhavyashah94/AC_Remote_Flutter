# Ventra Universal AC Hub - Panasonic AC Protocol & Hardware Specification

## 1. Hardware Pinout & Wiring (ESP32 Dev Module)

| Component | Pin | GPIO | Circuit / Details | Status |
| :--- | :--- | :---: | :--- | :---: |
| **IR Transmitter** | NPN Base Drive | **GPIO 4** | 38 kHz modulated IR LED via 2N2222 / BC547 NPN transistor | Live / Verified |
| **IR Receiver** | Signal Out | **GPIO 15** | TSOP1838 (38 kHz optical demodulator) with pull-up | Live / Verified |
| **Climate Sensor** | Data Pin | **GPIO 26** | DHT22 (AM2302) 3-pin module with built-in pull-up | Live / Verified |
| **PIR Motion** | Out Pin | **GPIO 27** | HC-SR501 Motion Detector (Interrupt attached on CHANGE) | Live / Verified |

---

## 2. Panasonic Inverter AC Protocol Architecture

Panasonic AC units operate on a pulse distance modulated 38 kHz optical carrier. Commands are split into two distinct packet categories:
1. **27-Byte Standard State Frame** (216 bits): Transmitted when changing global climate parameters (Power, Temperature, Mode, Fan Speed, Swing, Turbo, Quiet).
2. **16-Byte Extended Feature Frame** (128 bits): Transmitted for specialized inverter features (`converti7` capacity control, `CLEAN` coil mode, and `Display LED` toggle).

---

## 3. The 16-Byte Extended Feature Frame (Reverse Engineered)

### Frame Structure
```
Header (8 bytes) : 02 20 E0 04 00 00 00 06
Payload (8 bytes): 02 20 E0 04 80 [Byte 13] [Byte 14] [Checksum]
```

### Checksum Algorithm
```cpp
uint8_t checksum = (0x80 + byte13 + byte14 + 0x06) & 0xFF;
```

### Confirmed Feature Lookup Table

| Feature / Mode | AC Front Display | Byte 13 | Byte 14 | Checksum | Full 16-Byte Hex String |
| :--- | :---: | :---: | :---: | :---: | :--- |
| **`converti7` Full Capacity** | **`FC`** | `0x02` | `0xAA` | `0x32` | `02 20 E0 04 00 00 00 06 02 20 E0 04 80 02 AA 32` |
| **`converti7` 90% Capacity** | **`90`** | `0x03` | `0xAA` | `0x33` | `02 20 E0 04 00 00 00 06 02 20 E0 04 80 03 AA 33` |
| **`converti7` 80% Capacity** | **`80`** | `0x04` | `0xAA` | `0x34` | `02 20 E0 04 00 00 00 06 02 20 E0 04 80 04 AA 34` |
| **`converti7` 70% Capacity** | **`70`** | `0x05` | `0xAA` | `0x35` | `02 20 E0 04 00 00 00 06 02 20 E0 04 80 05 AA 35` |
| **`converti7` 55% Capacity** | **`55`** | `0x06` | `0xAA` | `0x36` | `02 20 E0 04 00 00 00 06 02 20 E0 04 80 06 AA 36` |
| **`converti7` 40% Capacity** | **`40`** | `0x07` | `0xAA` | `0x37` | `02 20 E0 04 00 00 00 06 02 20 E0 04 80 07 AA 37` |
| **`converti7` Normal / Auto** | **Temp** | `0x00` | `0xAA` | `0x30` | `02 20 E0 04 00 00 00 06 02 20 E0 04 80 00 AA 30` |
| **`Display LED` Toggle** | **LED Off/On** | `0x9E` | `0x32` | `0x56` | `02 20 E0 04 00 00 00 06 02 20 E0 04 80 9E 32 56` |
| **`CLEAN` Coil Self-Clean** | **Clean Icon** | `0xCB` | `0xF2` | `0x43` | `02 20 E0 04 00 00 00 06 02 20 E0 04 80 CB F2 43` |
| **`POWERFUL` Mode Toggle** | **Powerful Blower / Max Cool** | `0x86` | `0x35` | `0x41` | `02 20 E0 04 00 00 00 06 02 20 E0 04 80 86 35 41` |

---

## 4. The 27-Byte Standard Climate Frame

### Panasonic Model Profile
* **Target Profile**: `kPanasonicRkr` (Model 6)
* **Model Byte (Byte 23)**: `0x89` (Required by Panasonic Inverter AC units; generic `0x81` JKE will be ignored by modern Indian Panasonic units).

### Byte Offsets
* **Byte 0–7**: Fixed Section 1 Header: `02 20 E0 04 00 00 00 06`
* **Byte 8–12**: Fixed Section 2 Header: `02 20 E0 04 00`
* **Byte 13**: Operating Mode & Power
  * Bit 0: Power (1 = ON, 0 = OFF)
  * Bit 3: RKR Signature (Must be 1 for RKR models: `0x08`)
  * Bits 4–6: Mode (`0x00` Auto, `0x20` Cool, `0x30` Dry, `0x40` Heat, `0x60` Fan)
  * *Example Power ON Cool*: `0x39`
  * *Example Power OFF Cool*: `0x38`
* **Byte 14**: Target Temperature in Celsius (`Temp << 1`, e.g., 24°C = `0x30`)
* **Byte 15**: Mode Sub-flags (`0x80`)
* **Byte 16**: Fan Speed & Vertical Swing
  * High Nibble: Fan Speed (`0x50` Min, `0x60` Low, `0x70` Med, `0x80` High, `0x90` Max, `0xA0` Auto)
  * Low Nibble: Vertical Swing (`0x01` Highest ... `0x05` Lowest, `0x0F` Auto)
* **Byte 17**: Horizontal Swing (`0x0D` Auto, `0x06` Center, `0x09` Full Left, `0x0C` Full Right)
* **Byte 18–20**: On/Off Timers
* **Byte 21**: Turbo & Quiet flags (`0x20` Powerful, `0x01` Quiet)
* **Byte 22**: Ion / nanoe-G Air Filter (`0x01` Active)
* **Byte 23**: Hardware Model Signature: `0x89`
* **Byte 24–25**: Real-Time Clock minutes past midnight
* **Byte 26**: Checksum (`sum(bytes 0..25) + 0xF4`)

---

## 5. Serial CLI Diagnostic Commands (115200 Baud)

| Command | Action |
| :--- | :--- |
| `status` | Displays live Wi-Fi, MQTT, DHT22 readings, PIR status, and active protocol |
| `test_ir` | Emits Panasonic 24°C Cool Auto Fan RKR command on GPIO 4 |
| `display` | Toggles AC front display LED without affecting power or climate state |
| `clean` | Emits self-cleaning cycle command |
| `capacity <FC\|90\|80\|70\|55\|40\|auto>` | Direct capacity command |
| `converti7 <0-6>` | Step-based capacity command (0=Auto, 1=FC, 2=90%, etc.) |
| `send_hex <54 hex chars>` | Transmits raw 27 bytes via IR LED |
| `send_short <b13> <b14>` | Transmits raw 16-byte extended frame |
| `learn` | Arms TSOP1838 receiver on GPIO 15 for 30s auto-discovery |

---

## 6. How to Sniff College AC Remotes Tomorrow

1. Plug the ESP32 board into USB on any laptop.
2. Open Serial Monitor at **115200 baud** (or run `python3 scratch/serial_logger.py`).
3. Point the college AC remote at **GPIO 15** (TSOP1838 receiver) from 10–20 cm away.
4. Press Power ON once:
   * The sniffer will automatically decode the brand (e.g. `DAIKIN`, `VOLTAS`, `LG`, `BLUESTAR`, `MITSUBISHI`, `GREE`, `CARRIER`).
   * It will print the exact protocol ID, bit length, and raw hex bytes.
   * If supported by the universal engine, it will immediately store the detected brand into flash NVS memory!
