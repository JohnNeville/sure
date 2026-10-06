# Amazon order spike (Phase 0)

A read-only experiment to answer one question before anything is built in Sure: **how well can Amazon orders be matched to the charges already in your Sure data, and how good are LLM categories for the items?** Nothing here writes to Sure or Amazon.

The scripts use only the Python standard library, so they run in a plain `python:3.12-slim` container. Your Amazon export and the reports stay on your machine.

## 1. Export from Amazon

Amazon now answers most logins with a JavaScript challenge, so the CLI needs a real browser. Build an image with the `browser` extra and Chromium (a larger image, roughly 1.5 GB), log in once, and export:

```bash
docker build -t amazon-orders-cli - <<'DOCKERFILE'
FROM python:3.12-slim
RUN pip install --no-cache-dir "amazon-orders[browser]==4.6.1" \
 && playwright install --with-deps chromium \
 && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["amazon-orders"]
DOCKERFILE

# --ipc=host keeps Chromium stable inside Docker; the session is kept in the named volume
docker run --rm -it --ipc=host -v amazon-orders-config:/root/.config/amazonorders amazon-orders-cli login

mkdir -p ~/amazon-spike && cd ~/amazon-spike
docker run --rm --ipc=host -v amazon-orders-config:/root/.config/amazonorders amazon-orders-cli \
  history --last-3-months --full-details -o json > orders.json
docker run --rm --ipc=host -v amazon-orders-config:/root/.config/amazonorders amazon-orders-cli \
  transactions --days 90 -o json > transactions.json
```

Start with `--last-30-days` / `--days 30` if you want a gentler first run. `orders.json` contains recipient names and addresses: keep it local and never commit it. These scripts ignore those fields and never print them.

### If login still fails

- **"Browser timed out waiting for the JavaScript challenge"**: raise the wait by adding `browser_timeout: 90` to the volume's `config.yml` (inside the container: `~/.config/amazonorders/config.yml`), or retry; the challenge is best-effort headless.
- **A visual puzzle that headless Chromium cannot solve**: log in once on a machine with a display instead, where the library can open a visible browser window for you to solve it, then export there or copy the session into the Docker volume:

  ```bash
  python3 -m venv ~/amazon-venv && . ~/amazon-venv/bin/activate
  pip install "amazon-orders[browser]==4.6.1" && playwright install chromium
  mkdir -p ~/.config/amazonorders
  printf 'auth_forms_classes:\n  - amazonorders.contrib.browser.playwright.PlaywrightManualWafForm\n' \
    > ~/.config/amazonorders/config.yml
  amazon-orders login        # a window opens; solve the puzzle; answer any MFA prompt in the terminal
  # export on the host (same commands as above, without docker), or reuse the session in Docker:
  docker run --rm -v amazon-orders-config:/cfg -v ~/.config/amazonorders:/src alpine \
    cp /src/cookies.json /cfg/
  ```
- **Debugging**: add `--debug --output-dir /out` and mount `-v "$PWD/out:/out"`. The saved page snapshots contain personal data, so delete them afterwards.
- Neither route works: Amazon's own "Request My Data" export (Retail.OrderHistory CSV) avoids scraping entirely. It takes 24 to 72 hours and has no card-last-four, so ask if you want the spike to read that format instead.

## 2. Match against Sure

Create a **read-only** API key in Sure, then from `~/amazon-spike`:

```bash
git clone --depth 1 --branch spike/amazon-orders https://github.com/JohnNeville/sure.git /tmp/sure-spike
cp /tmp/sure-spike/contrib/amazon-spike/*.py .

export SURE_API_KEY=your_read_only_key
docker run --rm -v "$PWD":/work -w /work -e SURE_API_KEY \
  --add-host=host.docker.internal:host-gateway python:3.12-slim \
  python spike.py --orders orders.json --transactions transactions.json \
  --sure-url http://host.docker.internal:3000
```

Use your real Sure URL instead of `host.docker.internal:3000` if it runs elsewhere. It fetches your transactions for the same date range (about 1 request per 100 transactions; Sure allows 100 requests per hour per key) and writes `report.md` and `items.csv`.

Options: `--window N` sets the date window in days (default 4, the report also sweeps 0 to 7).

## 3. Try the LLM on item titles (optional)

Sends only item titles and your category names to any OpenAI-compatible endpoint:

```bash
export LLM_API_KEY=your_llm_key
docker run --rm -v "$PWD":/work -w /work -e SURE_API_KEY -e LLM_API_KEY \
  -e LLM_BASE_URL=https://api.openai.com/v1 \
  --add-host=host.docker.internal:host-gateway python:3.12-slim \
  python categorize_sample.py --orders orders.json \
  --sure-url http://host.docker.internal:3000 --model YOUR_MODEL --orders-sample 20
```

It prints `category  title` for each item, flags any category that is not one of yours with `??`, and reports token usage so you can estimate cost.

## How to read the report

- **Exactly one candidate** is what the real matcher would auto-apply. A high share here, with a small "several candidates" group that mostly resolves by closest date, means matching is workable.
- **Date window sweep**: pick the smallest window where the unique share stops improving.
- **Card last four to account**: shows whether the last four digits could narrow ambiguous matches (Sure accounts do not expose a card mask over the API, so this is learned from the matches).
- **Orders**: many orders paid in several charges, or paid partly with gift cards, make splitting harder; mostly single-item orders mean notes plus a category is most of the value.
- **Unmatched payments** with a near miss usually point to tax or currency differences or a missing account in Sure.

## Tests

```bash
python3 -m unittest
```

Runs offline against fake Sure and LLM servers.
