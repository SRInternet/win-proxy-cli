# 获取参数：PowerShell 端通过 $__WinProxyCliArgs 传入
if ($env:_PROXY_SHELL -eq "pwsh" -and (Test-Path Variable:__WinProxyCliArgs)) {
    $cliArgs = @($__WinProxyCliArgs)
} else {
    $cliArgs = @($args)
}

$shellType = if ($env:_PROXY_SHELL) { $env:_PROXY_SHELL.ToLower() } else { "cmd" }
$outFile = $env:_PROXY_OUT
$configPath = Join-Path $HOME ".proxy_config.json"
$envNames = @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")
$actions = New-Object System.Collections.Generic.List[string]

function Add-SetProxyEnv([string]$Key, [string]$Val) {
    if ($shellType -eq "pwsh") {
        Set-Item -Path "Env:$Key" -Value $Val
    } elseif ($shellType -eq "bash") {
        $esc = $Val -replace "'", "'\''"
        $actions.Add("export $Key='$esc'")
        $actions.Add("export $($Key.ToLower())='$esc'")
    } else {
        $esc = ($Val -replace '"', '') -replace '%', '%%'
        $actions.Add("set `"$Key=$esc`"")
    }
}

function Add-UnsetProxyEnv([string]$Key) {
    if ($shellType -eq "pwsh") {
        Remove-Item -Path "Env:$Key" -ErrorAction SilentlyContinue
    } elseif ($shellType -eq "bash") {
        $actions.Add("unset $Key $($Key.ToLower())")
    } else {
        $actions.Add("set `"$Key=`"")
    }
}

function Get-SessionCache {
    if ($shellType -eq "pwsh") {
        if ($global:_ProxySessionConfig) { return $global:_ProxySessionConfig }
        return [ordered]@{ http = ""; https = ""; all = "" }
    }
    return [ordered]@{
        http  = if ($env:_PROXY_TMP_HTTP)  { [string]$env:_PROXY_TMP_HTTP }  else { "" }
        https = if ($env:_PROXY_TMP_HTTPS) { [string]$env:_PROXY_TMP_HTTPS } else { "" }
        all   = if ($env:_PROXY_TMP_ALL)   { [string]$env:_PROXY_TMP_ALL }   else { "" }
    }
}

function Add-SetTmpCache([string]$ProtoKey, [string]$Val) {
    if ($shellType -eq "pwsh") {
        if (-not $global:_ProxySessionConfig) {
            $global:_ProxySessionConfig = [ordered]@{ http = ""; https = ""; all = "" }
        }
        $global:_ProxySessionConfig[$ProtoKey] = $Val
    } else {
        $tmpName = "_PROXY_TMP_$($ProtoKey.ToUpper())"
        if ($shellType -eq "bash") {
            $esc = $Val -replace "'", "'\''"
            $actions.Add("export $tmpName='$esc'")
        } else {
            $esc = ($Val -replace '"', '') -replace '%', '%%'
            $actions.Add("set `"$tmpName=$esc`"")
        }
    }
}

function Clear-AllTmpCache {
    if ($shellType -eq "pwsh") {
        $global:_ProxySessionConfig = $null
    } else {
        foreach ($tKey in @("_PROXY_TMP_HTTP", "_PROXY_TMP_HTTPS", "_PROXY_TMP_ALL")) {
            if ($shellType -eq "bash") {
                $actions.Add("unset $tKey")
            } else {
                $actions.Add("set `"$tKey=`"")
            }
        }
    }
}

function Flush-Actions {
    if ($shellType -ne "pwsh" -and $outFile -and $actions.Count -gt 0) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        if ($shellType -eq "bash") {
            $content = ($actions -join "`n") + "`n"
        } else {
            $content = "@echo off`r`n" + ($actions -join "`r`n") + "`r`n"
        }
        [System.IO.File]::WriteAllText($outFile, $content, $utf8NoBom)
    }
}

function Show-Help {
    Write-Host @"
用法:
  proxy on                                          检测代理连通性并在当前终端开启
  proxy off                                         关闭当前终端的代理
  proxy set [--all|-a|--http|--https] <URL> [--global]
                                                    设置代理地址 (默认等效于 --all)
                                                    加 --global 会同时写入预设及 Windows 全局环境变量
  proxy show                                        查看当前终端、临时缓存、预设及全局代理配置
  proxy clear | remove                              清空所有代理配置并关闭当前代理

示例:
  proxy set -a http://127.0.0.1:7890
  proxy set --http http://127.0.0.1:7890 --https http://127.0.0.1:7891 --global
  proxy on
"@ -ForegroundColor Cyan
}

