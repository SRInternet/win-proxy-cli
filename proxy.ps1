$global:_WinProxyCoreScript = Join-Path $PSScriptRoot "proxy_core.ps1"

function proxy {
    if (-not (Test-Path $global:_WinProxyCoreScript)) {
        Write-Host "[错误] 未找到核心脚本: $global:_WinProxyCoreScript" -ForegroundColor Red
        return
    }
    $env:_PROXY_SHELL = "pwsh"
    $__WinProxyCliArgs = @($args)
    try {
        & $global:_WinProxyCoreScript
    } finally {
        Remove-Item Env:_PROXY_SHELL -ErrorAction SilentlyContinue
    }
}