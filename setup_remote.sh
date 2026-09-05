#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# 一键把这台 Mac 装成「手机能随时开工的远程工位」
#
#   ./setup_remote.sh --name mymac                    # 预览要做什么(默认不动手)
#   ./setup_remote.sh --name mymac --apply            # 真的装
#   ./setup_remote.sh --name mymac --effort xhigh --apply   # 顺便定思考档位
#   ./setup_remote.sh --watchdog-only --apply         # 已有工位,只补装/升级看门狗
#   ./setup_remote.sh --list                          # 看已装了哪些工位
#   ./setup_remote.sh --uninstall <label> --apply     # 卸掉某个工位
#
# 装完得到:
#   1) 一个常驻的 remote-control daemon(launchd 管,崩了自动拉起,开机自启)
#   2) 一个看门狗(防 claude 升级后 daemon 持旧版本映像 → 手机卡「Allocating sandbox」)
#   3) 一份体检报告告诉你还差什么(主要是睡眠设置,那个需要你自己 sudo)
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

NAME=""; DIR="$PWD"; MODE="default"; APPLY=0; ACTION="install"; TARGET=""; EFFORT=""
WATCHDOG=1; INTERVAL=180
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LA="$HOME/Library/LaunchAgents"
WD_SCRIPT="$LA/claude-remote-watchdog.sh"
WD_LABEL="com.$(id -un).claude-remote-watchdog"

usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --dir) DIR="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --effort) EFFORT="${2:-}"; shift 2 ;;
    --interval) INTERVAL="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --no-watchdog) WATCHDOG=0; shift ;;
    --list) ACTION="list"; shift ;;
    --watchdog-only) ACTION="watchdog"; shift ;;
    --uninstall) ACTION="uninstall"; TARGET="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "未知参数: $1(用 --help 看用法)"; exit 1 ;;
  esac
done

info() { echo "  $*"; }
step() { echo; echo "▸ $*"; }
warn() { echo "  ⚠️  $*"; }
ok()   { echo "  ✅ $*"; }
bad()  { echo "  ❌ $*"; }
doit() { if [ "$APPLY" = 1 ]; then eval "$@"; else echo "     [预览] $*"; fi; }

