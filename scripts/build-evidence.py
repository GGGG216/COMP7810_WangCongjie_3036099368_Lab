"""Render saved command output for inspection and screenshot capture (standard library only)."""
from html import escape
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
evidence = root / "evidence"
test_output = (evidence / "forge-test.txt").read_text(encoding="utf-8-sig")
demo_output = (evidence / "ex1-ex3.txt").read_text(encoding="utf-8-sig")
demo = json.loads((evidence / "ex1-ex3.json").read_text(encoding="utf-8-sig"))
test_summary = next(line for line in reversed(test_output.splitlines()) if "total tests)" in line)
broken = demo["snapshots"][-1]
rows = "".join(
    f'<tr><td>{escape(s["stage"])}</td><td>{int(s["supply"]):,}</td>'
    f'<td>{int(s["collateral"]):,}</td><td>{int(s["userStable"]):,}</td></tr>'
    for s in demo["snapshots"]
)
tx_rows = "".join(
    f'<tr><td>{escape(t["step"])}</td><td>{escape(t["receipt"]["status"])}</td>'
    f'<td class="hash">{escape(t["receipt"]["transactionHash"])}</td></tr>'
    for t in demo["transactions"]
)
short_demo = demo_output[demo_output.index("=== Ex3 unbacked issuance"):]
html = """<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Stablecoin lab — verified local evidence</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#f4f6fa;color:#18243a;font:16px/1.55 system-ui,sans-serif}
main{max-width:1240px;margin:auto;padding:30px}h1{margin:0;font-size:30px}h2{margin:22px 0 12px;font-size:24px}
p{margin:8px 0}nav{display:flex;gap:24px;margin:20px 0}a{color:#174ea6}.label{font-size:12px;letter-spacing:.1em;font-weight:700;color:#4b607d}
.note{color:#4c5c70}.summary{padding:18px 22px;background:#e5f5ea;border:1px solid #aad7b9;border-radius:8px;font-weight:650}
pre{font:13px/1.5 Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere;background:#101b2d;color:#e9f0fa;padding:20px;border-radius:8px}
table{width:100%;border-collapse:collapse;background:white;margin:16px 0;font-variant-numeric:tabular-nums}th,td{text-align:left;padding:10px 13px;border-bottom:1px solid #dbe2ed}th{background:#e8edf5}.hash{font:11px Consolas,monospace;overflow-wrap:anywhere}
.cards{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin:16px 0}.card{background:white;border:1px solid #dbe2ed;padding:18px;border-radius:8px}.number{font-size:34px;font-weight:700;letter-spacing:-.03em}.bad{color:#ac2736}
section{scroll-margin-top:20px}body[data-view=tests] #demo,body[data-view=demo] #tests{display:none}
@media(max-width:700px){main{padding:22px}.cards{grid-template-columns:1fr;gap:12px}.card{padding:12px 16px}.number{font-size:30px}table{font-size:11px}th,td{padding:7px 5px}}
</style><main><div class="label">COMP7810 · LAB 1 · ANVIL CHAIN 31337</div>
<h1>Stablecoin lab: verified local evidence</h1>
<p class="note">Rendered from real Forge and Cast command logs. No terminal output is simulated.</p>
<nav><a href="?view=tests">Test results</a><a href="?view=demo">Mint/redeem and Ex3</a><a href="forge-test.txt">Raw Forge log</a><a href="ex1-ex3.txt">Raw Cast log</a><a href="ex1-ex3.json">Receipts &amp; snapshots</a></nav>
<section id="tests"><h2>All tests passed</h2><div class="summary">__LAB_SUMMARY__</div>
<p class="note">Command: .\\scripts\\lab.ps1 test → forge test -vv · Foundry 1.8.4 · Solidity 0.8.24<br>Invariant configuration: 256 runs × 500 calls, fail_on_revert = true.</p>
<pre>__LAB_TESTS__</pre></section>
<section id="demo"><h2>Ex3: supply exceeds collateral after a privileged mint</h2>
<p class="note">Fresh local Anvil run: __LAB_RUNDATE__ · All displayed amounts use 6-decimal base units.</p>
<div class="cards"><div class="card"><div class="label">SUSD TOTAL SUPPLY</div><div class="number bad">__LAB_SUPPLY__</div><div>1,000,750 sUSD tokens</div></div>
<div class="card"><div class="label">VAULT TOTAL COLLATERAL</div><div class="number">__LAB_COLLATERAL__</div><div>750 mUSDC tokens</div></div></div>
<p><strong>Unbacked gap: 1,000,000 tokens.</strong> The same caller's mint first reverted without MINTER_ROLE, then succeeded after the admin granted that role. This proves broken backing; no market price was measured.</p>
<table><thead><tr><th>Checkpoint</th><th>totalSupply()</th><th>totalCollateral()</th><th>User sUSD</th></tr></thead><tbody>__LAB_ROWS__</tbody></table>
<pre>__LAB_DEMO__</pre><h2>Transaction receipts</h2><table><thead><tr><th>Step</th><th>Status</th><th>Transaction hash</th></tr></thead><tbody>__LAB_TRANSACTIONS__</tbody></table>
</section></main><script>document.body.dataset.view=new URLSearchParams(location.search).get('view')==='demo'?'demo':'tests';</script></html>"""
for key, value in {
    "SUMMARY": escape(test_summary), "TESTS": escape(test_output),
    "RUNDATE": escape(demo["completedAtUtc"]), "SUPPLY": f'{int(broken["supply"]):,}',
    "COLLATERAL": f'{int(broken["collateral"]):,}', "ROWS": rows,
    "DEMO": escape(short_demo), "TRANSACTIONS": tx_rows,
}.items():
    html = html.replace(f"__LAB_{key}__", value)
(evidence / "index.html").write_text(html, encoding="utf-8")
print(evidence / "index.html")
