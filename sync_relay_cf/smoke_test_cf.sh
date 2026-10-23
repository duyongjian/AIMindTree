#!/usr/bin/env bash
# 方案 B 线上冒烟测试（需本机有互联网）。
# 用法（Git Bash / WSL）：  bash smoke_test_cf.sh
# 或改 BASE 后直接粘贴运行。
set -euo pipefail

BASE="${BASE:-https://aimindtree-sync-relay.tuanx.workers.dev}"
TS="$(date +%s)"
ALICE="alice_${TS}"
BOB="bob_${TS}"
PASS="Str0ng#Passw0rd"

jq_get() { python3 -c "import sys,json;print(json.load(sys.stdin)['$1'])"; }

echo "==> BASE=$BASE"
echo "==> 1. register alice"
REG_A=$(curl -s -X POST "$BASE/auth/register" -H "Content-Type: application/json" \
  -d "{\"username\":\"$ALICE\",\"password\":\"$PASS\"}")
echo "$REG_A"
TOKEN_A=$(echo "$REG_A" | jq_get token)

echo "==> 2. register bob"
REG_B=$(curl -s -X POST "$BASE/auth/register" -H "Content-Type: application/json" \
  -d "{\"username\":\"$BOB\",\"password\":\"$PASS\"}")
echo "$REG_B"
TOKEN_B=$(echo "$REG_B" | jq_get token)

echo "==> 3. dup register (expect 409)"
curl -s -o /dev/null -w "  http=%{http_code}\n" -X POST "$BASE/auth/register" \
  -H "Content-Type: application/json" -d "{\"username\":\"$ALICE\",\"password\":\"$PASS\"}"

echo "==> 4. weak password (expect 400)"
curl -s -o /dev/null -w "  http=%{http_code}\n" -X POST "$BASE/auth/register" \
  -H "Content-Type: application/json" -d '{"username":"weak_x","password":"123"}'

echo "==> 5. push WITHOUT token (expect 401)"
curl -s -o /dev/null -w "  http=%{http_code}\n" -X POST "$BASE/sync/push" \
  -H "Content-Type: application/json" -d '{"device_id":"d1","envelopes":[]}'

echo "==> 6. alice push 2 envelopes"
curl -s -X POST "$BASE/sync/push" -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN_A" \
  -d '{"device_id":"alice-phone","envelopes":[
        {"entity_table":"notes","entity_id":"n1","op":"upsert","payload":{"title":"hello"},"base_version":0,"updated_at":"2026-01-01T00:00:00Z","deleted_at":null},
        {"entity_table":"notes","entity_id":"n2","op":"upsert","payload":{"title":"world"},"base_version":0,"updated_at":"2026-01-01T00:00:01Z","deleted_at":null}
      ]}'
echo

echo "==> 7. alice manifest (expect count=2)"
curl -s "$BASE/sync/manifest" -H "Authorization: Bearer $TOKEN_A"
echo

echo "==> 8. alice pull (expect 2 envelopes)"
curl -s -X POST "$BASE/sync/pull" -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN_A" -d '{"device_id":"alice-phone","since":null}'
echo

echo "==> 9. bob pull (expect 0 envelopes = tenant isolation)"
curl -s -X POST "$BASE/sync/pull" -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN_B" -d '{"device_id":"bob-phone","since":null}'
echo

echo "==> 10. bob login then re-pull (expect 0, token 仍属 bob)"
LOGIN_B=$(curl -s -X POST "$BASE/auth/login" -H "Content-Type: application/json" \
  -d "{\"username\":\"$BOB\",\"password\":\"$PASS\"}")
TOKEN_B2=$(echo "$LOGIN_B" | jq_get token)
curl -s -X POST "$BASE/sync/pull" -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN_B2" -d '{"device_id":"bob-phone","since":null}'
echo

echo "==> DONE. 若 1/2/7/8 正常、3=409、4=400、5=401、9/10=0 条，则线上契约与隔离均通过。"
