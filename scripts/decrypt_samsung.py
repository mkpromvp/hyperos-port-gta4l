import hashlib, requests, time, re, os, sys
from Crypto.Cipher import AES

AUTH_AES_KEY = bytes([0x42, 0x2e, 0x73, 0x73, 0x36, 0x17, 0xae, 0x2b, 0x19, 0x89, 0x40, 0xfd, 0x4e, 0x32, 0xb0, 0xa5])

FW_VER = os.environ.get("FW_VER", "")
if not FW_VER:
    print("ERROR: FW_VER not set")
    sys.exit(1)

MODEL = os.environ.get("MODEL", "SM-T505N")
REGION = os.environ.get("REGION", "EGY")

ENC_FILE = ""
for f in os.listdir("fw_samsung"):
    if f.endswith(".zip") or f.endswith(".enc4"):
        ENC_FILE = f"fw_samsung/{f}"
        break

if not ENC_FILE:
    for f in os.listdir("fw_samsung"):
        if os.path.isfile(f"fw_samsung/{f}"):
            ENC_FILE = f"fw_samsung/{f}"
            break

if not ENC_FILE:
    print("NO ENCRYPTED FILE FOUND")
    sys.exit(1)

print(f"[*] Found encrypted file: {ENC_FILE}")

fw_parts = FW_VER.split("/")
if len(fw_parts) == 3:
    fw_parts.append(fw_parts[0])
FW = "/".join(fw_parts)
print(f"[*] FW version: {FW}")

