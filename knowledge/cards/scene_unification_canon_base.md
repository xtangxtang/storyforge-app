# 跨镜头场景统一（锚定单张 canon 基准图）

- scope: global
- type: continuity_method
- tags: continuity, scene, unification, reference, location, seedream, i2v, anchor
- captured_at: 2026-06-08

## Summary

让同一地点在多个镜头里看起来是「同一座门 / 同一间教室」，做法是先为每个地点生成一张唯一的 canon 基准空镜，再让该地点所有镜头的首帧都以这张基准图作参考图来生成。这样门楼 / 教室结构被统一压住，而首帧仍是背影 / 过肩、方向各自锁定。角色身份用定妆图（character sheet）作另一路参考图。参考图只喂「首帧图片生成」，绝不喂「视频生成」。

## When To Use

- 一个地点跨多个镜头、需要视觉统一（开场连续几镜都在校门口；教室里多镜）
- 同一角色跨镜头需要保持身份一致

## Do

- 每个地点先出 1 张 canon 基准空镜（统一服装人群背对镜头、无主要人物特写）
- 该地点每个镜头的首帧图都 refs=[canon_基准图] 再生成
- 角色身份用定妆图作另一路参考图，和 canon 基准图一起喂首帧
- 参考图只喂首帧图片生成，不喂视频生成
- **纯建立/环境镜（只有地点、没有角色）直接用该地点 canon 当首帧，不要再生成一张**——seedream 拿 canon 当参考也是「生成新图」会漂移、质量不如原图；建立镜直接复用 canon 最稳

## Avoid

- 每个镜头各自独立生成首帧 → 门 / 教室结构互不一致（出现两座不同的门）
- 把 canon 基准图喂给视频生成（会把相机拽成基准图的正面机位）

## Prompt Patterns

- canon 基准：「<地点>空镜，电影感，<结构细节>，统一校服学生背对镜头朝<目标>方向，无主要人物特写」
- 首帧 = frame_prompt(背影 / 过肩) + refs=[canon_base, character_sheet…]

## Examples

- 1-1 与 1-2 之前是两座不同的门 → 都锚定 canon_门口 后统一为同一座「茅盾中学」门楼

## Source Refs

- session: B+ 方案，canon 基准图统一校门 / 教室
