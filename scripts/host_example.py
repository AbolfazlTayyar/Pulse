#!/usr/bin/env python3
"""Minimal host: spawn the Lua worker, read its JSON. Standard library only.
Usage: REDIS_HOST=127.0.0.1 python3 scripts/host_example.py BTC,ETH"""
import json, os, pathlib, subprocess, sys

worker = pathlib.Path(__file__).resolve().parent.parent / "market.lua"
env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "REDIS_HOST": os.environ["REDIS_HOST"]}  # explicit, no inherited surprises
env.update({k: os.environ[k] for k in ("REDIS_PORT", "REDIS_PASSWORD", "MARKET_SOURCE") if k in os.environ})
try:  # argument list, no shell involved; cwd="/" because the worker doesn't depend on it
    p = subprocess.run(["lua", str(worker), "fetch", sys.argv[1] if len(sys.argv) > 1 else "BTC,ETH"],
                       env=env, cwd="/", capture_output=True, text=True, timeout=5)  # > DEADLINE_MS (4 s)
except subprocess.TimeoutExpired:
    sys.exit("killed: worker ran past 5 s")
if p.returncode == 3:
    sys.exit("Redis down: " + p.stdout.strip())
body = json.loads(p.stdout)  # exactly one JSON object; logs are on p.stderr
print(f"exit={p.returncode} ok={body['ok']} cache={body.get('meta', {}).get('cache')} code={body.get('code')}")
for item in body.get("items", []):
    print(item["symbol"], item["price"], item["quote"], "(stale)" if item["stale"] else "")
