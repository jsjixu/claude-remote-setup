---
name: claude-remote-setup
description: 把一台 Mac 配成「手机上随时能开工的远程工位」——装常驻 remote-control daemon、防睡眠、装看门狗防「手机新建会话永远卡在 Allocating sandbox」这个必犯的坑,并出体检报告。当用户说「想用手机控制电脑上的 Claude Code」「iOS/Claude App 连不上我的 Mac」「怎么远程控制」「手机上开不了会话」「新建会话一直转圈/卡在 Allocating sandbox」「远程工位怎么配」「出门也想跑 Claude」「工位/机器在手机上突然不见了」「重启后远控就没了」「登录项里那个 caffeinate 是什么」时用(关键词:手机远程/iOS 远程控制/Claude App/remote control/远程工位/连不上/开不了会话/Allocating sandbox/一直转圈/7x24/工位消失/登录项与扩展/Login Items/BTM/disallowed/重启后不自启/多个项目多个工位)。含三个可直接跑的脚本。已在真机验证。
---

# 把 Mac 配成手机能随时开工的远程工位

目标:人不在电脑前,掏出手机 → Claude App → Code → 选中那台 Mac → **New session** → 直接开工。

本 skill 带三个脚本(与本文件同目录):

| 脚本 | 干什么 | 安全性 |
|---|---|---|
| `doctor.sh` | 体检:一条条告诉你现在能不能连、差什么 | **只读**,不改任何东西 |
| `setup_remote.sh` | 一键装工位 + 看门狗 | **默认预览**,加 `--apply` 才动手 |
| `remote_watchdog.sh` | 看门狗本体(由 setup 自动安装,一般不用手动碰) | 自动发现,零配置 |

自测钩子(不用真造故障就能验全部分支):

- 看门狗:`WD_DRY_RUN=1` 只判定不动手、`WD_VERBOSE=1` 打印发现过程、`WD_FAKE_IMAGE=<路径>` 模拟映像状态、`WD_FAKE_LOG=<路径>` 用临时日志验 ENOENT 兜底。
- 体检:`DOC_FAKE_BTM=testdata/btm_fixture.txt bash doctor.sh` 走完登录项的三条分支
  (disallowed 报错 / allowed 放行 / 显示名还是 caffeinate 的迁移提示);
  `DOC_FAKE_BTM=SLOW bash doctor.sh` 模拟 `sfltool` 卡死,验超时兜底。
  **别为了测这个真去关一次登录项** —— 关掉是持久的,要手工 bootstrap 才能拉回来。

**执行顺序永远是**:先 `doctor.sh` 看现状 → 再 `setup_remote.sh`(先不加 --apply 给用户看预览)→ 用户确认后 `--apply` → 最后再 `doctor.sh` 验收。

## ★ 先分清两种「远程」,新手最容易混

| | 怎么开 | 手机上能干什么 |
|---|---|---|
| **A. 接管已有会话** | `settings.json` 里 `"remoteControlAtStartup": true`(或 `/config` 里那个开关) | 你在电脑上开着的会话,手机能接过来continue。**电脑前得先有人开会话** |
| **B. 凭空新建会话** ← 本 skill 的重点 | 常驻 `claude remote-control` daemon | 人不在电脑前,手机直接 New session。**这才是「在外面随时开工」** |

两者不冲突,可以都开。用户说「想在外面随时开工」,要的一定是 **B**。

## 三个硬条件(缺一不可)

1. **那台电脑醒着** —— 唯一真正的门槛。电脑睡了,手机按什么都没反应。
2. **那台电脑能出网** —— 但**不需要**跟手机同一个 WiFi,也不用 VPN/内网穿透。手机的指令走 Anthropic 服务器中转。
3. **daemon 活着** —— launchd 保证崩了自动拉起,看门狗保证它不会「活着但拒绝新会话」。

手机那头:登同一个账号、有网,没别的讲究。

## 步骤

