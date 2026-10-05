#include <Arduino.h>
#include <WiFi.h>
#include <Preferences.h>
#include <NimBLEDevice.h>
#include <DHT.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>

#include <IRremoteESP8266.h>
#include <IRsend.h>
#include <IRrecv.h>
#include <IRac.h>
#include <IRutils.h>
#include <ir_Panasonic.h>
#include <ir_Gree.h>

#include "config.h"

// Hardware Drivers
DHT dht(DHT_PIN, DHT_TYPE);
IRac ac(IR_SEND_PIN);
IRrecv irrecv(IR_RECV_PIN, 1024, 50, true);

WiFiClient espClient;
PubSubClient mqttClient(espClient);
Preferences prefs;

// BLE Provisioning
NimBLEServer* pBleServer = nullptr;
NimBLECharacteristic* pScanChar = nullptr;
NimBLECharacteristic* pConfigChar = nullptr;
NimBLECharacteristic* pStatusChar = nullptr;
bool bleProvisioningActive = false;

// Global State
float currentTemp = 24.0;
float currentHum = 50.0;
volatile bool currentMotion = false;
volatile bool motionLatched = false;

unsigned long lastSensorRead = 0;
unsigned long lastTelemetrySend = 0;
unsigned long lastMqttRetry = 0;
unsigned long lastWifiRetry = 0;
unsigned long wifiBackoffMs = 5000;
volatile bool pendingWifiConnect = false;
String savedSsid = "";
String savedPass = "";

// Active AC Brand / Protocol
String activeProtocol = "Panasonic"; // Default
bool isLearningMode = false;
unsigned long learnTimeout = 0;

// Interrupt for PIR motion sensor (GPIO 27)
void IRAM_ATTR pirMotionISR() {
  bool val = digitalRead(PIR_PIN);
  if (val) motionLatched = true;
  currentMotion = val;
}

// -------------------------------------------------------------
// BLE Provisioning Callbacks
// -------------------------------------------------------------
class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer) {
    Serial.println("[BLE] Phone connected for setup");
  }
  void onDisconnect(NimBLEServer* pServer) {
    Serial.println("[BLE] Phone disconnected from setup");
    if (bleProvisioningActive) {
      NimBLEDevice::getAdvertising()->start();
      Serial.println("[BLE] Resumed advertising.");
    }
  }
  void onDisconnect(NimBLEServer* pServer, ble_gap_conn_desc* desc) {
    Serial.println("[BLE] Phone disconnected from setup (desc)");
    if (bleProvisioningActive) {
      NimBLEDevice::getAdvertising()->start();
      Serial.println("[BLE] Resumed advertising.");
    }
  }
};

class ConfigCharCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pChar) {
    std::string val = pChar->getValue();
    if (val.empty()) return;

    Serial.printf("[BLE] Received Wi-Fi credentials (%d bytes)\n", (int)val.length());
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, val.c_str());

    String ssid = "";
    String pass = "";

    if (!err) {
      ssid = doc["ssid"] | "";
      pass = doc["password"] | "";
    }

    if (ssid.length() == 0) {
      int nl = val.find('\n');
      if (nl != std::string::npos) {
        ssid = String(val.substr(0, nl).c_str());
        pass = String(val.substr(nl + 1).c_str());
      } else {
        ssid = String(val.c_str());
      }
    }

    ssid.trim();
    pass.trim();

    if (ssid.length() > 0) {
      Serial.printf("[BLE] Storing Wi-Fi credentials for: %s\n", ssid.c_str());
      prefs.begin("ventra_wifi", false);
      prefs.putString("ssid", ssid);
      prefs.putString("pass", pass);
      prefs.end();
      savedSsid = ssid;
      savedPass = pass;

      if (pStatusChar) {
        pStatusChar->setValue("1:Connecting");
        pStatusChar->notify();
      }

      pendingWifiConnect = true;
    }
  }
};

class ScanCharCallbacks : public NimBLECharacteristicCallbacks {
  void onRead(NimBLECharacteristic* pChar) {
    Serial.println("[BLE] Wi-Fi network scan requested...");
    WiFi.disconnect(false);
    delay(50);
    WiFi.mode(WIFI_STA);
    delay(50);
    int n = WiFi.scanNetworks(false, true);
    Serial.printf("[BLE] Wi-Fi scan completed. Found %d networks.\n", n);
    JsonDocument doc;
    JsonArray arr = doc.to<JsonArray>();
    if (n > 0) {
      for (int i = 0; i < n && i < 12; ++i) {
        JsonObject net = arr.add<JsonObject>();
        net["s"] = WiFi.SSID(i);
        net["r"] = WiFi.RSSI(i);
        net["a"] = (WiFi.encryptionType(i) != WIFI_AUTH_OPEN);
      }
      WiFi.scanDelete();
    }
    String out;
    serializeJson(doc, out);
    pChar->setValue(out.c_str());
  }
};

