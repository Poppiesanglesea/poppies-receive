import json, sys
r = json.loads(sys.stdin.read())
print("integration: %d passed, %d failed" % (r["passed"], r["failed"]))
for f in r["failures"]:
    print(" FAIL", f["n"], f["name"], "--", f["detail"])
sys.exit(1 if r["failed"] else 0)