### 0. 先体检
```bash
bash doctor.sh
```
它会逐项报 ✅/⚠️/❌ 并给出修法。**照着 ❌ 修完再往下走。**

### 1. 确认用户已登录
新手最常见的卡点:装了 claude 但没登录过。判据是 `~/.claude.json` 存在。
没有的话让他先在终端裸跑一次 `claude`,按提示登录,再回来。

### 2. 想快速验证「能不能通」,先跑前台版
```bash
cd /要工作的/目录
claude remote-control --name mymac
```
跑起来后按 **空格** 显示二维码,手机扫;或者手机 App 里直接就能看到这台机器。
**这一步只是验证链路通不通,Ctrl-C 就没了。** 确认能连上再做成常驻。

### 3. 做成常驻(核心)
```bash
bash setup_remote.sh --name mymac --dir ~/你的项目 --mode default      # 预览
bash setup_remote.sh --name mymac --dir ~/你的项目 --mode default --apply  # 真装
```

参数:
- `--name` 手机上显示的名字,只能字母数字和 `-_`
- `--dir` 工作目录(默认当前目录)。**新会话都在这个目录里创建**
- `--mode` 权限档位:`default`(推荐给新手,写操作会问)/ `acceptEdits` / `auto` / `bypassPermissions`(危险,别给新手)
- `--effort` 思考档位:`low`/`medium`/`high`/`xhigh`,写进 `CLAUDE_CODE_EFFORT_LEVEL`。
  **`remote-control` 子命令不吃 `--effort`**(顶层 flag 塞进子命令会打乱解析,`--name` 变 unknown option → 崩溃重启循环),env 是唯一干净的持久杠杆。不给就按 `settings.json` 的默认档。`max` 只能靠交互式 CLI flag,写不进常驻配置。
- `--no-watchdog` 跳过看门狗(**不建议**,理由见下)
- `--watchdog-only` **已经有工位了,只补装/升级看门狗**(不新建工位)
- `--list` 看已装了哪些工位;`--uninstall <label> --apply` 卸掉

一个工位 = 一个目录。**想在多个项目里开工,就装多个工位**(名字不同即可) ——
因为 daemon 只在自己的 WorkingDirectory 里创建会话,手机端的目录选择器也只列该 daemon 有过历史的目录。

**别在这上面浪费时间的两条**(都实测过):
- 把新目录写进 `~/.claude.json` 的 `projects`(连 `hasTrustDialogAccepted` 一起)再重启 daemon,
  手机端目录列表**依然不会多出来** —— 远控不看那个文件。
- 想用 `claude -p` 在那个目录里造一次会话历史来「注册」它:ssh 非交互会话里会报 `Not logged in`
  (拿不到 GUI 域的 keychain)。多工位就得多 daemon,没有捷径。

### 3.5 已经有工位、只想补装看门狗
用户如果之前手工配过 daemon(或用旧办法装过),不用推倒重来:
```bash
bash setup_remote.sh --watchdog-only            # 预览
bash setup_remote.sh --watchdog-only --apply    # 装
```
看门狗**自动发现**所有已有工位,一个都不会漏,也不用告诉它 label。

⚠️ 如果对方机器上已经有一个手工装的看门狗,**注意 label 可能不同**
(本脚本按 `id -un` 生成 `com.<用户名>.claude-remote-watchdog`)。两个看门狗并存不会互相破坏,
但旧的那个可能指向已被删的脚本、每个周期失败一次。装完记得查一遍并卸掉旧的:
```bash
launchctl list | awk '$3 ~ /claude/ && $3 ~ /watchdog/ {print $3}'   # 应该只剩一个
```

### 4. 睡眠设置(脚本不会替你 sudo,得手动)
```bash
sudo pmset -c sleep 0        # 插电时永不空闲睡眠 —— 必须
sudo pmset -c autorestart 1  # 台式机:断电来电后自动开机 —— 强烈建议
```

