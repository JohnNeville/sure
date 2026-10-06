#!/usr/bin/env python3
"""Phase 0, step 3: try an LLM on real order item titles against your Sure categories.

Reads item titles from `orders.json`, your category names from Sure (read-only key), and asks any
OpenAI-compatible chat endpoint to pick one category per item. Prints a title -> category table and
the token usage so you can judge quality and cost before building anything. Only item titles and
category names are sent; no addresses, names, or order numbers. Standard library only.

Environment: SURE_API_KEY (read scope), LLM_API_KEY, optionally LLM_BASE_URL (default OpenAI).
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

from spike import SureClient, index_orders, load_json, order_items

BATCH = 25


def ask(base_url, api_key, model, categories, titles):
    """One chat call. Returns ({item_id: category}, usage dict)."""
    rows = [{"id": f"item-{i}", "title": title} for i, title in enumerate(titles)]
    system = ("You categorize retail purchase items for a personal finance app. For every item choose exactly "
              "one category name from the allowed list, spelled exactly as given. Respond with JSON only: "
              '{"items": [{"id": "item-0", "category": "<name>"}]}.')
    user = json.dumps({"allowed_categories": categories, "items": rows})
    body = {"model": model, "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "temperature": 0}
    for with_json_mode in (True, False):
        payload = dict(body)
        if with_json_mode:
            payload["response_format"] = {"type": "json_object"}
        request = urllib.request.Request(
            f"{base_url.rstrip('/')}/chat/completions", data=json.dumps(payload).encode(),
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                data = json.load(response)
            break
        except urllib.error.HTTPError as error:
            if error.code == 400 and with_json_mode:
                continue  # some servers don't support json mode
            raise SystemExit(f"LLM request failed: {error.code} {error.read().decode()[:300]}")
    content = data["choices"][0]["message"]["content"]
    parsed = json.loads(content[content.index("{"):content.rindex("}") + 1])
    return {row["id"]: row.get("category") for row in parsed.get("items", [])}, data.get("usage", {})


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--orders", required=True)
    parser.add_argument("--sure-url", required=True)
    parser.add_argument("--model", required=True, help="model name for your endpoint")
    parser.add_argument("--orders-sample", type=int, default=20, help="how many orders to sample (default 20)")
    parser.add_argument("--out", default="categorized.tsv")
    args = parser.parse_args(argv)

    sure_key, llm_key = os.environ.get("SURE_API_KEY"), os.environ.get("LLM_API_KEY")
    if not sure_key or not llm_key:
        raise SystemExit("Set SURE_API_KEY and LLM_API_KEY (pass them with `docker run -e`).")
    base_url = os.environ.get("LLM_BASE_URL", "https://api.openai.com/v1")

    categories = sorted({c["name"] for c in SureClient(args.sure_url, sure_key).categories()})
    if not categories:
        raise SystemExit("Sure returned no categories.")
    orders = list(index_orders(load_json(args.orders)).values())[:args.orders_sample]
    titles = [item.get("title") for order in orders for item in order_items(order) if item.get("title")]
    print(f"{len(orders)} orders, {len(titles)} items, {len(categories)} categories", file=sys.stderr)

    results, tokens = [], {"prompt_tokens": 0, "completion_tokens": 0}
    for start in range(0, len(titles), BATCH):
        chunk = titles[start:start + BATCH]
        chosen, usage = ask(base_url, llm_key, args.model, categories, chunk)
        for i, title in enumerate(chunk):
            category = chosen.get(f"item-{i}")
            results.append((title, category if category in categories else f"?? {category}"))
        for key in tokens:
            tokens[key] += int(usage.get(key, 0))

    with open(args.out, "w", encoding="utf-8") as handle:
        for title, category in results:
            handle.write(f"{category}\t{title}\n")
            print(f"{(category or '')[:28]:<28} {title[:80]}")
    invalid = sum(1 for _, category in results if category.startswith("??"))
    print(f"\n{len(results)} items, {invalid} invalid category names, tokens: {tokens}", file=sys.stderr)
    print(f"Wrote {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
