#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# 远程工位体检:一条条告诉你「手机现在能不能连上这台机器」,不能的话差在哪。
#   bash doctor.sh
# 只读,不改任何东西。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
LA="$HOME/Library/LaunchAgents"
PASS=0; WARN=0; FAIL=0
ok()   { echo "  ✅ $*"; PASS=$((PASS+1)); }
warn() { echo "  ⚠️  $*"; WARN=$((WARN+1)); }
bad()  { echo "  ❌ $*"; FAIL=$((FAIL+1)); }
info() { echo "     $*"; }
hd()   { echo; echo "── $* ─────────────────────────────────"; }

find_claude() {
  local c
  for c in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [ -e "$c" ] && { echo "$c"; return 0; }
  done
  c=$(command -v claude 2>/dev/null) && [ -n "$c" ] && { echo "$c"; return 0; }
  return 1
}
image_of() {
  /usr/sbin/lsof -p "$1" -Ffn 2>/dev/null | awk '
    /^f/ { fd=substr($0,2) }
    /^n/ { if (fd=="txt" && $0 ~ /\/claude\/versions\//) { print substr($0,2); exit } }'
}
discover_jobs() {
  local plist label args
  for plist in "$LA"/*.plist; do
    [ -f "$plist" ] || continue
    args=$(plutil -extract ProgramArguments json -o - "$plist" 2>/dev/null) || continue
    case "$args" in *'"remote-control"'*) ;; *) continue ;; esac
    case "$args" in *claude*) ;; *) continue ;; esac
    label=$(plutil -extract Label raw -o - "$plist" 2>/dev/null) || continue
    echo "$label"
  done
}

echo "════════════════════════════════════════════════════"
echo "  远程工位体检 —— $(scutil --get ComputerName 2>/dev/null || hostname)"
echo "  $(date '+%F %T')"
echo "════════════════════════════════════════════════════"

hd "1. Claude Code"
CLAUDE=$(find_claude) || { bad "找不到 claude 命令 —— 先安装 Claude Code"; echo; echo "体检中止"; exit 1; }
ok "已安装: ${CLAUDE}"
VER=$("$CLAUDE" --version 2>/dev/null | head -1); info "版本 ${VER:-未知}"
LINK=$(readlink "$CLAUDE" 2>/dev/null || echo "$CLAUDE")
NATIVE=0; case "$LINK" in *"/claude/versions/"*) NATIVE=1 ;; esac
if [ "$NATIVE" = 1 ]; then
  info "安装方式 native(版本目录式)"
  if [ -e "$LINK" ]; then ok "当前版本文件存在"; else bad "软链断了: ${LINK} —— claude 装坏了,需重装"; fi
else
  info "安装方式 npm/其它(不会犯版本映像那个病)"
fi
if [ -f "$HOME/.claude.json" ]; then ok "已登录过(找到 ~/.claude.json)"
else bad "没找到 ~/.claude.json —— 先在终端裸跑一次 claude 完成登录"; fi

hd "2. 远程工位(daemon)"

# ── BTM(系统设置 → 通用 → 登录项与扩展)状态 ────────────────────────────────
# 为什么要查这个:被用户在登录项里关掉的工位,**当下进程可能还在跑**(手工 bootstrap 过),
# 只查 PID 一切正常 —— 但 macOS 已把 Disposition 记成 disallowed,**下次登录不会再起**。
# 这是一个「今天看着好好的、明天开机就没了」的哑故障,只有查 BTM 才看得见。
# sfltool 不需要 sudo,但**耗时不可预测**(它对每个后台项做签名校验,实测有时 >2 分钟)
# —— 必须加硬超时,否则整个体检会卡死在这一步。查不到就明说并给手查命令,绝不假装没事。
run_capped() {   # $1=秒上限,其余=命令;超时则杀掉并返回 1
  local cap="$1"; shift
  local tmp; tmp=$(mktemp) || return 1
  "$@" >"$tmp" 2>/dev/null &
  local p=$! i=0
  while kill -0 "$p" 2>/dev/null; do
    sleep 0.2; i=$((i+1))
    if [ "$i" -ge $((cap*5)) ]; then
      kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; rm -f "$tmp"; return 1
    fi
  done
  wait "$p" 2>/dev/null
  cat "$tmp"; rm -f "$tmp"; return 0
}

# 自测钩子:DOC_FAKE_BTM=<文件> 用假 dump 走完全部分支(disallowed / allowed / 显示名 caffeinate),
# DOC_FAKE_BTM=SLOW 模拟 sfltool 卡死。不用真去关登录项就能验。
BTM_DUMP=""; BTM_SLOW=0
if [ -n "${DOC_FAKE_BTM:-}" ]; then
  if [ "$DOC_FAKE_BTM" = "SLOW" ]; then BTM_SLOW=1; else BTM_DUMP=$(cat "$DOC_FAKE_BTM" 2>/dev/null); fi
elif command -v sfltool >/dev/null 2>&1; then
  BTM_DUMP=$(run_capped 8 sfltool dumpbtm) || { BTM_SLOW=1; BTM_DUMP=""; }
fi

btm_field() {   # $1=label  $2=Disposition|Name  → 打印该字段,取不到则空
  [ -n "$BTM_DUMP" ] || return 0
  printf '%s\n' "$BTM_DUMP" | awk -v want="8.$1" -v key="$2" '
    $0 ~ ("^[[:space:]]*" key ":") { v=$0; sub("^[[:space:]]*" key ":[[:space:]]*","",v) }
    /^[[:space:]]*Identifier:/ {
      id=$0; sub(/^[[:space:]]*Identifier:[[:space:]]*/,"",id)
      if (id==want && v!="") { print v; exit }
    }'
}

