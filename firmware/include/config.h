#pragma once
#include <Arduino.h>

// Hardware Pin Configuration (Matches original circuit schematic)
#define IR_SEND_PIN       4    // NPN Transistor Base -> 38kHz IR LED
#define IR_RECV_PIN       15   // TSOP1838 IR Receiver
#define PIR_PIN           27   // HC-SR501 PIR Motion Sensor
#define DHT_PIN           26   // DHT22 (AM2302) Temperature & Humidity
#define DHT_TYPE          DHT22

// MQTT & Cloud Server Configuration
#define MQTT_SERVER       "ventra.bhavyashah.me"
#define MQTT_PORT         1883
#define MQTT_CLIENT_ID    "Ventra_ESP32_Hub"

#define TOPIC_CMD         "ventra/cmd"
#define TOPIC_TELEMETRY   "ventra/telemetry"
#define TOPIC_STATUS      "ventra/status"
#define TOPIC_ACK         "ventra/ack"

// In-App BLE Wi-Fi Provisioning UUIDs (128-bit)
#define BLE_DEVICE_NAME        "Ventra-Hub"
#define SERVICE_UUID           "19b10000-e8f2-537e-4f6c-d104768a1214"
#define CHAR_UUID_SCAN         "19b10001-e8f2-537e-4f6c-d104768a1214"
#define CHAR_UUID_CONFIG       "19b10002-e8f2-537e-4f6c-d104768a1214"
#define CHAR_UUID_STATUS       "19b10003-e8f2-537e-4f6c-d104768a1214"

// Sensor Reading & Telemetry Intervals
#define SENSOR_READ_INTERVAL_MS   4000   // Read DHT22 every 4s (non-blocking)
#define TELEMETRY_SEND_INTERVAL_MS 10000 // Send MQTT telemetry every 10s
