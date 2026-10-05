import socket
import time
import json
import sys

def send_cmd(payload):
    s = socket.socket()
    s.settimeout(3)
    s.connect(('ventra.bhavyashah.me', 1883))
    cid = b'c7_runner'
    pkt = bytearray([0x10, 12 + len(cid), 0, 4, 77, 81, 84, 84, 4, 2, 0, 60, 0, len(cid)]) + cid
    s.sendall(pkt)
    s.recv(4)
    topic = 'ventra/cmd'
    tb = topic.encode()
    pb = json.dumps(payload).encode()
    rem = 2 + len(tb) + len(pb)
    pub_pkt = bytearray([0x30, rem, 0, len(tb)]) + bytearray(tb) + bytearray(pb)
    s.sendall(pub_pkt)
    s.close()

print("Starting 6-second paced converti7 sequence in 2 seconds...")
sys.stdout.flush()
time.sleep(2.0)

for step in range(1, 7):
    print(f"\n[PACED TEST] >>> FIRING STEP {step} <<<")
    sys.stdout.flush()
    send_cmd({"converti7": step})
    time.sleep(6.0)

print("\n[PACED TEST] >>> FIRING RESET TO NORMAL (Step 0) <<<")
sys.stdout.flush()
send_cmd({"converti7": 0})
print("\n[PACED TEST] Completed full 6-second cycle!")
sys.stdout.flush()
