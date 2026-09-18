#!/usr/bin/env bash
# Dify 知识点提取工作流 验证脚本
# 用法：
#   1) 在 Dify 控制台创建 Workflow 应用、按 docs/DIFY_KNOWLEDGE_WORKFLOW.md 配置、发布、拿到 API Key
#   2) 把下面的 DIFY_API_KEY 换成你的 Key（或 export DIFY_API_KEY=... 再运行）
#   3) bash scripts/test_dify_workflow.sh
set -euo pipefail

DIFY_BASE_URL="${DIFY_BASE_URL:-http://localhost:8080}"
DIFY_API_KEY="${DIFY_API_KEY:-app-xxxx替换成你的Dify应用Key}"

NOTE_TEXT="${NOTE_TEXT:-"牛顿第一定律：任何物体都要保持匀速直线运动或静止状态，直到外力迫使它改变运动状态为止。它说明了惯性的概念，是经典力学的基础。"}"

echo "==> POST ${DIFY_BASE_URL}/v1/workflows/run"
RESP=$(curl -s -w "\n%{http_code}" -X POST "${DIFY_BASE_URL}/v1/workflows/run" \
  -H "Authorization: Bearer ${DIFY_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$(printf '{"inputs":{"note_text":%s},"response_mode":"blocking","user":"aimindtree-test"}' "$(printf '%s' "$NOTE_TEXT" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')")")

HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

echo "HTTP ${HTTP_CODE}"
echo "BODY: ${BODY}"

if [ "$HTTP_CODE" != "200" ]; then
  echo "❌ 调用失败（非 200）"
  exit 1
fi

# 提取 outputs.knowledge_points 并校验是合法 JSON
# 注意：推理模型（DeepSeek-R1 / Qwen 等）会在 JSON 前加 <think>...</think> 思考块，
# 必须先剥离再解析，否则 json.loads 失败。
echo "$BODY" | python3 -c '
import sys, json, re
try:
    j = json.load(sys.stdin)
    outs = j.get("data", {}).get("outputs", {})
    kp = outs.get("knowledge_points")
    if kp is None:
        print("⚠️ outputs 里没有 knowledge_points 字段，outputs =", outs); sys.exit(2)
    raw = kp if isinstance(kp, str) else json.dumps(kp, ensure_ascii=False)
    # 剥离 <think>...</think> 与 ```json 代码块
    raw = re.sub(r"<think>.*?</think>", "", raw, flags=re.DOTALL).strip()
    m = re.search(r"```(?:json)?\s*([\s\S]*?)```", raw, flags=re.IGNORECASE)
    if m: raw = m.group(1).strip()
    s = raw.find("{") if raw.find("{") != -1 else raw.find("[")
    e = raw.rfind("}") if raw.rfind("}") != -1 else raw.rfind("]")
    if s != -1 and e != -1 and e > s: raw = raw[s:e+1]
    parsed = json.loads(raw)
    print("✅ 知识点提取成功，条数 =", len(parsed.get("knowledge_points", [])))
    print(json.dumps(parsed, ensure_ascii=False, indent=2)[:800])
except Exception as e:
    print("❌ 解析失败：", e); sys.exit(3)
'
