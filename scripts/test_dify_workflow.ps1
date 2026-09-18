# Dify 知识点提取工作流 验证脚本 (PowerShell)
# 用法：
#   1) 在 Dify 控制台创建 Workflow 应用、按 docs/DIFY_KNOWLEDGE_WORKFLOW.md 配置、发布、拿到 API Key
#   2) 把下面的 $DIFY_API_KEY 换成你的 Key（或 $env:DIFY_API_KEY="..." 后运行）
#   3) pwsh scripts/test_dify_workflow.ps1
$ErrorActionPreference = "Stop"

$DIFY_BASE_URL = if ($env:DIFY_BASE_URL) { $env:DIFY_BASE_URL } else { "http://localhost:8080" }
$DIFY_API_KEY  = if ($env:DIFY_API_KEY)  { $env:DIFY_API_KEY }  else { "app-xxxx替换成你的Dify应用Key" }

$noteText = if ($env:NOTE_TEXT) { $env:NOTE_TEXT } else {
  "牛顿第一定律：任何物体都要保持匀速直线运动或静止状态，直到外力迫使它改变运动状态为止。它说明了惯性的概念，是经典力学的基础。"
}

$body = @{
  inputs         = @{ note_text = $noteText }
  response_mode = "blocking"
  user          = "aimindtree-test"
} | ConvertTo-Json -Compress

Write-Host "==> POST $DIFY_BASE_URL/v1/workflows/run"
try {
  $resp = Invoke-RestMethod -Uri "$DIFY_BASE_URL/v1/workflows/run" `
    -Method Post -ContentType "application/json" `
    -Headers @{ Authorization = "Bearer $DIFY_API_KEY" } `
    -Body $body
} catch {
  Write-Host "❌ 调用失败：$_"
  if ($_.Exception.Response) {
    $code = [int]$_.Exception.Response.StatusCode
    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
    Write-Host "HTTP $code  BODY: $($reader.ReadToEnd())"
  }
  exit 1
}

$outs = $resp.data.outputs
$kp = $outs.knowledge_points
if ($null -eq $kp) {
  Write-Host "⚠️ outputs 里没有 knowledge_points 字段，outputs = $($outs | ConvertTo-Json -Compress)"
  exit 2
}

# knowledge_points 可能是 JSON 字符串，也可能是对象
$parsed = if ($kp -is [string]) { $kp | ConvertFrom-Json } else { $kp }
$count = if ($parsed.PSObject.Properties['knowledge_points']) { $parsed.knowledge_points.Count } else { 1 }

Write-Host "✅ 知识点提取成功，条数 = $count"
Write-Host ($parsed | ConvertTo-Json -Depth 5 -Compress).Substring(0, [Math]::Min(800, ($parsed | ConvertTo-Json -Depth 5).Length))
