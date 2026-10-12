import importlib.machinery
import importlib.util
import json
from pathlib import Path
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("backend", str(Path(__file__).resolve().parents[1] / "bin/llama-local"))
spec = importlib.util.spec_from_loader(loader.name, loader)
backend = importlib.util.module_from_spec(spec)
loader.exec_module(backend)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.requests.append(("GET", self.path, None))
        if self.path == "/props":
            data = {"role": "router" if self.server.router else "server"}
        elif self.path in ("/models", "/v1/models"):
            data = {"data": [{"id": "a", "status": {"value": "loaded"}},
                             {"id": "b / test", "status": {"value": "unloaded"}}]}
        elif self.path.startswith("/slots"):
            data = [{"id": 0, "is_processing": self.server.busy, "n_prompt_tokens": 42, "n_ctx": 1024}]
        elif self.path.startswith("/metrics"):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"llamacpp:prompt_tokens_total 42\nllamacpp:tokens_predicted_total 8\nllamacpp:predicted_tokens_seconds 12.5\n")
            return
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests.append(("POST", self.path, payload))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"success":true}')


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.requests = []
        self.server.busy = False
        self.server.router = True
        self.endpoint = "http://127.0.0.1:" + str(self.server.server_port)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def test_status_never_autoloads_or_posts(self):
        with patch.object(backend, "hardware", return_value=[]), patch.object(backend, "processes", return_value=[]):
            result = backend.snapshot(self.endpoint)
        self.assertTrue(result["online"])
        self.assertEqual(result["models"][0]["metrics"]["tokens_predicted_total"], 8)
        self.assertNotIn("metrics", result["models"][1])
        for method, path, _ in self.server.requests:
            self.assertEqual(method, "GET")
            if path.startswith(("/slots", "/metrics")):
                self.assertIn("autoload=false", path)
                self.assertIn("model=a", path)

    def test_switch_uses_router_load_and_preserves_exact_id(self):
        result = backend.control(self.endpoint, "switch", "b / test")
        self.assertTrue(result["success"])
        self.assertEqual(self.server.requests[-1], ("POST", "/models/load", {"model": "b / test"}))
        self.assertFalse(any(path == "/models/unload" for _, path, _ in self.server.requests))

    def test_busy_blocks_mutation(self):
        self.server.busy = True
        with self.assertRaisesRegex(backend.BackendError, "generating"):
            backend.control(self.endpoint, "switch", "b / test")
        self.assertTrue(all(method == "GET" for method, _, _ in self.server.requests))

    def test_single_model_blocks_switch(self):
        self.server.router = False
        with self.assertRaisesRegex(backend.BackendError, "router mode"):
            backend.control(self.endpoint, "switch", "b / test")

    def test_unknown_model_blocks_mutation(self):
        with self.assertRaisesRegex(backend.BackendError, "catalog"):
            backend.control(self.endpoint, "switch", "not-found")
        self.assertTrue(all(method == "GET" for method, _, _ in self.server.requests))

    def test_unload(self):
        backend.control(self.endpoint, "unload", "a")
        self.assertEqual(self.server.requests[-1], ("POST", "/models/unload", {"model": "a"}))

    def test_metrics_labeled_and_nonfinite(self):
        result = backend.parse_metrics('# comment\nllamacpp:prompt_tokens_total{slot="0"} 12\nllamacpp:prompt_tokens_total{slot="1"} 2\nllamacpp:bad NaN\nllamacpp:bad2 +Inf\nllamacpp:invalid wat\n')
        self.assertEqual(result, {"prompt_tokens_total": 14})

    def test_discovery_prefers_router(self):
        procs = [{"pid": 1, "ppid": 0, "router": False, "port": "9999", "host": "127.0.0.1"},
                 {"pid": 2, "ppid": 0, "router": True, "port": "8081", "host": "0.0.0.0"}]
        self.assertEqual(backend.discover("auto", procs), "http://127.0.0.1:8081")

    def test_endpoint_restrictions(self):
        for url in ("http://example.com", "file:///etc/passwd", "http://localhost@evil.com", "http://localhost/a", "http://localhost:bad"):
            with self.assertRaises(backend.BackendError):
                backend.validate_endpoint(url)
        self.assertEqual(backend.validate_endpoint("http://[::1]:8080/"), "http://[::1]:8080")

    def test_offline_keeps_hardware_and_error(self):
        with patch.object(backend.Client, "request", side_effect=backend.BackendError("offline")), patch.object(backend, "hardware", return_value=[{"name": "GPU"}]):
            result = backend.snapshot(self.endpoint)
        self.assertFalse(result["online"])
        self.assertEqual(result["error"], "offline")
        self.assertEqual(result["gpus"], [{"name": "GPU"}])


if __name__ == "__main__":
    unittest.main()