def generate_client_nonce():
    seed = int(time.time() * 1_000_000_000) & 0xFFFFFFFFFFFFFFFF
    chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    nonce = ""
    for _ in range(16):
        seed = (seed * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
        idx = (seed >> 32) % len(chars)
        nonce += chars[idx]
    return nonce

def compute_auth_headers(model):
    client_nonce = generate_client_nonce()
    auth_str = f"auth:{client_nonce}:00000001"
    auth_hash = hashlib.md5(auth_str.encode()).hexdigest()
    interface_str = f"interface:{model.upper()}"
    interface_hash = hashlib.md5(interface_str.encode()).hexdigest()
    final_str = f"{auth_hash}:FUS:{interface_hash}"
    final_sig = hashlib.md5(final_str.encode()).hexdigest()
    auth_val = f'FUS nonce="{client_nonce}", signature="{final_sig}", nc="00000001", type="auth", realm="interface"'
    return auth_val

def decrypt_nonce(inp):
    block = bytearray(b'0' * 16)
    b = inp.encode()
    l = min(len(b), 16)
    block[:l] = b[:l]
    cipher = AES.new(AUTH_AES_KEY, AES.MODE_ECB)
    return cipher.encrypt(bytes(block)).hex()

def get_logic_check(inp, nonce):
    out = ""
    for c in nonce:
        idx = ord(c) & 0xf
        if idx < len(inp):
            out += inp[idx]
        else:
            out += "."
    return out

sess = requests.Session()
sess.headers.update({"User-Agent": "SMART 2.0"})

print("[*] Authenticating with Samsung FUS (new API)...")
r = sess.post("https://neofussvr.sslcs.cdngc.net/NF_SmartDownloadGenerateNonce.do",
    headers={"Authorization": compute_auth_headers(MODEL)}, data="", timeout=30)
r.raise_for_status()

encnonce = r.headers.get("NONCE") or r.headers.get("nonce") or ""
if not encnonce:
    print("ERROR: No nonce in response")
    print(f"Response headers: {dict(r.headers)}")
    print(f"Response text: {r.text[:500]}")
    sys.exit(1)

auth = decrypt_nonce(encnonce)
auth_header = f'FUS nonce="{encnonce}", signature="{auth}", nc="", type="", realm="", newauth="1"'
print("[+] Auth obtained")

print("[*] Fetching binary info...")
logic_check = get_logic_check(FW, encnonce)
inform_xml = f"""<FUSMsg>
<FUSHdr><ProtoVer>1.0</ProtoVer><SessionID>0</SessionID><MsgID>1</MsgID></FUSHdr>
<FUSBody>
    <Put>
        <CmdID>1</CmdID>
        <ACCESS_MODE><Data>1</Data></ACCESS_MODE>
        <BINARY_NATURE><Data>1</Data></BINARY_NATURE>
        <REQUEST_TYPE><Data>2</Data></REQUEST_TYPE>
        <LOGIC_CHECK><Data>{logic_check}</Data></LOGIC_CHECK>
        <BINARY_SW_VERSION><Data>{FW}</Data></BINARY_SW_VERSION>
        <BINARY_LOCAL_CODE><Data>{REGION}</Data></BINARY_LOCAL_CODE>
        <BINARY_MODEL_NAME><Data>{MODEL}</Data></BINARY_MODEL_NAME>
    </Put>
    <Get>
        <CmdID>2</CmdID>
        <BINARY_SW_VERSION></BINARY_SW_VERSION>
    </Get>
</FUSBody>
</FUSMsg>"""

r = sess.post("https://neofussvr.sslcs.cdngc.net/NF_SmartDownloadBinaryInform.do",
    headers={"Authorization": auth_header}, data=inform_xml, timeout=30)
r.raise_for_status()

# Parse BINARY_SW_VERSION from response - this may differ from the request value
resp_fw = ""
for m in re.finditer(r'<BINARY_SW_VERSION[^>]*>(.*?)</BINARY_SW_VERSION>', r.text, re.DOTALL):
    val = m.group(1).strip()
    val = re.sub(r'<[^>]+>', '', val).strip()
    if val:
        resp_fw = val
        break
if resp_fw:
    print(f"[*] Response FW version: {resp_fw}")
    FW = resp_fw

print(f"[*] Response XML (first 2000 chars): {r.text[:2000]}")

logic_val = ""
for m in re.finditer(r'<LOGIC_VALUE_FACTORY[^>]*>(.*?)</LOGIC_VALUE_FACTORY>', r.text, re.DOTALL):
    logic_val = m.group(1).strip()
    break

if not logic_val:
    for m in re.finditer(r'<LOGIC_VALUE_HOME[^>]*>(.*?)</LOGIC_VALUE_HOME>', r.text, re.DOTALL):
        logic_val = m.group(1).strip()
        break

if not logic_val:
    for m in re.finditer(r'<LOGIC_VALUE[^>]*>(.*?)</LOGIC_VALUE>', r.text, re.DOTALL):
        logic_val = m.group(1).strip()
        break

print(f"[+] Raw LOGIC_VALUE: {logic_val}")
if not logic_val:
    print(f"ERROR: No LOGIC_VALUE found in response")
    print(f"Response text: {r.text[:2000]}")
    sys.exit(1)

# Strip XML tags from LOGIC_VALUE (e.g. <Data>value</Data>)
logic_val = re.sub(r'<[^>]+>', '', logic_val).strip()
print(f"[+] Clean LOGIC_VALUE: {logic_val}")

key_str = get_logic_check(FW, logic_val)
key = hashlib.md5(key_str.encode()).digest()
print(f"[+] Decryption key: {key.hex()}")

file_size = os.path.getsize(ENC_FILE)
print(f"[*] Decrypting {ENC_FILE} ({file_size} bytes)...")

cipher = AES.new(key, AES.MODE_ECB)
out_path = "fw_samsung/samsung_ap.tar.md5"

with open(ENC_FILE, "rb") as f_in, open(out_path, "wb") as f_out:
    remaining = file_size
    while remaining > 0:
        chunk_size = 4096
        if remaining < chunk_size:
            chunk_size = remaining
        chunk = f_in.read(chunk_size)
        if not chunk:
            break
        dec = cipher.decrypt(chunk)
        if remaining <= chunk_size and chunk_size < 4096:
            pad_len = dec[-1]
            dec = dec[:-pad_len]
        f_out.write(dec)
        remaining -= chunk_size

print(f"[+] Decrypted to {out_path}")
print(f"    Size: {os.path.getsize(out_path)} bytes")