find_claude() {
  local c
  for c in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [ -e "$c" ] && { echo "$c"; return 0; }
  done
  c=$(command -v claude 2>/dev/null) && [ -n "$c" ] && { echo "$c"; return 0; }
  return 1
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

install_watchdog() {
if [ "$WATCHDOG" = 1 ]; then
  if [ ! -f "$SELF_DIR/remote_watchdog.sh" ]; then
    warn "找不到 remote_watchdog.sh(应与本脚本同目录),跳过看门狗"
  else
    info "作用: 防 claude 升级后 daemon 还抱着旧版本 → 手机卡「Allocating sandbox」"
    info "它会自动发现所有远控工位,不用配置。每 ${INTERVAL}s 查一次,正常时什么都不做。"
    doit "cp '$SELF_DIR/remote_watchdog.sh' '$WD_SCRIPT' && chmod +x '$WD_SCRIPT'"
    TMP_WD=$(mktemp)
    cat > "$TMP_WD" <<WDEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$WD_LABEL</string>
    <!-- 看门狗:自动发现所有 claude remote-control daemon 并保证它们不会因为
         「抱着已被删掉的旧版本可执行文件」而拒绝新会话。详见脚本头部注释。
         ⚠️ 不能把定时器加在 daemon 自己的 plist 上 —— 那些是 KeepAlive 常驻进程,
         launchd 的定时触发对已在运行的 job 是 no-op,不会重启它。 -->
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$WD_SCRIPT</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>
    <key>StartInterval</key>
    <integer>$INTERVAL</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/claude-remote-watchdog.err.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/claude-remote-watchdog.err.log</string>
</dict>
</plist>
WDEOF
    plutil -lint "$TMP_WD" >/dev/null 2>&1 || { bad "看门狗配置有问题"; rm -f "$TMP_WD"; }
    if [ "$APPLY" = 1 ]; then
      cp "$TMP_WD" "$LA/$WD_LABEL.plist"
      launchctl bootout "gui/$(id -u)/$WD_LABEL" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$LA/$WD_LABEL.plist" 2>/dev/null || launchctl load -w "$LA/$WD_LABEL.plist"
      launchctl list 2>/dev/null | grep -q "$WD_LABEL" && ok "看门狗已启动" || warn "看门狗没起来"
    else
      info "[预览] 将安装看门狗 $WD_LABEL(每 ${INTERVAL}s 一次)"
    fi
    rm -f "$TMP_WD"
  fi
else
  warn "按要求跳过看门狗(--no-watchdog)。风险:claude 升级后手机可能开不了会话。"
fi
}

# ── --list ─────────────────────────────────────────────────────────────────
if [ "$ACTION" = "list" ]; then
  echo "已装的远程工位:"
  found=0
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    found=1
    pid=$(launchctl list 2>/dev/null | awk -v x="$l" '$3==x{print $1}')
    nm=$(plutil -extract ProgramArguments json -o - "$LA/$l.plist" 2>/dev/null | tr ',' '\n' | grep -A1 '"--name"' | tail -1 | tr -d '" ')
    wd=$(plutil -extract WorkingDirectory raw -o - "$LA/$l.plist" 2>/dev/null)
    echo "  • $l"
    echo "      手机上显示: ${nm:-?}   目录: ${wd:-?}   状态: $([ -n "$pid" ] && echo "运行中(PID $pid)" || echo "未运行")"
  done <<< "$(discover_jobs)"
  [ "$found" = 0 ] && echo "  (还没有装任何工位)"
  echo
  # 宽松识别:任何 label 里同时含 claude 和 watchdog 的都算(兼容手工装过的各种命名)
  wdfound=$(launchctl list 2>/dev/null | awk '$3 ~ /claude/ && $3 ~ /watchdog/ {print $3}')
  if [ -n "$wdfound" ]; then
    echo "看门狗: 已装 ✅"
    echo "$wdfound" | sed 's/^/      • /'
  else
    echo "看门狗: 未装 —— 建议装上,否则 claude 升级后手机可能开不了会话"
  fi
  exit 0
fi

# ── --uninstall ────────────────────────────────────────────────────────────
if [ "$ACTION" = "uninstall" ]; then
  [ -n "$TARGET" ] || { echo "要卸哪个?先跑 --list 看 label"; exit 1; }
  echo "准备卸载: $TARGET"
  [ "$APPLY" = 1 ] || echo "(预览模式,加 --apply 才真的卸)"
  doit "launchctl bootout 'gui/$(id -u)/$TARGET' 2>/dev/null || true"
  doit "rm -f '$LA/$TARGET.plist'"
  ok "已卸载(日志文件保留,要删自己动手)"
  exit 0
fi

# ── --watchdog-only:已有工位,只补装/升级看门狗 ─────────────────────────────
if [ "$ACTION" = "watchdog" ]; then
  echo "══════════════════════════════════════════════════════════"
  echo " 只装看门狗 $([ "$APPLY" = 1 ] && echo '(真实执行)' || echo '(预览模式 —— 加 --apply 才动手)')"
  echo "══════════════════════════════════════════════════════════"
  n=$(discover_jobs | grep -c . | head -1); n=${n:-0}
  info "当前发现 ${n} 个远程工位,看门狗会全部自动纳管:"
  discover_jobs | sed 's/^/       • /'
  [ "$n" = "0" ] && warn "一个工位都没有 —— 先装工位: --name <名字> --apply"
  step "安装看门狗"
  install_watchdog
  echo
  if [ "$APPLY" = 1 ]; then
    echo "装好了。验证: WD_DRY_RUN=1 WD_VERBOSE=1 bash $WD_SCRIPT"
  else
    echo "以上是预览。确认没问题就加 --apply 重跑。"
  fi
  exit 0
fi

# ── 安装 ───────────────────────────────────────────────────────────────────
[ -n "$NAME" ] || { echo "必须给工位起个名字: --name <名字>(这个名字会显示在手机上)"; exit 1; }
case "$NAME" in *[!a-zA-Z0-9_-]*) echo "名字只能用字母数字和 - _"; exit 1 ;; esac

