#!/usr/bin/env python3
"""Tests du contrôle de Dozzle, avec un FAUX démon Docker (socket Unix temporaire) : aucun vrai conteneur n'est touché.

    python3 dashboard/logs-control/test_control.py
"""
import http.server
import json
import os
import socketserver
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
TMP = tempfile.mkdtemp(prefix="logsctl-")
SOCK = os.path.join(TMP, "docker.sock")
os.environ.update({"DOCKER_SOCKET": SOCK, "LOGS_MAX_MINUTES": "120", "AUTO_OFF_CHECK_SECONDS": "0.2"})
import control  # noqa: E402

CALLS = []                      # (méthode, chemin) reçus par le faux démon
CONTAINERS = {}                 # nom -> {"status": ..., "started": epoch}


def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ts)) + ".123456789Z"


class FakeDocker(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _reply(self, code, body=b""):
        try:
            self.send_response(code)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if body:
                self.wfile.write(body)
        except BrokenPipeError:      # le client a déjà lu la réponse et fermé : sans importance pour le test
            pass

    def address_string(self):
        return "unix"

    def do_GET(self):
        CALLS.append(("GET", self.path))
        parts = self.path.strip("/").split("/")
        if len(parts) == 3 and parts[0] == "containers" and parts[2] == "json" and parts[1] in CONTAINERS:
            c = CONTAINERS[parts[1]]
            st = {"Status": c["status"], "StartedAt": iso(c["started"])}
            return self._reply(200, json.dumps({"State": st}).encode())
        self._reply(404, b'{"message":"No such container"}')

    def do_POST(self):
        CALLS.append(("POST", self.path))
        path, _, q = self.path.partition("?")
        parts = path.strip("/").split("/")
        if len(parts) == 3 and parts[0] == "containers" and parts[1] in CONTAINERS and parts[2] in ("start", "stop"):
            c = CONTAINERS[parts[1]]
            want = "running" if parts[2] == "start" else "exited"
            if c["status"] == want:
                return self._reply(304)
            c["status"] = want
            if want == "running":
                c["started"] = time.time()
            return self._reply(204)
        self._reply(404, b'{"message":"No such container"}')


class UnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def http_req(base, method, path, headers=None, data=None):
    req = urllib.request.Request(base + path, method=method, headers=headers or {}, data=data)
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        return e.code, (json.loads(raw) if raw.startswith("{") else raw)


class Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fake = UnixServer(SOCK, FakeDocker)
        threading.Thread(target=cls.fake.serve_forever, daemon=True).start()
        cls.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), control.Handler)
        cls.srv.daemon_threads = True
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.base = "http://127.0.0.1:%d" % cls.srv.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.fake.shutdown()

    def setUp(self):
        control.MIN_INTERVAL = 0.0
        control._last_write = 0.0
        CALLS.clear()
        CONTAINERS.clear()
        CONTAINERS["dozzle"] = {"status": "exited", "started": 0}
        CONTAINERS["cloudflared-logs"] = {"status": "exited", "started": 0}

    H = {"X-Logs-Control": "1"}

    def posts(self):
        return [c[1] for c in CALLS if c[0] == "POST"]

    def test_state_arrete(self):
        code, s = http_req(self.base, "GET", "/state")
        self.assertEqual(code, 200)
        self.assertFalse(s["up"])
        self.assertFalse(s["partial"])
        self.assertFalse(s["missing"])
        self.assertIsNone(s["remaining_s"])
        self.assertEqual(s["services"], {"dozzle": "exited", "cloudflared-logs": "exited"})

    def test_post_sans_en_tete_refuse_et_sans_effet(self):
        code, _ = http_req(self.base, "POST", "/on")
        self.assertEqual(code, 403)
        self.assertEqual(self.posts(), [])
        self.assertEqual(CONTAINERS["dozzle"]["status"], "exited")

    def test_en_tete_incorrect_refuse(self):
        for v in ("0", "true", ""):
            code, _ = http_req(self.base, "POST", "/on", {"X-Logs-Control": v})
            self.assertEqual(code, 403, v)
        self.assertEqual(self.posts(), [])

    def test_on_demarre_dans_l_ordre(self):
        code, s = http_req(self.base, "POST", "/on", self.H)
        self.assertEqual(code, 200)
        self.assertTrue(s["up"])
        self.assertEqual(self.posts(), ["/containers/dozzle/start", "/containers/cloudflared-logs/start"])
        self.assertTrue(7100 <= s["remaining_s"] <= 7200)       # 120 min

    def test_off_arrete_dans_l_ordre_inverse(self):
        http_req(self.base, "POST", "/on", self.H)
        CALLS.clear()
        code, s = http_req(self.base, "POST", "/off", self.H)
        self.assertEqual(code, 200)
        self.assertFalse(s["up"])
        self.assertEqual(self.posts(), ["/containers/cloudflared-logs/stop?t=10", "/containers/dozzle/stop?t=10"])

    def test_idempotent(self):
        http_req(self.base, "POST", "/on", self.H)
        code, s = http_req(self.base, "POST", "/on", self.H)      # déjà démarré : 304 côté Docker
        self.assertEqual(code, 200)
        self.assertTrue(s["up"])

    def test_limitation_de_debit(self):
        control.MIN_INTERVAL = 5.0
        control._last_write = 0.0
        self.assertEqual(http_req(self.base, "POST", "/on", self.H)[0], 200)
        self.assertEqual(http_req(self.base, "POST", "/off", self.H)[0], 429)
        self.assertEqual(CONTAINERS["dozzle"]["status"], "running")      # le second appel n'a rien fait

    def test_conteneurs_absents(self):
        del CONTAINERS["dozzle"]
        code, s = http_req(self.base, "POST", "/on", self.H)
        self.assertEqual(code, 409)
        self.assertEqual(self.posts(), [])
        self.assertTrue(s["state"]["missing"])

    def test_chemins_et_methodes_stricts(self):
        for method, path in (("GET", "/on"), ("GET", "/"), ("GET", "/state/../x"), ("GET", "/containers/dozzle/json"),
                             ("POST", "/on?x=../../containers/evil/start"), ("POST", "/ON"), ("POST", "/state")):
            code, _ = http_req(self.base, method, path, self.H)
            self.assertEqual(code, 404, method + " " + path)
        for method in ("PUT", "DELETE", "PATCH"):
            self.assertEqual(http_req(self.base, method, "/off", self.H)[0], 405, method)
        self.assertEqual(self.posts(), [])

    def test_corps_ignore(self):
        code, _ = http_req(self.base, "POST", "/on", dict(self.H, **{"Content-Type": "application/json"}),
                           data=b'{"container":"evil"}' * 1000)
        self.assertEqual(code, 200)
        self.assertEqual(self.posts(), ["/containers/dozzle/start", "/containers/cloudflared-logs/start"])

    def test_seuls_les_deux_conteneurs_sont_appeles(self):
        for path in ("/on", "/off", "/on"):
            http_req(self.base, "POST", path, self.H)
            http_req(self.base, "GET", "/state")
        for method, path in CALLS:
            name = path.split("/")[2]
            self.assertIn(name, ("dozzle", "cloudflared-logs"), path)
            self.assertIn(path.split("?")[0].split("/")[3], ("json", "start", "stop"), path)

    def test_arret_automatique(self):
        CONTAINERS["dozzle"].update(status="running", started=time.time() - 3 * 3600)
        CONTAINERS["cloudflared-logs"].update(status="running", started=time.time() - 3 * 3600)
        control.CHECK_SECONDS = 0.2
        t = threading.Thread(target=control.auto_off_loop, daemon=True)
        t.start()
        deadline = time.time() + 5
        while time.time() < deadline and CONTAINERS["dozzle"]["status"] != "exited":
            time.sleep(0.1)
        self.assertEqual(CONTAINERS["dozzle"]["status"], "exited")
        self.assertEqual(CONTAINERS["cloudflared-logs"]["status"], "exited")

    def test_pas_d_arret_avant_l_echeance(self):
        CONTAINERS["dozzle"].update(status="running", started=time.time() - 3600)      # 1 h < 2 h
        CONTAINERS["cloudflared-logs"].update(status="running", started=time.time() - 3600)
        s = control.state()
        self.assertTrue(3500 <= s["remaining_s"] <= 3700)

    def test_docker_injoignable(self):
        saved = control.SOCKET
        control.SOCKET = os.path.join(TMP, "absent.sock")
        try:
            code, s = http_req(self.base, "GET", "/state")
            self.assertEqual(code, 502)
            self.assertNotIn(TMP, json.dumps(s))                 # pas de fuite de chemin interne
        finally:
            control.SOCKET = saved

    def test_en_tetes_de_reponse(self):
        req = urllib.request.Request(self.base + "/state")
        with urllib.request.urlopen(req, timeout=5) as r:
            self.assertEqual(r.headers["Cache-Control"], "no-store")
            self.assertEqual(r.headers["X-Content-Type-Options"], "nosniff")
            self.assertIsNone(r.headers.get("Access-Control-Allow-Origin"))     # jamais de CORS
            self.assertNotIn("Python", r.headers.get("Server", ""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
