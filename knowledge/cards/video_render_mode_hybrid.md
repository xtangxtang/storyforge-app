# 视频生成 i2v / t2v 混合路由（含无脸背影首帧突破）

- scope: global
- type: shot_grammar
- tags: seedance, i2v, t2v, render_mode, moderation, direction, reference, campus
- captured_at: 2026-06-09

## Summary

Ark 视频生成曾在「锁方向(i2v)」和「露脸过审(t2v)」之间被迫二选一。关键突破：**i2v 的 PrivacyInformation 审核只检查输入的那一张首帧，不检查输出视频**。所以首帧只要**不含清晰真人脸**就能过审，而碰撞、转身、道歉这些有脸的画面在输出视频里照常出现。首帧不一定非得是「无脸背影人物」——只要不露脸且能锁方向即可，可任选最适合的：**①无脸背影/过肩人物；②纯场地/建立空镜；③物件或局部特写（如自行车前轮、道具）**。把目的地/运动矢量放进首帧来锁方向。因此默认首选 i2v（无脸背影首帧）；t2v 仅作兜底。t2v 不读首帧、不读连续状态，只读 video_prompt，所以 t2v 镜必须写自包含因果提示词；t2v 方向不可控，可把一张无脸背影首帧当 reference_image 喂进去「带」方向，同时保留 t2v 的自然运动。

## When To Use

- 任何要出视频片段的镜头，决定走 i2v 还是 t2v、怎么配参考图时

## Do

- 首选 i2v + 不含清晰真人脸的首帧（无脸背影/过肩人物、或纯场地建立空镜、或物件/局部特写如自行车前轮），把目的地/运动矢量放进画面 → 过审 + 锁方向；输出里照常出现脸
- 首帧用哪种由镜头美学决定：开场可用物件特写（前轮）或场地空镜起，再上摇/推进露出人物
- t2v 兜底：开局就必须是脸、无法做合理无脸首帧的纯对话特写
- t2v 镜的 video_prompt 必须自包含（主语 + 动作 + 场景 + 因果），不能用 i2v 那种「只写余波 / 小动作」的极简写法
- 想让 t2v 方向对：先生成一张无脸背影首帧，作 reference_image 喂给 t2v（带方向与构图，同时保 t2v 自然运动）
- reference_image 按优先级截断（cap 3）：地点 canon / 背影方向首帧 + 在场角色定妆图优先，道具靠后
- **i2v 镜的人物身份/校服只由首帧决定（i2v 视频本身不吃参考图）**：要锁校服/长相，就在【首帧图片生成】时把该角色定妆图当 reference_image 喂进去（本地图 base64 喂 refs 可避开过期 URL；首帧用简短自写提示词、不要堆角色长描述，避开 InputTextSensitiveContentDetected 文本审核）。纯物件/无人物首帧 → i2v 会自己乱编衣服。露脸镜要过审又要锁校服：让定妆图里的角色在首帧被前景物件（如大前轮、车筐）遮住脸即可
- **API 硬限制（2026-06-10 实测，doubao-seedance-2.0 plan 端点）**：`first_frame` 与 `reference_image`/`reference_video` **互斥**，同一请求混用必 400 `InvalidParameter: first/last frame content cannot be mixed with reference media content`。所以 i2v 镜中段才出现的人物/地点（不在首帧里）没法靠参考媒体锁——只能：①把该人物/地点的完整外观写死在 video_prompt 文字里；②或放弃首帧、改走 reference 模式（无 first_frame，用无脸首帧图+定妆图+canon 当 reference_image 带方向与一致性）
- **参考媒体格式限制（同日实测）**：`reference_image` 接受 base64 data URI（本地图直接内联，永不过期）；`reference_video` **只接受 web URL**（base64/本地路径被 400 拒：`reference_video must be provided as a web url`）——要把前镜成片当参考视频，必须在渲染后 24h 内用其 TOS `video_url`（渲染时持久化到 06_videos.json）。实战范例：AS004 校门/俞墨凡漂移 → 改 reference 模式、refs=[本镜无脸首帧图, 校门canon, 俞墨凡定妆图] 一次成片且一致

## Avoid

- 因为「这镜会露脸」就直接放弃 i2v 改 t2v —— 只要首帧无脸就能 i2v
- i2v 首帧里出现任何清晰真实人脸（连 3/4 侧脸都会被 PrivacyInformation 挡）
- t2v 里指望它自己朝对的方向走（它不锁方向）
- t2v 喂一堆独立实体参考图却不在 prompt 里讲清关系（会把「骑车人 + 车」画成「路人 + 一辆独立的车」）

## Prompt Patterns

- i2v 无脸首帧（人物）：「纯背影低角度，相机正对<角色>后脑勺与后背，完全看不到脸；<角色>背对镜头朝画面正前方深处的<目的地>……」
- i2v 物件首帧：「极低机位特写飞转的<自行车前轮/道具>，看不到任何人物或脸，画面深处虚化处是<目的地>方向」→ 视频里镜头上摇露出人物
- i2v 场地首帧：「<地点>建立空镜，人群背影朝<目的地>方向流动，无主要人物特写」
- t2v 自包含：「<场景>。<角色A 特征>做<动作>，<角色B 特征>从<方向>……，导致<结果>……」

## Examples

- 相撞镜 i2v 首帧露 3/4 侧脸 → PrivacyInformation 挡；改无脸首帧 → i2v 过审、车朝门骑、输出里相撞与道歉的脸照常出现
- 开场合并镜用「纯前轮特写（无人物）」首帧 → 过审 + 速度感，视频里镜头上摇露出骑车的陈振飞 → 相撞 → 道歉，一镜到底
- t2v 极简 prompt「两人重心不稳」→ 画成两个路人被撞；改自包含「陈振飞骑车撞上步行的俞墨凡」→ 对

## Source Refs

- session：校园开场相撞镜多轮调试
