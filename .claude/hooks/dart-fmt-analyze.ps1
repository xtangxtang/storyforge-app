# PostToolUse hook: 对刚编辑过的 .dart 文件自动执行 dart format + dart analyze。
# - format 静默修复风格
# - analyze 若发现 warning/error,以 exit 2 把问题反馈给 Claude 处理(info 级 lint 默认不阻断)
$ErrorActionPreference = 'SilentlyContinue'

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }

$file = $payload.tool_input.file_path
if (-not $file) { exit 0 }
if ($file -notlike '*.dart') { exit 0 }
if (-not (Test-Path $file)) { exit 0 }

# 1) 静默格式化
& dart format $file | Out-Null

# 2) 静态分析;dart analyze 默认 warning/error 退出码非 0,info 不算
$analysis = & dart analyze $file 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("dart analyze 在 $file 发现问题,请修复:")
    [Console]::Error.WriteLine($analysis)
    exit 2
}
exit 0
