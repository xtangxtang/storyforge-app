# 框架输出统一使用中文

- scope: global
- type: framework_rule
- tags: language, output, review, prompt

## Summary

Storyforge 的所有面向用户、审阅、创作和提示词内容默认使用简体中文。JSON 字段名、CLI 参数名、文件名、skill id 可以保留英文，但字段值、说明、审阅意见、创作 prompt、风格规则、风险提示、修改建议应使用中文。

## When To Use

- 生成 stage 产物时
- 生成 agent review 和 user review package 时
- 生成视觉锚点、分镜、原子镜头、关键帧和视频 prompt 时
- 编写知识卡、风格档案、项目 wiki 时

## Do

- 使用简体中文表达所有人类可读内容
- 必要的技术标识保留英文，例如 `skill_id`、`stages/01_script.json`
- 如果模型需要英文提示词，由专门翻译步骤处理，不要把英文作为默认用户可见内容

## Avoid

- 英文审阅标题和英文风险提示
- 中英混杂的风格规则
- 面向用户的 stage message 使用英文

## Prompt Patterns

- 所有面向用户和创作内容必须使用简体中文；JSON 字段名可以保持英文
- 请用中文输出审阅意见、风险、修改建议和下一步确认点

## Source Refs

- user: 整个框架的输出的内容都要用中文