JOBS=$(discover_jobs); NJOB=0
if [ -z "$JOBS" ]; then
  bad "一个常驻工位都没有 —— 手机上无法「新建」会话"
  info "装一个: bash setup_remote.sh --name mymac --apply"
else
  while IFS= read -r L; do
    [ -n "$L" ] || continue
    NJOB=$((NJOB+1))
    NM=$(plutil -extract ProgramArguments json -o - "$LA/$L.plist" 2>/dev/null | tr ',' '\n' | grep -A1 '"--name"' | tail -1 | tr -d '" ')
    PID=$(launchctl list 2>/dev/null | awk -v x="$L" '$3==x{print $1}')
    echo "  ▸ ${L}"
    info "手机上显示: ${NM:-?}"
    DISP=$(btm_field "$L" "Disposition")
    if [ -z "$PID" ]; then
      bad "没在运行"
      case "$DISP" in
        *disallowed*)
          info "真因已确认:它在「登录项与扩展」里被关掉了(BTM: ${DISP})"
          ;;
        *)
          info "头号嫌疑:被「登录项与扩展」关掉了 —— plist 还在、job 却整个不在 launchctl list 里,"
          info "         这正是 BTM 关掉一个后台项时的样子(launchd 会 removing service)"
          ;;
      esac
      info "先去 UI 里确认那一项是开着的: open \"x-apple.systempreferences:com.apple.LoginItems-Settings.extension\""
      info "再拉起来: launchctl bootstrap gui/$(id -u) ${LA}/${L}.plist"
      continue
    fi
    ok "运行中 (PID ${PID})"

    # 进程在跑 ≠ 明天还在。被关过的项,重启后就没了
    case "$DISP" in
      *disallowed*)
        bad "★但它在「登录项与扩展」里是关着的★ (BTM: ${DISP})"
        info "现在能跑只是因为有人手工 bootstrap 过 —— **下次登录/重启不会自启**"
        info "去打开它: open \"x-apple.systempreferences:com.apple.LoginItems-Settings.extension\""
        info "(这个开关是用户同意闸,没有命令行接口;launchctl enable 管的是另一套列表)"
        ;;
      *allowed*) ok "登录项已允许(重启后会自启)" ;;
      "")        : ;;
    esac

    # 显示名叫 caffeinate 的老工位:极易被当成 Caffeine.app 残留误关
    case "$(btm_field "$L" "Name")" in
      caffeinate)
        warn "它在登录项里显示成「caffeinate」—— 和第三方 Caffeine.app 残留难以区分,极易被误关"
        info "建议摘掉 plist 里 /usr/bin/caffeinate 那两行(新版本已不再生成),改显示成 claude"
        ;;
    esac
    if [ "$NATIVE" = 1 ]; then
      IMG=$(image_of "$PID")
      if [ -z "$IMG" ]; then
        info "读不到版本映像(可忽略)"
      elif [ ! -e "$IMG" ]; then
        bad "★正在发病★ 它抱着的版本文件已被删除: ${IMG}"
        info "手机上新建会话此刻必然卡在「Allocating sandbox」"
        info "立刻修: launchctl kickstart -k gui/$(id -u)/${L}"
      elif [ "$IMG" != "$LINK" ]; then
        warn "版本漂移: 它跑 $(basename "$IMG"),而当前版本是 $(basename "$LINK")"
        info "还没坏,但下次清理旧版本时就会坏。看门狗会在你空闲时自动追平"
      else
        ok "版本一致 ($(basename "$IMG"))"
      fi
    fi
    DLOG=$(plutil -extract StandardOutPath raw -o - "$LA/$L.plist" 2>/dev/null)
    if [ -n "$DLOG" ] && [ -f "$DLOG" ]; then
      SZ=$(du -h "$DLOG" 2>/dev/null | cut -f1)
      NE=$(grep -a -c "spawn error: ENOENT" "$DLOG" 2>/dev/null | head -1); NE=${NE:-0}
      info "日志 ${SZ}$([ "${NE:-0}" -gt 0 ] && echo "  (历史上有 ${NE} 次 ENOENT 故障记录)")"
    fi
  done <<< "$JOBS"
  if [ "${BTM_SLOW:-0}" = "1" ]; then
    warn "登录项(BTM)状态这次没查成 —— sfltool dumpbtm 超过 8 秒没返回(它有时就是这么慢)"
    info "手查: sfltool dumpbtm | grep -B12 \"Identifier: 8.<label>\$\" | grep -E \"Name:|Disposition:\""
    info "看到 disallowed = 它被在「登录项与扩展」里关掉了,下次登录不会自启"
  fi