void startBleProvisioning() {
  if (bleProvisioningActive) {
    if (pBleServer != nullptr) {
      NimBLEDevice::getAdvertising()->start();
      Serial.println("[BLE] Advertising re-triggered.");
    }
    return;
  }
  bleProvisioningActive = true;

  if (pBleServer == nullptr) {
    NimBLEDevice::init(BLE_DEVICE_NAME);
    NimBLEDevice::setPower(ESP_PWR_LVL_P9);
    NimBLEDevice::setMTU(512);

    pBleServer = NimBLEDevice::createServer();
    pBleServer->setCallbacks(new ServerCallbacks());
    pBleServer->advertiseOnDisconnect(true);

    NimBLEService* pService = pBleServer->createService(SERVICE_UUID);
    pScanChar = pService->createCharacteristic(CHAR_UUID_SCAN, NIMBLE_PROPERTY::READ);
    pScanChar->setCallbacks(new ScanCharCallbacks());

    pConfigChar = pService->createCharacteristic(CHAR_UUID_CONFIG, NIMBLE_PROPERTY::WRITE);
    pConfigChar->setCallbacks(new ConfigCharCallbacks());

    pStatusChar = pService->createCharacteristic(CHAR_UUID_STATUS, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
    pStatusChar->setValue("0:Idle");

    pService->start();
  }

  NimBLEAdvertising* pAdvertising = NimBLEDevice::getAdvertising();
  pAdvertising->stop();

  // Primary advertisement: 128-bit Service UUID (21 bytes, strictly within 31-byte limit)
  NimBLEAdvertisementData advData;
  advData.setFlags(0x06);
  advData.setCompleteServices(NimBLEUUID(SERVICE_UUID));
  pAdvertising->setAdvertisementData(advData);

  // Scan response: Name (shunted to avoid 31-byte overflow on Android 14)
  NimBLEAdvertisementData scanRespData;
  scanRespData.setName(BLE_DEVICE_NAME);
  pAdvertising->setScanResponseData(scanRespData);

  pAdvertising->start();
  Serial.printf("[BLE] Setup mode active. Device: %s (Service: %s)\n", BLE_DEVICE_NAME, SERVICE_UUID);
}

// -------------------------------------------------------------
// Universal AC Command Transmission (IRac on GPIO 4)
// -------------------------------------------------------------
decode_type_t resolveProtocol(const String& brand) {
  String b = brand;
  b.toUpperCase();

  if (b.indexOf("PANASONIC") >= 0) return decode_type_t::PANASONIC_AC;
  if (b.indexOf("GREE") >= 0)      return decode_type_t::GREE;
  if (b.indexOf("DAIKIN") >= 0)    return decode_type_t::DAIKIN;
  if (b.indexOf("MITSUBISHI") >= 0) return decode_type_t::MITSUBISHI_AC;
  if (b.indexOf("LG") >= 0)        return decode_type_t::LG;
  if (b.indexOf("SAMSUNG") >= 0)   return decode_type_t::SAMSUNG_AC;
  if (b.indexOf("VOLTAS") >= 0)    return decode_type_t::VOLTAS;
  if (b.indexOf("MIDEA") >= 0)     return decode_type_t::MIDEA;
  if (b.indexOf("CARRIER") >= 0)   return decode_type_t::CARRIER_AC64;
  if (b.indexOf("HITACHI") >= 0)   return decode_type_t::HITACHI_AC;
  if (b.indexOf("TCL") >= 0)       return decode_type_t::TCL112AC;
  if (b.indexOf("WHIRLPOOL") >= 0) return decode_type_t::WHIRLPOOL_AC;

  return strToDecodeType(brand.c_str());
}

void sendPanasonic16(uint8_t byte13, uint8_t byte14) {
  uint8_t packet[16] = {
    0x02, 0x20, 0xE0, 0x04, 0x00, 0x00, 0x00, 0x06,
    0x02, 0x20, 0xE0, 0x04, 0x80, byte13, byte14, 0x00
  };
  packet[15] = (uint8_t)(0x80 + byte13 + byte14 + 0x06);
  irrecv.disableIRIn();
  IRsend irsend(IR_SEND_PIN);
  irsend.begin();
  irsend.sendPanasonicAC(packet, 16);
  delay(25);
  irrecv.enableIRIn();
  Serial.printf("[Panasonic 16] Emitted on GPIO 4: 13=0x%02X, 14=0x%02X, Checksum=0x%02X\n", byte13, byte14, packet[15]);
}

void panasonicSetCapacity(const String& cap) {
  uint8_t val = 0x00;
  String c = cap;
  c.toUpperCase();
  c.trim();
  if (c == "FC" || c == "100" || c == "1") val = 0x02;
  else if (c == "90" || c == "2") val = 0x03;
  else if (c == "80" || c == "3") val = 0x04;
  else if (c == "70" || c == "4") val = 0x05;
  else if (c == "55" || c == "5") val = 0x06;
  else if (c == "40" || c == "6") val = 0x07;
  else val = 0x00; // Normal / Auto

  Serial.printf("[Panasonic Converti7] Capacity: %s -> Byte 13 = 0x%02X, Byte 14 = 0xAA\n", cap.c_str(), val);
  sendPanasonic16(val, 0xAA);
}

void panasonicSetConverti7(uint8_t step) {
  uint8_t val = (step == 0) ? 0x00 : (uint8_t)(step + 1);
  Serial.printf("[Panasonic Ext] Sending converti7 step %d (Byte 13 = 0x%02X, Byte 14 = 0xAA)...\n", step, val);
  sendPanasonic16(val, 0xAA);
}

void panasonicClean() {
  Serial.println("[Panasonic Ext] Sending CLEAN cycle command (Byte 13 = 0xCB, Byte 14 = 0xF2)...");
  sendPanasonic16(0xCB, 0xF2);
}

void panasonicToggleDisplay() {
  Serial.println("[Panasonic Ext] Sending Display LED Toggle command (Byte 13 = 0x9E, Byte 14 = 0x32)...");
  sendPanasonic16(0x9E, 0x32);
}

void panasonicTogglePowerful() {
  Serial.println("[Panasonic Ext] Sending Powerful Mode command (Byte 13 = 0x86, Byte 14 = 0x35)...");
  sendPanasonic16(0x86, 0x35);
}

void executeUniversalAcCommand(const JsonDocument& doc) {
  // Check for extended Panasonic features
  bool isExtFeature = false;
  if (doc["capacity"].is<const char*>()) {
    panasonicSetCapacity(doc["capacity"].as<String>());
    isExtFeature = true;
  } else if (doc["capacity"].is<int>()) {
    panasonicSetCapacity(String(doc["capacity"].as<int>()));
    isExtFeature = true;
  } else if (doc["converti7"].is<int>()) {
    uint8_t c7 = doc["converti7"];
    panasonicSetConverti7(c7);
    isExtFeature = true;
  }
  if (doc["clean"] == true || doc["cmd"] == "clean") {
    panasonicClean();
    isExtFeature = true;
  }
  if (doc["display_toggle"] == true || doc["cmd"] == "display") {
    panasonicToggleDisplay();
    isExtFeature = true;
  }
  if (doc["powerful_toggle"] == true || doc["cmd"] == "powerful" || (doc["powerful"].is<bool>() && !doc["temp"].is<int>() && !doc["temp"].is<float>())) {
    panasonicTogglePowerful();
    isExtFeature = true;
  }

  // If this was an extended feature (converti7, clean, display), send ACK and do NOT emit 27-byte frame
  if (isExtFeature) {
    if (mqttClient.connected()) {
      JsonDocument ack;
      ack["status"] = "executed";
      ack["brand"] = activeProtocol;
      ack["feature"] = "extended";
      String ackStr;
      serializeJson(ack, ackStr);
      mqttClient.publish(TOPIC_ACK, ackStr.c_str());
    }
    return;
  }

  String brand = doc["protocol"] | activeProtocol;
  decode_type_t vendor = resolveProtocol(brand);

  if (!IRac::isProtocolSupported(vendor)) {
    Serial.printf("[IRac] Unsupported protocol: %s. Defaulting to Panasonic.\n", brand.c_str());
    vendor = decode_type_t::PANASONIC_AC;
  }

  activeProtocol = brand;

  bool power = doc["power"] | false;
  float temp = doc["temp"] | 24;
  String modeStr = doc["mode"] | "Cool";
  String fanStr = doc["fan"] | "Auto";
  int swingVVal = doc["swing_v"] | 0;
  int swingHVal = doc["swing_h"] | 0;

  // Convert to stdAc types
  stdAc::opmode_t opmode = stdAc::opmode_t::kCool;
  if (modeStr.equalsIgnoreCase("Heat")) opmode = stdAc::opmode_t::kHeat;
  else if (modeStr.equalsIgnoreCase("Dry")) opmode = stdAc::opmode_t::kDry;
  else if (modeStr.equalsIgnoreCase("Fan")) opmode = stdAc::opmode_t::kFan;
  else if (modeStr.equalsIgnoreCase("Auto")) opmode = stdAc::opmode_t::kAuto;

  stdAc::fanspeed_t fanSpeed = stdAc::fanspeed_t::kAuto;
  if (fanStr.equalsIgnoreCase("Min")) fanSpeed = stdAc::fanspeed_t::kMin;
  else if (fanStr.equalsIgnoreCase("Low")) fanSpeed = stdAc::fanspeed_t::kLow;
  else if (fanStr.equalsIgnoreCase("Med")) fanSpeed = stdAc::fanspeed_t::kMedium;
  else if (fanStr.equalsIgnoreCase("High")) fanSpeed = stdAc::fanspeed_t::kHigh;
  else if (fanStr.equalsIgnoreCase("Max")) fanSpeed = stdAc::fanspeed_t::kMax;

  stdAc::swingv_t swingV = (swingVVal == 0) ? stdAc::swingv_t::kOff : stdAc::swingv_t::kAuto;
  stdAc::swingh_t swingH = (swingHVal == 0) ? stdAc::swingh_t::kOff : stdAc::swingh_t::kAuto;

  bool quiet = doc["quiet"] | false;
  bool turbo = doc["turbo"] | doc["powerful"] | false;
  bool light = (doc["display"] | 1) != 0;

  Serial.printf("[IRac] Sending -> Vendor: %s, Power: %d, Temp: %.1fC, Mode: %s, Fan: %s\n",
                typeToString(vendor).c_str(), power, temp, modeStr.c_str(), fanStr.c_str());

  if (vendor == decode_type_t::PANASONIC_AC) {
    IRPanasonicAc panasonicAc(IR_SEND_PIN);
    panasonicAc.begin();
    panasonicAc.setModel(kPanasonicRkr);
    panasonicAc.setPower(power);
    panasonicAc.setMode(panasonicAc.convertMode(opmode));
    panasonicAc.setTemp((uint8_t)temp);
    panasonicAc.setFan(panasonicAc.convertFan(fanSpeed));

    // Discrete vertical louver control
    if (swingVVal == 0xF || swingVVal == 15) {
      panasonicAc.setSwingVertical(kPanasonicAcSwingVAuto);
    } else if (swingVVal >= 1 && swingVVal <= 5) {
      panasonicAc.setSwingVertical(swingVVal);
    } else {
      panasonicAc.setSwingVertical(panasonicAc.convertSwingV(swingV));
    }

    panasonicAc.setSwingHorizontal(panasonicAc.convertSwingH(swingH));
    panasonicAc.setQuiet(false);

    // Enforce real hardware Powerful bit: Bit 5 (0x20) on Byte 21 with Auto Fan (0xAF)
    uint8_t* rawState = panasonicAc.getRaw();
    if (turbo) {
      panasonicAc.setFan(panasonicAc.convertFan(stdAc::fanspeed_t::kAuto));
      rawState[21] |= 0x20;
    } else {
      rawState[21] &= ~0x20;
    }
    rawState[kPanasonicAcStateLength - 1] = IRPanasonicAc::calcChecksum(rawState, kPanasonicAcStateLength);

    irrecv.disableIRIn();
    panasonicAc.send();
    delay(25);
    irrecv.enableIRIn();
  } else if (vendor == decode_type_t::GREE) {
    gree_ac_remote_model_t gModel = gree_ac_remote_model_t::YAW1F;
    if (doc["model"].is<const char*>()) {
      String m = doc["model"].as<String>();
      if (m.equalsIgnoreCase("YBOFB") || m.equalsIgnoreCase("YB0F") || m.equalsIgnoreCase("YB1F2")) {
        gModel = gree_ac_remote_model_t::YBOFB;
      }
    }

    IRGreeAC greeAc(IR_SEND_PIN, gModel);
    greeAc.begin();
    greeAc.setModel(gModel);
    greeAc.setPower(power);

    // CRITICAL FIX: setMode MUST be called BEFORE setTemp!
    // In IRremoteESP8266, IRGreeAC initializes in kGreeAuto (0).
    // IRGreeAC::setTemp contains: `if (_.Mode == kGreeAuto) safecelsius = 25;`
    // If setTemp is called before setMode, it forcibly clamps any temperature (16C, 20C, etc.) to 25C!
    uint8_t gMode = kGreeCool;
    if (modeStr.equalsIgnoreCase("Heat")) gMode = kGreeHeat;
    else if (modeStr.equalsIgnoreCase("Dry")) gMode = kGreeDry;
    else if (modeStr.equalsIgnoreCase("Fan")) gMode = kGreeFan;
    else if (modeStr.equalsIgnoreCase("Auto")) gMode = kGreeAuto;
    greeAc.setMode(gMode);

    // Now that mode is Cool/Heat/Dry/Fan, setTemp sets the actual desired temperature!
    greeAc.setTemp((uint8_t)temp);

    uint8_t gFan = kGreeFanAuto;
    if (fanStr.equalsIgnoreCase("Low") || fanStr.equalsIgnoreCase("Min")) gFan = kGreeFanMin;
    else if (fanStr.equalsIgnoreCase("Med") || fanStr.equalsIgnoreCase("Medium")) gFan = kGreeFanMed;
    else if (fanStr.equalsIgnoreCase("High") || fanStr.equalsIgnoreCase("Max")) gFan = kGreeFanMax;
    greeAc.setFan(gFan);

    if (swingVVal == 1) {
      greeAc.setSwingVertical(true, kGreeSwingAuto);
    } else if (swingVVal >= 2 && swingVVal <= 11) {
      greeAc.setSwingVertical(false, swingVVal);
    } else {
      greeAc.setSwingVertical(false, kGreeSwingLastPos);
    }

    greeAc.setSwingHorizontal(swingHVal);

    greeAc.setTurbo(turbo);
    bool lightOn = doc["light"].is<bool>() ? doc["light"].as<bool>() : ((doc["display"] | 1) != 0);
    greeAc.setLight(lightOn);
    greeAc.setXFan(doc["x_fan"] | false);
    greeAc.setSleep(doc["sleep"] | false);
    greeAc.setIFeel(doc["ifeel"] | false);
    if (doc["display_temp"].is<int>()) {
      greeAc.setDisplayTempSource(doc["display_temp"].as<int>());
    } else {
      // Default to displaying Set Temperature on the AC display
      greeAc.setDisplayTempSource(kGreeDisplayTempSet);
    }

    irrecv.disableIRIn();
    greeAc.send();
    delay(25);
    irrecv.enableIRIn();
    Serial.printf("[Gree %s] IR Emitted! Power:%d, EncodedTemp:%dC (Target:%.1fC), Mode:%s, Fan:%s, Turbo:%d, Light:%d, XFan:%d, SwingV:%d, SwingH:%d\n",
                  (gModel == gree_ac_remote_model_t::YAW1F) ? "YAW1F" : "YBOFB",
                  power, greeAc.getTemp(), temp, modeStr.c_str(), fanStr.c_str(), turbo, lightOn, (doc["x_fan"] | false), swingVVal, swingHVal);
  } else {
    // Universal IR Blast for other brands
    irrecv.disableIRIn();
    ac.sendAc(
      vendor, -1,
      power, opmode, temp, true,
      fanSpeed, swingV, swingH,
      quiet, turbo, false, light, false, false, true
    );
    delay(25);
    irrecv.enableIRIn();
  }

  Serial.println("[IRac] Pulse emitted successfully on GPIO 4!");

  // Send ACK over MQTT
  if (mqttClient.connected()) {
    JsonDocument ack;
    ack["status"] = "executed";
    ack["brand"] = activeProtocol;
    ack["power"] = power;
    ack["temp"] = temp;
    String ackStr;
    serializeJson(ack, ackStr);
    mqttClient.publish(TOPIC_ACK, ackStr.c_str());
  }
}

// -------------------------------------------------------------
// IR Remote Auto-Discovery & Reverse Engineering (TSOP1838 on GPIO 15)
// -------------------------------------------------------------
static uint8_t prevSniffState[32];
static uint16_t prevSniffNbytes = 0;
static decode_type_t prevSniffVendor = decode_type_t::UNKNOWN;
static bool hasPrevSniffState = false;

void printByteBits(uint8_t b) {
  for (int i = 7; i >= 0; i--) {
    Serial.print((b & (1 << i)) ? '1' : '0');
  }
}

void printStateHex(const uint8_t* state, uint16_t nbytes) {
  for (int i = 0; i < nbytes; i++) {
    Serial.printf("%02X ", state[i]);
  }
  Serial.println();
}

void printBitDiffs(const uint8_t* prevState, const uint8_t* currState, uint16_t nbytes) {
  int diffCount = 0;
  for (int i = 0; i < nbytes; i++) {
    if (currState[i] != prevState[i]) {
      diffCount++;
      Serial.printf("  * Byte [%02d] (0x%02X -> 0x%02X): ", i, prevState[i], currState[i]);
      printByteBits(prevState[i]);
      Serial.print(" -> ");
      printByteBits(currState[i]);
      uint8_t diffBits = prevState[i] ^ currState[i];
      Serial.printf(" (Flipped: ");
      for (int b = 7; b >= 0; b--) {
        if (diffBits & (1 << b)) Serial.printf("b%d ", b);
      }
      Serial.println(")");
    }
  }
  if (diffCount == 0) {
    Serial.println("  (Identical to previous frame)");
  }
}

void armRemoteLearning() {
  isLearningMode = true;
  learnTimeout = millis() + 30000; // 30s timeout
  irrecv.enableIRIn();
  Serial.println("[IR Sniffer] Armed on GPIO 15! Waiting for user to press remote button...");
}

void pollIrReceiver() {
  decode_results results;
  if (irrecv.decode(&results)) {
    decode_type_t vendor = results.decode_type;
    uint16_t nbytes = (results.bits + 7) / 8;

    Serial.printf("\n=======================================================\n");
    Serial.printf("[IR Sniffer] >>> SIGNAL DETECTED! <<<\n");
    Serial.printf("[IR Sniffer] Protocol: %s (Type: %d), Bits: %d, RawLen: %d\n",
                  typeToString(vendor).c_str(), vendor, results.bits, results.rawlen);

    if (vendor == decode_type_t::PANASONIC_AC) {
      Serial.printf("[Panasonic HEX (%d Bytes)]:\n", nbytes);
      printStateHex(results.state, nbytes);

      if (nbytes == 27) {
        IRPanasonicAc pAc(0);
        pAc.setRaw(results.state);
        Serial.printf("[Panasonic Standard 27-Byte]: %s\n", pAc.toString().c_str());
      } else if (nbytes == 16) {
        Serial.printf("[Panasonic Short Frame / Feature Frame]: Byte[12]=0x%02X, Byte[13]=0x%02X, Byte[14]=0x%02X, Checksum=0x%02X\n",
                      results.state[12], results.state[13], results.state[14], results.state[15]);
      }

      if (hasPrevSniffState && prevSniffVendor == vendor && prevSniffNbytes == nbytes) {
        Serial.println("--- BIT-BY-BIT DIFFERENCES FROM PREVIOUS ---");
        printBitDiffs(prevSniffState, results.state, nbytes);
        Serial.println("--------------------------------------------");
      } else {
        Serial.println("--- PANASONIC BASELINE RECORDED! Press another button to view diff ---");
      }
      if (nbytes <= sizeof(prevSniffState)) {
        memcpy(prevSniffState, results.state, nbytes);
        prevSniffNbytes = nbytes;
        prevSniffVendor = vendor;
        hasPrevSniffState = true;
      }
    } else if (vendor == decode_type_t::GREE) {
      Serial.printf("[GREE HEX (%d Bytes)]:\n", nbytes);
      printStateHex(results.state, nbytes);

      IRGreeAC greeAc(0);
      greeAc.setRaw(results.state);
      Serial.printf("[Gree Decoded]: %s\n", greeAc.toString().c_str());
      Serial.printf("  Model: %s, Power: %s, Mode: %d, Temp: %dC, Fan: %d, Turbo: %d, Light: %d, SwingV: %d (Auto: %d), SwingH: %d, Sleep: %d, Xfan: %d, IFeel: %d\n",
                    (greeAc.getModel() == gree_ac_remote_model_t::YAW1F) ? "YAW1F" : "YBOFB",
                    greeAc.getPower() ? "ON" : "OFF", greeAc.getMode(), greeAc.getTemp(),
                    greeAc.getFan(), greeAc.getTurbo(), greeAc.getLight(),
                    greeAc.getSwingVerticalPosition(), greeAc.getSwingVerticalAuto() ? 1 : 0,
                    greeAc.getSwingHorizontal(),
                    greeAc.getSleep(), greeAc.getXFan(), greeAc.getIFeel());

      if (hasPrevSniffState && prevSniffVendor == vendor && prevSniffNbytes == nbytes) {
        Serial.println("--- BIT-BY-BIT DIFFERENCES FROM PREVIOUS ---");
        printBitDiffs(prevSniffState, results.state, nbytes);
        Serial.println("--------------------------------------------");
      } else {
        Serial.println("--- GREE BASELINE RECORDED! Press another button to view diff ---");
      }
      if (nbytes <= sizeof(prevSniffState)) {
        memcpy(prevSniffState, results.state, nbytes);
        prevSniffNbytes = nbytes;
        prevSniffVendor = vendor;
        hasPrevSniffState = true;
      }
    } else {
      if (nbytes > 0 && results.state != nullptr && results.bits > 0) {
        Serial.printf("[%s HEX (%d Bytes)]:\n", typeToString(vendor).c_str(), nbytes);
        printStateHex(results.state, nbytes);

        if (hasPrevSniffState && prevSniffVendor == vendor && prevSniffNbytes == nbytes) {
          Serial.println("--- BIT-BY-BIT DIFFERENCES FROM PREVIOUS ---");
          printBitDiffs(prevSniffState, results.state, nbytes);
          Serial.println("--------------------------------------------");
        } else {
          Serial.println("--- BASELINE RECORDED! Press another button to view diff ---");
        }
        if (nbytes <= sizeof(prevSniffState)) {
          memcpy(prevSniffState, results.state, nbytes);
          prevSniffNbytes = nbytes;
          prevSniffVendor = vendor;
          hasPrevSniffState = true;
        }
      } else if (results.bits <= 64) {
        Serial.printf("[IR Value]: 0x%llX\n", (unsigned long long)results.value);
      }

      if (vendor == decode_type_t::UNKNOWN && results.rawlen > 40) {
        Serial.printf("[Unknown Protocol Raw Summary]: %s\n", resultToTimingInfo(&results).c_str());
      }
    }
    Serial.printf("=======================================================\n\n");

    if (isLearningMode && IRac::isProtocolSupported(vendor)) {
      String detectedBrand = typeToString(vendor);
      activeProtocol = detectedBrand;

      // Save to NVS
      prefs.begin("ventra_ac", false);
      prefs.putString("protocol", detectedBrand);
      prefs.end();

      // Send to server
      if (mqttClient.connected()) {
        JsonDocument detDoc;
        detDoc["event"] = "detected";
        detDoc["brand"] = detectedBrand;
        detDoc["protocol_id"] = (int)vendor;
        detDoc["bits"] = results.bits;
        detDoc["success"] = true;

        String detStr;
        serializeJson(detDoc, detStr);
        mqttClient.publish("ventra/detected", detStr.c_str());
      }

      isLearningMode = false;
    }
    irrecv.resume();
  }

  if (isLearningMode && millis() > learnTimeout) {
    isLearningMode = false;
    Serial.println("[IR Sniffer] Learning mode timed out.");
    if (mqttClient.connected()) {
      mqttClient.publish("ventra/detected", "{\"event\":\"timeout\", \"success\":false}");
    }
  }
}

// -------------------------------------------------------------
// MQTT Handlers
// -------------------------------------------------------------
static volatile bool hasPendingCommand = false;
static String pendingCommandJson = "";

void onMqttMessage(char* topic, byte* payload, unsigned int length) {
  if (String(topic) == TOPIC_CMD) {
    String body = "";
    body.reserve(length + 1);
    for (unsigned int i = 0; i < length; i++) body += (char)payload[i];
    pendingCommandJson = body;
    hasPendingCommand = true;
  } else if (String(topic) == "ventra/learn") {
    armRemoteLearning();
  }
}

String getMqttClientId() {
  uint8_t mac[6];
  WiFi.macAddress(mac);
  char buf[32];
  snprintf(buf, sizeof(buf), "Ventra_%02X%02X%02X", mac[3], mac[4], mac[5]);
  return String(buf);
}

void connectMqtt() {
  if (mqttClient.connected() || WiFi.status() != WL_CONNECTED) return;
  String cid = getMqttClientId();
  if (mqttClient.connect(cid.c_str(), TOPIC_STATUS, 0, false, "offline")) {
    Serial.printf("[MQTT] Connected to broker as %s!\n", cid.c_str());
    mqttClient.publish(TOPIC_STATUS, "online", false);
    mqttClient.subscribe(TOPIC_CMD, 1);
    mqttClient.subscribe("ventra/learn", 0);
  }
}

void pollSensors() {
  float h = dht.readHumidity();
  float t = dht.readTemperature();
  bool dhtOk = !isnan(t) && !isnan(h);
  if (dhtOk) {
    currentTemp = t;
    currentHum = h;
  }
  currentMotion = digitalRead(PIR_PIN);

  if (dhtOk) {
    Serial.printf("[Sensors] DHT22: %.1fC, %.1f%% RH | PIR (GPIO %d): %s\n",
                  currentTemp, currentHum, PIR_PIN, currentMotion ? "MOTION DETECTED" : "Clear");
  } else {
    Serial.printf("[Sensors] DHT22: Failed to read from GPIO %d! Check wiring/pullup. | PIR: %s\n",
                  DHT_PIN, currentMotion ? "MOTION DETECTED" : "Clear");
  }
}

void sendTelemetry() {
  if (!mqttClient.connected()) return;

  bool reportMotion = currentMotion || motionLatched;
  motionLatched = false;

  JsonDocument doc;
  doc["room_temp"] = currentTemp;
  doc["room_hum"] = currentHum;
  doc["motion"] = reportMotion;
  doc["rssi"] = WiFi.RSSI();
  doc["uptime"] = millis() / 1000;
  doc["protocol"] = activeProtocol;

  String out;
  serializeJson(doc, out);
  mqttClient.publish(TOPIC_TELEMETRY, out.c_str());
}

void handleSerialCli() {
  if (Serial.available()) {
    String cmd = Serial.readStringUntil('\n');
    cmd.trim();
    if (cmd.length() == 0) return;

    Serial.printf("[CLI] Received command: %s\n", cmd.c_str());

    if (cmd == "test_ir" || cmd == "test" || cmd == "test_panasonic") {
      Serial.println("[CLI] Emitting test Panasonic AC IR pulse on GPIO 4...");
      JsonDocument testDoc;
      testDoc["protocol"] = "Panasonic";
      testDoc["power"] = true;
      testDoc["temp"] = 24;
      testDoc["mode"] = "Cool";
      testDoc["fan"] = "Auto";
      executeUniversalAcCommand(testDoc);
    } else if (cmd == "test_gree" || cmd == "gree_test") {
      Serial.println("[CLI] Emitting test Gree AC IR pulse on GPIO 4 (Cool 24C Auto Fan Light ON)...");
      JsonDocument testDoc;
      testDoc["protocol"] = "Gree";
      testDoc["power"] = true;
      testDoc["temp"] = 24;
      testDoc["mode"] = "Cool";
      testDoc["fan"] = "Auto";
      testDoc["display"] = 1;
      executeUniversalAcCommand(testDoc);
    } else if (cmd.startsWith("protocol ")) {
      String p = cmd.substring(9);
      p.trim();
      if (p.equalsIgnoreCase("gree")) {
        activeProtocol = "Gree";
        prefs.begin("ventra_ac", false);
        prefs.putString("protocol", "Gree");
        prefs.end();
        Serial.println("[CLI] Active protocol switched to: Gree (persisted to NVS)");
      } else if (p.equalsIgnoreCase("panasonic")) {
        activeProtocol = "Panasonic";
        prefs.begin("ventra_ac", false);
        prefs.putString("protocol", "Panasonic");
        prefs.end();
        Serial.println("[CLI] Active protocol switched to: Panasonic (persisted to NVS)");
      } else {
        activeProtocol = p;
        prefs.begin("ventra_ac", false);
        prefs.putString("protocol", p);
        prefs.end();
        Serial.printf("[CLI] Active protocol set to: %s\n", p.c_str());
      }
    } else if (cmd == "learn") {
      armRemoteLearning();
    } else if (cmd == "status") {
      Serial.println("\n--- VENTRA HARDWARE STATUS ---");
      Serial.printf("Active Protocol: %s\n", activeProtocol.c_str());
      Serial.printf("WiFi Status: %s\n", WiFi.status() == WL_CONNECTED ? "Connected" : "Disconnected (BLE Setup Active)");
      if (WiFi.status() == WL_CONNECTED) {
        Serial.printf("IP: %s, RSSI: %d dBm\n", WiFi.localIP().toString().c_str(), WiFi.RSSI());
        Serial.printf("MQTT Broker: %s\n", mqttClient.connected() ? "Connected" : "Disconnected");
      }
      Serial.printf("DHT22 (GPIO %d): %.1fC, %.1f%% RH\n", DHT_PIN, currentTemp, currentHum);
      Serial.printf("PIR Motion (GPIO %d): %s\n", PIR_PIN, currentMotion ? "MOTION DETECTED" : "Clear");
      Serial.printf("IR Receiver (GPIO %d): Ready\n", IR_RECV_PIN);
      Serial.printf("IR Transmitter (GPIO %d): Ready\n", IR_SEND_PIN);
      Serial.println("-------------------------------\n");
    } else if (cmd == "dht_scan") {
      Serial.println("\n[DHT Scan] Testing GPIO pins for DHT sensor...");
      const int testPins[] = {27, 25, 26, 14, 12, 13, 32, 33, 16, 17, 18, 19, 21, 22, 23};
      for (int p : testPins) {
        if (p == IR_SEND_PIN || p == IR_RECV_PIN) continue;
        pinMode(p, INPUT_PULLUP);
        delay(50);
        int idleLvl = digitalRead(p);
        Serial.printf("[DHT Scan] Pin GPIO %d (Idle: %s)... ", p, idleLvl ? "HIGH" : "LOW");

        DHT tempDht(p, DHT22);
        tempDht.begin();
        delay(300);
        float t = tempDht.readTemperature();
        float h = tempDht.readHumidity();

        if (!isnan(t) && !isnan(h) && t > -40.0 && t < 80.0) {
          Serial.printf(">>> SUCCESS! DHT22 FOUND on GPIO %d! Temp: %.1fC, Hum: %.1f%% <<<\n", p, t, h);
          return;
        } else {
          DHT tempDht11(p, DHT11);
          tempDht11.begin();
          delay(300);
          float t11 = tempDht11.readTemperature();
          float h11 = tempDht11.readHumidity();
          if (!isnan(t11) && !isnan(h11) && t11 > -40.0 && t11 < 80.0) {
            Serial.printf(">>> SUCCESS! DHT11 FOUND on GPIO %d! Temp: %.1fC, Hum: %.1f%% <<<\n", p, t11, h11);
            return;
          }
          Serial.println("No response.");
        }
      }
      Serial.println("[DHT Scan] Scan complete. No responding DHT found.");
    } else if (cmd.startsWith("wifi ")) {
      int spaceIdx = cmd.indexOf(' ', 5);
      if (spaceIdx > 5) {
        String ssid = cmd.substring(5, spaceIdx);
        String pass = cmd.substring(spaceIdx + 1);
        ssid.trim();
        pass.trim();
        Serial.printf("[CLI] Storing Wi-Fi credentials for SSID: %s\n", ssid.c_str());
        savedSsid = ssid;
        savedPass = pass;
        prefs.begin("ventra_wifi", false);
        prefs.putString("ssid", ssid);
        prefs.putString("pass", pass);
        prefs.end();
        Serial.println("[CLI] Reconnecting Wi-Fi...");
        WiFi.disconnect();
        WiFi.begin(ssid.c_str(), pass.c_str());
      } else {
        Serial.println("[CLI] Usage: wifi <SSID> <PASSWORD>");
      }
    } else if (cmd == "ble" || cmd == "ble_start") {
      startBleProvisioning();
    } else if (cmd == "ble_stop") {
      if (pBleServer) NimBLEDevice::getAdvertising()->stop();
      bleProvisioningActive = false;
      Serial.println("[BLE] Advertising stopped.");
    } else if (cmd == "status") {
      Serial.printf("[Status] Wi-Fi: %s (IP: %s), SSID: '%s'\n",
                    WiFi.status() == WL_CONNECTED ? "Connected" : "Disconnected",
                    WiFi.localIP().toString().c_str(), savedSsid.c_str());
      Serial.printf("[Status] MQTT: %s | BLE Active: %d\n",
                    mqttClient.connected() ? "Connected" : "Disconnected", bleProvisioningActive);
      Serial.printf("[Status] Sensors -> DHT22: %.1fC, %.1f%% RH | PIR: %d\n",
                    currentTemp, currentHum, (int)currentMotion);
    } else if (cmd == "connect") {
      prefs.begin("ventra_wifi", false);
      savedSsid = prefs.getString("ssid", "");
      savedPass = prefs.getString("pass", "");
      prefs.end();
      Serial.printf("[CLI] Connecting to saved SSID '%s' (pass len %d)...\n", savedSsid.c_str(), (int)savedPass.length());
      WiFi.disconnect(false);
      WiFi.begin(savedSsid.c_str(), savedPass.c_str());
    } else if (cmd == "scan" || cmd == "wifi_scan") {
      Serial.println("[CLI] Scanning Wi-Fi networks (2.4 GHz)...");
      WiFi.disconnect(false);
      delay(50);
      WiFi.mode(WIFI_STA);
      delay(50);
      int n = WiFi.scanNetworks(false, true);
      Serial.printf("[CLI] Scan complete. Found %d networks:\n", n);
      for (int i = 0; i < n; ++i) {
        Serial.printf("  [%02d] SSID: '%s' | RSSI: %d dBm | Ch: %d | Enc: %s\n",
                      i + 1, WiFi.SSID(i).c_str(), WiFi.RSSI(i), WiFi.channel(i),
                      WiFi.encryptionType(i) == WIFI_AUTH_OPEN ? "Open" : "Secured");
      }
      if (n > 0) WiFi.scanDelete();
    } else if (cmd.startsWith("send_hex ") || cmd.startsWith("send_raw ")) {
      String hexStr = cmd.substring(cmd.indexOf(' ') + 1);
      hexStr.trim();
      hexStr.replace(" ", "");
      hexStr.replace("0x", "");
      hexStr.replace(",", "");

      uint8_t rawBytes[64];
      int byteCount = 0;
      for (size_t i = 0; i + 1 < hexStr.length() && byteCount < 64; i += 2) {
        String bStr = hexStr.substring(i, i + 2);
        rawBytes[byteCount++] = (uint8_t)strtol(bStr.c_str(), NULL, 16);
      }

      if (byteCount == 27) {
        Serial.printf("[CLI] Emitting 27-byte Panasonic packet on GPIO 4...\n");
        IRsend irsend(IR_SEND_PIN);
        irsend.sendPanasonicAC(rawBytes, 27);
        Serial.println("[CLI] Packet sent!");
      } else {
        Serial.printf("[CLI] Error: Expected 27 bytes (54 hex characters), got %d bytes.\n", byteCount);
      }
    } else if (cmd == "clean") {
      panasonicClean();
    } else if (cmd == "display" || cmd == "display_toggle") {
      panasonicToggleDisplay();
    } else if (cmd == "powerful" || cmd == "powerful_toggle") {
      panasonicTogglePowerful();
    } else if (cmd.startsWith("capacity ")) {
      String cap = cmd.substring(9);
      panasonicSetCapacity(cap);
    } else if (cmd.startsWith("converti7 ")) {
      int step = cmd.substring(10).toInt();
      panasonicSetConverti7((uint8_t)step);
    } else if (cmd.startsWith("send_short ")) {
      int sp = cmd.indexOf(' ', 11);
      if (sp > 0) {
        uint8_t b13 = (uint8_t)strtol(cmd.substring(11, sp).c_str(), NULL, 16);
        uint8_t b14 = (uint8_t)strtol(cmd.substring(sp + 1).c_str(), NULL, 16);
        sendPanasonic16(b13, b14);
      } else {
        Serial.println("[CLI] Usage: send_short <hexByte13> <hexByte14>");
      }
    } else if (cmd == "reset_diff") {
      hasPrevSniffState = false;
      Serial.println("[CLI] Diff baseline reset. Next button press will be the new baseline.");
    } else if (cmd == "learn") {
      armRemoteLearning();
    } else {
      Serial.println("[CLI] Commands: wifi <ssid> <pass>, ble, ble_stop, status, test_ir, clean, display, converti7 <0-6>, send_short <b13> <b14>, send_hex <hex>, reset_diff");
    }
  }
}

// -------------------------------------------------------------
// Setup & Loop
// -------------------------------------------------------------
void setup() {
  Serial.begin(115200);
  delay(400);
  Serial.println("\n=== VENTRA UNIVERSAL SMART AC HUB 2.0 ===");

  setCpuFrequencyMhz(160); // Cool 160MHz operation

  pinMode(PIR_PIN, INPUT);
  attachInterrupt(digitalPinToInterrupt(PIR_PIN), pirMotionISR, CHANGE);
  dht.begin();

  // Initialize Universal IR Transmitter & Receiver
  irrecv.enableIRIn();
  Serial.printf("[Hardware] IR Receiver (GPIO %d) & Transmitter (GPIO %d) ready.\n", IR_RECV_PIN, IR_SEND_PIN);

  // Load configured brand from NVS
  prefs.begin("ventra_ac", false);
  activeProtocol = prefs.getString("protocol", "Panasonic");
  prefs.end();
  Serial.printf("[Config] Loaded active AC brand: %s\n", activeProtocol.c_str());

  // Wi-Fi Connection
  prefs.begin("ventra_wifi", false);
  savedSsid = prefs.getString("ssid", "");
  savedPass = prefs.getString("pass", "");
  prefs.end();

  if (savedSsid.length() > 0) {
    Serial.printf("[WiFi] Connecting to %s...\n", savedSsid.c_str());
    WiFi.begin(savedSsid.c_str(), savedPass.c_str());
    int attempts = 0;
    while (WiFi.status() != WL_CONNECTED && attempts < 10) {
      delay(250);
      attempts++;
    }
  }

  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("[WiFi] Connected! IP: %s\n", WiFi.localIP().toString().c_str());
  } else {
    Serial.println("[WiFi] No network connected. Starting BLE Provisioning mode...");
    WiFi.disconnect(true);
    startBleProvisioning();
  }

  mqttClient.setServer(MQTT_SERVER, MQTT_PORT);
  mqttClient.setCallback(onMqttMessage);
  mqttClient.setBufferSize(1024);
  mqttClient.setKeepAlive(60);
  mqttClient.setSocketTimeout(15);
}