LABEL="com.$(id -un).claude-remote-$NAME"
PLIST="$LA/$LABEL.plist"
DLOG="$HOME/Library/Logs/claude-remote-$NAME.log"

echo "══════════════════════════════════════════════════════════"
echo " 远程工位安装 $([ "$APPLY" = 1 ] && echo '(真实执行)' || echo '(预览模式 —— 加 --apply 才动手)')"
echo "══════════════════════════════════════════════════════════"

step "1/6 检查 claude"
CLAUDE=$(find_claude) || { bad "找不到 claude 命令。先装 Claude Code 再回来。"; exit 1; }
info "路径: $CLAUDE"
VER=$("$CLAUDE" --version 2>/dev/null | head -1) && info "版本: $VER"
REAL=$(readlink "$CLAUDE" 2>/dev/null || echo "$CLAUDE")
case "$REAL" in
  *"/claude/versions/"*) info "安装方式: native(有版本目录 → 看门狗很有必要)" ;;
  *) info "安装方式: npm/其它(不犯版本映像那个病,看门狗只做日志维护)" ;;
esac
if [ ! -f "$HOME/.claude.json" ]; then
  warn "没找到 ~/.claude.json —— 你可能还没登录过。"
  warn "先在终端裸跑一次 'claude',按提示登录,再回来跑本脚本。"
fi

step "2/6 确认工位参数"
[ -d "$DIR" ] || { bad "目录不存在: $DIR"; exit 1; }
DIR="$(cd "$DIR" && pwd)"
info "手机上显示的名字: $NAME"
info "launchd label:    $LABEL"
info "工作目录:         $DIR"
info "权限档位:         $MODE"
[ -n "$EFFORT" ] && info "思考档位:         $EFFORT(写进 CLAUDE_CODE_EFFORT_LEVEL)"
info "日志:             $DLOG"
if [ -f "$PLIST" ]; then
  warn "同名工位已存在,继续会覆盖: $PLIST"
fi

# remote-control 子命令**不吃 `--effort`**(它只认顶层 flag,塞进子命令会打乱解析,
# --name 会变成 unknown option → 崩溃重启循环)。环境变量是唯一干净的持久杠杆。
# 留空则不写这一项,会话按 settings.json 里的默认档跑。
EFFORT_XML=""
if [ -n "$EFFORT" ]; then
  case "$EFFORT" in
    low|medium|high|xhigh) ;;
    *) echo "  ⚠️  --effort 只认 low/medium/high/xhigh(max 只能靠 CLI flag,写不进常驻配置),已忽略"; EFFORT="" ;;
  esac
fi
[ -n "$EFFORT" ] && EFFORT_XML="
        <key>CLAUDE_CODE_EFFORT_LEVEL</key>
        <string>$EFFORT</string>"

step "3/6 生成 daemon 配置"
TMP_PLIST=$(mktemp)
# ⚠️ 这个 heredoc 是 **unquoted** 的(要展开 $LABEL/$NAME/$CLAUDE 等)。所以下面的 XML 注释里
#    **不能出现反引号**(会被当成命令替换真的执行掉,内容还会从注释里消失)、`$` 也要小心。
#    踩过:注释里写 `sudo pmset -c sleep 0` → 生成时真去跑了一次 sudo,注释里只剩两个空格。
cat > "$TMP_PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <!-- 手机 Claude App 里认名字「${NAME}」,点进去就能在这台机器上新建会话。

         ★ 这里**故意不用 /usr/bin/caffeinate 包一层**(2026-09-05 真机踩过,代价是两个工位被误杀):
         系统设置 → 通用 → 登录项与扩展 里,每个后台项显示的名字取自 ProgramArguments[0]。
         包了 caffeinate,这一项就显示成「caffeinate」、归属 Apple —— 和第三方 Caffeine.app 的
         残留一模一样。用户清理登录项时把它关掉是完全合理的判断,而**关掉 = BTM 标记
         disallowed = launchd 立刻 removing service,且下次登录也不会再起**,手机端直接失联。
         直接跑 claude 则显示成「claude」、归属 Anthropic PBC,一眼认得出。

         代价:少了一层插电防睡眠。这不亏 —— 第 6 步那条 sudo pmset -c sleep 0 才是真正管用的
         那道(caffeinate -s 本来也只在插电时生效),doctor.sh 每次都会检查它;要按需防睡眠用
         Amphetamine 之类。

         另:ProgramArguments 必须同时含 claude 和 remote-control —— 看门狗靠这两个词自动发现
         工位。想换成脚本包装来「起个好名字」的话,看门狗会漏掉它,那个「手机卡 Allocating
         sandbox」的坑就回来了。 -->
    <key>ProgramArguments</key>
    <array>
        <string>$CLAUDE</string>
        <string>remote-control</string>
        <string>--name</string>
        <string>$NAME</string>
        <string>--permission-mode</string>
        <string>$MODE</string>
    </array>

    <key>WorkingDirectory</key>
    <string>$DIR</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>$HOME</string>$EFFORT_XML
    </dict>

    <!-- 登录即起 + 崩了自动重来;15s 节流防疯转 -->
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>15</integer>
    <key>ProcessType</key>
    <string>Background</string>

    <key>StandardOutPath</key>
    <string>$DLOG</string>
    <key>StandardErrorPath</key>
    <string>$DLOG</string>