fi

hd "3. 看门狗"
WDJOB=$(launchctl list 2>/dev/null | awk '$3 ~ /claude/ && $3 ~ /watchdog/ {print $3}')
if [ -n "$WDJOB" ]; then
  ok "已装并在运行"
  echo "$WDJOB" | sed 's/^/       • /'
  # 通配扫描,兼容手工装过的各种命名(而不是硬编码某台机器的文件名)
  for f in "$HOME"/Library/Logs/*watchdog*.log; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in *.err.log) continue ;; esac
    [ -s "$f" ] && { info "最近动作($(basename "$f")):"; tail -3 "$f" | sed 's/^/       /'; }
  done
else
  warn "没装看门狗"
  if [ "$NATIVE" = 1 ]; then
    info "★ 你是 native 安装,强烈建议装 —— 否则 claude 下次升级后,"
    info "  手机上新建会话会永远卡在「Allocating sandbox」且毫无提示"
    info "  装它: bash setup_remote.sh --name <你的工位名> --apply"
  fi
fi

hd "4. 睡眠(最常见的「连不上」原因)"
AC=$(pmset -g custom 2>/dev/null | awk '/AC Power/,0' | awk '$1=="sleep"{print $2; exit}')
LAP=$(pmset -g batt 2>/dev/null | grep -qi "InternalBattery" && echo 1 || echo 0)
if [ "${AC:-1}" = "0" ]; then ok "插电时永不睡眠"
else bad "插电时 ${AC} 分钟就睡 —— 电脑一睡手机必连不上"; info "修: sudo pmset -c sleep 0"; fi
if [ "$LAP" = 1 ]; then
  warn "这是笔记本 —— 不适合当「随时能连」的工位"
  info "· 用电池时上面的设置不生效"
  info "· 合盖基本等于断线"
  info "· 想真 7x24,用常插电的台式机(Mac mini 之类)"
  PW=$(pmset -g batt 2>/dev/null | head -1 | sed "s/.*drawing from //; s/'//g")
  info "当前供电: ${PW}"
else
  AR=$(pmset -g custom 2>/dev/null | awk '/AC Power/,0' | awk '$1=="autorestart"{print $2; exit}')
  if [ "${AR:-0}" = "1" ]; then ok "断电来电后自动开机"
  else warn "没开「来电自动开机」—— 跳闸后要手动开机"; info "修: sudo pmset -c autorestart 1"; fi
fi
CAF=$(pmset -g assertions 2>/dev/null | grep -c "caffeinate" | head -1); CAF=${CAF:-0}
[ "${CAF:-0}" -gt 0 ] && ok "caffeinate 正在挡睡眠(daemon 带的)" || info "没看到 caffeinate 断言(daemon 没跑时正常)"

hd "5. 网络"
if curl -s -o /dev/null -m 8 -w "" https://api.anthropic.com/ 2>/dev/null; then
  ok "能连到 Anthropic"
else
  warn "连 api.anthropic.com 失败(可能是代理/防火墙,也可能只是这个探针被拦)"
  info "远程控制不需要跟手机同一个 WiFi,但电脑必须能出网"
fi

echo
echo "════════════════════════════════════════════════════"
echo "  通过 ${PASS}  ·  提醒 ${WARN}  ·  问题 ${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  echo "  → 有 ❌ 项,手机大概率连不上。按上面的提示逐条修。"
elif [ "$NJOB" = 0 ]; then
  echo "  → 还没装工位,手机无法新建会话。"
else
  echo "  → 一切正常。手机 Claude App → Code → 选这台机器 → New session"
fi
echo "════════════════════════════════════════════════════"
