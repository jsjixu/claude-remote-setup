# claude-remote-setup

把一台 Mac 配成「手机上随时能开工的远程工位」——装常驻 `claude remote-control` daemon、
防睡眠、并根治一个**必然会犯、但完全没有提示**的坑:手机上新建会话永远卡在 `Allocating sandbox`。

> **EN**: A Claude Code skill (+ 3 standalone bash scripts) that turns a Mac into a 7×24 remote
> workstation you can drive from the Claude mobile app. It also fixes a silent failure mode where
> the long-running `remote-control` daemon keeps a deleted binary path after Claude auto-updates,
> so every new session from your phone hangs on "Allocating sandbox" forever with no error shown.
> Docs and script comments are in Chinese.

## 它解决的那个坑

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
