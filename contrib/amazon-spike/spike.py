#!/usr/bin/env python3
"""Read-only spike: how well do Amazon orders match your Sure transactions?

Inputs
  --orders        JSON from `amazon-orders history --full-details -o json`
  --transactions  JSON from `amazon-orders transactions --days N -o json`
  Sure (read-only API key): --sure-url and the SURE_API_KEY environment variable.

Nothing is written to Sure. The report contains order numbers and item titles but
never recipient names or addresses. Standard library only (Python 3.9+).
"""
import argparse
import collections
import csv
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from decimal import Decimal, ROUND_HALF_UP

AMAZON_NAME = re.compile(r"amzn|amazon|prime video|audible|kindle|whole foods", re.I)


def to_cents(value):
    """Absolute amount in cents, rounded half up (Amazon exports floats)."""
    return int((Decimal(str(value)).copy_abs() * 100).to_integral_value(rounding=ROUND_HALF_UP))


def parse_date(value):
    return dt.date.fromisoformat(str(value)[:10])


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, list):
        raise SystemExit(f"{path}: expected a JSON list, got {type(data).__name__}")
    return data


# --------------------------------------------------------------------------- Amazon side
def amazon_charges(raw_transactions):
    """Normalize the payments-page transactions. Charges are negative, refunds positive."""
    charges = []
    for row in raw_transactions:
        if row.get("grand_total") is None or not row.get("completed_date"):
            continue
        total = Decimal(str(row["grand_total"]))
        charges.append({
            "date": parse_date(row["completed_date"]),
            "cents": to_cents(total),
            "refund": bool(row.get("is_refund", total > 0)),
            "last4": row.get("payment_method_last_4"),
            "order_number": row.get("order_number"),
            "seller": row.get("seller"),
        })
    return sorted(charges, key=lambda charge: (charge["date"], charge["cents"]))


def index_orders(raw_orders):
    return {order["order_number"]: order for order in raw_orders if order.get("order_number")}


def order_items(order):
    """Items of an order; falls back to shipment items when the order lists none."""
    items = list(order.get("items") or [])
    if not items:
        for shipment in order.get("shipments") or []:
            items.extend(shipment.get("items") or [])
    return items


