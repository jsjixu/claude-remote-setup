#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Claude Remote Control 看门狗(通用版,自动发现,零配置)
#
# 【治什么病】
# 常驻的 remote-control daemon 一旦跑起来就是几周不重启。期间 claude 会自动升级
# (软链 ~/.local/bin/claude 改指新版本),旧版本文件随后被 cleanup 删掉。
# daemon 自己还活着(它早把映像加载进内存了),但它每次 spawn 新会话用的是
# **自己启动时的 execPath**(旧版本号)—— 文件没了 → ENOENT →
# **手机上新建会话永远卡在「Allocating sandbox」转圈**,而且 UI 完全不报错。
#
# 只有 native 安装(~/.local/share/claude/versions/<版本号> 这种)会犯这个病。
# npm 安装的 claude 入口是 node,不受影响 —— 本脚本会自动识别,对 npm 装法只做
# 日志轮转和 ENOENT 兜底,不误动。
#
# 【为什么不能给主 plist 加 StartCalendarInterval】
# 远控 daemon 是 KeepAlive=true 的常驻进程。launchd 定时触发的语义是
# 「到点了如果**没跑**就拉起来」,对一个已在运行的 job 是 no-op,根本不会重启它。
# 所以必须用这个独立的看门狗 job。
#
# 【自动发现】
# 扫 ~/Library/LaunchAgents/*.plist,凡 ProgramArguments 里同时含 claude 和
# remote-control 的,都自动纳管。以后你再加新工位,不用改这个脚本。
#
# 【设计原则】宁可不动作,也不误杀:
#   - 拿不到证据(lsof 读不到映像)→ 跳过
#   - claude 软链自己坏了 → 只记日志不重启(重启也没用,只会每几分钟抖一次)
#   - 还没坏、只是版本旧了 → 有会话在跑就推迟,绝不打断你正在用的工位
#   - 真坏了(映像没了 / 日志出现 ENOENT)→ 无条件重启,因为此刻新会话已经开不出来了
#
# 【自测】不用真造故障:
#   WD_DRY_RUN=1 bash remote_watchdog.sh            # 只判定不动手
#   WD_DRY_RUN=1 WD_VERBOSE=1 bash remote_watchdog.sh   # 打印发现了哪些 daemon
#   WD_DRY_RUN=1 WD_FAKE_IMAGE=/不存在的路径 bash remote_watchdog.sh  # 模拟硬故障
#   WD_DRY_RUN=1 WD_FAKE_LOG=/tmp/fake.log bash remote_watchdog.sh    # 用临时日志验证 ENOENT 兜底
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

WD_LOG="$HOME/Library/Logs/claude-remote-watchdog.log"
ERR_LOG="$HOME/Library/Logs/claude-remote-watchdog.err.log"
COOLDOWN=300                       # 同一 daemon 两次重启的最小间隔,防抖
MAIN_LOG_MAX=$((64*1024*1024))     # daemon 主日志超 64MB 就轮转
MAIN_LOG_KEEP=$((8*1024*1024))     # 保留尾部 8MB
DRY="${WD_DRY_RUN:-0}"
VERBOSE="${WD_VERBOSE:-0}"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$WD_LOG"; }
say() { [ "$VERBOSE" = "1" ] && echo "$*"; return 0; }

# ── 找 claude 的软链(native 安装才有版本概念) ───────────────────────────────
find_claude_link() {
  local c
  for c in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [ -L "$c" ] || [ -f "$c" ] || continue
    echo "$c"; return 0
  done
  c=$(command -v claude 2>/dev/null) && [ -n "$c" ] && { echo "$c"; return 0; }
  return 1
}

