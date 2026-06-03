/// 题材/场景创作模板库（雏形）。
///
/// 设计分层（从广泛到具体）：
///   通用基座 prompt（与题材无关，见 agents.dart 各 *SystemPrompt）
///   + [可选] 本文件的题材模板（用户挑选或按题材自动匹配）
///   + 用户的具体创意输入（最高优先级）
///
/// 这一层只携带"题材风格倾向"（视觉风格、情绪、节奏、镜头语言、常见坑），
/// 不写死任何具体人物/地点/道具——具体内容永远来自用户的剧本。
/// 注入方式：把选中模板的 [toPromptHint] 作为 `参考模板` 传入各 Agent 的上下文
/// （PlanningAgent 已支持 context.data['template']；可同理接到编剧/分镜阶段）。
///
/// 这是一个可扩展的雏形——按需增删题材、补充场景模式条目即可。
class CreativeTemplate {
  /// 稳定 key（用于持久化用户选择）。
  final String id;

  /// 显示名。
  final String name;

  /// 对应 Brief.genre 的倾向。
  final String genre;

  /// 一句话情境提示，可作为用户创意的起点/占位（不强加具体人物）。
  final String synopsisHint;

  /// 视觉风格倾向（注入 brief 的 visual_style 方向；保持"看起来怎样"，不含构图/机位）。
  final String visualStyle;

  /// 情绪基调。
  final String mood;

  /// 节奏与镜头语言倾向。
  final String pacing;

  /// 该题材常见的注意点 / 易踩的坑。
  final String notes;

  const CreativeTemplate({
    required this.id,
    required this.name,
    required this.genre,
    required this.synopsisHint,
    required this.visualStyle,
    required this.mood,
    required this.pacing,
    required this.notes,
  });

  /// 注入到各阶段上下文的提示片段。用户创意优先——与本模板冲突时以用户为准。
  String toPromptHint() => '''
【题材模板：$name（$genre）— 仅作风格倾向参考，与用户创意冲突时以用户为准】
- 视觉风格：$visualStyle
- 情绪基调：$mood
- 节奏/镜头语言：$pacing
- 注意：$notes''';
}

/// 题材模板雏形清单（覆盖几个常见题材，后续可继续补充）。
const List<CreativeTemplate> kCreativeTemplates = [
  CreativeTemplate(
    id: 'campus_youth',
    name: '校园青春',
    genre: '青春校园',
    synopsisHint: '校园里几个同龄人之间一次小小的相遇/误会，引出青春的悸动与羁绊。',
    visualStyle: '清新自然光、明亮通透、轻微胶片质感，突出季节与校园环境细节',
    mood: '青春、明快、略带怀旧或悸动',
    pacing: '生活流，跟拍与自然过渡为主，节奏轻快',
    notes: '同校角色服装应统一；动作贴近日常、避免夸张；多用环境烘托情绪',
  ),
  CreativeTemplate(
    id: 'urban_romance',
    name: '都市情感',
    genre: 'romance',
    synopsisHint: '都市中两个人因一件小事产生交集，情感在日常细节里悄然变化。',
    visualStyle: '都市夜景或暖调室内、浅景深、柔和光斑，精致质感',
    mood: '细腻、温暖、含蓄',
    pacing: '舒缓，重表情与眼神特写，留白多',
    notes: '重点在微表情与肢体细节；环境(咖啡馆/街道/室内)要有生活气但不抢戏',
  ),
  CreativeTemplate(
    id: 'suspense_thriller',
    name: '悬疑惊悚',
    genre: 'thriller',
    synopsisHint: '一个看似平常的处境里藏着异样，线索逐步逼近真相。',
    visualStyle: '低调冷色、强对比阴影、局部光，质感粗粝',
    mood: '紧张、压抑、不安',
    pacing: '克制中带突变，善用空镜与节奏停顿制造悬念',
    notes: '靠光影与构图营造威胁感，而非血腥；关键信息逐步释放、不要一次说尽',
  ),
  CreativeTemplate(
    id: 'scifi',
    name: '科幻未来',
    genre: 'sci-fi',
    synopsisHint: '在一个有别于当下的科技/世界设定里，角色面对一次抉择或异常。',
    visualStyle: '冷调金属/霓虹光、体积光、未来感材质与空间',
    mood: '冷峻、宏大或孤寂',
    pacing: '建立镜头交代世界观，再聚焦人物；运镜可更大气',
    notes: '世界观元素要一致连贯；避免堆砌特效而忽略人物动机',
  ),
  CreativeTemplate(
    id: 'period_drama',
    name: '古风年代',
    genre: 'daily',
    synopsisHint: '在某个特定年代/古典背景下，一段人物关系或一件小事缓缓展开。',
    visualStyle: '与年代相符的服化道与色调、自然光、考究的环境陈设',
    mood: '怀旧、典雅或厚重',
    pacing: '沉稳，重氛围与仪式感，镜头平稳',
    notes: '年代/朝代的服装、道具、环境必须一致且符合设定；避免现代物件穿帮',
  ),
  CreativeTemplate(
    id: 'healing_daily',
    name: '治愈日常',
    genre: 'daily',
    synopsisHint: '平凡一天里的一个温暖小瞬间，安静而有余味。',
    visualStyle: '柔和暖光、自然色调、生活化场景，画面干净舒适',
    mood: '温暖、平静、治愈',
    pacing: '慢节奏，长镜头与细节特写，少冲突',
    notes: '靠细节与光线传递情绪；动作平缓、避免戏剧化冲突',
  ),
];

/// 按 id 取模板（找不到返回 null）。
CreativeTemplate? creativeTemplateById(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final t in kCreativeTemplates) {
    if (t.id == id) return t;
  }
  return null;
}
