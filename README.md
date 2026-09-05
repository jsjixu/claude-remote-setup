# claude-remote-setup

把一台 Mac 配成「手机上随时能开工的远程工位」——装常驻 `claude remote-control` daemon、
防睡眠,并根治**两个都没有任何提示**的坑:

1. 手机上新建会话永远卡在 `Allocating sandbox`(Claude 自动升级后 daemon 抱着已被删掉的旧版本)
2. 工位**在「登录项与扩展」里被自己误关**,而且是持久的 —— 今天还好好的,重启后就没了

> **EN**: A Claude Code skill (+ 3 standalone bash scripts) that turns a Mac into a 7×24 remote
> workstation you can drive from the Claude mobile app. It fixes two silent failure modes:
> (1) after Claude auto-updates, the long-running `remote-control` daemon still points at the
> deleted binary, so every new session from your phone hangs on "Allocating sandbox" with no error;
> (2) wrapping the agent in `/usr/bin/caffeinate` makes it show up as "caffeinate" in
> Login Items & Extensions — indistinguishable from leftovers of the third-party Caffeine app —
> so people turn it off, which permanently disables it (macOS records `disallowed`; it won't come
> back after reboot, and there is no CLI to undo it). Docs and script comments are in Chinese.

## 第一个坑:手机卡「Allocating sandbox」

常驻的 `claude remote-control` daemon 一跑就是几周不重启。期间 Claude Code 自动升级
(`~/.local/bin/claude` 软链改指新版本),旧版本文件随后被清理删掉。

daemon 自己**还活着**(映像早加载进内存了),但它 spawn 新会话用的是**自己启动时的 execPath**
——那个文件已经没了 → `ENOENT` → **永远开不出新会话**。

手机上只显示 `Allocating sandbox` 转圈,**不报错、不超时**,真因只写在 Mac 本地日志里。
很容易误判成沙箱、权限或网络问题。

只有 native 安装(`~/.local/share/claude/versions/<版本号>` 这种)会犯。npm 装的入口是 node,不受影响。

一句话确诊:
```bash
grep -a "spawn error: ENOENT" ~/Library/Logs/claude-remote-*.log | tail -3
```

## 第二个坑:工位被「登录项与扩展」误关

macOS 的 BTM 给「系统设置 → 通用 → 登录项与扩展」里每个后台项显示的名字,取自
`ProgramArguments[0]` 的可执行文件名。**如果你用 `/usr/bin/caffeinate` 包一层来防睡眠**
(很多教程这么写,本仓库早期版本也是),那这个工位在那个列表里就显示成 **`caffeinate`**、
归属 Apple —— 和第三方 Caffeine.app 的残留长得一模一样。

清理登录项的人关掉它是完全合理的判断,而一关:

```
backgroundtaskmanagementd  getItemWithIdentifier: 8.com.<user>.claude-remote-<name>
launchd                    removing service: com.<user>.claude-remote-<name>
```

**而且这是持久的** —— BTM 把 Disposition 记成 `[enabled, disallowed, notified]`,
手工 `launchctl bootstrap` 能把它拉起来,但**下次登录还是不会自启**,
而 `doctor.sh` 只查「进程在不在跑」的话会报一切正常。这是一个「今天好好的、明天开机就没」的哑故障。

**本仓库的做法**:生成的 plist **不包 caffeinate**,直接跑 `claude` ——
在登录项里显示成 `claude`、归属 **Anthropic PBC**,一眼认得出。
防睡眠交给 `sudo pmset -c sleep 0`(`caffeinate -s` 本来也只在插电时生效),`doctor.sh` 每次都查它。
`doctor.sh` 另外会读 BTM 状态,`disallowed` 直接报错并给出打开它的命令。

> ⚠️ 两个注意:`sfltool dumpbtm` **耗时不可预测、甚至会无限阻塞**(实测),所以 `doctor.sh`
> 给它加了 8 秒硬超时,超时就给手查命令而不是卡死;另外 `disallowed` 这个标记
> **只能在系统设置 UI 里翻回来**,没有命令行接口(`launchctl enable` 管的是另一套列表)。

