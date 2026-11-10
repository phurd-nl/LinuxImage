import importlib.util, json, os, socket, tempfile, threading
from pathlib import Path

spec = importlib.util.spec_from_file_location("chk", Path(__file__).resolve().parent.parent / "imaging" / "check-tpm-encryption.py")
chk = importlib.util.module_from_spec(spec); spec.loader.exec_module(chk)

owned = {"result": {"storage-encryption": {"support": "unavailable", "storage-safety": "prefer-encrypted",
         "unavailable-reason": "error with TPM2 device: one or more of the TPM hierarchies is already owned"}}}
ok, why = chk.verdict(owned)
assert not ok and "already owned" in why
assert chk.verdict({"result": {"storage-encryption": {"support": "available"}}}) == (True, "available")

# a fake snapd on a unix socket, answering like the real one
path = os.path.join(tempfile.mkdtemp(), "snapd.socket")
srv = socket.socket(socket.AF_UNIX); srv.bind(path); srv.listen(1)
def serve():
    conn, _ = srv.accept(); conn.recv(4096)
    body = json.dumps(owned).encode()
    conn.sendall(b"HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n" + body); conn.close()
threading.Thread(target=serve, daemon=True).start()
got = chk.snapd_get("/v2/systems/enhanced-secureboot-desktop", path)
assert got["result"]["storage-encryption"]["support"] == "unavailable"
print("ok")