void loop() {
  unsigned long now = millis();

  // 0. Handle Asynchronous BLE Wi-Fi Provisioning Connect
  if (pendingWifiConnect) {
    pendingWifiConnect = false;
    Serial.printf("[WiFi] Initiating connection to %s...\n", savedSsid.c_str());
    WiFi.disconnect();
    WiFi.begin(savedSsid.c_str(), savedPass.c_str());
    unsigned long t0 = millis();
    while (WiFi.status() != WL_CONNECTED && (millis() - t0 < 8000)) {
      delay(200);
    }
    if (WiFi.status() == WL_CONNECTED) {
      Serial.printf("[WiFi] Connected! IP: %s\n", WiFi.localIP().toString().c_str());
      if (pStatusChar) {
        String okMsg = "2:" + WiFi.localIP().toString();
        pStatusChar->setValue(okMsg.c_str());
        pStatusChar->notify();
      }
      delay(600);
      if (pBleServer) {
        NimBLEDevice::getAdvertising()->stop();
      }
      bleProvisioningActive = false;
    } else {
      Serial.println("[WiFi] Provisioning connect failed.");
      if (pStatusChar) {
        pStatusChar->setValue("3:Failed");
        pStatusChar->notify();
      }
    }
  }

  // 1. Maintain Network & Autonomous Wi-Fi Reconnect Loop
  if (WiFi.status() == WL_CONNECTED) {
    wifiBackoffMs = 5000;
    if (!mqttClient.connected()) {
      if (now - lastMqttRetry > 1000) {
        lastMqttRetry = now;
        connectMqtt();
      }
    } else {
      mqttClient.loop();
    }
  } else {
    // If not connected to Wi-Fi, ensure BLE provisioning is advertising!
    if (!bleProvisioningActive && !pendingWifiConnect) {
      startBleProvisioning();
    }
    if (!bleProvisioningActive && !pendingWifiConnect && savedSsid.length() > 0 && (now - lastWifiRetry > wifiBackoffMs)) {
      lastWifiRetry = now;
      Serial.printf("[WiFi] Reconnecting to %s (backoff %lums)...\n", savedSsid.c_str(), wifiBackoffMs);
      WiFi.disconnect();
      WiFi.begin(savedSsid.c_str(), savedPass.c_str());
      wifiBackoffMs = min(wifiBackoffMs * 2, 60000UL);
    }
  }

  // 1b. Asynchronously execute pending AC IR command outside MQTT callback
  if (hasPendingCommand) {
    hasPendingCommand = false;
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, pendingCommandJson);
    if (!err) {
      executeUniversalAcCommand(doc);
    }
  }

  // 2. Poll IR Receiver for Remote Auto-Discovery (GPIO 15)
  pollIrReceiver();

  // 3. Poll Climate Sensors (GPIO 26)
  if (now - lastSensorRead > SENSOR_READ_INTERVAL_MS) {
    lastSensorRead = now;
    pollSensors();
  }

  // 4. Send Cloud Telemetry (MQTT)
  if (now - lastTelemetrySend > TELEMETRY_SEND_INTERVAL_MS) {
    lastTelemetrySend = now;
    sendTelemetry();
  }

  // 5. USB Serial CLI for Diagnostics
  handleSerialCli();

  delay(10);
}
