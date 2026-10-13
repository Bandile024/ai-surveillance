import http.client
import json
import unittest

from local_engine_api import LocalEngineBridge, LocalEngineServer


class LocalEngineApiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.bridge = LocalEngineBridge()
        self.server = LocalEngineServer(self.bridge, port=0)
        self.server.start()

    def tearDown(self) -> None:
        self.server.shutdown()

    def _request(self, method: str, path: str, body: bytes = b""):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.port)
        connection.request(
            method,
            path,
            body=body,
            headers={"Content-Type": "application/json"},
        )
        response = connection.getresponse()
        result = response.status, response.read()
        connection.close()
        return result

    def test_status_returns_latest_engine_state_with_localhost_cors(self) -> None:
        self.bridge.publish(
            b"jpeg-frame",
            mode="GUARD",
            person_count=2,
            avg_confidence=0.88,
            max_confidence=0.92,
            fps=18.2,
            last_detection_at="2026-10-11T17:00:00Z",
            last_frame_at="2026-10-11T17:00:01Z",
            peak_count=2,
            occupancy_ratio=0.5,
        )
        connection = http.client.HTTPConnection("127.0.0.1", self.server.port)
        connection.request(
            "GET",
            "/api/status",
            headers={"Origin": "http://localhost:53211"},
        )
        response = connection.getresponse()
        payload = json.loads(response.read())
        connection.close()

        self.assertEqual(response.status, 200)
        self.assertEqual(
            response.getheader("Access-Control-Allow-Origin"),
            "http://localhost:53211",
        )
        self.assertEqual(payload["mode"], "GUARD")
        self.assertEqual(payload["person_count"], 2)
        self.assertEqual(payload["max_confidence"], 0.92)

    def test_mode_request_accepts_only_supported_modes(self) -> None:
        status, response = self._request(
            "POST",
            "/api/mode",
            json.dumps({"mode": "guard"}).encode(),
        )

        self.assertEqual(status, 202)
        self.assertEqual(json.loads(response), {"requested_mode": "GUARD"})
        self.assertEqual(self.bridge.take_mode_request(), "GUARD")

        status, _ = self._request(
            "POST",
            "/api/mode",
            json.dumps({"mode": "ARMED"}).encode(),
        )
        self.assertEqual(status, 400)

    def test_local_shutdown_request_is_accepted(self) -> None:
        status, response = self._request("POST", "/api/shutdown")

        self.assertEqual(status, 202)
        self.assertEqual(json.loads(response), {"status": "shutdown_requested"})
        self.assertTrue(self.bridge.take_shutdown_request())
        self.assertFalse(self.bridge.take_shutdown_request())

    def test_non_local_browser_origin_is_rejected(self) -> None:
        connection = http.client.HTTPConnection("127.0.0.1", self.server.port)
        connection.request(
            "GET",
            "/api/status",
            headers={"Origin": "https://untrusted.example"},
        )
        response = connection.getresponse()
        response.read()
        connection.close()

        self.assertEqual(response.status, 403)

    def test_stream_returns_latest_frame_as_mjpeg(self) -> None:
        self.bridge.publish(
            b"test-jpeg",
            mode="SAFE",
            person_count=0,
            avg_confidence=0.0,
            max_confidence=0.0,
            fps=10.0,
            last_detection_at=None,
            last_frame_at="2026-10-11T17:00:01Z",
            peak_count=0,
            occupancy_ratio=0.0,
        )
        connection = http.client.HTTPConnection("127.0.0.1", self.server.port)
        connection.request("GET", "/stream.mjpg")
        response = connection.getresponse()
        body = response.read1(128)
        connection.close()

        self.assertEqual(response.status, 200)
        self.assertTrue(
            response.getheader("Content-Type").startswith(
                "multipart/x-mixed-replace"
            )
        )
        self.assertIn(b"Content-Type: image/jpeg", body)
        self.assertIn(b"test-jpeg", body)

    def test_api_refuses_to_bind_to_a_network_interface(self) -> None:
        with self.assertRaises(ValueError):
            LocalEngineServer(self.bridge, host="0.0.0.0", port=8765)


if __name__ == "__main__":
    unittest.main()
