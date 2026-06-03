---
name: commit
description: 基于当前 git 暂存/工作区改动,生成一条规范的中文提交信息并提交。当用户说"提交 / commit / 帮我 commit"时使用。
disable-model-invocation: true
---

# 规范化中文提交

为当前改动生成一条清晰的**中文**提交信息并提交。目标:取代仓库里 "update"、"update" 这种无信息量的提交记录。

## 步骤

1. 先看清楚改了什么:
   - `git status`
   - `git diff --staged`(若没有暂存内容,看 `git diff`)
   - `git log --oneline -10`(对齐已有风格)
2. 若没有任何暂存内容,先 `git add` 相关文件(只加与本次改动相关的,不要无脑 `git add .`;留意不要提交日志、构建产物、密钥)。
3. 生成提交信息(见下方格式),用 here-string 传给 `git commit`。
4. 提交后 `git log --oneline -1` 回显确认。

## 提交信息格式

采用 Conventional Commits 前缀 + 中文描述:

```
<type>: <一句话说明本次改动做了什么>

- 要点1(可选,解释为什么 / 影响范围)
- 要点2(可选)
```

`type` 取值:`feat`(新功能)、`fix`(修 bug)、`refactor`(重构)、`perf`(性能)、`docs`(文档)、`test`(测试)、`chore`(杂项/依赖/构建)。

本项目场景示例:
- `feat: 新增 TranslationAgent 字幕翻译阶段`
- `fix: 修复 DashScope 视频轮询超时后未释放任务`
- `refactor: ProjectDetailScreen 拆分分镜列表为独立 widget`
- `chore: 升级 sqflite_common_ffi 并更新 dependency_overrides`

## 约束

- **只在用户明确要求时提交**;不要自动 push。
- 信息正文一律中文;不要写成 "update"。
- 不要使用 `--no-verify` 跳过钩子;若钩子失败,先修问题。
- 当前在 main 分支且改动较大时,先提醒用户是否需要新建分支。
