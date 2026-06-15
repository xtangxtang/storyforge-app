# video_generate_ark

用已审阅的控制首帧生成 Ark Seedance 视频片段。

## Reads

```text
stages/05_keyframes.json
```

## Writes

```text
stages/06_videos.json
clips/*.mp4
review/06_videos.md
```

## Rules

- 只在关键帧已由 agent 和用户审阅后运行。
- 按每条 keyframe 的 `render_mode` 路由：
  - `i2v`（默认）：从无清晰真人脸的控制首帧驱动，例如背影、过肩、地点建立镜头或物件/动作特写。首帧负责锁方向、空间和动作初态，输出视频中可以按剧情出现正脸。
  - `t2v`：用于必须从正脸情绪/对白镜头开始、无法合理做无脸首帧的镜头。`video_prompt` 必须自包含主语、动作、场景和因果；方向、地点和身份由参考图辅助。
- 默认不要把上一条视频作为 `reference_video`，除非明确传入 `chain_reference_video`；否则容易干扰运动方向并增加审核风险。
- 本地首帧图片提交 Ark 前会转为 data URL。
- 所有 prompt 都必须附带无字幕、无文字、无水印、无 logo 的整洁画面约束。
- 失败片段写入 `stages/06_videos.json`，不中断整个批次。

## CLI

```bash
python -m storyforge.cli --project <project-id> run video_generate_ark
```
