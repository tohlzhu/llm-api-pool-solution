# Architecture SVG Diagrams Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two hand-authored SVG architecture diagrams to `llm-api-pool-solution.md` that show the LiteLLM + multi-subscription Azure Foundry supply model, endpoint grouping, and fallback-driven fault isolation.

**Architecture:** Two static `.svg` files in a new `assets/` directory, written by hand on a 20px coordinate grid with a single class-driven `<style>` block per file. No generator script and no build step — the SVG source is the deliverable, matching this repo's existing convention of static, reviewable example files. Diagram 1 (overview) attaches to §5; diagram 2 (isolation/fallback) attaches to §4.2.1.

**Tech Stack:** SVG 1.1 (hand-written), Python 3 `xml.etree.ElementTree` for well-formedness checks, Playwright's cached Chromium binary for headless render inspection.

## Global Constraints

- All text inside both SVGs is **English**. Document prose stays Chinese.
- No `<script>`, no `<foreignObject>`, no external references (fonts, images, stylesheets). GitHub renders `.svg` via `<img>` in SVG secure static mode, which blocks them.
- Palette must read on both white and GitHub dark `#0d1117`: explicit light fill + saturated stroke + near-black text on every shape, over a `#f8fafc` base canvas rect. `prefers-color-scheme` is NOT usable (follows OS theme, not GitHub's toggle).
- Font stack exactly: `'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif`.
- Minimum label size 12px; box titles 15px or larger.
- All coordinates land on a 20px grid where practical; every shape declares `class`, never inline `fill`/`stroke` presentation attributes (markers excepted).
- Every SVG has `role="img"`, `<title>`, and `<desc>`.
- No real tenant IDs, subscription IDs, keys, or endpoints. Subscription names use the `{prefix}` placeholder form, e.g. `{prefix}-claude-sub01`.
- Palette (fill / stroke), used verbatim:
  - Consumers `#eef2ff` / `#4f5bd5`
  - Gateway `#e0f2fe` / `#0369a1`
  - Claude supply `#fff1e6` / `#c2570e`
  - GPT supply `#e7f7ef` / `#15803d`
  - Batch `#f3e8ff` / `#7e22ce`
  - DeepSeek / Vertex `#f1f5f9` / `#475569`
  - Fault / blocked `#fee2e2` / `#b91c1c`
  - Text `#0f172a`; muted text `#475569`
- Chromium binary for rendering: `~/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome`
- Model names, exact spellings: `claude-opus-4-8`, `claude-sonnet-5`, `claude-haiku-4-5`, `gpt-5.5`, `gpt-5.6-terra`, `gpt-5.6-sol`, `gpt-5.6-luna`, `DeepSeek-V4-Pro`, `DeepSeek-V4-Flash`.
- Subscription counts: 10 Claude (3 endpoints each), 5 GPT interactive (4 each), 2 GPT batch, 1 DeepSeek (2 endpoints) = 18 subscriptions.
- Foundry naming: `fdry-{subscription_name}` / `proj-{subscription_name}`, region `eastus2`, SKU `GlobalStandard`.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `assets/architecture-overview.svg` | Create. Five-band layered supply diagram for §5. |
| `assets/architecture-isolation-fallback.svg` | Create. Before/after isolation comparison + fallback ladder for §4.2.1. |
| `scripts/check-svg.sh` | Create. Reusable validation: XML well-formedness + forbidden-construct grep for both SVGs. This is a checker, not a generator — it does not produce the diagrams. |
| `llm-api-pool-solution.md` | Modify §4.2.1 (insert diagram 2) and §5 (insert diagram 1, wrap existing ASCII block in `<details>`). |
| `README.md` | Modify: add both SVGs to the file list. |
| `CLAUDE.md`, `AGENTS.md` | Modify: add `assets/*.svg` to supporting artifacts, note diagrams track the doc. |

Task order: validation harness first (Task 1) so Tasks 2 and 3 can each verify themselves the moment they produce a file. Diagram 2 (Task 2) precedes diagram 1 (Task 3) because it is smaller and exercises the shared style conventions on fewer elements. Doc integration (Task 4) last, once both files exist and pass.

---

### Task 1: SVG validation harness

**Files:**
- Create: `scripts/check-svg.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `scripts/check-svg.sh [file...]` — exits 0 if all checked SVGs are well-formed XML and free of forbidden constructs, exits 1 otherwise. Defaults to `assets/architecture-overview.svg assets/architecture-isolation-fallback.svg` when given no arguments. Tasks 2 and 3 invoke it as `scripts/check-svg.sh <their file>`.

- [ ] **Step 1: Write the failing test**

Create a deliberately bad SVG and a good one in `/tmp`, then assert the checker rejects the bad and accepts the good. Run these commands as the test:

```bash
mkdir -p /tmp/svgtest
printf '<svg xmlns="http://www.w3.org/2000/svg"><rect width="10" height="10"/></svg>' > /tmp/svgtest/good.svg
printf '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script><rect width="10"</svg>' > /tmp/svgtest/bad.svg
scripts/check-svg.sh /tmp/svgtest/good.svg && echo "GOOD-ACCEPTED"
scripts/check-svg.sh /tmp/svgtest/bad.svg || echo "BAD-REJECTED"
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/check-svg.sh /tmp/svgtest/good.svg`
Expected: FAIL with `bash: scripts/check-svg.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

```bash
#!/usr/bin/env bash
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }

DEFAULT_FILES=(
  "assets/architecture-overview.svg"
  "assets/architecture-isolation-fallback.svg"
)

require_python() {
  command -v python3 >/dev/null 2>&1 || {
    log "ERROR: python3 is required"
    exit 1
  }
}

check_wellformed() {
  local file="$1"
  python3 - "$file" <<'PY'
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
try:
    ET.parse(path)
except ET.ParseError as exc:
    print(f"malformed XML: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

check_forbidden() {
  local file="$1" rc=0

  if grep -qi '<script' "$file"; then
    log "  FORBIDDEN: <script> element present"
    rc=1
  fi
  if grep -qi '<foreignObject' "$file"; then
    log "  FORBIDDEN: <foreignObject> element present"
    rc=1
  fi
  if grep -qi 'xlink:href\|<image' "$file"; then
    log "  FORBIDDEN: external image or xlink reference present"
    rc=1
  fi
  # Any http(s) URL other than the SVG/xlink namespace declarations.
  if grep -o 'https\?://[^"'"'"' )]*' "$file" \
    | grep -v '^http://www\.w3\.org/2000/svg$' \
    | grep -v '^http://www\.w3\.org/1999/xlink$' \
    | grep -q .; then
    log "  FORBIDDEN: external URL reference present"
    rc=1
  fi
  if grep -q '@font-face\|@import' "$file"; then
    log "  FORBIDDEN: external font or stylesheet import present"
    rc=1
  fi

  return "$rc"
}

main() {
  require_python

  local files=("$@")
  if [[ ${#files[@]} -eq 0 ]]; then
    files=("${DEFAULT_FILES[@]}")
  fi

  local failed=0
  for file in "${files[@]}"; do
    log "Checking $file"
    if [[ ! -f "$file" ]]; then
      log "  MISSING: $file"
      failed=1
      continue
    fi
    if ! check_wellformed "$file"; then
      log "  FAIL: not well-formed XML"
      failed=1
      continue
    fi
    if ! check_forbidden "$file"; then
      log "  FAIL: forbidden construct"
      failed=1
      continue
    fi
    log "  OK"
  done

  if [[ "$failed" -ne 0 ]]; then
    log "SVG check FAILED"
    exit 1
  fi
  log "SVG check passed"
}

main "$@"
```

Then `chmod +x scripts/check-svg.sh`.

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
bash -n scripts/check-svg.sh
scripts/check-svg.sh /tmp/svgtest/good.svg && echo "GOOD-ACCEPTED"
scripts/check-svg.sh /tmp/svgtest/bad.svg || echo "BAD-REJECTED"
```
Expected: `bash -n` silent; then `GOOD-ACCEPTED`; then the bad file reports both a forbidden `<script>` and malformed XML, and prints `BAD-REJECTED`.

- [ ] **Step 5: Commit**

```bash
git add scripts/check-svg.sh
git commit -m "Add SVG validation checker for architecture diagrams"
```

---

### Task 2: Isolation and fallback diagram

**Files:**
- Create: `assets/architecture-isolation-fallback.svg`

**Interfaces:**
- Consumes: `scripts/check-svg.sh` from Task 1.
- Produces: `assets/architecture-isolation-fallback.svg`, canvas `viewBox="0 0 1480 900"`. Task 4 embeds this path in §4.2.1. Establishes the shared class vocabulary that Task 3 reuses: `.canvas`, `.frame`, `.frame-title`, `.chip-claude`, `.chip-fault`, `.band-claude`, `.band-label`, `.lbl`, `.lbl-muted`, `.lbl-strong`, `.title`, `.subtitle`, `.arrow-normal`, `.arrow-fallback`, `.arrow-blocked`, `.step-num`.

**Layout geometry (computed, verified to fit):**
- Canvas 1480×900. Title at y=44, subtitle y=70.
- Left panel "Without isolation": frame x=40 y=110 w=580 h=250. 10 chips in 2 rows of 5: w=88 h=54, x positions 82/178/274/370/466, rows y=176 and y=250. Verdict text at y=330.
- Right panel "With 5 isolation groups": frame x=660 y=110 w=780 h=250. 5 group bands w=138 h=150 at x=670/818/966/1114/1262, y=150. Inside each band, 2 chips w=60 h=48 at band_x+8 and band_x+72, y=196. Team label at y=336 under each band.
- Fallback ladder: frame x=660 y=400 w=780 h=420. Ladder rows at y=470 (①), 540 (②), 610 (③), 690 (blocked ╳).
- Footer note y=860.

- [ ] **Step 1: Write the failing test**

The test for a diagram is: it validates, it renders, and the render matches the spec's content. Write the check invocation first:

```bash
scripts/check-svg.sh assets/architecture-isolation-fallback.svg
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/check-svg.sh assets/architecture-isolation-fallback.svg`
Expected: FAIL with `MISSING: assets/architecture-isolation-fallback.svg` and `SVG check FAILED`

- [ ] **Step 3: Write minimal implementation**

Create `assets/` then write the file. Content requirements, all in English:

Header:
```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1480 900" width="1480" height="900" role="img">
  <title>LiteLLM model_name Isolation and Fallback Order</title>
  <desc>Comparison of a single shared model name against five isolation groups, showing that one suspended group affects only two of ten Foundry endpoints, followed by the ordered fallback path from the affected group to Vertex Claude and then to GPT, with cross-group fallback explicitly forbidden.</desc>
  <style>
    .canvas { fill: #f8fafc; }
    .frame { fill: #ffffff; stroke: #94a3b8; stroke-width: 1.5; }
    .frame-title { font-size: 17px; font-weight: 600; fill: #0f172a; }
    .title { font-size: 25px; font-weight: 700; fill: #0f172a; }
    .subtitle { font-size: 14px; fill: #475569; }
    .band-claude { fill: #fff1e6; stroke: #c2570e; stroke-width: 1.5; }
    .band-fault { fill: #fee2e2; stroke: #b91c1c; stroke-width: 2; }
    .band-label { font-size: 14px; font-weight: 700; fill: #9a3412; }
    .band-label-fault { font-size: 14px; font-weight: 700; fill: #b91c1c; }
    .chip-claude { fill: #ffffff; stroke: #c2570e; stroke-width: 1.2; }
    .chip-fault { fill: #fee2e2; stroke: #b91c1c; stroke-width: 1.5; }
    .chip-shared { fill: #fee2e2; stroke: #b91c1c; stroke-width: 1.2; }
    .box-vertex { fill: #f1f5f9; stroke: #475569; stroke-width: 1.5; }
    .box-gpt { fill: #e7f7ef; stroke: #15803d; stroke-width: 1.5; }
    .box-fault { fill: #fee2e2; stroke: #b91c1c; stroke-width: 2; }
    .lbl { font-size: 13px; fill: #0f172a; }
    .lbl-muted { font-size: 12px; fill: #475569; }
    .lbl-strong { font-size: 14px; font-weight: 600; fill: #0f172a; }
    .lbl-fault { font-size: 13px; font-weight: 600; fill: #b91c1c; }
    .lbl-ok { font-size: 13px; font-weight: 600; fill: #15803d; }
    .mono { font-size: 13px; font-family: 'Cascadia Code', Consolas, 'DejaVu Sans Mono', monospace; fill: #0f172a; }
    .arrow-normal { stroke: #0369a1; stroke-width: 2; fill: none; }
    .arrow-fallback { stroke: #c2570e; stroke-width: 2; fill: none; stroke-dasharray: 7 4; }
    .arrow-blocked { stroke: #b91c1c; stroke-width: 2.5; fill: none; }
    .step-num { font-size: 15px; font-weight: 700; fill: #0369a1; }
    .strike { stroke: #b91c1c; stroke-width: 3; }
  </style>
  <defs>
    <marker id="arrow-normal-head" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#0369a1"/>
    </marker>
    <marker id="arrow-fallback-head" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#c2570e"/>
    </marker>
    <marker id="arrow-blocked-head" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#b91c1c"/>
    </marker>
  </defs>
  <rect class="canvas" x="0" y="0" width="1480" height="900"/>
```

Body content, using the geometry above:

1. Title: `model_name Isolation — Blast Radius and Fallback Order`. Subtitle: `Example: claude-sonnet-5 across 10 Foundry subscriptions (2 endpoints per isolation group)`.
2. Left frame, title `Without isolation — one shared model_name`. Sub-label `model_name: claude-sonnet-5` in `.mono`. 10 chips class `.chip-shared`, labelled `sub01`…`sub10` in `.lbl`. Below frame, two lines: `One content-policy hit suspends the shared name` (`.lbl-fault`) and `Impact: all 10 endpoints · every team loses the model` (`.lbl-fault`).
3. Right frame, title `With 5 isolation groups`. Five bands: band 1 class `.band-fault` with label `grp1 ✗ SUSPENDED` (`.band-label-fault`) and its 2 chips class `.chip-fault`; bands 2–5 class `.band-claude` with labels `grp2 ✓ healthy` … `grp5 ✓ healthy` (`.band-label`) and chips class `.chip-claude`. Chip labels `sub01`/`sub02` in band 1 through `sub09`/`sub10` in band 5. Under each band a team label `team A` … `team E` (`.lbl-muted`). Below the frame: `Impact: 2 of 10 endpoints · 80% capacity intact · only team A affected` (`.lbl-ok`).
4. Fallback ladder frame, title `Fallback order for the affected group`. Source box class `.box-fault` containing `.mono` text `claude-sonnet-5-grp1` and `.lbl-fault` text `suspended`. Three ordered rows, each with a `.step-num` marker, an arrow, a target box, and a rationale label:
   - ① arrow class `.arrow-normal` marker `arrow-normal-head` → target box `.chip-claude` with `.mono` `sub01 → sub02`, rationale `Healthy endpoint inside the same group first` (`.lbl`).
   - ② arrow class `.arrow-fallback` marker `arrow-fallback-head` → target box `.box-vertex` with `.mono` `vertex-claude-sonnet`, rationale `Same model type, different cloud — output style preserved` (`.lbl`).
   - ③ arrow class `.arrow-fallback` marker `arrow-fallback-head` → target box `.box-gpt` with `.mono` `gpt-5.5-grp1`, rationale `Cross-model, same group number` (`.lbl`).
   - Blocked row: arrow class `.arrow-blocked` marker `arrow-blocked-head` toward a box `.chip-claude` with `.mono` `claude-sonnet-5-grp2..5`, PLUS a `.strike` line drawn diagonally across that arrow, a `╳` glyph in `.lbl-fault`, and rationale `NEVER — would spread suspect traffic into healthy groups` (`.lbl-fault`).
5. Footer: `Audit requirement: log the model_name group and user identity on every request` (`.lbl-muted`).

Close with `</svg>`.

- [ ] **Step 4: Run tests to verify they pass**

```bash
scripts/check-svg.sh assets/architecture-isolation-fallback.svg
~/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome --headless --disable-gpu --no-sandbox \
  --hide-scrollbars --force-device-scale-factor=1 \
  --screenshot=/tmp/iso-full.png --window-size=1480,900 \
  "file://$PWD/assets/architecture-isolation-fallback.svg"
~/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome --headless --disable-gpu --no-sandbox \
  --hide-scrollbars --force-device-scale-factor=1 \
  --screenshot=/tmp/iso-small.png --window-size=800,487 \
  "file://$PWD/assets/architecture-isolation-fallback.svg"
```
Expected: `SVG check passed`, and both PNGs written. Then **read both PNGs with the Read tool** and confirm: no overlapping shapes, no text extending past its box, all three fallback arrows terminate on their target box, the strike-through is visibly crossing the blocked arrow, and every label is legible in `/tmp/iso-small.png`. Fix and re-render until clean. Chromium may log a `UPower`/dbus ERROR line — that is unrelated to rendering; judge success by the PNG being written.

- [ ] **Step 5: Commit**

```bash
git add assets/architecture-isolation-fallback.svg
git commit -m "Add model_name isolation and fallback order diagram"
```

---

### Task 3: Layered supply overview diagram

**Files:**
- Create: `assets/architecture-overview.svg`

**Interfaces:**
- Consumes: `scripts/check-svg.sh` from Task 1; the class vocabulary established in Task 2 (reuse the same class names and palette values so the two diagrams look like one system).
- Produces: `assets/architecture-overview.svg`, canvas `viewBox="0 0 1480 1080"`. Task 4 embeds this path in §5.

**Layout geometry (computed, verified to fit):**
- Canvas 1480×1080. Title y=44, subtitle y=70.
- Band 1 Consumers, y=100 h=110: apps box x=40 w=560; jobs box x=620 w=340; IDE box x=1080 w=360 (side lane, drawn with `.box-copilot`).
- Band 2 Gateway, y=250 h=140: LiteLLM box x=40 w=920; ops-plane box x=1000 w=440.
- Band 3 Model names, y=430 h=90: five boxes x=40 w=270, x=330 w=250, x=600 w=270, x=890 w=210, x=1120 w=320.
- Band 4 Supply pools, two rows:
  - Row A y=560 h=200: Claude frame x=40 w=1020; Vertex frame x=1080 w=360.
  - Row B y=790 h=180: GPT frame x=40 w=620; Batch frame x=680 w=200; DeepSeek frame x=900 w=200. Vertex frame from row A may extend to y=970.
- Claude frame interior: 5 bands w=186 h=130 at x=60/256/452/648/844, y=610. Each band holds 2 sub boxes w=80 h=76 at band_x+6 and band_x+100, y=650. Last band ends x=1030, inside frame edge 1060. ✓
- GPT frame interior: 5 bands w=106 h=120 at x=60/176/292/408/524, y=830. Each holds 1 sub box w=80 h=70 at band_x+13, y=866. Last band ends x=630, inside frame edge 660. ✓
- Batch frame interior: 2 bands w=76 h=120 at x=700/784, y=830, each holding 1 sub box w=64 h=70 at band_x+6. Last ends x=860, frame edge 880. ✓
- Legend row y=1010; footnote y=1050.

- [ ] **Step 1: Write the failing test**

```bash
scripts/check-svg.sh assets/architecture-overview.svg
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/check-svg.sh assets/architecture-overview.svg`
Expected: FAIL with `MISSING: assets/architecture-overview.svg` and `SVG check FAILED`

- [ ] **Step 3: Write minimal implementation**

Reuse the Task 2 `<style>` block verbatim, then add these classes to it:

```css
    .box-consumer { fill: #eef2ff; stroke: #4f5bd5; stroke-width: 1.5; }
    .box-gateway { fill: #e0f2fe; stroke: #0369a1; stroke-width: 2; }
    .box-ops { fill: #e0f2fe; stroke: #0369a1; stroke-width: 1.5; }
    .box-copilot { fill: #f1f5f9; stroke: #475569; stroke-width: 1.5; stroke-dasharray: 6 4; }
    .box-name-claude { fill: #fff1e6; stroke: #c2570e; stroke-width: 1.5; }
    .box-name-gpt { fill: #e7f7ef; stroke: #15803d; stroke-width: 1.5; }
    .box-name-batch { fill: #f3e8ff; stroke: #7e22ce; stroke-width: 1.5; }
    .box-name-ds { fill: #f1f5f9; stroke: #475569; stroke-width: 1.5; }
    .band-gpt { fill: #e7f7ef; stroke: #15803d; stroke-width: 1.5; }
    .band-batch { fill: #f3e8ff; stroke: #7e22ce; stroke-width: 1.5; }
    .chip-gpt { fill: #ffffff; stroke: #15803d; stroke-width: 1.2; }
    .chip-batch { fill: #ffffff; stroke: #7e22ce; stroke-width: 1.2; }
    .band-label-gpt { font-size: 14px; font-weight: 700; fill: #15803d; }
    .band-label-batch { font-size: 13px; font-weight: 700; fill: #7e22ce; }
    .layer-tag { font-size: 12px; font-weight: 700; fill: #475569; }
```

Header `<title>`: `LiteLLM Gateway and Multi-Subscription Azure Foundry Supply Pools`. `<desc>`: `Layered architecture showing consumer applications and scheduled jobs entering a LiteLLM gateway on AKS, which routes user-facing model names to five isolation groups across ten Claude Foundry subscriptions, five GPT subscriptions, two dedicated batch subscriptions, one DeepSeek subscription, and a cross-cloud Vertex Claude backup channel.`

Body content, all English:

1. Title `LiteLLM Gateway + Multi-Subscription Azure Foundry Supply Pools`. Subtitle `18 subscriptions · eastus2 · GlobalStandard deployments · ~1000 employees across 5 teams`.
2. **Band 1 Consumers** (`.box-consumer` except IDE):
   - Apps box: `.frame-title` `Developer Apps / Internal Tools / Agents`, `.lbl-muted` `5 teams · ~1000 employees · interactive workloads`.
   - Jobs box: `.frame-title` `Scheduled Jobs / Batch Workloads`, `.lbl-muted` `repetitive prompts · unattended`.
   - IDE box `.box-copilot`: `.frame-title` `Employee IDE — VS Code + GitHub Copilot`, `.lbl-muted` `L5 · Vibe Coding · NOT a LiteLLM backend`, `.lbl-muted` `1:1 accounts · human-interactive only`.
   - Arrows: apps → gateway labelled `virtual key` (`.arrow-normal`); jobs → gateway labelled `batch key` (`.arrow-normal`). The IDE box gets NO arrow into the gateway — it bypasses the pool entirely. Add a short `.arrow-normal` from IDE box straight down to a small `.box-copilot` labelled `GitHub Copilot service` at the far right of band 2.
3. **Band 2 Gateway**: `.box-gateway` titled `LiteLLM API Gateway on AKS`, with two columns of `.lbl` bullets: left column `auth · virtual keys · teams`, `model_name isolation (5 groups)`, `routing: simple-shuffle + weighted failover`; right column `retry · cooldown · fallback chains`, `full request/response logging`, `cost, budget and quota governance`. Adjacent `.box-ops` titled `Shared state and operations plane` with `.lbl` lines `Redis — shared router state`, `PostgreSQL — spend and logs`, `Key Vault — endpoint secrets`, `Monitor / Sentinel / Langfuse`.
4. **Band 3 Model names**, header `.layer-tag` `USER-FACING MODEL NAMES`:
   - `.box-name-claude` with `.mono` `claude-opus-4-8-grp{1..5}`, `claude-sonnet-5-grp{1..5}`, `claude-haiku-4-5-grp{1..5}`
   - `.box-name-gpt` with `.mono` `gpt-5.5-grp{1..5}`, `gpt-5.6-terra/sol/luna-grp{1..5}`
   - `.box-name-batch` with `.mono` `batch-gpt-5.5-grp{1..2}`, `batch-gpt-5.6-terra/sol/luna-grp{1..2}`
   - `.box-name-ds` with `.mono` `DeepSeek-V4-Pro-grp1`, `DeepSeek-V4-Flash-grp1`
   - `.box-name-ds` with `.mono` `vertex-claude-opus / -sonnet / -haiku`, plus `.lbl-muted` `fallback target only`
   - Arrows from gateway down into this band, then from this band into band 4.
5. **Band 4 Supply pools**:
   - Claude frame: `.layer-tag` `L1 / L2`, `.frame-title` `Microsoft Foundry — Claude Pool`, `.lbl-muted` `10 subscriptions × 3 endpoints = 30 endpoints · Opus / Sonnet / Haiku`. Five `.band-claude` bands labelled `grp1`…`grp5` (`.band-label`), each containing 2 `.chip-claude` sub boxes. Sub box text: `.mono` `{prefix}-claude-` on one line, `sub01` on the next, `.lbl-muted` `3 ep`. Under the bands: `.lbl-muted` `2 subscriptions per group — a suspended group costs 20% of capacity`.
   - GPT frame: `.layer-tag` `L3`, `.frame-title` `Microsoft Foundry — GPT Pool`, `.lbl-muted` `5 subscriptions × 4 endpoints · gpt-5.5 / 5.6-terra / 5.6-sol / 5.6-luna`. Five `.band-gpt` bands labelled `grp1`…`grp5` (`.band-label-gpt`), one `.chip-gpt` each, text `.mono` `{prefix}-gpt-`, `sub01`…`sub05`, `.lbl-muted` `4 ep`.
   - Batch frame: `.frame-title` `Batch Pool (isolated)`, `.lbl-muted` `2 dedicated subscriptions`. Two `.band-batch` bands labelled `bgrp1`/`bgrp2` (`.band-label-batch`), one `.chip-batch` each with `.mono` `{prefix}-gpt-`, `sub06`/`sub07`, `.lbl-muted` `4 ep`.
   - DeepSeek frame: `.frame-title` `DeepSeek Pool`, `.lbl-muted` `1 subscription × 2 endpoints`, one `.chip-gpt`-styled box reusing `.box-name-ds` with `.mono` `{prefix}-deepseek-sub01`, `.lbl-muted` `grp1 · 2 ep`.
   - Vertex frame `.box-vertex`: `.layer-tag` `L4`, `.frame-title` `Partner Vertex AI — Claude`, `.lbl` `Cross-cloud backup channel`, `.lbl-muted` `Separate provider, billing and SLA`, `.lbl-muted` `First fallback for every Claude group`. Draw a `.arrow-fallback` from the Claude frame to this frame labelled `fallback ①`, and a `.arrow-fallback` from Claude frame to GPT frame labelled `fallback ②`.
6. **Legend**: small swatches with labels `Claude supply`, `GPT supply`, `Batch (isolated)`, `DeepSeek / Vertex backup`, `Gateway`, `Consumers`, plus a dashed-line sample labelled `fallback path` and a dashed-border sample labelled `outside the API pool`.
7. **Footnote** (`.lbl-muted`): `Region eastus2 · SKU GlobalStandard · one Foundry account per subscription: fdry-{subscription_name} / proj-{subscription_name} · names are placeholders`.

- [ ] **Step 4: Run tests to verify they pass**

```bash
scripts/check-svg.sh assets/architecture-overview.svg
~/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome --headless --disable-gpu --no-sandbox \
  --hide-scrollbars --force-device-scale-factor=1 \
  --screenshot=/tmp/ovw-full.png --window-size=1480,1080 \
  "file://$PWD/assets/architecture-overview.svg"
~/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome --headless --disable-gpu --no-sandbox \
  --hide-scrollbars --force-device-scale-factor=1 \
  --screenshot=/tmp/ovw-small.png --window-size=800,584 \
  "file://$PWD/assets/architecture-overview.svg"
```
Expected: `SVG check passed`, both PNGs written. **Read both PNGs with the Read tool** and confirm: all 18 subscription boxes present and non-overlapping, group bands visibly enclose their members, no text spills outside any box or frame, every arrow lands on a target, the Copilot lane clearly has no arrow into the gateway, and band/frame titles stay legible in `/tmp/ovw-small.png`. Fix and re-render until clean.

- [ ] **Step 5: Commit**

```bash
git add assets/architecture-overview.svg
git commit -m "Add layered supply overview architecture diagram"
```

---

### Task 4: Document integration and rubber-duck verification

**Files:**
- Modify: `llm-api-pool-solution.md` — §4.2.1 (after the 隔离效果 table, before 配套配置示例见…) and §5 (after the `## 5. 目标架构` heading, wrapping the existing `text` block at lines 178-211)
- Modify: `README.md` — 方案文件 list
- Modify: `CLAUDE.md` — Project Summary supporting-artifacts sentence
- Modify: `AGENTS.md` — equivalent supporting-artifacts sentence

**Interfaces:**
- Consumes: `assets/architecture-overview.svg` (Task 3), `assets/architecture-isolation-fallback.svg` (Task 2).
- Produces: final delivered state; no downstream tasks.

- [ ] **Step 1: Write the failing test**

The test is that both images are referenced from the doc and every referenced path exists. Write this check:

```bash
python3 - <<'PY'
import pathlib, re, sys
doc = pathlib.Path("llm-api-pool-solution.md").read_text(encoding="utf-8")
refs = re.findall(r'!\[[^\]]*\]\(([^)]+)\)', doc)
expected = {
    "assets/architecture-overview.svg",
    "assets/architecture-isolation-fallback.svg",
}
missing_ref = expected - set(refs)
missing_file = {r for r in refs if not pathlib.Path(r).is_file()}
if missing_ref:
    print("NOT REFERENCED:", sorted(missing_ref)); sys.exit(1)
if missing_file:
    print("REFERENCED BUT ABSENT:", sorted(missing_file)); sys.exit(1)
print("doc image references OK")
PY
```

- [ ] **Step 2: Run test to verify it fails**

Run the block above.
Expected: FAIL printing `NOT REFERENCED: ['assets/architecture-isolation-fallback.svg', 'assets/architecture-overview.svg']`

- [ ] **Step 3: Write minimal implementation**

In §4.2.1, insert immediately before the line `配套配置示例见 [config/litellm-config.example.yaml]...`:

```markdown
下图对比无隔离与 5 组隔离下的故障影响范围，并给出受影响组的 fallback 优先级（图中文字为英文以避免字形缺失导致的显示问题）：

![model_name isolation and fallback order](assets/architecture-isolation-fallback.svg)
```

In §5, replace the opening of the section so the SVG leads and the ASCII block becomes a collapsible text fallback. Insert these five lines directly after the `## 5. 目标架构` heading:

```markdown
下图为整体目标架构（图中文字为英文以避免字形缺失导致的显示问题）：

![LiteLLM gateway and multi-subscription Azure Foundry supply pools](assets/architecture-overview.svg)

<details>
<summary>纯文本等价描述（便于终端查看与文本检索）</summary>
```

Then leave the existing ` ```text ` fenced ASCII block (currently lines 178-211) exactly as it is — do not retype or reflow it. Immediately after that block's closing fence, insert a blank line followed by:

```markdown
</details>
```

Keep the existing 运维平面建议 paragraph after the `</details>`. Note: the `<summary>` line must be followed by a blank line before the fence, otherwise GitHub will not render the fenced block inside the collapsed section.

In `README.md` 方案文件 list, append two entries:

```markdown
9. `assets/architecture-overview.svg`：整体架构图（LiteLLM 网关 + 多订阅 Foundry 供应池）。
10. `assets/architecture-isolation-fallback.svg`：model_name 分组隔离与 fallback 顺序图。
```

In `CLAUDE.md`, extend the supporting-artifacts sentence in Project Summary with:

```markdown
`assets/architecture-overview.svg` and `assets/architecture-isolation-fallback.svg` (architecture diagrams — English text only, must stay consistent with §4.2.1 and §5; validate with `scripts/check-svg.sh`)
```

Apply the equivalent addition to `AGENTS.md`.

- [ ] **Step 4: Run tests to verify they pass**

```bash
python3 - <<'PY'
import pathlib, re, sys
doc = pathlib.Path("llm-api-pool-solution.md").read_text(encoding="utf-8")
refs = re.findall(r'!\[[^\]]*\]\(([^)]+)\)', doc)
expected = {"assets/architecture-overview.svg", "assets/architecture-isolation-fallback.svg"}
assert not (expected - set(refs)), sorted(expected - set(refs))
assert all(pathlib.Path(r).is_file() for r in refs)
print("doc image references OK")
PY
scripts/check-svg.sh
grep -c "<details>" llm-api-pool-solution.md
```
Expected: `doc image references OK`, `SVG check passed`, and the `<details>` count is at least 1.

Then run the **rubber-duck comparison** required by `todo.md`. Re-read §3 capacity table, §4.2.1, §4.3, §4.4, §4.6, §6.1 table, and `config/litellm-config.example.yaml` `fallbacks:` block, and verify against the two rendered PNGs:

| Claim in diagram | Must match |
| --- | --- |
| 10 Claude subs / 3 endpoints each | §3 item 2A, §6.1 |
| 5 GPT interactive subs / 4 endpoints | §3 item 2B, §3 litellm item 2 |
| 2 batch subs, `batch-*` groups | §3 litellm item 3, §4.6 |
| 1 DeepSeek sub / 2 endpoints | §3 item 2C, §3 litellm item 4 |
| `claude-opus-4-8` / `claude-sonnet-5` / `claude-haiku-4-5` | §7.2 table |
| `gpt-5.5` / `gpt-5.6-terra` / `gpt-5.6-sol` / `gpt-5.6-luna` | §7.2 table |
| fallback ① same group → ② vertex → ③ gpt | config `fallbacks:`, §6.2 item 8 |
| never cross-group | §4.2.1 容灾与降级 item 2, §6.2 item 8 |
| `fdry-{sub}` / `proj-{sub}`, eastus2, GlobalStandard | §7.1, §3 item 2 |
| Copilot outside the pool | §4.5 |

Fix any mismatch in the SVG, re-run `scripts/check-svg.sh`, re-render, and re-read the PNG before continuing.

- [ ] **Step 5: Commit**

```bash
git add llm-api-pool-solution.md README.md CLAUDE.md AGENTS.md
git commit -m "Embed architecture diagrams in solution doc and file lists"
```

---

## Self-Review Notes

Spec coverage check against `docs/superpowers/specs/2026-08-02-architecture-svg-design.md`:

- §2 deliverables → Tasks 2, 3 (files), Task 4 (all four doc edits)
- §3 technical constraints → Global Constraints + Task 1 forbidden-construct grep
- §4 overview design, all five bands → Task 3 step 3 items 2-7
- §5 isolation design, both panels + ladder + footer → Task 2 step 3 items 2-5
- §6 visual system, palette + structural rules → Global Constraints + the `<style>` blocks in Tasks 2 and 3
- §7 validation gates 1 and 2 → `scripts/check-svg.sh` (Task 1), invoked in Tasks 2, 3, 4
- §7 gate 3 render inspection → Task 2 and Task 3 step 4
- §7 gate 4 rubber duck → Task 4 step 4 comparison table
- §8 non-goals → no generator task exists; no script/config behavior changes in any task

Class-name consistency: Task 3 reuses Task 2's `<style>` verbatim and only appends new classes, so `.chip-claude`, `.band-claude`, `.box-vertex`, `.mono`, `.arrow-fallback` and friends carry identical definitions across both files. `.box-vertex` and `.box-gpt` are defined in Task 2 and reused in Task 3 — do not redefine them.
