#!/usr/bin/env bash
# T3（前置关系推断）/ T4（深度补前置）工作流冒烟脚本
#
# 前置条件（必须先在 Dify 控制台做完）：
#   1) 控制台 → DSL 导入 → 选 scripts/dify_t3_prerequisite.yaml   → 发布 → 拿到 App API Key
#   2) 控制台 → DSL 导入 → 选 scripts/dify_t4_gap_analysis.yaml   → 发布 → 拿到 App API Key
#   3) 导入后务必核对 start/end 变量名（见 docs/WORKFLOW_T3_T4_GUIDE.md §4）
#
# 用法：
#   export DIFY_T3_API_KEY=app-xxxxxxxxxxxx
#   export DIFY_T4_API_KEY=app-yyyyyyyyyyyy
#   bash scripts/test_dify_t3_t4.sh
#
# 说明：
#   - Dify /v1/workflows/run 必填 user 字段（本项目已知坑 #1），缺失会报错。
#   - 推理模型（DeepSeek-R1 / Qwen 等）会在 JSON 前加 <think>...</think>，
#     脚本会先剥离思考块与 ```json 代码块再解析（本项目已知坑 #3）。
#   - T4 校验 level 恒为 1（Dify 只算直接前置一层，递归在客户端 AutoGraphService）。
set -euo pipefail

DIFY_BASE_URL="${DIFY_BASE_URL:-http://localhost:8080}"
DIFY_T3_API_KEY="${DIFY_T3_API_KEY:-app-xxxx替换成T3应用Key}"
DIFY_T4_API_KEY="${DIFY_T4_API_KEY:-app-xxxx替换成T4应用Key}"

# T3 样例输入：三个知识点（含 id/name/type/definition）
T3_POINTS='- id: kp-newton2
  name: 牛顿第二定律
  type: 定理
  definition: 物体加速度与合外力成正比、与质量成反比
- id: kp-force
  name: 力
  type: 概念
  definition: 物体之间的相互作用，能改变物体的运动状态
- id: kp-accel
  name: 加速度
  type: 概念
  definition: 速度随时间的变化率'

# T4 样例输入：单个目标知识点 + depth=medium
T4_TARGET='牛顿第二定律 | 定理 | 物体加速度与合外力成正比、与质量成反比'
T4_DEPTH='medium'

post_run() {
  # $1 = api key, $2 = JSON body
  curl -s -w "\n%{http_code}" -m 120 -X POST "${DIFY_BASE_URL}/v1/workflows/run" \
    -H "Authorization: Bearer $1" \
    -H "Content-Type: application/json" \
    -d "$2"
}

