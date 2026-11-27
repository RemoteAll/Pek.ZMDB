# Pek.ZMDB 一键回归：格式化检查 → Debug 测试 → ReleaseFast 测试 → 示例
#
# 退出码：0 = 全部通过；1 = 有步骤失败（可直接接 CI）。
# 注意：含中文的 .ps1 必须存为 UTF-8 with BOM（PS 5.1 按 ANSI 读取无 BOM 文件会乱码/语法错误）。

param([switch]$SkipExample)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root

$script:failures = 0

function Invoke-Step {
    param([string]$Name, [string]$Command)

    Write-Host "==> $Name"
    iex $Command
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Write-Host "[FAIL] $Name（exit $code）" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
}

Invoke-Step 'zig fmt --check' 'zig fmt --check build.zig src examples'
Invoke-Step '单元/集成测试（Debug）' 'zig build test'
Invoke-Step '单元/集成测试（ReleaseFast）' 'zig build test -Doptimize=ReleaseFast'
if (-not $SkipExample) {
    Invoke-Step '示例端到端' 'zig build example'
}

Pop-Location

if ($script:failures -gt 0) {
    Write-Host "回归失败：$($script:failures) 个步骤" -ForegroundColor Red
    exit 1
}
Write-Host '回归全部通过' -ForegroundColor Green
exit 0
