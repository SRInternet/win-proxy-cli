# 若继承了 Windows 全局环境变量，启动时自动补充小写变量以兼容 curl 等工具
[ -n "$HTTP_PROXY" ]  && [ -z "$http_proxy" ]  && export http_proxy="$HTTP_PROXY"
[ -n "$HTTPS_PROXY" ] && [ -z "$https_proxy" ] && export https_proxy="$HTTPS_PROXY"
[ -n "$ALL_PROXY" ]   && [ -z "$all_proxy" ]   && export all_proxy="$ALL_PROXY"

_PROXY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

proxy() {
    local tmp_out win_out win_script rc
    tmp_out="$(mktemp)"
    win_out="$(cygpath -w "$tmp_out")"
    win_script="$(cygpath -w "$_PROXY_DIR/proxy_core.ps1")"

    MSYS_NO_PATHCONV=1 _PROXY_SHELL="bash" _PROXY_OUT="$win_out" \
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$win_script" "$@"
    rc=$?

    if [ -s "$tmp_out" ]; then
        # shellcheck disable=SC1090
        source "$tmp_out"
    fi
    rm -f "$tmp_out"
    return $rc
}