run_case() {
  # $1 = 名称, $2 = api key, $3 = JSON body, $4 = 期望输出字段(prerequisites|gaps)
  local name="$1" key="$2" body="$3" expect="$4"
  echo "=============================================="
  echo "==> ${name}: POST ${DIFY_BASE_URL}/v1/workflows/run"
  local resp http body_out
  resp="$(post_run "$key" "$body")"
  http="$(printf '%s' "$resp" | tail -n1)"
  body_out="$(printf '%s' "$resp" | sed '$d')"
  echo "HTTP ${http}"
  if [ "$http" != "200" ]; then
    echo "BODY: ${body_out}"
    echo "❌ ${name} 调用失败（HTTP ${http}）。检查：应用是否已发布 / Key 是否正确 / 变量名是否匹配。"
    return 1
  fi
  printf '%s' "$body_out" | EXPECT="$expect" NAME="$name" python3 -c '
import sys, json, re, os
expect = os.environ["EXPECT"]       # prerequisites | gaps
name = os.environ["NAME"]
try:
    j = json.load(sys.stdin)
except Exception as e:
    print("❌ 响应不是合法 JSON：", e); sys.exit(3)
# Dify 错误响应形如 {"code": "...", "message": "..."}
if "code" in j and "data" not in j:
    print("❌ Dify 返回错误：", j.get("code"), "-", j.get("message")); sys.exit(3)
outs = j.get("data", {}).get("outputs", {})
val = outs.get(expect)
if val is None:
    print("⚠️ outputs 里没有 %s 字段，outputs = %s" % (expect, outs)); sys.exit(2)
raw = val if isinstance(val, str) else json.dumps(val, ensure_ascii=False)
# 1) 剥离 <think>...</think>（含「未闭合」的情况：推理模型的思考块吃掉 token 预算）
if "<think>" in raw:
    end = raw.find("</think>")
    if end != -1:
        raw = raw[end + len("</think>"):]
    else:
        cand = [i for i in (raw.find("{"), raw.find("[")) if i != -1]
        if cand: raw = raw[min(cand):]
raw = raw.strip()
# 2) 剥离 ```json 代码块
m = re.search(r"```(?:json)?\s*([\s\S]*?)```", raw, flags=re.IGNORECASE)
if m: raw = m.group(1).strip()
# 3) 解析：先整体解析；失败则在文本里扫第一个「能完整解码」的 JSON（忽略前后杂文）。
#    不要用「首 { → 末 }」硬切：模型若在 JSON 前后带说明文字，硬切会把杂文并进来。
def try_load(t):
    try:
        return json.loads(t)
    except Exception:
        return None

def scan_json(t):
    dec = json.JSONDecoder()
    for i, ch in enumerate(t):
        if ch in "{[":
            try:
                obj, _ = dec.raw_decode(t, i)
                return obj
            except Exception:
                continue
    return None

parsed = try_load(raw)
if parsed is None:
    parsed = scan_json(raw)
salvaged = False
if parsed is None:
    # 4) 抢救：输出被截断时截到最后一个完整条目并补上 ]}
    idx = raw.rfind("}")
    cut = raw[:idx + 1] if idx != -1 else raw
    for cand in (cut, cut + "]}", cut + "]", cut + "}"):
        parsed = try_load(cand)
        if parsed is not None:
            raw = cand
            salvaged = True
            break
if parsed is None:
    try:
        json.loads(raw)
    except Exception as e:
        print("❌ JSON 解析失败：", e)
    print("RAW HEAD:", repr(raw[:200]))
    print("RAW TAIL:", repr(raw[-200:]))
    sys.exit(3)
if salvaged:
    print("⚠️ 输出被截断，已抢救到最后一个完整条目 —— 建议调高 Dify LLM 节点的 max_tokens")
items = parsed.get(expect, [])
print("✅ %s 成功，条数 = %d" % (name, len(items)))
bad = []
required = ["from", "to", "reason"] if expect == "prerequisites" else ["name", "definition", "reason", "level"]
for it in items:
    miss = [k for k in required if k not in it]
    if miss: bad.append((it.get("name") or it.get("from"), miss))
    if expect == "gaps" and it.get("level", 1) != 1:
        bad.append((it.get("name"), ["level != 1（Dify 只应返回直接前置）"]))
if bad:
    print("⚠️ 字段不完整/层级异常：", bad); sys.exit(4)
print(json.dumps(items[:3], ensure_ascii=False, indent=2))
'
}

run_case "T3 前置关系推断" "${DIFY_T3_API_KEY}" \
  "$(printf '{"inputs":{"points":%s},"response_mode":"blocking","user":"aimindtree-test"}' \
      "$(printf '%s' "${T3_POINTS}" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')")" \
  "prerequisites"

run_case "T4 深度补前置" "${DIFY_T4_API_KEY}" \
  "$(printf '{"inputs":{"target":%s,"depth":%s,"depth_instruction":""},"response_mode":"blocking","user":"aimindtree-test"}' \
      "$(printf '%s' "${T4_TARGET}" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')" \
      "\"${T4_DEPTH}\"")" \
  "gaps"

echo "=============================================="
echo "全部冒烟用例执行完毕。"