# --------------------------------------------------------------------------- Sure side
class SureClient:
    def __init__(self, base_url, api_key):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key

    def get(self, path, params):
        url = f"{self.base_url}{path}?{urllib.parse.urlencode(params)}"
        request = urllib.request.Request(url, headers={"X-Api-Key": self.api_key, "Accept": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code == 429:
                raise SystemExit("Sure rate limit reached (100 requests/hour per API key). Wait and rerun, "
                                 f"or narrow --days. Retry-After: {error.headers.get('Retry-After', '?')}")
            if error.code in (401, 403):
                raise SystemExit(f"Sure rejected the API key ({error.code}). Use a key with read scope.")
            raise SystemExit(f"Sure request failed: {error.code} {error.reason} for {path}")

    def paged(self, path, params, key):
        page, rows = 1, []
        while True:
            body = self.get(path, dict(params, page=page, per_page=100))
            rows.extend(body.get(key, []))
            if page >= int(body.get("pagination", {}).get("total_pages", 1)):
                return rows
            page += 1

    def transactions(self, start, end):
        return self.paged("/api/v1/transactions", {"start_date": start.isoformat(), "end_date": end.isoformat()},
                          "transactions")

    def categories(self):
        return self.paged("/api/v1/categories", {}, "categories")


# --------------------------------------------------------------------------- matching
def candidates_for(charge, sure_transactions, window_days):
    """Sure transactions with the same amount, direction and a date within the window."""
    wanted = "income" if charge["refund"] else "expense"
    found = []
    for txn in sure_transactions:
        if txn.get("classification") != wanted or int(txn["amount_cents"]) != charge["cents"]:
            continue
        gap = abs((parse_date(txn["date"]) - charge["date"]).days)
        if gap <= window_days:
            found.append({"txn": txn, "gap": gap, "amazon_name": bool(AMAZON_NAME.search(txn.get("name") or ""))})
    return sorted(found, key=lambda c: (c["gap"], not c["amazon_name"]))


def classify(charge, sure_transactions, window_days):
    found = candidates_for(charge, sure_transactions, window_days)
    if not found:
        status = "unmatched"
    elif len(found) == 1:
        status = "unique"
    else:
        status = "ambiguous"
    resolvable = None
    if status == "ambiguous":
        closest = [c for c in found if c["gap"] == found[0]["gap"]]
        by_name = [c for c in found if c["amazon_name"]]
        resolvable = "date" if len(closest) == 1 else ("name" if len(by_name) == 1 else None)
    return {"charge": charge, "status": status, "candidates": found, "resolvable_by": resolvable}


def near_misses(charge, sure_transactions, window_days, tolerance_cents=100):
    wanted = "income" if charge["refund"] else "expense"
    near = []
    for txn in sure_transactions:
        if txn.get("classification") != wanted:
            continue
        diff = abs(int(txn["amount_cents"]) - charge["cents"])
        gap = abs((parse_date(txn["date"]) - charge["date"]).days)
        if 0 < diff <= tolerance_cents and gap <= window_days:
            near.append((diff, gap, txn))
    return sorted(near, key=lambda item: (item[0], item[1]))[:2]


def claimed_twice(results):
    """Sure transactions that are the only candidate for more than one Amazon charge."""
    counts = collections.Counter(r["candidates"][0]["txn"]["id"] for r in results if r["status"] == "unique")
    return {txn_id for txn_id, count in counts.items() if count > 1}


# --------------------------------------------------------------------------- report
def pct(part, whole):
    return f"{(100.0 * part / whole):.0f}%" if whole else "n/a"


def money(cents):
    return f"${cents / 100:,.2f}"


def build_report(charges, orders, sure_transactions, window_days):
    results = [classify(c, sure_transactions, window_days) for c in charges]
    by_status = collections.Counter(r["status"] for r in results)
    total = len(results)
    lines = []
    out = lines.append

    out("# Amazon order spike report")
    if charges:
        out(f"\nAmazon payments considered: **{total}** ({charges[0]['date']} to {charges[-1]['date']}); "
            f"Sure transactions fetched: **{len(sure_transactions)}**; date window: +/-{window_days} days.")

    out("\n## Match summary\n")
    out("| Outcome | Count | Share |\n|---|---|---|")
    labels = {"unique": "Exactly one Sure candidate (would auto-match)", "ambiguous": "Several candidates",
              "unmatched": "No candidate"}
    for key in ("unique", "ambiguous", "unmatched"):
        out(f"| {labels[key]} | {by_status[key]} | {pct(by_status[key], total)} |")
    resolvable = collections.Counter(r["resolvable_by"] for r in results if r["status"] == "ambiguous")
    if by_status["ambiguous"]:
        out(f"\nOf the ambiguous ones, {resolvable['date']} resolve by closest date and {resolvable['name']} "
            f"by an Amazon-looking name; {resolvable[None]} stay ambiguous.")
    twice = claimed_twice(results)
    if twice:
        out(f"\n**Warning:** {len(twice)} Sure transaction(s) are the sole candidate for more than one Amazon payment.")
    refunds = sum(1 for r in results if r["charge"]["refund"])
    out(f"\nRefunds among the payments: {refunds}.")

    out("\n## Date window sweep (share that would auto-match)\n")
    out("| Window (days) | Unique | Ambiguous | Unmatched |\n|---|---|---|---|")
    for window in range(0, 8):
        counts = collections.Counter(classify(c, sure_transactions, window)["status"] for c in charges)
        out(f"| {window} | {pct(counts['unique'], total)} | {pct(counts['ambiguous'], total)} | "
            f"{pct(counts['unmatched'], total)} |")

    matched = [r for r in results if r["status"] in ("unique", "ambiguous")]
    out("\n## Bank-side names of matched transactions\n")
    names = collections.Counter((r["candidates"][0]["txn"].get("name") or "")[:50] for r in matched)
    amazon_like = sum(1 for r in matched if r["candidates"][0]["amazon_name"])
    out(f"{amazon_like} of {len(matched)} matched transactions have an Amazon-looking name "
        f"(regex: `{AMAZON_NAME.pattern}`). Most common names:\n")
    for name, count in names.most_common(15):
        out(f"- {count}x `{name}`")

    out("\n## Card last four -> Sure account (from matches)\n")
    last4 = collections.defaultdict(collections.Counter)
    for r in matched:
        last4[r["charge"]["last4"] or "unknown"][r["candidates"][0]["txn"]["account"]["name"]] += 1
    for card, accounts in sorted(last4.items()):
        out(f"- **{card}**: " + ", ".join(f"{name} ({count})" for name, count in accounts.most_common()))

    out("\n## Orders\n")
    per_order = collections.Counter(c["order_number"] for c in charges if c["order_number"])
    multi = [order for order, count in per_order.items() if count > 1]
    linked = [c for c in charges if c["order_number"] in orders]
    missing = [c for c in charges if c["order_number"] and c["order_number"] not in orders]
    out(f"- Payments linked to an exported order: {len(linked)} of {total} "
        f"({len(missing)} reference an order missing from orders.json; export a longer history)")
    out(f"- Orders paid in several charges (one order, multiple card charges): {len(multi)}")
    gift = [o for o in orders.values() if o.get("gift_card")]
    out(f"- Orders using a gift card: {len(gift)}")
    sizes = collections.Counter(min(len(order_items(o)), 6) for o in orders.values())
    out("- Items per order: " + ", ".join(f"{('6+' if k == 6 else k)} items: {v}" for k, v in sorted(sizes.items())))
    with_tax = sum(1 for o in orders.values() if o.get("estimated_tax") is not None)
    out(f"- Orders with tax and shipping detail available: {with_tax} of {len(orders)}")

    out("\n## Unmatched payments\n")
    shown = [r for r in results if r["status"] == "unmatched"][:30]
    for r in shown:
        charge = r["charge"]
        order = orders.get(charge["order_number"])
        titles = "; ".join((i.get("title") or "")[:40] for i in order_items(order)[:3]) if order else "(order not exported)"
        near = near_misses(charge, sure_transactions, window_days)
        hint = f" | near miss: {money(int(near[0][2]['amount_cents']))} on {near[0][2]['date']}" if near else ""
        out(f"- {charge['date']} {money(charge['cents'])}{' REFUND' if charge['refund'] else ''} "
            f"order {charge['order_number']}: {titles}{hint}")

    out("\n## Ambiguous payments\n")
    for r in [r for r in results if r["status"] == "ambiguous"][:20]:
        charge = r["charge"]
        out(f"- {charge['date']} {money(charge['cents'])} order {charge['order_number']}: "
            + ", ".join(f"{c['txn']['date']} {c['txn'].get('name', '')[:30]!r} ({c['txn']['account']['name']})"
                        for c in r["candidates"][:4]))

    matched_ids = {c["txn"]["id"] for r in matched for c in r["candidates"]}
    orphans = [t for t in sure_transactions if AMAZON_NAME.search(t.get("name") or "") and t["id"] not in matched_ids]
    out(f"\n## Amazon-looking Sure transactions with no Amazon payment ({len(orphans)})\n")
    out("Often Prime membership, Audible/Kindle, Whole Foods, or purchases outside the export range.\n")
    for txn in orphans[:30]:
        out(f"- {txn['date']} {money(int(txn['amount_cents']))} `{(txn.get('name') or '')[:50]}` ({txn['account']['name']})")

    return "\n".join(lines) + "\n", results


def write_items_csv(path, results, orders):
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["order_number", "order_date", "charge_cents", "asin", "title", "quantity", "price"])
        for r in results:
            order = orders.get(r["charge"]["order_number"])
            if r["status"] == "unmatched" or not order:
                continue
            for item in order_items(order):
                writer.writerow([order["order_number"], order.get("order_placed_date"), r["charge"]["cents"],
                                 item.get("asin"), item.get("title"), item.get("quantity"), item.get("price")])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--orders", required=True)
    parser.add_argument("--transactions", required=True)
    parser.add_argument("--sure-url", required=True, help="e.g. http://host.docker.internal:3000")
    parser.add_argument("--window", type=int, default=4, help="date window in days (default 4)")
    parser.add_argument("--out", default="report.md")
    parser.add_argument("--items-csv", default="items.csv")
    args = parser.parse_args(argv)

    api_key = os.environ.get("SURE_API_KEY")
    if not api_key:
        raise SystemExit("Set SURE_API_KEY (a read-scope key; pass it with `docker run -e SURE_API_KEY`).")

    charges = amazon_charges(load_json(args.transactions))
    if not charges:
        raise SystemExit("No Amazon payments found in the transactions file.")
    orders = index_orders(load_json(args.orders))

    start = charges[0]["date"] - dt.timedelta(days=args.window)
    end = charges[-1]["date"] + dt.timedelta(days=args.window)
    sure_transactions = SureClient(args.sure_url, api_key).transactions(start, end)

    report, results = build_report(charges, orders, sure_transactions, args.window)
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(report)
    write_items_csv(args.items_csv, results, orders)
    print(report)
    print(f"Wrote {args.out} and {args.items_csv}", file=sys.stderr)


if __name__ == "__main__":
    main()