**★ 笔记本当工位基本不成立**,务必跟用户说清楚:
- 用电池时上面的设置不生效(daemon 带的 `caffeinate -s` 也只在插电时挡睡眠)
- **合盖基本等于断线**
- 真想 7×24,用一台常插电的台式机(Mac mini 之类)

### 5. 验收
```bash
bash doctor.sh
```
全绿后让用户在手机上实际点一次 New session。**没实际点过不算配好。**

## ★★ 必须知道的坑:手机卡在「Allocating sandbox」

**症状**:手机上点 New session,永远显示 `Allocating sandbox` 转圈,不报错、不超时。

**真因**(手机 UI 完全不暴露):常驻 daemon 一跑就是几周不重启。期间 claude 自动升级(软链改指新版本),旧版本文件随后被清理删掉。daemon 自己还活着(映像早加载进内存了),但它 spawn 新会话用的是**自己启动时的 execPath**(旧版本号)—— 文件没了 → `ENOENT` → 永远开不出新会话。

**只有 native 安装**(`~/.local/share/claude/versions/<版本号>` 这种)会犯。npm 装的入口是 node,不受影响。

**立刻确诊**:
```bash
grep -a "spawn error: ENOENT" ~/Library/Logs/claude-remote-*.log | tail -3
# 或看进程实际抱着哪个文件:
lsof -p <daemon PID> | grep versions/
```

**立刻修**:
```bash
launchctl kickstart -k gui/$(id -u)/<label>
```

**根治 = 看门狗**(`--apply` 时默认就装了)。它每 180 秒查一次,两条互补判据:
- **主动**:进程实际映像的文件没了 → 立刻重启;版本漂移了(还没坏)**且当前没人在用** → 空闲时提前追平,让用户永远撞不上
- **兜底**:daemon 日志新增部分出现 `spawn error: ENOENT` → 重启。这条是故障的直接证据,绝对准确

四道防误杀闸:拿不到证据不动作;claude 软链自己坏了只记日志不重启(重启也没用,只会不停抖);**有会话在跑时,「版本漂移」只推迟不打断**;300 秒冷却。

**一个必须讲明的权衡**:「真坏了」时看门狗会**无条件重启,哪怕杀掉正在跑的会话**。因为那一刻用户正卡在开不出新会话上,救那个才是他要的。如果那台机器上常年挂着长会话,提前告诉用户这件事。

**为什么不能图省事把定时器加在 daemon 自己的 plist 上**:daemon 是 `KeepAlive=true` 的常驻进程,launchd 定时触发的语义是「到点了如果**没跑**就拉起来」,对已在运行的 job 是 no-op,根本不会重启它。必须用独立的看门狗 job。

## ★★ 第二个坑:工位被「登录项与扩展」误关(2026-09-05 真机踩过)

**症状**:手机上这台机器突然整个不见了 / 目录选择器空了;电脑上 `launchctl list` 里那个 label
**连条目都没有**(不是「未运行」,是被 removing service 了)。plist 文件还在。

**真因**:macOS 的 BTM(系统设置 → 通用 → 登录项与扩展)给每个后台项显示的名字,
取自 `ProgramArguments[0]` 的可执行文件名。老版本的本脚本用 `/usr/bin/caffeinate` 包一层,
于是每个工位在那个列表里都显示成 **`caffeinate`**、归属 Apple —— 和第三方 Caffeine.app 的残留
长得一模一样。用户清理登录项时关掉它是完全合理的判断,而**一关就是**:

```
backgroundtaskmanagementd  getItemWithIdentifier: 8.com.<user>.claude-remote-<name>
launchd                    removing service: com.<user>.claude-remote-<name>
```

而且这个「关」是**持久**的:BTM 把 Disposition 记成 `[enabled, disallowed, notified]`,
**下次登录也不会再起**。手工 `launchctl bootstrap` 能把它拉起来,但重启后照样没有。