</dict>
</plist>
PLISTEOF
plutil -lint "$TMP_PLIST" >/dev/null 2>&1 && ok "配置语法正确" || { bad "生成的配置有问题"; rm -f "$TMP_PLIST"; exit 1; }
if [ "$APPLY" = 1 ]; then
  mkdir -p "$LA"; cp "$TMP_PLIST" "$PLIST"; ok "已写入 $PLIST"
else
  info "[预览] 将写入 $PLIST"
fi
rm -f "$TMP_PLIST"

step "4/6 加载 daemon"
doit "launchctl bootout 'gui/$(id -u)/$LABEL' 2>/dev/null || true"
doit "launchctl bootstrap 'gui/$(id -u)' '$PLIST' 2>/dev/null || launchctl load -w '$PLIST'"
if [ "$APPLY" = 1 ]; then
  sleep 3
  PID=$(launchctl list 2>/dev/null | awk -v l="$LABEL" '$3==l{print $1}')
  if [ -n "$PID" ]; then ok "已启动(PID $PID)"; else bad "没起来,看日志: $DLOG"; fi
fi

step "5/6 安装看门狗"
install_watchdog

step "6/6 睡眠设置(这步需要你自己来,脚本不擅自 sudo)"
AC_SLEEP=$(pmset -g custom 2>/dev/null | awk '/AC Power/,0' | awk '$1=="sleep"{print $2; exit}')
IS_LAPTOP=$(pmset -g batt 2>/dev/null | grep -qi "InternalBattery" && echo 1 || echo 0)
info "当前「插电时空闲睡眠」= ${AC_SLEEP:-未知}  (0 表示永不睡,这才是我们要的)"
if [ "${AC_SLEEP:-1}" != "0" ]; then
  bad "插电时仍会睡 —— 电脑一睡,手机就连不上了。请执行:"
  echo "         sudo pmset -c sleep 0"
else
  ok "插电时永不睡,符合要求"
fi
if [ "$IS_LAPTOP" = 1 ]; then
  warn "这是笔记本。两个额外提醒:"
  warn "  · 用电池时上面的设置不生效(pmset 的 AC 档只管插电)"
  warn "  · 合盖基本等于断线。想真正 7x24,用一台常插电的台式机(如 Mac mini)当工位"
fi
if [ "$IS_LAPTOP" = 0 ]; then
  info "台式机建议再开一条(断电来电后自动开机): sudo pmset -c autorestart 1"
fi

echo
echo "══════════════════════════════════════════════════════════"
if [ "$APPLY" = 1 ]; then
  echo " 装好了。手机上打开 Claude App → Code → 找到这台机器 → New session"
  echo " 体检随时跑: bash $SELF_DIR/doctor.sh"
else
  echo " 以上是预览。确认没问题就加 --apply 重跑一次。"
fi
echo "══════════════════════════════════════════════════════════"