function Get-ProxyConfig([string]$Path) {
    $cfg = [ordered]@{ http = ""; https = ""; all = "" }
    if (Test-Path $Path) {
        try {
            $raw = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($raw.http)  { $cfg.http  = [string]$raw.http }
            if ($raw.https) { $cfg.https = [string]$raw.https }
            if ($raw.all)   { $cfg.all   = [string]$raw.all }
        } catch {}
    }
    return $cfg
}

function Save-ProxyConfig([string]$Path, $Cfg) {
    $Cfg | ConvertTo-Json | Set-Content -Path $Path -Encoding UTF8
}

function Normalize-ProxyUrl([string]$Url) {
    $Url = $Url.Trim()
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    if ($Url -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $Url = "http://$Url"
    }
    try {
        $uri = [System.Uri]$Url
        if (-not $uri.Host -or $uri.Port -le 0) { return $null }
        return $Url
    } catch {
        return $null
    }
}

function Test-ProxyConnection([string]$ProxyUrl, [int]$TimeoutMs = 1500) {
    $client = $null
    try {
        $uri = [System.Uri]$ProxyUrl
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($uri.Host, $uri.Port, $null, $null)
        $wait = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($wait -and $client.Connected) {
            $client.EndConnect($async)
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        if ($client) { $client.Close() }
    }
}

try {
    if ($cliArgs.Count -eq 0) {
        Show-Help
        return
    }

    $cmd = $cliArgs[0].ToLower()

    switch ($cmd) {
        "on" {
            $targets = [ordered]@{}

            # 1. 读当前终端临时缓存
            $sc = Get-SessionCache
            if ($sc.http)  { $targets["HTTP_PROXY"]  = $sc.http }
            if ($sc.https) { $targets["HTTPS_PROXY"] = $sc.https }
            if ($sc.all)   { $targets["ALL_PROXY"]   = $sc.all }

            # 2. 读全局预设文件 (.proxy_config.json)
            if ($targets.Count -eq 0) {
                $cfg = Get-ProxyConfig $configPath
                if ($cfg.http)  { $targets["HTTP_PROXY"]  = $cfg.http }
                if ($cfg.https) { $targets["HTTPS_PROXY"] = $cfg.https }
                if ($cfg.all)   { $targets["ALL_PROXY"]   = $cfg.all }
            }

            # 3. 读当前终端环境变量
            if ($targets.Count -eq 0) {
                foreach ($name in $envNames) {
                    $v = (Get-Item -Path "Env:$name" -ErrorAction SilentlyContinue).Value
                    if ($v) { $targets[$name] = $v }
                }
            }

            if ($targets.Count -eq 0) {
                Write-Host "[提示] 尚未配置任何代理链接，请先设置代理地址。输入 proxy help 以查看帮助和示例。" -ForegroundColor Yellow
                return
            }

            $checked = @{}
            foreach ($entry in $targets.GetEnumerator()) {
                $url = $entry.Value
                if (-not $checked.ContainsKey($url)) {
                    Write-Host "正在检测代理连通性: $url ... " -NoNewline
                    $ok = Test-ProxyConnection $url
                    $checked[$url] = $ok
                    if ($ok) { Write-Host "通畅" -ForegroundColor Green }
                    else     { Write-Host "连接失败" -ForegroundColor Red }
                }
                if (-not $checked[$url]) {
                    Write-Host "[失败] 代理 $url 无法连接，已中止开启（请确认代理软件已启动）。" -ForegroundColor Red
                    return
                }
            }

            foreach ($entry in $targets.GetEnumerator()) {
                Add-SetProxyEnv $entry.Key $entry.Value
            }
            Write-Host "[成功] 已在当前终端连接代理。" -ForegroundColor Green
        }

        "off" {
            foreach ($name in $envNames) {
                Add-UnsetProxyEnv $name
            }
            Write-Host "[成功] 已断开当前终端的代理。" -ForegroundColor Green
        }

        "set" {
            $isGlobal = $false
            $updates = [ordered]@{}
            $positionalUrl = $null

            $i = 1
            while ($i -lt $cliArgs.Count) {
                $arg = $cliArgs[$i]
                switch ($arg.ToLower()) {
                    "--global" { $isGlobal = $true }
                    "-g"       { $isGlobal = $true }
                    { $_ -in @("--all", "-a", "--http", "--https") } {
                        if ($i + 1 -ge $cliArgs.Count -or $cliArgs[$i + 1].StartsWith("-")) {
                            Write-Host "[错误] 参数 $arg 后面缺少代理地址。" -ForegroundColor Red
                            return
                        }
                        $val = Normalize-ProxyUrl $cliArgs[$i + 1]
                        if (-not $val) {
                            Write-Host "[错误] 无效的代理地址: $($cliArgs[$i + 1])" -ForegroundColor Red
                            return
                        }
                        if ($_ -in @("--all", "-a")) {
                            $updates["http"]  = $val
                            $updates["https"] = $val
                            $updates["all"]   = $val
                        } elseif ($_ -eq "--http") {
                            $updates["http"]  = $val
                        } elseif ($_ -eq "--https") {
                            $updates["https"] = $val
                        }
                        $i++
                    }
                    default {
                        if ($arg.StartsWith("-")) {
                            Write-Host "[错误] 未知参数: $arg" -ForegroundColor Red
                            return
                        }
                        $val = Normalize-ProxyUrl $arg
                        if (-not $val) {
                            Write-Host "[错误] 无效的代理地址: $arg" -ForegroundColor Red
                            return
                        }
                        $positionalUrl = $val
                    }
                }
                $i++
            }

            if ($updates.Count -eq 0 -and $positionalUrl) {
                $updates["http"]  = $positionalUrl
                $updates["https"] = $positionalUrl
                $updates["all"]   = $positionalUrl
            }

            if ($updates.Count -eq 0) {
                Write-Host "[错误] 请提供代理地址，例如: proxy set -a http://127.0.0.1:7890" -ForegroundColor Red
                return
            }

            $envMap = @{ http = "HTTP_PROXY"; https = "HTTPS_PROXY"; all = "ALL_PROXY" }

            if ($isGlobal) {
                $cfg = Get-ProxyConfig $configPath
                foreach ($entry in $updates.GetEnumerator()) {
                    $cfg[$entry.Key] = $entry.Value
                }
                Save-ProxyConfig $configPath $cfg
                Clear-AllTmpCache

                foreach ($entry in $updates.GetEnumerator()) {
                    $envKey = $envMap[$entry.Key]
                    Add-SetProxyEnv $envKey $entry.Value
                    [Environment]::SetEnvironmentVariable($envKey, $entry.Value, "User")
                }
                Write-Host "[成功] 已设置代理（当前终端 + 预设配置 + Windows 全局用户环境变量）。" -ForegroundColor Green
            } else {
                foreach ($entry in $updates.GetEnumerator()) {
                    Add-SetProxyEnv $envMap[$entry.Key] $entry.Value
                    Add-SetTmpCache $entry.Key $entry.Value
                }
                Write-Host "[成功] 已在当前终端临时设置代理（仅当前窗口有效，未写入全局配置）。" -ForegroundColor Green
            }
        }

        "show" {
            Write-Host "=== 当前终端代理 (Session) ===" -ForegroundColor Cyan
            foreach ($name in $envNames) {
                $val = (Get-Item -Path "Env:$name" -ErrorAction SilentlyContinue).Value
                Write-Host ("  {0,-12}: {1}" -f $name, $(if ($val) { $val } else { "(未设置)" }))
            }

            $sc = Get-SessionCache
            Write-Host "`n=== 当前终端临时配置 (Session Cache) ===" -ForegroundColor Cyan
            Write-Host ("  {0,-12}: {1}" -f "http",  $(if ($sc.http)  { $sc.http }  else { "(未设置)" }))
            Write-Host ("  {0,-12}: {1}" -f "https", $(if ($sc.https) { $sc.https } else { "(未设置)" }))
            Write-Host ("  {0,-12}: {1}" -f "all",   $(if ($sc.all)   { $sc.all }   else { "(未设置)" }))

            $cfg = Get-ProxyConfig $configPath
            Write-Host "`n=== 已保存预设配置 ($configPath) ===" -ForegroundColor Cyan
            Write-Host ("  {0,-12}: {1}" -f "http",  $(if ($cfg.http)  { $cfg.http }  else { "(未设置)" }))
            Write-Host ("  {0,-12}: {1}" -f "https", $(if ($cfg.https) { $cfg.https } else { "(未设置)" }))
            Write-Host ("  {0,-12}: {1}" -f "all",   $(if ($cfg.all)   { $cfg.all }   else { "(未设置)" }))

            Write-Host "`n=== Windows 全局用户环境变量 (Global/User) ===" -ForegroundColor Cyan
            foreach ($name in $envNames) {
                $gVal = [Environment]::GetEnvironmentVariable($name, "User")
                Write-Host ("  {0,-12}: {1}" -f $name, $(if ($gVal) { $gVal } else { "(未设置)" }))
            }
        }

        { $_ -in @("clear", "remove") } {
            foreach ($name in $envNames) {
                Add-UnsetProxyEnv $name
                if ([Environment]::GetEnvironmentVariable($name, "User")) {
                    [Environment]::SetEnvironmentVariable($name, $null, "User")
                }
            }
            Clear-AllTmpCache
            if (Test-Path $configPath) {
                Remove-Item -Path $configPath -Force
            }
            Write-Host "[成功] 已清空当前终端、临时缓存、预设配置以及 Windows 全局用户环境变量中的所有代理设置。" -ForegroundColor Green
        }

        default {
            Show-Help
        }
    }
} finally {
    Flush-Actions
}