**确诊**(不用猜):
```bash
sfltool dumpbtm | grep -B12 "Identifier: 8.com.<user>.claude-remote-<name>$" | grep -E "Name:|Disposition"
# Disposition: [enabled, disallowed, ...] = 被用户关过
/usr/bin/log show --last 1h --predicate 'eventMessage CONTAINS "claude-remote"' --style compact | grep -i "removing service"
```
⚠️ 用 `/usr/bin/log` 绝对路径 —— 有些 shell 里 `log` 是个同名函数,直接写 `log show` 会静默失败
(报 `too many arguments`,然后你以为「日志里什么都没有」)。

**修**:
1. 摘掉 plist 里的 caffeinate 两行(新版脚本已不再生成),重新 bootstrap
   → 该项在登录项里改显示成 `claude`、归属 **Anthropic PBC**,一眼认得出,不会再被误杀。
2. **`disallowed` 这个标记只能在系统设置 UI 里翻回来**(它是用户同意闸,没有命令行接口;
   `launchctl enable` 管的是另一套 disabled 列表,不是这个)。
   `open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"` 打开那一页,
   把 Anthropic PBC 名下的 `claude` 项打开。
3. `sfltool resetbtm` 能清干净,但它**重置全机所有后台项**,别用。

**给新工位起名时也记着这条**:能让人在登录项里认出来的名字,比好看的名字重要。

## 排障速查

| 症状 | 多半是 | 怎么办 |
|---|---|---|
| 手机上根本看不到这台机器 | daemon 没跑 / 没登录 / 账号不同 | `bash doctor.sh` |
| 机器/目录**突然整个消失**,plist 还在但 `launchctl list` 里没这个 label | **被「登录项与扩展」关掉了**(见上一节) | 去系统设置打开那一项,再 `launchctl bootstrap` |
| 现在能连,**重启后就没了** | 同上:BTM 记着 `disallowed`,手工 bootstrap 只治当下 | 同上 —— 这个开关只能在 UI 里翻 |
| 看得到机器,New session 卡 `Allocating sandbox` | **上面那个版本映像坑** | `launchctl kickstart -k gui/$(id -u)/<label>`,然后装看门狗 |
| 白天能连,晚上连不上 | 电脑睡了 | `sudo pmset -c sleep 0`;笔记本换台式机 |
| 出门就断,回家又好 | 笔记本合盖了 / 拔了电 | 换常插电的机器当工位 |
| 会话开出来但目录不对 | 工位的 WorkingDirectory 是固定的 | 给那个目录单独装一个工位 |
| 日志把磁盘吃满 | launchd 的 StandardOutPath 纯追加、**无 rotation** | 看门狗会在超 64MB 时自动截到 8MB |

**日志在哪**:
- daemon:`~/Library/Logs/claude-remote-<name>.log`
- 看门狗动作:`~/Library/Logs/claude-remote-watchdog.log`(正常时是空的)

**改日志大小要注意**:必须**原地截断保 inode**(`tail -c N > tmp; cat tmp > 原文件`)。launchd 的 fd 是 `O_APPEND`,截断安全;但如果你用 `mv`/`rm`,launchd 会一直往那个已改名/已删的 inode 里写,你看到的新文件永远是空的。

## 卸载

```bash
bash setup_remote.sh --list                                  # 先看 label
bash setup_remote.sh --uninstall <label> --apply             # 卸工位
launchctl bootout gui/$(id -u)/com.<用户名>.claude-remote-watchdog   # 卸看门狗
rm -f ~/Library/LaunchAgents/com.<用户名>.claude-remote-watchdog.plist ~/Library/LaunchAgents/claude-remote-watchdog.sh
```

## 怎么把这套给别人

整个目录拷给对方,放进 `~/.claude/skills/claude-remote-setup/`,重开 Claude Code 即可。
之后对方只要说一句「帮我配一下手机远程控制」,他的 Claude 就会加载本 skill 照着做。

对方机器上会不一样的地方,脚本都已自适应:用户名、家目录、claude 装在哪、native 还是 npm、
笔记本还是台式机、已经装过几个工位。**不需要改脚本里的任何硬编码。**
