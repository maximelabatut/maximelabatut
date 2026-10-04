#!/usr/bin/env python3
"""Contrôle minimal de Dozzle « à la demande ».

Démarre et arrête UNIQUEMENT les deux conteneurs de MANAGED (Dozzle et son tunnel), via l'API Docker (socket Unix).
Aucune valeur des requêtes n'entre dans un chemin d'API : les noms sont des constantes. Rien d'autre n'est possible.

  GET  /state   état des deux conteneurs et temps restant avant l'arrêt automatique
  POST /on      démarre Dozzle puis son tunnel
  POST /off     arrête le tunnel puis Dozzle

Garde-fous :
  - les POST exigent l'en-tête « X-Logs-Control: 1 » (un site tiers ne peut pas l'ajouter sans autorisation CORS, que ce
    service ne donne jamais : protection contre les requêtes forgées depuis un navigateur) ;
  - aucun corps de requête n'est interprété ; une seule action d'écriture toutes les 2 secondes ;
  - arrêt AUTOMATIQUE : Dozzle est arrêté LOGS_MAX_MINUTES (120 par défaut) après son démarrage, quel que soit
    le moyen de démarrage (bouton ou ligne de commande). L'heure de démarrage vient de Docker : rien à mémoriser,
    ce service peut être redémarré sans perdre l'échéance.
Le service est joint par le nginx du dashboard (donc derrière Cloudflare Access depuis Internet) ; il n'écoute que sur
127.0.0.1 de la machine hôte.
"""
import calendar
import http.client
import http.server
import json
import os
import socket
import sys
import threading
import time

SOCKET = os.environ.get("DOCKER_SOCKET", "/var/run/docker.sock")
MANAGED = ("dozzle", "cloudflared-logs")        # ordre de démarrage : l'application, puis son tunnel
MAX_MINUTES = int(os.environ.get("LOGS_MAX_MINUTES", "120"))
HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
PORT = int(os.environ.get("LISTEN_PORT", "8090"))
CHECK_SECONDS = float(os.environ.get("AUTO_OFF_CHECK_SECONDS", "30"))
CSRF_HEADER = "X-Logs-Control"
MIN_INTERVAL = 2.0

_lock = threading.Lock()
_last_write = 0.0


class DockerError(Exception):
    pass


class _UnixConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout=20):
        http.client.HTTPConnection.__init__(self, "localhost", timeout=timeout)
        self._path = path

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self._path)
        self.sock = s


def _docker(method, path):
    conn = _UnixConnection(SOCKET)
    try:
        conn.request(method, path, headers={"Host": "docker"})
        resp = conn.getresponse()
        return resp.status, resp.read()
    except (OSError, http.client.HTTPException) as exc:
        raise DockerError("API Docker injoignable") from exc
    finally:
        conn.close()


def _epoch(ts):
    """'2026-10-04T19:05:50.123456789Z' -> secondes epoch (UTC)."""
    return calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))


def inspect(name):
    status, body = _docker("GET", "/containers/%s/json" % name)
    if status == 404:
        return {"status": "missing"}
    if status != 200:
        raise DockerError("réponse Docker inattendue (%d)" % status)
    st = json.loads(body.decode("utf-8")).get("State", {})
    return {"status": st.get("Status", "unknown"), "started_at": st.get("StartedAt")}


def state():
    items = {n: inspect(n) for n in MANAGED}
    running = [n for n, i in items.items() if i["status"] == "running"]
    remaining = None
    first = items[MANAGED[0]]
    if first["status"] == "running" and first.get("started_at"):
        remaining = max(0, int(_epoch(first["started_at"]) + MAX_MINUTES * 60 - time.time()))
    return {
        "up": len(running) == len(MANAGED),
        "partial": 0 < len(running) < len(MANAGED),
        "missing": any(i["status"] == "missing" for i in items.values()),
        "services": {n: i["status"] for n, i in items.items()},
        "remaining_s": remaining,
        "max_minutes": MAX_MINUTES,
    }


def _act(verb, names, query=""):
    for n in names:
        status, _ = _docker("POST", "/containers/%s/%s%s" % (n, verb, query))
        if status not in (204, 304):          # 304 : déjà dans l'état demandé
            raise DockerError("%s %s : réponse Docker %d" % (verb, n, status))


def start_all():
    _act("start", MANAGED)


def stop_all():
    _act("stop", tuple(reversed(MANAGED)), "?t=10")


def auto_off_loop():
    while True:
        time.sleep(CHECK_SECONDS)
        try:
            s = state()
            if s["remaining_s"] == 0:
                sys.stderr.write("arrêt automatique après %d min\n" % MAX_MINUTES)
                stop_all()
        except Exception as exc:                # la boucle ne doit jamais s'arrêter
            sys.stderr.write("auto-off : %s\n" % exc)


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "logs-control"
    sys_version = ""
    timeout = 10

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.command, self.path))

    def _send(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/state":
            return self._send(404, {"error": "introuvable"})
        try:
            self._send(200, state())
        except DockerError as exc:
            self._send(502, {"error": str(exc)})

    def do_POST(self):
        global _last_write
        if self.path not in ("/on", "/off"):
            return self._send(404, {"error": "introuvable"})
        if self.headers.get(CSRF_HEADER) != "1":
            return self._send(403, {"error": "en-tête de contrôle manquant"})
        with _lock:
            now = time.time()
            if now - _last_write < MIN_INTERVAL:
                return self._send(429, {"error": "trop rapide, réessayer dans un instant"})
            _last_write = now
            try:
                current = state()
                if current["missing"]:
                    return self._send(409, {"error": "conteneurs absents", "state": current})
                (start_all if self.path == "/on" else stop_all)()
                self._send(200, state())
            except DockerError as exc:
                self._send(502, {"error": str(exc)})

    def _refuse(self):
        self._send(405, {"error": "méthode non autorisée"})

    do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = _refuse


def main():
    threading.Thread(target=auto_off_loop, daemon=True).start()
    srv = http.server.ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True
    sys.stderr.write("logs-control prêt sur %s:%d (arrêt auto : %d min)\n" % (HOST, PORT, MAX_MINUTES))
    srv.serve_forever()


if __name__ == "__main__":
    main()
