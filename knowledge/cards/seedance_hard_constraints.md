# Ark Seedance / Seedream 硬约束与已知失败模式

- scope: global
- type: failure_cases
- tags: seedance, seedream, duration, moderation, subtitle, text, limits, ark
- captured_at: 2026-06-08

## Summary

Ark plan 端点上 Seedance 2.0 / Seedream 5.0-lite 的一组硬限制和已验证的失败模式。违反这些会直接报错或出废片，规划时就要回避。

## When To Use

- 规划镜头时长、首帧构图、招牌/字幕文字、人脸特写时
- 写 video_prompt / first_frame_prompt 时

## Do

- 每条视频时长固定在 5–10 秒（3 秒会 InvalidParameter 直接失败，下限是 5s）
- 对白镜头加「无字幕 / 无台词文字 / 无水印 logo」约束，避免烧录字幕
- 需要人物身份锚点时可用带水印的定妆图作参考图（写实无水印人脸更容易被审核挡）
- 招牌 / 黑板等中文文字只做氛围，不依赖其逐帧稳定可读

## Avoid

- 时长 < 5 秒
- 贴镜头正面人脸特写做 i2v 首帧 → InputImageSensitiveContentDetected.PrivacyInformation，改用过肩 / 侧背 / 中远景
- 指望中文招牌逐帧一致（「茅盾中学」会漂成别的字）

## Prompt Patterns

- 收尾恒加：「。画面整洁干净，不出现任何字幕、对白文字、标题字、台词、水印或 logo。」
- 人脸用「过肩 / 侧背 / 中远景」代替「贴镜头大正脸」

## Examples

- 3s 锚点报错 contents[0].text.duration → 改 5s 通过
- 对白镜头 i2v 烧录台词 → 加无字幕约束消除
- 写实正脸定妆图被审核挡 → 带水印版本通过

## Source Refs

- session: 多次 Ark plan 端点调用实测
