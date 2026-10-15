"""Private local HTTP workload, exercising the image's Python/requests stack."""
import json
import os
from pathlib import Path
import signal
from http.server import BaseHTTPRequestHandler, HTTPServer

state_path = Path('/kubedoop/run/state.json')
state = json.loads(state_path.read_text()) if state_path.exists() else {'count': 0}
state['flushed'] = False
stopping = False


def terminate(signum, frame):
    global stopping
    stopping = True


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        state['count'] += 1
        body = json.dumps({'count': state['count']}).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)


signal.signal(signal.SIGTERM, terminate)
server = HTTPServer(('127.0.0.1', 18991), Handler)
server.timeout = 0.2
print('TEST_PYTHON_READY', flush=True)
while not stopping:
    server.handle_request()
server.server_close()
state['flushed'] = True
with state_path.open('w') as stream:
    json.dump(state, stream)
    stream.flush()
    os.fsync(stream.fileno())
print('TEST_PYTHON_FLUSHED', flush=True)
raise SystemExit(42)
