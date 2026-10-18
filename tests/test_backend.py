import importlib.machinery
import importlib.util
import json
from datetime import date, timedelta
from pathlib import Path
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("backend", str(Path(__file__).resolve().parents[1] / "bin/llama-omarchy"))
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
            data = [{"id": 0, "is_processing": self.server.busy, "n_prompt_tokens": 42, "n_ctx": 1024,
                     "id_task": 7, "next_token": [{"n_decoded": 123}]}]
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


class UsageTests(unittest.TestCase):
    def sample(self, prompt=100, output=20, endpoint="http://localhost:8080"):
        return {"endpoint": endpoint, "online": True, "models": [
            {"id": "a", "state": "loaded", "metrics": {
                "prompt_tokens_total": prompt, "tokens_predicted_total": output}}]}

    def test_baseline_deltas_midnight_and_reset(self):
        state = {}
        first = backend.usage_history(self.sample(), state, date(2026, 10, 11))
        self.assertEqual(first["total"], 0)
        backend.usage_history(self.sample(130, 25), state, date(2026, 10, 11))
        same = backend.usage_history(self.sample(130, 25), state, date(2026, 10, 11))
        self.assertEqual(same["total"], 35)
        next_day = backend.usage_history(self.sample(140, 30), state, date(2026, 10, 12))
        self.assertEqual(next_day["today"], {"prompt": 10, "output": 5})
        reset = backend.usage_history(self.sample(2, 3), state, date(2026, 10, 12))
        self.assertEqual(reset["total"], 55)
        self.assertEqual(len(reset["days"]), 182)
        self.assertEqual(date.fromisoformat(reset["days"][0]["date"]).weekday(), 0)
        self.assertIsNone(reset["days"][0]["total"])
        self.assertTrue(reset["days"][-1]["future"])

    def test_missing_metrics_offline_and_endpoint_isolation(self):
        state = {}
        backend.usage_history(self.sample(), state)
        missing = backend.usage_history(self.sample(None, None), state)
        self.assertFalse(missing["observing"])
        offline = self.sample()
        offline.update(online=False, models=[])
        backend.usage_history(offline, state)
        self.assertEqual(backend.usage_history(self.sample(105, 23), state)["total"], 8)
        self.assertEqual(backend.usage_history(self.sample(200, 100, "http://localhost:9000"), state)["total"], 0)

    def test_unloaded_model_rebaselines_and_retains_history(self):
        state = {}
        backend.usage_history(self.sample(), state)
        backend.usage_history(self.sample(110, 25), state)
        unloaded = self.sample()
        unloaded["models"][0]["state"] = "unloaded"
        backend.usage_history(unloaded, state)
        self.assertEqual(backend.usage_history(self.sample(500, 100), state)["total"], 15)

    def test_persistence_and_corrupt_file_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            with patch.object(backend, "snapshot", side_effect=[self.sample(), self.sample(110, 25)]):
                backend.tracked_snapshot(directory=directory)
                self.assertEqual(backend.tracked_snapshot(directory=directory)["usage"]["total"], 15)
            path = directory / "usage.json"
            path.write_text("broken")
            with patch.object(backend, "snapshot", return_value=self.sample()):
                self.assertIn("unavailable", backend.tracked_snapshot(directory=directory)["usage"]["error"])
            self.assertEqual(path.read_text(), "broken")

    def test_auto_history_survives_restart_with_new_port(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            old_endpoint = "http://127.0.0.1:58167"
            new_endpoint = "http://127.0.0.1:59849"
            yesterday = date.today() - timedelta(days=1)
            # Existing on-disk format from before the fix / computer restart.
            state = {}
            backend.usage_history(self.sample(endpoint=old_endpoint), state, yesterday)
            backend.usage_history(self.sample(110, 25, old_endpoint), state, yesterday)
            path = directory / "usage.json"
            path.write_text(json.dumps(state))
            with patch.object(backend, "snapshot", return_value=self.sample(500, 100, new_endpoint)):
                usage = backend.tracked_snapshot(directory=directory)["usage"]
            self.assertEqual(usage["total"], 15)
            self.assertEqual(next(d for d in usage["days"] if d["date"] == yesterday.isoformat())["total"], 15)
            self.assertEqual(usage["today"], {"prompt": 0, "output": 0})
            with patch.object(backend, "snapshot", return_value=self.sample(505, 103, new_endpoint)):
                for _ in range(2):
                    usage = backend.tracked_snapshot(directory=directory)["usage"]
                    self.assertEqual(usage["total"], 23)
                    self.assertEqual(usage["today"], {"prompt": 5, "output": 3})
                explicit = backend.tracked_snapshot(endpoint=new_endpoint, directory=directory)
                self.assertEqual(explicit["usage"]["total"], 8)
            offline = {"endpoint": "http://127.0.0.1:8080", "online": False, "models": []}
            with patch.object(backend, "snapshot", return_value=offline):
                self.assertEqual(backend.tracked_snapshot(directory=directory)["usage"]["total"], 23)
            self.assertEqual(json.loads(path.read_text())[old_endpoint], state[old_endpoint])

    def test_auto_history_combines_same_day_and_filters_old_records(self):
        state = {}
        today = date(2026, 10, 18)
        for endpoint in ("http://localhost:8000", "http://localhost:9000"):
            backend.usage_history(self.sample(endpoint=endpoint), state, today)
            backend.usage_history(self.sample(110, 25, endpoint), state, today)
        state["http://localhost:8000"]["days"]["2025-01-01"] = {"prompt": 999, "output": 999}
        offline = {"endpoint": "http://localhost:8080", "online": False, "models": []}
        usage = backend.usage_history(offline, state, today, aggregate=True)
        self.assertEqual(usage["total"], 30)
        self.assertEqual(usage["today"], {"prompt": 20, "output": 10})
        self.assertEqual(len(usage["days"]), 182)
        self.assertIsNone(usage["days"][0]["total"])


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
        self.assertTrue(result["models"][0]["slots_available"])
        self.assertGreater(result["models"][0]["slots_sample_time"], 0)
        self.assertEqual(result["models"][0]["slots"][0]["decoded_tokens"], 123)
        self.assertEqual(result["models"][0]["slots"][0]["task_id"], 7)
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

    def test_slot_progress_missing_and_alternate_shapes(self):
        for value in (None, [], {}, [{"n_decoded": -1}], [{"n_decoded": "NaN"}]):
            self.assertIsNone(backend.decoded_tokens({"next_token": value}))
        self.assertEqual(backend.decoded_tokens({"next_token": {"n_decoded": 0}}), 0)
        self.assertEqual(backend.decoded_tokens({"next_token": [{"n_decoded": 42}]}), 42)

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
