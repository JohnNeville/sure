import http.server
import json
import os
import tempfile
import threading
import unittest

import spike

ORDERS = [
    {"order_number": "111-1", "order_placed_date": "2026-09-01", "grand_total": 25.0, "gift_card": None,
     "estimated_tax": 1.0, "recipient": {"name": "SECRET NAME", "address": "SECRET ADDRESS"},
     "items": [{"title": "Dog food 30lb", "asin": "A1", "quantity": 1, "price": 24.0}], "shipments": []},
    {"order_number": "222-2", "order_placed_date": "2026-09-02", "grand_total": 40.0, "gift_card": 5.0,
     "items": [], "shipments": [{"items": [{"title": "USB cable", "asin": "B1", "quantity": 2, "price": 8.0}]}]},
]
CHARGES = [
    {"completed_date": "2026-09-02", "grand_total": -25.0, "payment_method_last_4": "1234", "order_number": "111-1"},
    {"completed_date": "2026-09-03", "grand_total": -40.0, "payment_method_last_4": "1234", "order_number": "222-2"},
    {"completed_date": "2026-09-04", "grand_total": -9.99, "payment_method_last_4": "9999", "order_number": "333-3"},
    {"completed_date": "2026-09-05", "grand_total": 12.5, "is_refund": True, "payment_method_last_4": "1234",
     "order_number": "111-1"},
]
SURE = [
    {"id": "t1", "date": "2026-09-03", "amount_cents": 2500, "classification": "expense",
     "name": "AMZN Mktp US*1A2B3", "account": {"name": "Visa"}},
    {"id": "t2", "date": "2026-09-04", "amount_cents": 4000, "classification": "expense",
     "name": "AMAZON.COM*X", "account": {"name": "Visa"}},
    {"id": "t3", "date": "2026-09-05", "amount_cents": 4000, "classification": "expense",
     "name": "AMZN Mktp US*SECOND", "account": {"name": "Visa"}},
    {"id": "t4", "date": "2026-09-05", "amount_cents": 1250, "classification": "income",
     "name": "AMAZON REFUND", "account": {"name": "Visa"}},
    {"id": "t5", "date": "2026-09-04", "amount_cents": 1099, "classification": "expense",
     "name": "Corner Store", "account": {"name": "Debit"}},
    {"id": "t6", "date": "2026-08-01", "amount_cents": 1199, "classification": "expense",
     "name": "Prime Video", "account": {"name": "Visa"}},
]


class SpikeTest(unittest.TestCase):
    def setUp(self):
        self.charges = spike.amazon_charges(CHARGES)

    def test_cents_rounding_and_sign(self):
        self.assertEqual(spike.to_cents(-9.99), 999)
        self.assertEqual(spike.to_cents(0.285), 29)

    def test_refunds_are_flagged_and_use_income(self):
        refund = [c for c in self.charges if c["refund"]][0]
        result = spike.classify(refund, SURE, 4)
        self.assertEqual(result["status"], "unique")
        self.assertEqual(result["candidates"][0]["txn"]["id"], "t4")

    def test_unique_ambiguous_unmatched(self):
        by_cents = {c["cents"]: spike.classify(c, SURE, 4) for c in self.charges if not c["refund"]}
        self.assertEqual(by_cents[2500]["status"], "unique")
        self.assertEqual(by_cents[4000]["status"], "ambiguous")
        self.assertEqual(by_cents[4000]["resolvable_by"], "date")  # charge on 09-03: t2 is closer than t3
        self.assertEqual(by_cents[999]["status"], "unmatched")

    def test_window_limits_candidates(self):
        charge = [c for c in self.charges if c["cents"] == 4000][0]
        self.assertEqual(len(spike.candidates_for(charge, SURE, 0)), 0)
        self.assertEqual(len(spike.candidates_for(charge, SURE, 1)), 1)
        self.assertEqual(len(spike.candidates_for(charge, SURE, 4)), 2)

    def test_near_miss_finds_off_by_a_dime(self):
        charge = [c for c in self.charges if c["cents"] == 999][0]
        near = spike.near_misses(charge, SURE, 4)
        self.assertEqual(near[0][2]["id"], "t5")

    def test_order_items_fall_back_to_shipments(self):
        orders = spike.index_orders(ORDERS)
        self.assertEqual(spike.order_items(orders["222-2"])[0]["title"], "USB cable")

    def test_report_never_contains_recipient_details(self):
        report, results = spike.build_report(self.charges, spike.index_orders(ORDERS), SURE, 4)
        self.assertNotIn("SECRET", report)
        self.assertIn("Exactly one Sure candidate", report)
        self.assertIn("1234", report)
        self.assertIn("Amazon-looking Sure transactions with no Amazon payment (1)", report)

    def test_items_csv(self):
        _, results = spike.build_report(self.charges, spike.index_orders(ORDERS), SURE, 4)
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "items.csv")
            spike.write_items_csv(path, results, spike.index_orders(ORDERS))
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
        self.assertIn("Dog food 30lb", text)
        self.assertNotIn("SECRET", text)


