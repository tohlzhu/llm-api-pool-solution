# SVG check fixtures

These fixtures exercise `scripts/check-svg.sh`. Each malformed/forbidden fixture
is a minimal SVG that asserts exactly one specific rejection reason; `good.svg`
is a minimal SVG that must pass all checks.

| File | Asserts |
|---|---|
| `malformed.svg` | Not well-formed XML (unclosed `<rect>` tag) — rejected by the well-formedness check. |
| `forbidden-script.svg` | Contains a `<script>` element — rejected by the forbidden-construct check. |
| `forbidden-foreignobject.svg` | Contains a `<foreignObject>` element — rejected by the forbidden-construct check. |
| `forbidden-xlink.svg` | Declares the `xlink` namespace and uses `xlink:href` (a `<use>` reference) — rejected by the forbidden-construct check. |
| `forbidden-external-url.svg` | Contains an `http(s)://` URL (in an XML comment) other than the SVG/xlink namespace declarations — rejected by the forbidden-construct check. |
| `forbidden-font-import.svg` | Contains an `@font-face` rule inside `<style>` — rejected by the forbidden-construct check. |
| `good.svg` | A minimal, well-formed SVG with none of the forbidden constructs — must be accepted. |

## Commands

```bash
# every forbidden/malformed fixture must be rejected
for f in tests/fixtures/malformed.svg tests/fixtures/forbidden-*.svg; do
  bash scripts/check-svg.sh "$f" && echo "UNEXPECTED PASS: $f"
done

# the good fixture must be accepted
bash scripts/check-svg.sh tests/fixtures/good.svg
```
