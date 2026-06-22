# director_style_select

选择本项目的导演语言/流派风格，并把它持久化为后续所有视觉阶段必须读取的风格层。

它叠加在 `style_select` 之后：`style_select` 负责电影/短剧/漫剧/动画/纪实等生产类型，`director_style_select` 负责日系治愈、青春校园写实、运动热血写实等导演语言。

## Reads

```text
stages/01_script.json
stages/00_style.json
wiki/style.md
```

## Writes

```text
stages/00a_director_style.json
wiki/director_style.md
review/00a_director_style_select.md
```

## Input

```json
{
  "director_style": "japanese_healing",
  "director_style_note": "可选用户补充"
}
```

如果不传 `director_style`，skill 会输出可选项并停在用户选择门。

## Built-In Options

- `japanese_healing`：日系治愈风格。
- `youth_campus_realism`：青春校园写实风格。
- `youth_inspirational_campus`：青春励志校园风格。
- `sports_hotblood_realism`：运动热血写实风格。
- `urban_lyrical_restraint`：都市抒情留白风格。
- `eastern_color_ensemble`：东方浓彩群像风格。

## Rules

- 不要把导演语言写成单纯的名人模仿标签；必须落成可执行的视觉、机位、调度、表演、剪辑和 prompt 规则。
- 后续 `scene_bible`、`scene_reference_plan`、`asset_design`、`storyboard_plan`、`atomic_shot_plan`、`keyframe_plan`、`keyframe_generate_ark`、`video_generate_ark` 和 `scene_transition_plan` 必须读取 `wiki/director_style.md`。
- `director_guard_agent` 必须按该导演语言审查镜头调度是否跑偏。
- 更换导演语言后，应重跑或复查所有后续视觉 stage。
- 所有字段值使用简体中文。

## CLI

```bash
python -m storyforge.cli --project <project-id> run director_style_select --input-json "{\"director_style\":\"japanese_healing\"}"
```