# ── 自动发现所有远控 daemon:输出 label|主日志路径 ───────────────────────────
discover_jobs() {
  local plist label args logpath
  for plist in "$HOME/Library/LaunchAgents"/*.plist; do
    [ -f "$plist" ] || continue
    args=$(plutil -extract ProgramArguments json -o - "$plist" 2>/dev/null) || continue
    case "$args" in *'"remote-control"'*) ;; *) continue ;; esac
    case "$args" in *claude*) ;; *) continue ;; esac
    label=$(plutil -extract Label raw -o - "$plist" 2>/dev/null) || continue
    [ -n "$label" ] || continue
    logpath=$(plutil -extract StandardOutPath raw -o - "$plist" 2>/dev/null) || logpath=""
    printf '%s|%s\n' "$label" "$logpath"
  done
}

# ── 日志轮转:必须**原地截断保 inode** ───────────────────────────────────────
# launchd 的 StandardOutPath fd 是 O_APPEND(已实测),所以 `cat tmp > 原文件` 安全:
# 截断后写偏移自动回到末尾,继续追加无空洞。若改用 mv/rm,launchd 会一直往那个
# 已改名/已删的 inode 里写,你看到的新文件永远是空的。
rotate() {
  local f="$1" max="$2" keep="$3" sz tmp
  [ -n "$f" ] && [ -f "$f" ] || return 0
  sz=$(stat -f%z "$f" 2>/dev/null) || return 0
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  [ "$sz" -gt "$max" ] || return 0
  tmp=$(mktemp) || return 0
  tail -c "$keep" "$f" > "$tmp" 2>/dev/null
  cat "$tmp" > "$f"
  rm -f "$tmp"
  log "日志轮转: $(basename "$f") ${sz} → $(stat -f%z "$f" 2>/dev/null) 字节"
}

# 进程**实际加载**的可执行映像。注意不能看 argv[0](那是软链路径,看不出真相)
image_of() {
  /usr/sbin/lsof -p "$1" -Ffn 2>/dev/null | awk '
    /^f/ { fd=substr($0,2) }
    /^n/ { if (fd=="txt" && $0 ~ /\/claude\/versions\//) { print substr($0,2); exit } }'
}

# ── 兜底判据:扫主日志**新增部分**,见到 spawn ENOENT 就修 ────────────────────
# 上面的 lsof 判据看的是 inode 反查路径,未必等于进程缓存的 execPath 字符串。
# 日志里的 ENOENT 是故障的**直接证据**,绝对准确。两条判据互补:
# lsof 抢在前面防(还没坏就追平),日志兜在后面救(真坏了立刻修)。
scan_log_for_enoent() {
  local f="$1" off_file="$2" off sz new
  [ -n "$f" ] && [ -f "$f" ] || return 1
  sz=$(stat -f%z "$f" 2>/dev/null) || return 1
  if [ ! -f "$off_file" ]; then
    echo "$sz" > "$off_file"        # 首次:只记位置,不追溯历史
    return 1
  fi
  off=$(cat "$off_file" 2>/dev/null)
  case "${off:-}" in ''|*[!0-9]*) off=0 ;; esac
  if [ "$off" -gt "$sz" ]; then     # 文件变小 = 刚轮转过,偏移作废
    echo "$sz" > "$off_file"; return 1
  fi
  new=$(tail -c "+$((off+1))" "$f" 2>/dev/null | tr -d '\000' | grep -c "spawn error: ENOENT" 2>/dev/null)
  echo "$sz" > "$off_file"
  case "${new:-0}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$new" -gt 0 ]
}

restart() {
  local label="$1" why="$2" stamp="$3" now last=0
  now=$(date +%s)
  [ -f "$stamp" ] && last=$(cat "$stamp" 2>/dev/null)
  case "${last:-}" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -lt "$COOLDOWN" ]; then
    log "[$label] 需重启($why)但在冷却期内($((now-last))s < ${COOLDOWN}s),跳过"; return 0
  fi
  if [ "$DRY" = "1" ]; then
    log "[$label] [DRY-RUN] 本应重启: $why"; say "  → [DRY-RUN] 本应重启: $why"; return 0
  fi
  echo "$now" > "$stamp"
  if launchctl kickstart -k "gui/$(id -u)/$label" 2>>"$WD_LOG"; then
    log "[$label] ✅ 已重启: $why"
  else
    log "[$label] ❌ 重启失败(kickstart 非零退出): $why"
  fi
}

# ── 主流程 ─────────────────────────────────────────────────────────────────
rotate "$WD_LOG"  $((1024*1024)) $((256*1024))
rotate "$ERR_LOG" $((1024*1024)) $((256*1024))

LINK=$(find_claude_link) || { say "找不到 claude 可执行文件,退出"; exit 0; }
WANT=$(readlink "$LINK" 2>/dev/null || echo "$LINK")
case "$WANT" in /*) ;; *) WANT="$(cd "$(dirname "$LINK")" && pwd)/$WANT" ;; esac   # 相对软链转绝对

NATIVE=0
case "$WANT" in *"/claude/versions/"*) NATIVE=1 ;; esac
say "claude 入口: $LINK"
say "解析到:     $WANT"
say "安装方式:   $([ "$NATIVE" = 1 ] && echo 'native(有版本目录,需要看门狗)' || echo 'npm/其它(不犯这个病,只做日志轮转+ENOENT兜底)')"

if [ "$NATIVE" = 1 ] && [ ! -e "$WANT" ]; then
  # 软链自己就是断的 → 重启也没用,只会不停抖动。留给人工。
  log "⚠️ claude 软链指向不存在的文件: $WANT —— claude 安装本身坏了,需人工修复,全部跳过"
  say "⚠️ 软链已断:$WANT"
  exit 0
fi

FOUND=0
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  FOUND=$((FOUND+1))
  LABEL="${entry%%|*}"
  MAIN_LOG="${WD_FAKE_LOG:-${entry#*|}}"   # WD_FAKE_LOG 仅供自测:用临时日志验证 ENOENT 兜底,不碰生产日志
  say ""
  say "发现 daemon: $LABEL"
  say "  主日志: ${MAIN_LOG:-(plist 未配 StandardOutPath)}"

  STAMP="$HOME/Library/Logs/.${LABEL}.watchdog.stamp"
  OFFSET="$HOME/Library/Logs/.${LABEL}.watchdog.offset"

  rotate "$MAIN_LOG" "$MAIN_LOG_MAX" "$MAIN_LOG_KEEP"

  PID=$(launchctl list 2>/dev/null | awk -v l="$LABEL" '$3==l{print $1}')
  case "${PID:-}" in
    ''|*[!0-9]*) say "  未在运行(KeepAlive 会自己管),跳过"; continue ;;
  esac
  say "  PID: $PID"

  IMAGE="${WD_FAKE_IMAGE:-$(image_of "$PID")}"
  if [ -z "$IMAGE" ]; then
    # npm 安装或读不到映像 —— 仍然跑 ENOENT 兜底,但不做版本判断
    if scan_log_for_enoent "$MAIN_LOG" "$OFFSET"; then
      restart "$LABEL" "主日志出现 spawn error: ENOENT —— 已在拒绝新会话" "$STAMP"
    else
      say "  拿不到版本映像(非 native 或 lsof 无结果),仅做日志兜底 → 无异常"
    fi
    continue
  fi
  say "  实际映像: $IMAGE"

  if [ ! -e "$IMAGE" ]; then
    say "  ❌ 映像文件已不存在 = 正在发病"
    restart "$LABEL" "映像已被清理($IMAGE 不存在)—— 手机端此刻必然卡在 Allocating sandbox" "$STAMP"
    continue
  fi

  if scan_log_for_enoent "$MAIN_LOG" "$OFFSET"; then
    say "  ❌ 日志出现 ENOENT"
    restart "$LABEL" "主日志出现 spawn error: ENOENT —— 已在拒绝新会话" "$STAMP"
    continue
  fi

  if [ "$IMAGE" != "$WANT" ]; then
    # 版本漂移:还没坏,但下次 cleanup 就会把 $IMAGE 删掉。趁没人用时提前追平。
    KIDS=0
    for c in $(pgrep -P "$PID" 2>/dev/null); do
      cmd=$(ps -o command= -p "$c" 2>/dev/null)
      case "${cmd:-}" in
        /usr/bin/caffeinate*) ;;    # plist 自带的,不算会话
        '') ;;
        *) KIDS=$((KIDS+1)) ;;
      esac
    done
    if [ "$KIDS" -gt 0 ]; then
      log "[$LABEL] 版本漂移($IMAGE → $WANT)但有 $KIDS 个活跃会话,推迟到下次"
      say "  ⏳ 版本漂移,但有 $KIDS 个活跃会话 → 推迟(不打断你正在用的工位)"
    else
      say "  ⚠️ 版本漂移且空闲 → 追平"
      restart "$LABEL" "版本漂移,空闲追平: $IMAGE → $WANT" "$STAMP"
    fi
  else
    say "  ✅ 健康(映像与软链一致)"
  fi
done <<< "$(discover_jobs)"

say ""
say "共发现 $FOUND 个远控 daemon"
[ "$FOUND" = 0 ] && say "(没发现任何常驻远控 daemon —— 先用 setup_remote.sh 装一个)"
exit 0
