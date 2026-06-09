# 先抽取共享元素再统一（Consistency Bible）

- scope: global
- type: continuity_method
- tags: consistency, uniform, layout, props, bible, pipeline, unification
- captured_at: 2026-06-09

## Summary

跨镜头统一不能靠每个镜头各自描述——校服、教室布局、复用道具一旦各镜自由发挥就会漂移（白蓝校服→纯白、课桌排列每镜不同）。正解：在所有视觉设计**之前**，先抽取一份**共享元素清单（Consistency Bible）**：统一校服、配色、各地点固定布局与方位、复用道具统一外观、世界规则；然后 asset_design、canon 基准图、定妆图、分镜、原子镜、首帧**全部引用它、不得各自发明**。canon 基准图生成时把「统一校服 + 该地点布局」烘进提示词，从源头统一。

## When To Use

- 任何多镜头项目；在 script_ingest / style_select 之后、asset_design 之前先跑

## Do

- 先用 `consistency_bible` 抽取 `{uniform, fixed_outfits, palette, location_layouts, recurring_props, world_rules}`，写进 `wiki/consistency.md`
- canon 基准图 / 定妆图生成时烘进统一校服 + 该地点固定布局（从源头统一锚点）
- 分镜 / 原子镜 / 首帧 prompt 一律引用 bible，不重新描述校服 / 布局 / 道具
- 把「穿在所有人身上的统一校服」「同一地点的固定布局」这类**跨实体共享属性**显式锁定，而不只锚单个 asset
- 建立镜 / 人群锚点要写清人流真实细节：**携带物**（如开学背双肩书包 / 拖行李箱）、**间距密度**（三三两两、拉开自然间距、不聚堆不列队）——否则模型会把人挤成一团且漏掉书包

## Avoid

- 让每个镜头各自描述校服 / 教室布局（必漂）
- 只锚地点 canon 与角色定妆图，却漏掉跨实体的共享属性（统一校服、复用道具）
- 把不复用的一次性细节也塞进 bible（只锁真正跨镜头共享的）

## Prompt Patterns

- 「画面中所有学生一律统一校服：<bible.uniform>」
- 「该地点固定布局（与全片一致）：<bible.location_layouts[地点]>」

## Examples

- 校服没统一、教室布局每镜不同 → 先 `consistency_bible` 锁定，再让 asset_design 与各阶段引用，锚点与镜头随之统一

## Source Refs

- session：用户指出共享元素（校服 / 教室布局）需先抽取再统一
