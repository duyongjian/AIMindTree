#!/usr/bin/env bash
# ============================================================================
#  AIMindTree 同步中继 · Netlify 一键部署（设环境变量 → 推生产 → 冒烟验证）
#
#  为什么需要这个脚本：
#    M11 管理面板走中继的 /admin/* 接口，而该组接口只在配置了 ADMIN_TOKEN
#    时才存在（未配置一律 404，端点整体不可见）。同时 netlify.toml 里的
#    /admin/* rewrite 要重新部署才生效。**两步顺序不能反**：先 env:set，再
#    deploy —— 反了就会部署出一个「函数读不到令牌」的版本。
#
#  用法（在 Git Bash 里执行，必须在 sync_relay_netlify 目录内，
#  因为 CLI 靠 .netlify/state.json 的 link 认站点；本机 CLI 17.0.0 的
#  env:set / env:list / deploy 都不接受 --site 参数）：
#      cd sync_relay_netlify
#      ./deploy.sh                          # 复用已登录的 CLI 会话
#      NETLIFY_AUTH_TOKEN=xxx ./deploy.sh   # 或用令牌免登录
#
#  密钥来源（脚本本身不含任何令牌，可安全入库）：
#      1) 环境变量 ADMIN_TOKEN / NETLIFY_BLOBS_TOKEN
#      2) 项目内 .workbuddy/backups/netlify_deploy.env（已 gitignore）
#      3) 交互式输入（不回显）—— 仅在该变量站点里也还没有时才问
#
#  两个变量分别是什么：
#      ADMIN_TOKEN          —— 我们自建的中继管理令牌，M11 面板用它调 /admin/*
#      NETLIFY_BLOBS_TOKEN  —— Netlify Personal Access Token，函数访问 Blobs 必需
#                              （User settings → Applications → Personal access tokens）
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

SITE_URL="https://aimindtree-sync-relay.netlify.app"
ENV_FILE="../.workbuddy/backups/netlify_deploy.env"

info() { printf '%s\n' "$*"; }
fail() { printf '\n✗ %s\n' "$*" >&2; exit 1; }

# --- 0) 载入被 gitignore 的密钥文件（若存在） -------------------------------
if [ -f "$ENV_FILE" ]; then
  echo "· 读取密钥文件 $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

# --- 1) CLI（本地 17.0.0 优先；未装则临时用 npx） ---------------------------
CLI="./node_modules/.bin/netlify"
if [ -x "$CLI" ]; then
  info "· 使用本地 CLI：$CLI ($("$CLI" --version 2>/dev/null | tail -1))"
else
  info "· 本地未装 netlify-cli，改用 npx（首次会下载，稍慢）"
  CLI="npx --yes netlify-cli@17.0.0"
fi

# --- 2) 认证检查 ------------------------------------------------------------
if [ -n "${NETLIFY_AUTH_TOKEN:-}" ]; then
  info "· 使用 NETLIFY_AUTH_TOKEN 认证"
elif $CLI status >/dev/null 2>&1; then
  info "· 使用已登录的 CLI 会话"
else
  fail "未登录。二选一：
    a) 先执行登录（会开浏览器授权）：$CLI login
    b) 或者带令牌重跑：NETLIFY_AUTH_TOKEN=<你的 PAT> ./deploy.sh"
fi

# --- 3) 读站点现有变量名（production context） ------------------------------
# 注意：不带 --context 时 env:list 会漏掉 production 变量，必须显式指定。
EXISTING="$($CLI env:list --context production --json 2>/dev/null || true)"
has_var() { printf '%s' "$EXISTING" | grep -q "\"$1\""; }

# --- 4) ADMIN_TOKEN：站点没有才要（有则默认覆盖成当前值，便于轮换） --------
if [ -z "${ADMIN_TOKEN:-}" ] && ! has_var ADMIN_TOKEN; then
  info ""
  info "ADMIN_TOKEN —— M11 面板调用 /admin/* 用的中继管理令牌（Cloudflare 与 Netlify 共用同一枚）"
  printf '  粘贴后回车（不回显）：'
  IFS= read -r -s ADMIN_TOKEN
  printf '\n'
  [ -n "$ADMIN_TOKEN" ] || fail "ADMIN_TOKEN 不能为空"
fi

# --- 5) NETLIFY_BLOBS_TOKEN：站点已有就完全不碰（避免冲掉历史值） ----------
if ! has_var NETLIFY_BLOBS_TOKEN; then
  if [ -z "${NETLIFY_BLOBS_TOKEN:-}" ]; then
    info ""
    info "NETLIFY_BLOBS_TOKEN —— Netlify Personal Access Token（函数访问 Blobs 必需）"
    info "  取法：Netlify → User settings → Applications → Personal access tokens"
    printf '  粘贴后回车（不回显）：'
    IFS= read -r -s NETLIFY_BLOBS_TOKEN
    printf '\n'
    [ -n "$NETLIFY_BLOBS_TOKEN" ] || fail "NETLIFY_BLOBS_TOKEN 不能为空"
  fi
else
  info "· NETLIFY_BLOBS_TOKEN 站点已存在，保持原值（要换请先 env:unset 再重跑）"
fi

# --- 6) 先写环境变量（顺序关键：env 必须在 deploy 之前） --------------------
info ""
info "· 写入生产环境变量（--context production）"
if [ -n "${ADMIN_TOKEN:-}" ]; then
  $CLI env:set ADMIN_TOKEN "$ADMIN_TOKEN" --context production >/dev/null
  info "  ✓ ADMIN_TOKEN"
else
  info "  · ADMIN_TOKEN 站点已存在且本次未提供新值，保持不变"
fi
if [ -n "${NETLIFY_BLOBS_TOKEN:-}" ] && ! has_var NETLIFY_BLOBS_TOKEN; then
  $CLI env:set NETLIFY_BLOBS_TOKEN "$NETLIFY_BLOBS_TOKEN" --context production >/dev/null
  info "  ✓ NETLIFY_BLOBS_TOKEN（新建）"
fi

# --- 7) 部署到生产 ----------------------------------------------------------
# 不带 --dir/--functions：netlify.toml 已声明 publish 与 functions，交给它更不易漂移。
info ""
info "· 部署到生产（含 /admin/* rewrite 与 DELETE 预检头）"
$CLI deploy --prod

# --- 8) 冒烟验证 ------------------------------------------------------------
if [ -z "${ADMIN_TOKEN:-}" ]; then
  info ""
  info "· 本次未提供 ADMIN_TOKEN，跳过 /admin/ping 冒烟（站点已有变量时请手动验证）"
  exit 0
fi
info ""
info "· 冒烟验证 $SITE_URL/admin/ping"
code=$(curl -s -o /tmp/aimt_ping.json -w '%{http_code}' \
  -H "Authorization: Bearer $ADMIN_TOKEN" "$SITE_URL/admin/ping" || true)
if [ "$code" = "200" ]; then
  info "  ✓ HTTP 200：$(head -c 200 /tmp/aimt_ping.json)"
  info ""
  info "完成。本地管理后台 M11 →「云端同步」→ 后端选 netlify → 点「测试连接」。"
  info "注意：netlify 免代理可达，M11 里「出站代理」请留空。"
else
  fail "冒烟失败（HTTP $code）。常见原因：
    · 部署刚完成，边缘还没生效（等 30 秒再试）
    · ADMIN_TOKEN 没写进生产环境（上一步失败）
    · NETLIFY_BLOBS_TOKEN 缺失 → 函数每请求 500，响应里会直接说明"
fi