## 快速开始

```bash
git clone https://github.com/jsjixu/claude-remote-setup.git
cd claude-remote-setup

bash doctor.sh                                        # 体检:现在能不能连、差什么(只读)
bash setup_remote.sh --name mymac --dir ~/project     # 预览要做什么(不动手)
bash setup_remote.sh --name mymac --dir ~/project --apply   # 真装
sudo pmset -c sleep 0                                 # 插电时永不睡(必须,脚本不替你 sudo)
bash doctor.sh                                        # 复检
```

然后手机 Claude App → Code → 找到这台机器 → **New session**。

## 三个脚本

| 脚本 | 干什么 | 安全性 |
|---|---|---|
| `doctor.sh` | 逐项体检并给出修法 | **只读**,不改任何东西 |
| `setup_remote.sh` | 装工位 + 看门狗,支持 `--list` / `--uninstall` / `--watchdog-only` | **默认预览**,`--apply` 才动手 |
| `remote_watchdog.sh` | 看门狗,**自动发现**所有工位,零配置 | 四道防误杀闸 |

## 看门狗怎么工作

每 180 秒查一次,两条互补判据:

- **主动**:进程实际映像(`lsof` 读 txt 段)的文件没了 → 立刻重启;版本漂移了(还没坏)
  **且当前没人在用** → 空闲时提前追平,让你永远撞不上故障
- **兜底**:daemon 日志**新增部分**出现 `spawn error: ENOENT` → 重启。
  这条是故障的直接证据,绝对准确(存字节偏移,不追溯历史、不重复触发)

四道防误杀闸:拿不到证据不动作;claude 软链自己坏了只记日志不重启(重启也没用,只会不停抖);
**有会话在跑时「版本漂移」只推迟不打断**;300 秒冷却(按 daemon 独立)。

顺带做日志轮转(超 64MB 截到尾部 8MB)——launchd 的 `StandardOutPath` 是纯追加、**无 rotation** 的。

### 一个刻意的取舍

「真坏了」时看门狗会**无条件重启,哪怕杀掉正在跑的会话**。因为那一刻你正卡在开不出新会话上,
救那个才是你要的。如果你的机器上常年挂着长会话,心里有个数。

## 两个反直觉的坑(踩过了写在这)

**`StartCalendarInterval` 对 `KeepAlive=true` 的常驻服务无效。**
launchd 定时触发的语义是「到点了如果**没跑**就拉起来」,对已在运行的 job 是 no-op,根本不会重启它。
所以必须用独立的看门狗 job,不能图省事往 daemon 自己的 plist 上加定时器。

**日志轮转必须原地截断保 inode**(`tail -c N > tmp; cat tmp > 原文件`)。
launchd 的 fd 是 `O_APPEND`,截断安全;但如果用 `mv`/`rm`,launchd 会一直往那个已改名/已删的
inode 里写,你看到的新文件永远是空的。

## 作为 Claude Code Skill 使用

把整个目录放进 `~/.claude/skills/claude-remote-setup/`,重开 Claude Code。
之后只要说一句「帮我配一下手机远程控制」,Claude 会加载 `SKILL.md` 并带你走完全流程
——先体检、再预览、你点头才动手、最后复检。

## 兼容性

脚本对这些差异全自适应,**没有任何硬编码需要改**:用户名、家目录、claude 装在哪、
native 还是 npm 装的、笔记本还是台式机、已经装过几个工位。

在 macOS 26 / Apple Silicon 上,一台 MacBook Pro(1 个工位)与一台 Mac mini(2 个工位)
双机验证过:自动发现、正常态 no-op、硬故障判定、版本漂移(空闲追平 vs 有会话推迟)、
软链断裂保护、冷却、ENOENT 兜底四情形,外加真实重启与 launchd 定时器。

## 笔记本当工位基本不成立

- 用电池时防睡眠设置不生效(daemon 带的 `caffeinate -s` 也只在插电时挡睡眠)
- **合盖基本等于断线**
- 真想 7×24,用一台常插电的台式机

## License

MIT
