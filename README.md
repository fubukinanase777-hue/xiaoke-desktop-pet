# 小克 · Claude Code 桌宠

一个住在 Windows 桌面右下角的 Q 版像素风小人。她跟着 Claude Code 的状态变：Claude 在干活她就坐在书桌前看书写字，做完了她蹦起来叫你来看，需要你点头时她摇铃，闲久了会打瞌睡、说梦话。点她一下她会回你一句（冷傲娇口吻，有配音）。

*A pixel-art desktop pet for Claude Code on Windows. She reacts to Claude's state through Claude Code hooks: working, done, needs your input, idle, dozing. Click her for a voiced reaction (Chinese).*

## 她会做什么

| Claude 的状态 | 她的样子 |
|---|---|
| 在干活 | 坐在书桌前看书、写字；偶尔伸懒腰揉肩，或者灵光一闪 |
| 做完了 | 蹦一下 / 比耶，冒出气泡说一句，气泡里是项目名和 Claude 最后一句话的开头 |
| 等你点头（权限确认、提问） | 摇铃叫你 |
| 中途汇报（Claude 还有后台任务在跑） | 灰蓝色的小气泡，安静地报个进度 |
| 闲着 | 坐在书堆旁看书，偶尔翻书、喝茶、伸懒腰、打哈欠 |
| 闲太久 | 点头打盹，睡着，说梦话 |

- **点她**：有消息时点她会打开那个对话；没消息时就是戳她——干活时、闲着时、连戳好几下、打瞌睡时，反应和台词都不一样。
- **拖动**：按住拖到想放的位置，下次还在那里。
- **右键菜单**：静音、音量滑杆、说梦话的频率和要不要出声、先藏起来、重置、退出。

## 需要

- Windows 10 / 11，自带的 Windows PowerShell 5.1
- [Claude Code](https://claude.com/claude-code)（桌面应用或命令行都行；点她打开对话这一项只对桌面应用有效）

## 安装

1. 把这个仓库放到一个固定的文件夹，比如 `C:\tools\xiaoke-desktop-pet`（之后别再挪，挪了要重装）。
2. 在这个文件夹里运行：
   ```powershell
   powershell -ExecutionPolicy Bypass -File install.ps1
   ```
   它会注册一个按需运行的计划任务 `XiaokePet`（不会开机自启，只在被叫的时候运行，不需要管理员权限），并生成 `hooks-snippet.json`。
3. 把 `hooks-snippet.json` 里的 `hooks` 合并进 `~/.claude/settings.json`（也可以直接让 Claude Code 帮你合并）。
4. 重启 Claude Code，发一句话，她就会出来。

**为什么要计划任务**：钩子是 Claude 的子进程，直接从钩子启动的桌宠会在 Claude 重启、更新时被一起关掉；交给 Windows 任务计划程序启动，她就和 Claude 没有父子关系了。

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```
然后把 `~/.claude/settings.json` 里调用 `launch.ps1` 的四条钩子删掉。

## 改她

所有给人看的文字、台词、动画都在 `config.json`，改完右键「退出」再发一句话让她重新出来即可。

- **台词和配音**：`voices.冷傲娇.<类别>` 是一组 `{text, audio}`，有多条就随机挑、不连着重复。类别：`done` 做完了、`need` 要你定、`progress` 进度汇报、`pokeWork` / `pokeIdle` / `pokeMany` / `pokeWake` 干活时 / 闲着 / 连戳 / 打瞌睡时被戳、`sleepTalk` 说梦话。没有 `audio` 就只冒气泡。
- **动画**：`anim.<状态>`：`fps` 每秒几帧（低帧率是故意的）；`seq` 一组帧；`seqs` 几组里每次随机挑一组；`extras` 循环中偶尔插一段（`chance` 是每循环一遍插的概率 %）。
- **其他**：`dozeMinutes` 闲多久开始打瞌睡，`sleepTalkChance` 说梦话频率，`staleMinutes` 多久没动静就不算在干活，`bubbleSec` 气泡停留秒数，`clearWhenClaudeFocused` 切到 Claude 窗口就算看过了。

### 加新动作

帧在 `art/frames/`，名字必须是 `work|idle|cheer|need|wait|poke|doze|wake` 加数字。做法：

1. 画一张 2 行 × 4 列、纯洋红 `#FF00FF` 背景的序列帧大图，每一行是一个连续动作的 4 个中间帧。我们用的提示词在 `art/prompts/`；当时给模型的参考图是这个形象的设定图（别人的作品，不在仓库里），再加一张已有的序列帧大图（保证画风和大小接得上）。
2. 在 `art/cut.py` 的 `NAMES` 里加上这张图和 8 个帧名，运行 `python -X utf8 cut.py`（需要 Python、Pillow、NumPy、SciPy）。它会抠掉洋红底、按脚底对齐、统一画布。新图人物大小和旧帧不一样时调 `ROWSCALE`；跳起来那一行加进 `FLOOR_ROWS`。
3. 在 `config.json` 的 `anim` 里把新帧排进 `seqs` 或 `extras`。

## 文件

- `pet.ps1`：桌宠本体（WPF）
- `launch.ps1`：钩子入口（work / done / need / end），记下状态、确保桌宠在运行，立刻返回
- `install.ps1` / `uninstall.ps1`：安装、卸载
- `config.json`：台词、配音、动画、菜单文字
- `art/frames/`：95 张成品帧；`art/cut.py`：切帧脚本；`art/prompts/`：出图提示词
- `voice/`：冷傲娇配音 37 句
- 运行时会生成 `state/`（会话状态、位置）和 `fired.log`，不用管

## 怎么做出来的

- 形象：中文社区里流行的 Claude 拟人形象（橙发、花朵发饰、抱着书），不是本仓库原创，原设定的版权归原作者。我们以它为参考，用 GPT 图像模型重画成 Q 版像素风的 2×4 序列帧大图，再用 `cut.py` 抠图切帧。
- 声音：先用千问 Qwen3-TTS 声音设计做出"冷傲娇"的样本音色，再用千问克隆和 Drama 3 给每句台词各出一版，逐句盲听挑出来（都在 RunningHub 上跑）。
- 代码：和 Claude Code 一起写的。

## 许可与声明

- **脚本、配置、配音**：[CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/)（署名-非商业性使用）：可以免费下载、使用、修改、转发，但要注明出处，不能商用。详见 [LICENSE](LICENSE)。
- **角色形象和 `art/frames/` 里的动画帧**：是社区 Claude 拟人形象的二次创作，形象本身的权利归原作者，不在上面的 CC 授权范围内。仅供个人、非商业交流使用；原作者如有异议，请提 issue，我们会删除。
- 这是粉丝做的非官方项目，与 Anthropic 无关。Claude 是 Anthropic 的商标。