class FakeSure(http.server.BaseHTTPRequestHandler):
    seen_keys = []

    def do_GET(self):
        FakeSure.seen_keys.append(self.headers.get("X-Api-Key"))
        page = int(self.path.split("page=")[1].split("&")[0])
        rows = SURE[:3] if page == 1 else SURE[3:]
        body = json.dumps({"transactions": rows, "pagination": {"page": page, "total_pages": 2}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class ClientTest(unittest.TestCase):
    def test_pages_and_sends_the_api_key(self):
        server = http.server.HTTPServer(("127.0.0.1", 0), FakeSure)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            client = spike.SureClient(f"http://127.0.0.1:{server.server_port}", "secret-key")
            rows = client.transactions(spike.parse_date("2026-09-01"), spike.parse_date("2026-09-30"))
        finally:
            server.shutdown()
            server.server_close()
        self.assertEqual(len(rows), len(SURE))
        self.assertEqual(set(FakeSure.seen_keys), {"secret-key"})


class FakeEverything(http.server.BaseHTTPRequestHandler):
    """Stands in for both Sure (categories, transactions) and an OpenAI-compatible endpoint."""
    llm_requests = []

    def _send(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/api/v1/categories"):
            self._send({"categories": [{"name": "Pets"}, {"name": "Electronics"}, {"name": "Pets"}],
                        "pagination": {"total_pages": 1}})
        else:
            self._send({"transactions": SURE, "pagination": {"total_pages": 1}})

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        FakeEverything.llm_requests.append(payload)
        items = json.loads(payload["messages"][1]["content"])["items"]
        answers = {"item-0": "Pets", "item-1": "Not A Real Category"}
        self._send({"choices": [{"message": {"content": json.dumps(
            {"items": [{"id": row["id"], "category": answers.get(row["id"], "Electronics")} for row in items]})}}],
            "usage": {"prompt_tokens": 120, "completion_tokens": 30}})

    def log_message(self, *args):
        pass


class EndToEndTest(unittest.TestCase):
    def setUp(self):
        self.server = http.server.HTTPServer(("127.0.0.1", 0), FakeEverything)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.folder = tempfile.TemporaryDirectory()
        for name, rows in (("orders.json", ORDERS), ("transactions.json", CHARGES)):
            with open(os.path.join(self.folder.name, name), "w", encoding="utf-8") as handle:
                json.dump(rows, handle)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.folder.cleanup()

    def path(self, name):
        return os.path.join(self.folder.name, name)

    def test_spike_cli_writes_report_and_items(self):
        os.environ["SURE_API_KEY"] = "k"
        spike.main(["--orders", self.path("orders.json"), "--transactions", self.path("transactions.json"),
                    "--sure-url", self.url, "--out", self.path("report.md"), "--items-csv", self.path("items.csv")])
        with open(self.path("report.md"), encoding="utf-8") as handle:
            report = handle.read()
        self.assertIn("Date window sweep", report)
        self.assertTrue(os.path.exists(self.path("items.csv")))

    def test_categorize_sample_flags_invalid_categories(self):
        import categorize_sample
        os.environ.update({"SURE_API_KEY": "k", "LLM_API_KEY": "l", "LLM_BASE_URL": self.url})
        categorize_sample.main(["--orders", self.path("orders.json"), "--sure-url", self.url, "--model", "test",
                                "--out", self.path("categorized.tsv")])
        with open(self.path("categorized.tsv"), encoding="utf-8") as handle:
            rows = handle.read().splitlines()
        self.assertEqual(rows[0].split("\t")[0], "Pets")
        self.assertTrue(rows[1].startswith("?? Not A Real Category"))
        sent = json.loads(FakeEverything.llm_requests[-1]["messages"][1]["content"])
        self.assertEqual(sent["allowed_categories"], ["Electronics", "Pets"])
        self.assertNotIn("SECRET", json.dumps(FakeEverything.llm_requests[-1]))
        self.assertNotIn("111-1", json.dumps(FakeEverything.llm_requests[-1]))


if __name__ == "__main__":
    unittest.main()
