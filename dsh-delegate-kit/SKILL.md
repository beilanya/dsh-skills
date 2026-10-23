---
name: dsh-delegate-kit
description: 把执行类工作委派给命令行版 dsh（DeepSeek Harness，dsh headless，模型由用户在 setup 时选定）：主 Agent 负责思考、写任务单、审核，dsh 负责写代码、检索定位、构建测试、排查取证、网页和桌面操作。用户说 /dsh-delegate-kit 或 $dsh-delegate-kit（含 help、setup、status、check、repair、stats、diag、rules、update、uninstall、on、off），说“交给 dsh 做”“派给 dsh”，或全局规则要求委派时使用。Delegates coding, search, build/test and browser/desktop work from Claude Code or Codex to the dsh CLI on Windows.
---

# dsh-delegate-kit（通用入口）

本文件是通用入口，供 `npx skills add` 这类不区分宿主的安装方式使用。Claude Code 和 Codex 的派发方式不同，具体流程分别写在本目录 `hosts\` 下。

每次使用本 Skill 时先做这一步：

1. 判断自己运行在哪个宿主里：
   - Claude Code（含 Claude 桌面端的 Code 页）：读取本目录下的 `hosts\claude-code.md` 全文。
   - Codex（含 Codex 桌面端）：读取本目录下的 `hosts\codex.md` 全文。
   - 其他宿主：告诉用户本 kit 只支持 Windows 上的 Claude Code 和 Codex，然后停止。
2. 完全按读到的文件执行用户的请求（例如 `setup`、`help` 或委派任务）。文件里说的「本 Skill 目录」就是本文件所在的目录，`$KIT` 是本目录下的 `scripts`。
3. 同一会话里已经读过对应文件、内容还在上下文里时，不用重复读取。
