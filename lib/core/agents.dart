import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'agent.dart';
import '../config/app_config.dart';
import '../config/creative_templates.dart';
import '../services/llm_service.dart';
import '../services/media_service.dart';
import '../models/models.dart';
import '../services/app_logger.dart';
import '../services/persistent_image_store.dart';

const _briefSystemPrompt = '''你是专业的影视策划人。根据用户的创意描述，生成一个短剧项目的 Brief。

要求输出严格的 JSON 格式，不要任何多余的文字：
{
  "genre": "类型（romance/thriller/sci-fi/daily/comedy）",
  "duration": 目标时长（秒，30-120之间）,
  "aspect_ratio": "画面比例（9:16 或 16:9）",
  "mood": "情绪基调",
  "visual_style": "视觉风格描述（中文）",
  "story_outline": "故事大纲（200字以内，中文）"
}

默认：竖屏 9:16，时长 60-90 秒，面向手机短视频。''';

const _scriptSystemPrompt = '''你是专业影视编剧。根据创意编写短剧剧本，必须输出严格 JSON 格式，不要任何多余文字。

JSON 结构必须完全匹配：
{
  "scenes": [
    {
      "scene_num": 1,
      "location": "场景名称",
      "description": "场景描述（中文）",
      "action": "角色动作（中文）",
      "dialogue": ["台词1", "台词2"],
      "duration": 15
    }
  ],
  "assets": [
    {"type": "character", "name": "角色名称", "description": "角色视觉描述（中文，详细描述外貌、服装、发型等用于AI图像生成）"},
    {"type": "location", "name": "场景名称", "description": "场景视觉描述（中文，详细描述环境、光线、色调等用于AI图像生成）"},
    {"type": "prop", "name": "道具名称", "description": "道具视觉描述（中文，详细描述外观、材质、颜色等用于AI图像生成）"}
  ]
}

要求：
- 2-5 个场景，总时长匹配目标时长
- 每个场景必须有 scene_num, location, description, action, dialogue, duration
- 提取所有角色(character)、场景(location)和关键道具(prop)作为 assets
- 关键道具指对剧情有重要作用或多次出现的物品
- 所有 description 必须用中文，详细描述用于 AI 图像生成
- dialogue 可以是空数组

【资产描述的最高优先级规则 — 必须严格遵守】

1. **角色(character)描述要求**：
   - 必须明确角色的具体类型和身份（人物/动物/物体/拟人化角色等）
   - 必须描述核心外观特征（形状、颜色、尺寸、材质等）
   - 必须描述关键视觉细节（用于区分该角色与其他类似事物）
   - 示例格式："一个拟人化的包子角色，白色面团身体，带有笑脸表情，戴着红色厨师帽"
   - 禁止使用模糊描述如"一个东西"、"某个角色"
   - 描述必须与创意描述中的角色设定一致

2. **场景(location)描述要求**：
   - 必须明确场景类型（室内/室外/虚构空间等）
   - 必须描述主要建筑物或环境特征
   - 必须描述光线和色调
   - 示例格式："室外场景，某地点入口，对应年代与风格的建筑，早晨阳光，暖色调"

3. **道具(prop)描述要求**：
   - 必须明确物品的具体类型
   - 必须描述外观、材质、颜色
   - 示例格式："一辆老式自行车，金属框架，黑色车架，橡胶轮胎"
''';

const _storyboardSystemPrompt =
    '''你是专业分镜师。你的任务是把剧本切成若干「连续 beat」，每个 beat 会被生成为**一整段连续视频**。必须输出严格 JSON，不要任何多余文字。

【什么是一个 beat（最重要的概念，必须正确理解）】
- 一个 beat = **一个不间断的连续镜头（单条运镜的一镜到底）**，会被作为**一整段视频**生成。
- 因此一个 beat 内部的动作、道具状态、人物位置天然是连续的——这正是用来保证连贯性的手段。
- **同一时间、同一地点、连续不断发生的动作，必须合并进同一个 beat**，即使中间镜头要移动（用运镜表达）。
- **多人互动事件绝不能拆**：两个角色之间一次连续的互动（碰撞、对话、递东西、搀扶等），从起因到反应到收尾是一个完整 beat，必须把**所有参与角色放进同一个 beat 同框演完**。
- **即使剧本把这次连续互动拆到了不同场景**（如：碰撞在场景1、对方的反应/离开在场景2），只要时间地点连续，就必须合并成同一个 beat，characters 列出事件中全部在场角色。
  抽象示例（仅示范原则，勿照搬内容）：「主体A 朝主体B 移动 → 与 B 发生连续互动（碰撞/对话/递物等） → B 作出反应 → A、B 完成收尾各自动作」整段是**一个 beat**，characters 同时列出 A 与 B，绝不能把 B 的反应单独拆成另一个 beat（拆开会导致互动对象凭空出现/消失、关键道具忽有忽无、动作不接）。
- **只有遇到下列情况才切换到新的 beat**：
  1) 换地点 / 换场景（如从一个地点切到另一个地点）；
  2) 明显的时间跳跃；
  3) 必须切到一个无法用连续运镜衔接的全新视角（如从街上切到另一人的主观视角）。
- 不要为了"多几个镜头"而把连续动作切碎；也不要把跨地点/跨时间的内容硬塞进一个 beat。

【最高优先级规则 — 违反任一条输出将被拒绝】
1. 角色绝对忠于剧本：用剧本中的角色原名；剧本是男生就是男生、是女生就是女生，不得改性别；不得凭空添加角色。
2. 剧情/地点/道具绝对忠于剧本：不得新增事件、相遇、冲突；不得替换地点或道具。
3. 一个 beat 只能在一个地点、一段连续时间内。
4. 专有名词（人名/地名/机构名/品牌等）必须与剧本原文逐字一致，严禁改写或另起名；画面中出现的招牌/牌匾/标识文字必须写成剧本里的原文。
5. 机位/构图：户外动作或碰撞 beat 必须用清晰无遮挡的机位（平视或低角度跟拍，主体完整入画），严禁隔着窗户/门框/栏杆/前景障碍物拍摄；隔窗/门框/前景遮挡的构图只允许用在"室内人物向外观望"这类 beat。

JSON 结构必须完全匹配：
{
  "storyboards": [
    {
      "scene_num": 1,
      "shot_num": 1,
      "continuous_camera": true,
      "shot_type": "wide",
      "camera_move": "dolly",
      "characters": ["角色原名"],
      "description": "这一整段连续镜头的画面与动作（中文，用角色原名）",
      "first_frame_prompt": "这段连续镜头**开场第一帧**的画面（中文，五维度：[主体描述]出场角色外貌/服装/此刻姿态/表情；[细节描述]关键道具及其此刻状态；[背景描述]场景环境与景别；[光影描述]光源/色调；[情绪描述]情绪基调）。注意：写的是 beat 开始那一刻、动作即将发生的状态，而不是动作结束后的状态。",
      "video_prompt": "这一整段连续镜头的内容（中文），严格按下文 Seedance 公式 ①~⑧ 结构写。",
      "duration": 8
    }
  ]
}

字段要求：
- scene_num 对应剧本场景号；shot_num 是该场景内 beat 的序号（1,2,...）。
- continuous_camera：该 beat 是否为需要连续运镜的一镜到底（连续动作 beat 为 true；纯空镜/建立镜头可为 false）。
- shot_type 用 close-up/medium/wide/extreme-close-up（指这条镜头的主景别）。
- camera_move 用 static/pan/zoom/tilt/dolly/follow（这条连续镜头主要的运镜方式）。
- characters：本 beat 画面中**实际出现**的角色原名数组；空镜写 []。这直接决定该镜头调用哪些角色参考图，必须与画面严格一致，不要列入未出现的角色。
- description / first_frame_prompt / video_prompt 中所有人物一律用剧本原名，禁止用"他/她/一个人/路人"等模糊指代。
- duration：覆盖整个 beat 的时长，建议 5-10（秒）；连续动作 beat 通常较长。

【video_prompt 必须按 Seedance 2.0 公式「主体+动作+场景+光影+镜头+风格+画质+约束」写成一段连贯中文，顺序如下】
①【主体】（最重要、写在最前）开场画面里每个在场角色的外貌/服装/年龄/表情 + 此刻姿态（与 first_frame 一致）；只用"能被画出来"的具体形容词，不要"美/好看/帅"等主观词。
②【动作】用「先…→紧接着…→随后…→最后…」把整段动作写成一条不间断、连贯自然流畅的时间线，显式写出动作之间的物理因果（抽象示例：「主体A 做出动作并因某原因导致后果X → 触发 B 的反应Y → 同一瞬间道具Z 因受力发生状态变化 → 各自收尾」）；动作要连贯不僵硬（该慢则慢、该快则快但始终流畅）；关键道具全程连续、不凭空有无。
③【场景】地点、年代、天气、前景/背景关键元素。
④【光影】光源方向、色温、明暗关系。
⑤【镜头】景别（近景/中景/全景/特写）+ 单一主运镜（如缓慢推镜/轻微拉远/平稳横移/低角度跟拍/环绕半圈），单独成句；整段只用一种主运镜，绝不在一个 beat 里切换多种机位或描述剪切。
⑥【风格】影调与氛围（题材对应的视觉风格、情绪基调）。
⑦【画质】固定补一组可被渲染的画质词：电影质感、画面稳定、锐度清晰、光影柔和、色彩自然。
⑧【正向约束】（Seedance 规则：只说"要什么"、不说"不要什么"，全部用正向词）结尾固定加一句：「五官清晰、面部与身体稳定、人体结构正常、比例自然、动作连贯不僵硬、同一角色服装发型保持一致、运动符合重力与惯性、一镜到底连贯流畅」。
- 一个 beat 只承载一条连续动作链，可包含完整事件（起因→过程→反应→收尾），因为是一整段连续视频不会被切断。
- 凡剧本写到某角色"离开/进入/前往某处"，video_prompt 必须写成**实际完成的连续位移**（转身→迈步→走向目标→穿过/进入→远去），明确人物移动并最终离开画面或抵达目标；不要让人物停在原地或只给一个静态结束姿势。

【剪切点必须接得上 — 相邻 beat 衔接，最高优先级】每个 beat（除第1个）的开场必须**严格承接上一个 beat 的结尾状态**：上一镜结尾时主体在画面什么位置、什么景别（远景/中景/近景）、朝向哪、正在做什么动作，本镜**开场就从那个状态接着开始**。同一主体、同一地点的连续动作尤其要对齐：景别、人物在画面里的大小与位置、朝向、正在进行的动作，都要和上一镜结尾一致，像同一条连续镜头被切成两段；绝不能突然跳成另一个景别（如远景结尾→近景特写开场）。只有真正换场景/换地点才允许换景别，且用建立镜头平滑过渡。在每个 beat 的 first_frame_prompt 与 video_prompt 的【主体起始】里都要显式写出"承接上一镜结尾：……（上一镜结尾的景别/人物位置/朝向/动作）"。

【场景模式规则库 — 按每个 beat 的实际类型，挂载适用的模块（与题材无关，适用于任何同类场景；下列示例均为抽象占位，勿照搬内容）】
〔物理碰撞 / 剧烈接触〕碰撞瞬间分解到帧级让冲击可见：接触前（主体A 高速接近、对方未察觉）→接触瞬间（写明 A 的哪个部位撞到 B 的哪个部位、B 如何反应：上身前倾/侧倾、踉跄迈出一步、双臂张开找平衡）→接触后（B 晃动后才站稳；A 因惯性前冲、急停）。力度真实可信（踉跄而非夸张飞出），但必须明确"发生了实打实的接触"，不要写成擦肩而过或提前停下。被携带/被持的道具要在撞击那一刻因冲击被猛地弹飞、划抛物线落地，而非缓缓滑落。
〔从高处/窗户目睹他人〕用"过肩俯视"：镜头在观望者斜后方，越过其肩膀/侧脸朝窗外**向下俯视**；观望者**半背对或侧对镜头、面朝窗外**（非正脸肖像），前景是其肩头侧脸，中后景透过窗框是楼下；被目睹者因俯视而在画面中**位置偏低、个头较小**；观望者明确在室内（画面有室内景物线索）；characters 同列"观望者"与"被目睹者"，且被目睹者与其上一镜结尾状态严丝衔接。
〔进入/前往某地〕运动方向写死且正确：主体朝目标由远及近接近并穿过、进入，越走越深入目标内部；**绝不能把"进入某地"拍成背对目标、朝相反方向越走越远**。用镜头与朝向关系消歧（如"目标在主体正前方、他朝里走"，或"镜头在入口内侧朝外、主体从外面朝镜头走来并穿过入口进入"）。
〔随身道具持续〕角色随身携带/操作的物品或交通工具，在 beat 内与跨 beat 必须被合理处置：人物移动/换场景时要带着它一起，绝不能让它凭空消失，也不能无故丢弃在原地（除非剧本明确要求）；如推/扶着某物移动，要写明"一手扶着…一边移动"。
〔公共/生活场所〕公共场所（街道、广场、校园、车站等）的 beat 要在环境里写出可信的背景人物活动，让画面有生活气息；但背景人物只能是模糊的次要群众，不抢主体、不与主角互动、不得是剧本里的具名角色。

【综合示例（抽象占位，仅示范结构与原则，切勿照搬内容）】某 beat 是一次连续碰撞互动：主体A 快速移动、来不及避让而撞上主体B；B 踉跄一步、A 随身携带的小物件因冲击弹飞落地；A 急停、伸手致意；B 站稳后转身离开、走向远处并最终离开画面。镜头全程低角度跟拍 A 并随其移动平稳横摇，撞击后转固定记录二人互动。下一 beat 开场承接上一镜结尾（B 已离开、A 留在原地的同一景别与位置），从该状态接着演下去。''';

/// Derives ONE unified school/team uniform shared by every character. Cross-shot
/// inconsistency's biggest root cause was each character getting a *different*
/// outfit (the script invents a per-character 校服), so when cut together it
/// looks like different worlds. We compute a single canonical uniform once and
/// force every character sheet to wear exactly it (keeping only per-character
/// face/hair/glasses/build).
const _uniformSystemPrompt =
    '''你是影视服装指导。如果剧本里的学生/团队角色应当穿统一制服（如同校学生穿同款校服），请根据剧本的年代、季节、地点设计**唯一一套**统一制服，全体相关角色完全一致。必须输出严格 JSON，不要多余文字：
{"applicable": true, "uniform": "一句话精确描述这套统一制服：上衣款式与颜色、裤子/裙子款式与颜色、鞋子，要具体且唯一，不要给选项"}
如果剧本角色本就不该穿统一制服（如不同身份的成年人），输出 {"applicable": false, "uniform": ""}。''';

class PlanningAgent extends Agent {
  @override
  String get name => 'PlanningAgent';

  final LlmService llm;
  PlanningAgent({required this.llm});

  @override
  Future<AgentResult> run(AgentContext context) async {
    final prompt = context.data['prompt'] as String?;
    if (prompt == null || prompt.isEmpty) {
      return AgentResult.error('No prompt provided for planning');
    }
    final feedback = context.data['feedback'] as String?;
    final feedbackText = feedback != null ? '\n修改建议（请根据以下建议调整）：$feedback' : '';
    final directorGuidance = context.data['director_guidance'] as String?;
    final guidanceText = directorGuidance != null &&
            directorGuidance.trim().isNotEmpty
        ? '\n\nDirectorAgent 已向用户逐步确认的创作约束如下，必须优先遵守，不要自行覆盖：\n$directorGuidance'
        : '';
    final memoryText = _creativeMemoryInstruction(context);
    final templateText = _creativeTemplateInstruction(context);

    final messages = [
      ChatMessage(role: 'system', content: _briefSystemPrompt),
      ChatMessage(
          role: 'user',
          content:
              '请为以下创意生成 Brief：$prompt$guidanceText$templateText$memoryText$feedbackText'),
    ];

    if (context.data['template'] != null) {
      messages.add(
        ChatMessage(
          role: 'user',
          content: '参考模板：${jsonEncode(context.data['template'])}',
        ),
      );
    }

    try {
      final response = await llm.chatCompletion(
        messages: messages,
        jsonMode: true,
        temperature: 0.8,
        requestTag: 'planning.generate',
      );

      final decoded = jsonDecode(response.content);

      // Handle both {..} and [{..}] responses from LLM
      Map<String, dynamic>? brief;
      if (decoded is Map<String, dynamic>) {
        brief = decoded;
      } else if (decoded is List && decoded.isNotEmpty) {
        final first = decoded[0];
        if (first is Map<String, dynamic>) {
          brief = first;
        } else if (first is Map) {
          brief = Map<String, dynamic>.from(first);
        }
      } else if (decoded is Map) {
        brief = Map<String, dynamic>.from(decoded);
      }

      if (brief == null) {
        return AgentResult.error('LLM returned invalid brief format');
      }

      // Robust field extraction — tolerate string numbers, nulls, etc.
      var genre = brief['genre']?.toString().trim();
      if (genre == null || genre.isEmpty) genre = 'daily';

      final rawDuration = brief['duration'];
      int duration;
      if (rawDuration is num) {
        duration = rawDuration.toInt();
      } else if (rawDuration is String) {
        duration = int.tryParse(rawDuration) ?? 60;
      } else {
        duration = 60;
      }
      duration = duration.clamp(30, 120);

      final storyOutline = brief['story_outline']?.toString();
      if (storyOutline == null || storyOutline.isEmpty) {
        return AgentResult.error(
            'LLM returned invalid brief format (missing story_outline)');
      }

      return AgentResult.success({
        'genre': genre,
        'duration': (duration as num).toInt().clamp(30, 120),
        'aspect_ratio': brief['aspect_ratio'] ?? '9:16',
        'mood': brief['mood'] ?? 'neutral',
        'visual_style': brief['visual_style'] ?? '',
        'story_outline': storyOutline,
      });
    } catch (e, st) {
      await AppLogger.error(
        'Planning agent failed',
        data: {
          'projectId': context.projectId,
        },
        error: e,
        stackTrace: st,
      );
      return AgentResult.error('Planning failed: $e');
    }
  }
}

class ScriptAgent extends Agent {
  @override
  String get name => 'ScriptAgent';

  final LlmService llm;
  ScriptAgent({required this.llm});

  @override
  Future<AgentResult> run(AgentContext context) async {
    final prompt = context.data['prompt'] as String? ?? '';
    final brief = context.data['brief'] as Map<String, dynamic>?;
    final feedback = context.data['feedback'] as String?;
    final memoryText = _creativeMemoryInstruction(context);
    final templateText = _creativeTemplateInstruction(context);

    final briefText = brief != null
        ? 'Brief: genre=${brief['genre']}, mood=${brief['mood']}, story=${brief['story_outline']}, style=${brief['visual_style']}'
        : '';
    final feedbackText = feedback != null ? '\n修改建议（请根据以下建议调整）：$feedback' : '';

    final messages = [
      ChatMessage(role: 'system', content: _scriptSystemPrompt),
      ChatMessage(
        role: 'user',
        content:
            '根据以下创意编写剧本：$prompt${briefText.isNotEmpty ? '\n$briefText' : ''}$templateText$memoryText$feedbackText',
      ),
    ];

    String? responseContent;

    try {
      final response = await llm.chatCompletion(
        messages: messages,
        jsonMode: true,
        temperature: 0.8,
        requestTag: 'script.generate',
      );
      responseContent = response.content;

      final decoded = jsonDecode(response.content);
      final result = _asStringDynamicMap(decoded);
      if (result == null) {
        return AgentResult.error(
          'Invalid script root format from LLM: ${decoded.runtimeType}',
        );
      }

      final rawScenes = result['scenes'];
      if (rawScenes is! List) {
        return AgentResult.error('Invalid script format from LLM');
      }

      final scenes = <Scene>[];
      for (var index = 0; index < rawScenes.length; index++) {
        final sceneMap = _asStringDynamicMap(rawScenes[index]);
        if (sceneMap == null) {
          await AppLogger.warn(
            'Script scene item has invalid type',
            data: {
              'projectId': context.projectId,
              'index': index,
              'runtimeType': rawScenes[index].runtimeType.toString(),
              'valuePreview': AppLogger.preview(rawScenes[index].toString()),
            },
          );
          return AgentResult.error(
            'Invalid script scene[$index] format: ${rawScenes[index].runtimeType}',
          );
        }
        scenes.add(Scene.fromMap(sceneMap));
      }

      final rawAssets = result['assets'];
      if (rawAssets != null && rawAssets is! List) {
        return AgentResult.error(
          'Invalid script assets format: ${rawAssets.runtimeType}',
        );
      }

      final assetList = <Asset>[];
      final assetItems = rawAssets as List? ?? const [];
      for (var index = 0; index < assetItems.length; index++) {
        final assetMap = _asStringDynamicMap(assetItems[index]);
        if (assetMap == null) {
          await AppLogger.warn(
            'Script asset item has invalid type',
            data: {
              'projectId': context.projectId,
              'index': index,
              'runtimeType': assetItems[index].runtimeType.toString(),
              'valuePreview': AppLogger.preview(assetItems[index].toString()),
            },
          );
          return AgentResult.error(
            'Invalid script asset[$index] format: ${assetItems[index].runtimeType}',
          );
        }

        final assetName = assetMap['name']?.toString() ?? '';
        final assetDescription = assetMap['description']?.toString() ?? '';
        assetList.add(
          Asset(
            id: 'asset_${assetName.replaceAll(' ', '_').toLowerCase()}',
            projectId: context.projectId,
            type: assetMap['type']?.toString() ?? 'character',
            name: assetName,
            description: assetDescription,
            prompt: assetDescription,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }

      await AppLogger.info(
        'Script agent parsed response',
        data: {
          'projectId': context.projectId,
          'sceneCount': scenes.length,
          'assetCount': assetList.length,
        },
      );

      return AgentResult.success({
        'scenes': scenes,
        'assets': assetList,
        'raw': result,
      });
    } catch (e, st) {
      await AppLogger.error(
        'Script agent failed',
        data: {
          'projectId': context.projectId,
          'responsePreview': responseContent == null
              ? 'n/a'
              : AppLogger.preview(responseContent, maxLength: 800),
        },
        error: e,
        stackTrace: st,
      );
      return AgentResult.error('Script generation failed: $e');
    }
  }
}

class ProductionAgent extends Agent {
  @override
  String get name => 'ProductionAgent';

  final LlmService llm;
  ProductionAgent({required this.llm});

  @override
  Future<AgentResult> run(AgentContext context) async {
    final script = context.data['script'] as Map<String, dynamic>?;
    final brief = context.data['brief'] as Map<String, dynamic>?;
    final feedback = context.data['feedback'] as String?;
    final memoryText = _creativeMemoryInstruction(context);
    final templateText = _creativeTemplateInstruction(context);

    final scriptText = script != null ? _formatScriptForStoryboard(script) : '';
    final briefText = brief != null
        ? '\n策划参考：mood=${brief['mood']}, visual_style=${brief['visual_style']}'
        : '';
    final feedbackText = feedback != null ? '\n修改建议（请根据以下建议调整）：$feedback' : '';

    final messages = [
      ChatMessage(role: 'system', content: _storyboardSystemPrompt),
      ChatMessage(
        role: 'user',
        content: '请根据以下剧本制作分镜。注意：必须严格按照剧本的场景、角色、剧情来制作分镜，不得自行创作新内容。\n\n'
            '连续性要求：生成每个镜头时，请把同一场景内的上一镜头结尾状态和下一镜头开头需求一起考虑。'
            '每个 video_prompt 都必须写清“起始状态 -> 动作过程 -> 结束状态”，尤其是人物朝向、运动方向、与场景出入口/目标地点/道具的空间关系。'
            '如果两个镜头之间发生转身、掉头、跨越空间或时间跳切，必须显式说明，否则不要改变运动方向。\n\n'
            '$scriptText$briefText$templateText$memoryText$feedbackText',
      ),
    ];

    try {
      final temperature =
          (context.data['storyboardTemperature'] as num?)?.toDouble() ?? 0.3;
      final response = await llm.chatCompletion(
        messages: messages,
        jsonMode: true,
        temperature: temperature,
        requestTag: 'storyboard.generate',
      );

      final decoded = jsonDecode(response.content);
      Map<String, dynamic>? result;
      if (decoded is Map<String, dynamic>) {
        result = decoded;
      } else if (decoded is Map) {
        result = Map<String, dynamic>.from(decoded);
      }
      if (result == null ||
          result['storyboards'] == null ||
          result['storyboards'] is! List) {
        return AgentResult.error('Invalid storyboard format from LLM');
      }

      final storyboards = <Storyboard>[];
      for (final sbItem in result['storyboards'] as List) {
        final m = _asStringDynamicMap(sbItem);
        if (m == null) {
          await AppLogger.warn('Storyboard item has invalid type',
              data: {'projectId': context.projectId});
          continue;
        }
        storyboards.add(Storyboard(
          id: 'shot_${const Uuid().v4().substring(0, 8)}',
          projectId: context.projectId,
          sceneNum: (m['scene_num'] as num?)?.toInt() ?? 0,
          shotNum: (m['shot_num'] as num?)?.toInt() ?? 0,
          shotType: m['shot_type'] as String? ?? 'medium',
          cameraMove: m['camera_move'] as String? ?? 'static',
          description: m['description'] as String? ?? '',
          firstFramePrompt: m['first_frame_prompt'] as String? ?? '',
          videoPrompt: m['video_prompt'] as String? ?? '',
          duration: _readInt(m['duration'], fallback: 5),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }

      return AgentResult.success({'storyboards': storyboards});
    } catch (e, st) {
      await AppLogger.error(
        'Production agent failed',
        data: {
          'projectId': context.projectId,
        },
        error: e,
        stackTrace: st,
      );
      return AgentResult.error('Storyboard generation failed: $e');
    }
  }
}

Map<String, dynamic>? _asStringDynamicMap(dynamic value) {
  if (value is Asset) {
    return value.toMap();
  }

  if (value is Storyboard) {
    return value.toMap();
  }

  if (value is Scene) {
    return value.toMap();
  }

  if (value is Map<String, dynamic>) {
    return value;
  }

  if (value is Map) {
    try {
      return Map<String, dynamic>.from(value);
    } catch (_) {
      return null;
    }
  }

  return null;
}

int _readInt(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

String _creativeMemoryInstruction(AgentContext context) {
  final memory = context.data['creative_memory'] as String?;
  if (memory == null || memory.trim().isEmpty) return '';
  return '''

【项目 Wiki 记忆】
以下内容是本项目持续维护的创作事实源。必须优先遵守用户确认的约束、人物关系、视觉锚点和已生成阶段事实；如与当前任务输入冲突，以用户确认约束和最新 wiki 为准，不要自行改写。

${memory.trim()}
''';
}

/// Optional genre/scene template hint (the "general -> specific" middle layer).
/// Resolves context.data['creativeTemplateId'] to a preset and returns its hint;
/// '' when none selected. User creative input always takes priority over it.
String _creativeTemplateInstruction(AgentContext context) {
  final t = creativeTemplateById(context.data['creativeTemplateId'] as String?);
  if (t == null) return '';
  return '\n\n${t.toPromptHint()}';
}

/// Build a concise global "style lock" from the brief. Injected verbatim into
/// every generated image and video prompt so the whole short shares one era,
/// palette, lighting and film texture — the single biggest lever for
/// cross-shot visual coherence (characters/scenes drifting in look is the most
/// visible continuity failure).
String buildStyleLock(AgentContext context) {
  final brief = _asStringDynamicMap(context.data['brief']);
  if (brief == null) return '';
  final parts = <String>[];
  final vs = brief['visual_style']?.toString().trim();
  final mood = brief['mood']?.toString().trim();
  if (vs != null && vs.isNotEmpty) parts.add(_stripComposition(vs));
  if (mood != null && mood.isNotEmpty) parts.add('情绪基调：$mood');
  // Global look: cinematic semi-real. Must stay just under the "real person"
  // moderation line so the previous shot's video can be fed back as
  // reference_video (full photoreal video input is blocked; this look passes and
  // still reads as realistic film, not animation).
  parts.add('整体为2000年代怀旧电影胶片质感：粗颗粒胶片、轻微漏光与电影感暖调调色，'
      '半写实电影质感（介于写实与手绘之间、明显是影视画面而非真实人物照片），'
      '实景电影摄影感、自然光影与景深；非动画、非卡通、非3D渲染');
  return parts.where((p) => p.trim().isNotEmpty).join('；');
}

/// The style lock must carry LOOK (era/palette/texture/lighting), NOT shot
/// composition. Baking camera/composition gimmicks (e.g. "窗框构图/手持跟拍") into
/// the global style forced every shot through a window; composition belongs
/// per-beat, so drop those clauses here.
String _stripComposition(String visualStyle) {
  const drop = [
    '窗框',
    '构图',
    '机位',
    '运镜',
    '跟拍',
    '手持',
    '景别',
    '推拉',
    '摇镜',
    '俯拍',
    '仰拍',
    '视角',
    '镜头运动',
    '分屏',
    // photoreal cues: a 纪实/超写实 push tips the render over the "real person"
    // line and gets the beat's video blocked as a reference_video.
    '纪实',
    '写实',
    '超写实',
    '逼真',
    '真实感',
    '真人',
    '实拍',
    '高清写真'
  ];
  final clauses = visualStyle
      .split(RegExp(r'[、，。/；;,]'))
      .map((c) => c.trim())
      .where((c) => c.isNotEmpty)
      .where((c) => !drop.any(c.contains))
      .toList();
  return clauses.isEmpty ? visualStyle : clauses.join('、');
}

/// Prepend the style lock to an image/video prompt (no-op when empty).
String withStyleLock(String styleLock, String prompt) {
  if (styleLock.trim().isEmpty) return prompt;
  return '【全局视觉风格锁 — 所有镜头的时代背景、画质、色调、光线、胶片质感必须严格统一】\n'
      '$styleLock\n\n$prompt';
}

/// Format script as a readable scene-by-scene list for the storyboard LLM.
/// This makes it much clearer than raw JSON what scenes, characters, and
/// actions the storyboard must faithfully follow.
String _formatScriptForStoryboard(Map<String, dynamic> script) {
  final buffer = StringBuffer();
  buffer.writeln('=== 剧本 ===\n');

  // Extract and list assets (characters, locations, and props)
  final rawAssets = script['assets'];
  if (rawAssets is List && rawAssets.isNotEmpty) {
    final characters = <Map<String, dynamic>>[];
    final locations = <Map<String, dynamic>>[];
    final props = <Map<String, dynamic>>[];
    for (final a in rawAssets) {
      Map<String, dynamic>? m;
      if (a is Asset) {
        m = {'type': a.type, 'name': a.name, 'description': a.description};
      } else {
        m = _asStringDynamicMap(a);
      }
      if (m == null) continue;
      if (m['type'] == 'character') characters.add(m);
      if (m['type'] == 'location') locations.add(m);
      if (m['type'] == 'prop') props.add(m);
    }

    if (characters.isNotEmpty) {
      buffer.writeln('【角色列表】（分镜中只能出现这些角色，不得添加新角色）');
      for (final c in characters) {
        buffer.writeln('- 名字：${c['name']}，描述：${c['description']}');
      }
      buffer.writeln('');
    }
    if (locations.isNotEmpty) {
      buffer.writeln('【场景地点】（分镜画面必须基于这些地点，不得替换）');
      for (final l in locations) {
        buffer.writeln('- 地点：${l['name']}，描述：${l['description']}');
      }
      buffer.writeln('');
    }
    if (props.isNotEmpty) {
      buffer.writeln('【关键道具】（分镜中如涉及道具必须与以下描述一致）');
      for (final p in props) {
        buffer.writeln('- 名称：${p['name']}，描述：${p['description']}');
      }
      buffer.writeln('');
    }
  }

  // List each scene explicitly
  final rawScenes = script['scenes'];
  if (rawScenes is List && rawScenes.isNotEmpty) {
    buffer.writeln('【场景清单】（分镜必须严格按以下场景逐个制作，不得增删、改写）');
    buffer.writeln('共 ${rawScenes.length} 个场景：\n');
    for (var i = 0; i < rawScenes.length; i++) {
      final item = rawScenes[i];
      String sceneNum, location, description, action;
      List<dynamic>? dialogue;

      if (item is Scene) {
        sceneNum = item.sceneNum.toString();
        location = item.location;
        description = item.description;
        action = item.action;
        dialogue = item.dialogue;
      } else {
        final m = _asStringDynamicMap(item);
        if (m == null) continue;
        sceneNum = (m['scene_num'] ?? 0).toString();
        location = m['location'] ?? '';
        description = m['description'] ?? '';
        action = m['action'] ?? '';
        dialogue = m['dialogue'] as List?;
      }

      buffer.writeln('场景 $sceneNum：');
      buffer.writeln('  地点：$location');
      buffer.writeln('  场景描述：$description');
      buffer.writeln('  角色动作：$action');
      if (dialogue != null && dialogue.isNotEmpty) {
        buffer.writeln('  台词：${dialogue.join('；')}');
      }
      buffer.writeln('');
    }
  }

  return buffer.toString();
}

/// Asset design agent - generates reference images for each character and
/// location asset. These canonical images serve as visual anchors throughout
/// the pipeline, ensuring character and scene consistency across all storyboards.
class AssetDesignAgent extends Agent {
  @override
  String get name => 'AssetDesignAgent';

  final MediaService _dashscope = MediaService();
  final LlmService llm;
  AssetDesignAgent({required this.llm});

  @override
  Future<AgentResult> run(AgentContext context) async {
    final scriptData = context.data['script'] as Map<String, dynamic>?;
    final rawAssets = scriptData?['assets'];
    if (rawAssets is! List || rawAssets.isEmpty) {
      return AgentResult.error('没有资产数据，无法设计参考图');
    }

    final assets = <Asset>[];
    for (final a in rawAssets) {
      if (a is Asset) {
        assets.add(a);
      } else if (a is Map<String, dynamic>) {
        assets.add(Asset.fromMap(a));
      }
    }

    if (assets.isEmpty) {
      return AgentResult.error('解析资产列表失败');
    }

    final feedback = context.data['feedback'] as String?;
    final feedbackText = feedback != null ? '。修改建议：$feedback' : '';
    final memoryText = _creativeMemoryInstruction(context);
    final styleLock = buildStyleLock(context);

    // Derive one unified uniform so every character sheet matches (root cause of
    // cross-shot inconsistency was each character getting a different outfit).
    // Only meaningful when ≥2 characters could plausibly share a uniform.
    final characterCount = assets.where((a) => a.type == 'character').length;
    final uniform =
        characterCount >= 2 ? await _deriveUniform(scriptData!) : '';

    int successCount = 0;
    int failCount = 0;
    final updatedAssets = <Asset>[];
    final imageStore = PersistentImageStore();

    for (final asset in assets) {
      final prompt = _cleanImagePrompt(asset.prompt ?? asset.description ?? '');
      if (prompt.isEmpty) {
        await AppLogger.warn(
          'Asset has no prompt/description, skipping image generation',
          data: {'assetId': asset.id, 'assetName': asset.name},
        );
        updatedAssets.add(asset);
        failCount++;
        continue;
      }

      // Enhance prompt with visual style context from brief
      final enhancedPrompt = _buildAssetPrompt(
        prompt,
        asset.type,
        styleLock,
        memoryText,
        feedbackText,
        uniform,
      );

      try {
        await AppLogger.info(
          'Generating reference image for asset',
          data: {
            'assetId': asset.id,
            'assetName': asset.name,
            'assetType': asset.type
          },
        );

        final imageUrl = await _dashscope.generateImage(enhancedPrompt);
        final localPath = await imageStore.persistRemoteImage(
          imageUrl,
          category: 'assets',
          entityId: asset.id,
        );

        updatedAssets.add(Asset(
          id: asset.id,
          projectId: asset.projectId,
          type: asset.type,
          name: asset.name,
          description: asset.description,
          prompt: asset.prompt,
          referenceImageUrl: imageUrl,
          referenceImageLocalPath: localPath,
          state: asset.state,
          createdAt: asset.createdAt,
        ));
        successCount++;
      } catch (e) {
        await AppLogger.warn(
          'Asset image generation failed',
          data: {'assetId': asset.id, 'assetName': asset.name},
          error: e,
        );
        updatedAssets.add(asset); // Keep original asset without image
        failCount++;
      }
    }

    await AppLogger.info(
      'Asset design completed',
      data: {
        'total': assets.length,
        'success': successCount,
        'failed': failCount,
      },
    );

    return AgentResult.success({
      'assets': updatedAssets,
      'total': assets.length,
      'success': successCount,
      'failed': failCount,
    });
  }

  /// Build enhanced image prompt for asset reference image generation.
  ///
  /// Two consistency levers are applied here:
  /// 1. The global [styleLock] (era/palette/film texture) is prepended so every
  ///    reference sheet — and therefore every downstream shot built on it —
  ///    shares one look.
  /// 2. Character/location sheets are framed as *clean anchor images* (neutral
  ///    background, full body, even lighting). A clean sheet is a far better
  ///    conditioning image for Qwen-Image-Edit than a busy in-scene shot, which
  ///    is what keeps a character's identity stable across later keyframes.
  /// Asks the LLM for one canonical uniform shared by all characters. Returns ''
  /// when not applicable or on any failure (falls back to per-character outfits).
  Future<String> _deriveUniform(Map<String, dynamic> scriptData) async {
    try {
      final response = await llm.chatCompletion(
        messages: [
          ChatMessage(role: 'system', content: _uniformSystemPrompt),
          ChatMessage(role: 'user', content: '剧本：${jsonEncode(scriptData)}'),
        ],
        jsonMode: true,
        temperature: 0.3,
        requestTag: 'asset.uniform',
      );
      final decoded = _asStringDynamicMap(jsonDecode(response.content));
      if (decoded == null) return '';
      final applicable = decoded['applicable'];
      if (applicable == false) return '';
      return decoded['uniform']?.toString().trim() ?? '';
    } catch (e) {
      await AppLogger.warn(
          'Uniform derivation failed, using per-character outfits',
          error: e);
      return '';
    }
  }

  String _buildAssetPrompt(
    String basePrompt,
    String assetType,
    String styleLock,
    String memoryText,
    String feedbackText,
    String uniform,
  ) {
    final buffer = StringBuffer();

    // Add type-specific framing with clear instructions
    if (assetType == 'character') {
      // Neutral identity sheet (standing front, arms down, no props/action) so
      // it's a clean conditioning anchor — plus the unified uniform overriding
      // whatever per-character outfit the script invented.
      buffer.writeln('[角色设计参考图 / character reference sheet]');
      buffer.writeln('生成一张角色设定图，用作后续所有分镜和视频中该角色外观一致性的锚点。');
      buffer.writeln(
          '要求：单人全身正面直立站立，双臂自然下垂贴身体两侧，中性表情平视镜头，不做任何动作、不拿任何道具、无座椅无背包；纯中性灰色无缝影棚背景，不要其他人物、不要复杂场景；均匀柔和光照，五官清晰，证件照式标准姿态。');
      if (uniform.isNotEmpty) {
        buffer.writeln('【统一制服，必须严格按此，忽略下方角色描述里任何不同的服装颜色款式】$uniform。');
        buffer.writeln('【下方角色描述仅用于保留该角色的个人特征：脸型、发型、眼镜、体型，服装一律以上面的统一制服为准】');
      } else {
        buffer.writeln('必须严格按照角色描述生成，不得自由发挥或替换为其他物体。');
      }
      buffer.writeln('');
      buffer.writeln('角色描述：$basePrompt');
    } else if (assetType == 'location') {
      buffer.writeln('[场景设计参考图 / location establishing shot]');
      buffer.writeln('生成一张场景建立镜头（空镜），用作后续该场景环境一致性的锚点。');
      buffer.writeln('要求：画面中不要出现任何角色/人物，重点表现该地点的建筑、空间布局、光线与色调。');
      buffer.writeln('必须严格按照场景描述生成，不得自由发挥或替换为其他地点。');
      buffer.writeln('');
      buffer.writeln('场景描述：$basePrompt');
    } else if (assetType == 'prop') {
      buffer.writeln('[道具设计参考图 / prop reference]');
      buffer.writeln('生成一张道具参考图，用于后续所有分镜和视频中该道具的外观一致性。');
      buffer.writeln('要求：道具居中、纯色/中性背景、清晰展示外形与材质。');
      buffer.writeln('必须严格按照道具描述生成，不得自由发挥或替换为其他物品。');
      buffer.writeln('');
      buffer.writeln('道具描述：$basePrompt');
    } else {
      buffer.writeln(basePrompt);
    }

    if (feedbackText.isNotEmpty) {
      buffer.writeln();
      buffer.write(_cleanImagePrompt(feedbackText, maxLength: 180));
    }

    return withStyleLock(
        styleLock, _cleanImagePrompt(buffer.toString(), maxLength: 1400));
  }

  String _cleanImagePrompt(String value, {int maxLength = 900}) {
    var text = value
        .replaceAll(RegExp(r'---[\s\S]*?---'), ' ')
        .replaceAll(RegExp(r'#.+'), ' ')
        .replaceAll(RegExp(r'https?://\S+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.length > maxLength) {
      text = text.substring(0, maxLength);
    }
    return text;
  }
}

/// Video generation agent - generates reference images + videos for each storyboard
/// with character/scene consistency anchors and inter-shot continuity.
///
/// Key design:
/// 1. Extract character + scene descriptions from the script as "consistency anchors"
/// 2. Inject these anchors into every shot's first_frame_prompt and video_prompt
/// 3. Always generate reference images with enhanced prompts for visual consistency
/// 4. Use adjacent-frame passing for temporal continuity within each scene
class VideoAgent extends Agent {
  @override
  String get name => 'VideoAgent';

  final MediaService _dashscope = MediaService();

  @override
  Future<AgentResult> run(AgentContext context) async {
    final storyboards = context.data['storyboards'] as List?;
    if (storyboards == null || storyboards.isEmpty) {
      return AgentResult.error('没有分镜数据，无法生成视频');
    }

    // ============================================================
    // Step 1: Extract consistency anchors from the script
    // ============================================================
    final consistencyAnchors = _extractConsistencyAnchors(context);

    // Sort by scene_num then shot_num for correct sequential order
    final sorted = <Map<String, dynamic>>[];
    for (final item in storyboards) {
      final m = _asStringDynamicMap(item);
      if (m != null) sorted.add(m);
    }
    sorted.sort((a, b) {
      final sceneA = (a['scene_num'] as num?)?.toInt() ?? 0;
      final sceneB = (b['scene_num'] as num?)?.toInt() ?? 0;
      if (sceneA != sceneB) return sceneA - sceneB;
      final shotA = (a['shot_num'] as num?)?.toInt() ?? 0;
      final shotB = (b['shot_num'] as num?)?.toInt() ?? 0;
      return shotA - shotB;
    });

    final feedback = context.data['feedback'] as String?;
    final feedbackText = feedback != null ? '。修改建议：$feedback' : '';
    final memoryText = _creativeMemoryInstruction(context);
    final styleLock = buildStyleLock(context);

    // ============================================================
    // Step 2: Generate videos with consistency anchors + continuity
    // ============================================================
    final clips = <Map<String, dynamic>>[];
    int successCount = 0;
    int failCount = 0;

    // Continuity: track the reference image from the previous shot
    String? continuityRefImage;
    int? lastSceneNum;

    // Per-character ANCHOR clips (Ark): for each character we first generate ONE
    // single-character, stylized clip that reliably passes reference_video
    // moderation. Every story beat then references the anchors of its present
    // characters (≤3), so each character's identity stays consistent across the
    // film — a video "character sheet". This sidesteps two walls: (1) a realistic
    // still as i2v first-frame is moderation-blocked, and (2) busy multi-character
    // story beats themselves can't serve as reference_video, but clean single-
    // character clips can. So we never feed images, and never rely on story beats
    // as references.
    final chainMode = AppConfig.useArkForVideo;
    final anchorByChar =
        <String, String>{}; // character name -> anchor clip url
    if (chainMode) {
      final names =
          (consistencyAnchors['characterNames'] as List?)?.cast<String>() ??
              const [];
      final descByName = (consistencyAnchors['characterDescByName'] as Map?)
              ?.map((k, v) => MapEntry(k.toString(), v.toString())) ??
          const {};
      for (final name in names) {
        if (name.isEmpty) continue;
        final anchorPrompt = withStyleLock(
              styleLock,
              '角色锚段：画面里只有这一个角色（单人，绝无其他人物）：${descByName[name] ?? ''}。'
              '该角色在与剧本相符的环境中由远及近、神情自然地走向镜头，平视中近景，看清面部与全身，动作平缓自然',
            ) +
            memoryText;
        try {
          anchorByChar[name] = await _dashscope.generateVideo(
            prompt: anchorPrompt,
            firstFrameUrl: '',
            duration: 5,
          );
          await AppLogger.info('Character anchor clip generated',
              data: {'tag': 'video.anchor', 'character': name});
        } catch (e) {
          await AppLogger.warn('Character anchor clip failed',
              data: {'character': name}, error: e);
        }
      }
    }

    for (int i = 0; i < sorted.length; i++) {
      final sbMap = sorted[i];

      final storyboardId = sbMap['id'] as String?;
      final videoPrompt = sbMap['video_prompt'] as String? ?? '';
      final firstFramePrompt = sbMap['first_frame_prompt'] as String? ?? '';
      final duration = (sbMap['duration'] as num?)?.toInt() ?? 5;
      final sceneNum = (sbMap['scene_num'] as num?)?.toInt() ?? 0;
      final shotDescription = sbMap['description'] as String? ?? '';
      final previousShot = i > 0 ? sorted[i - 1] : null;
      final nextShot = i + 1 < sorted.length ? sorted[i + 1] : null;
      final isNewScene = lastSceneNum == null || sceneNum != lastSceneNum;

      // Detect scene change — reset continuity chain for new scenes
      if (isNewScene) {
        continuityRefImage = null;
      }

      // Which characters/props/location actually appear in THIS shot, matched
      // by name against the shot's own text. This is the key to consistency:
      // only the references truly present are passed to image-edit, so a
      // single-character close-up never gets other characters' faces bled in.
      final shotText = '$shotDescription\n$firstFramePrompt\n$videoPrompt';

      // Build enhanced image prompt (always used for reference image generation)
      final enhancedImagePrompt = withStyleLock(
            styleLock,
            _enhanceImagePrompt(
              consistencyAnchors,
              sceneNum,
              firstFramePrompt,
              shotDescription,
              shotText,
            ),
          ) +
          memoryText;

      // Build enhanced video prompt (injects visual context for video generation)
      final enhancedVideoPrompt = withStyleLock(
            styleLock,
            _enhanceVideoPrompt(
              consistencyAnchors,
              sceneNum,
              _withAdjacentShotContinuity(
                current: sbMap,
                previous: previousShot,
                next: nextShot,
                basePrompt: videoPrompt,
              ),
              shotDescription,
              shotText,
            ),
          ) +
          memoryText +
          feedbackText;

      // ============================================================
      // Generate reference image with consistency anchors
      // Always regenerate to ensure consistency (skip only if already
      // has a URL, to save API calls for resume scenarios)
      // ============================================================
      // Generate reference image with consistency anchors and canonical images.
      // Skipped entirely in reference_video chain mode (no image inputs).
      String? refImageUrl = sbMap['reference_image_url'] as String?;
      String? refImageLocalPath =
          sbMap['reference_image_local_path'] as String?;
      if (!chainMode &&
          (refImageUrl == null || refImageUrl.isEmpty) &&
          enhancedImagePrompt.isNotEmpty) {
        final refUrls = _selectRefsForShot(
          consistencyAnchors,
          sceneNum,
          shotText,
        );
        await AppLogger.info(
          'Generating shot keyframe with per-shot reference images',
          data: {
            'storyboard_id': storyboardId,
            'scene': sceneNum,
            'shot': '${i + 1}/${sorted.length}',
            'refImageCount': refUrls.length
          },
        );
        refImageUrl = await _dashscope.generateImage(
          enhancedImagePrompt,
          referenceImageUrls: refUrls.isNotEmpty ? refUrls : null,
        );
      }

      if (refImageLocalPath == null &&
          refImageUrl != null &&
          refImageUrl.isNotEmpty) {
        refImageLocalPath = await PersistentImageStore().persistRemoteImage(
          refImageUrl,
          category: 'storyboards',
          entityId: storyboardId ?? 'storyboard_${i + 1}',
        );
      }

      // ============================================================
      // First frame for video generation: always this shot's OWN keyframe.
      // The keyframe was generated with the correct per-shot references (and,
      // for same-scene continuation shots, the previous keyframe as an anchor),
      // so it already carries both the right composition and visual continuity.
      // Starting i2v from the previous shot's image instead would force a wrong
      // opening composition whenever the angle/subject changes.
      // ============================================================
      final videoFirstFrame = refImageUrl;

      // ============================================================
      // Generate video
      // ============================================================
      try {
        if (!chainMode &&
            (videoFirstFrame == null || videoFirstFrame.isEmpty)) {
          clips.add({
            'storyboard_id': storyboardId,
            'state': 'failed',
            'error_reason': '缺少参考图片，无法生成视频',
          });
          failCount++;
        } else {
          // Chain mode: reference the ANCHOR clips of the present characters
          // (≤3, deduped) — no image inputs. Otherwise: t2v with this shot's
          // per-shot reference_image.
          final presentChars = _charactersInShot(consistencyAnchors, shotText);
          final refVideos = <String>[];
          if (chainMode) {
            for (final n in presentChars) {
              final u = anchorByChar[n];
              if (u != null && u.isNotEmpty && !refVideos.contains(u)) {
                refVideos.add(u);
              }
              if (refVideos.length >= 3) break;
            }
          }
          final videoRefUrls = chainMode
              ? const <String>[]
              : _selectRefsForShot(consistencyAnchors, sceneNum, shotText);
          final videoUrl = await _dashscope.generateVideo(
            prompt: enhancedVideoPrompt,
            firstFrameUrl: chainMode ? '' : (videoFirstFrame ?? ''),
            duration: duration,
            referenceImageUrls: videoRefUrls.isNotEmpty ? videoRefUrls : null,
            referenceVideoUrls:
                chainMode && refVideos.isNotEmpty ? refVideos : null,
          );

          clips.add({
            'storyboard_id': storyboardId,
            'reference_image_url': refImageUrl,
            'reference_image_local_path': refImageLocalPath,
            'continuity_ref_image_url': isNewScene ? null : continuityRefImage,
            'reference_video_urls': chainMode ? refVideos : null,
            'video_url': videoUrl,
            'state': 'completed',
          });
          successCount++;
        }

        // Update continuity anchor for next shot in same scene
        continuityRefImage = refImageUrl;
      } catch (e) {
        await AppLogger.warn(
          'Video clip generation failed',
          data: {'storyboard_id': storyboardId},
          error: e,
        );
        clips.add({
          'storyboard_id': storyboardId,
          'state': 'failed',
          'error_reason': e.toString(),
        });
        failCount++;
      }

      lastSceneNum = sceneNum;
    }

    await AppLogger.info(
      'Video generation completed',
      data: {
        'total': sorted.length,
        'success': successCount,
        'failed': failCount,
      },
    );

    return AgentResult.success({
      'clips': clips,
      'total': sorted.length,
      'success': successCount,
      'failed': failCount,
    });
  }

  // ============================================================
  // Consistency anchor extraction and injection
  // ============================================================

  String _withAdjacentShotContinuity({
    required Map<String, dynamic> current,
    required Map<String, dynamic>? previous,
    required Map<String, dynamic>? next,
    required String basePrompt,
  }) {
    final currentScene = (current['scene_num'] as num?)?.toInt();
    final currentShot = (current['shot_num'] as num?)?.toInt();
    final previousScene = (previous?['scene_num'] as num?)?.toInt();
    final nextScene = (next?['scene_num'] as num?)?.toInt();

    final buffer = StringBuffer()
      ..writeln(basePrompt)
      ..writeln()
      ..writeln('【相邻镜头连续性约束】')
      ..writeln('当前镜头：Scene $currentScene Shot $currentShot')
      ..writeln('当前镜头描述：${current['description'] ?? ''}');

    if (previous != null && previousScene == currentScene) {
      buffer
        ..writeln('上一镜头描述：${previous['description'] ?? ''}')
        ..writeln('上一镜头动态：${previous['video_prompt'] ?? ''}')
        ..writeln('当前镜头首帧必须承接上一镜头的结束位置、人物朝向、运动方向和场景空间关系。');
    } else {
      buffer.writeln('这是该场景的第一个镜头，需要建立清楚的场景地理关系和人物运动方向。');
    }

    if (next != null && nextScene == currentScene) {
      buffer
        ..writeln('下一镜头描述：${next['description'] ?? ''}')
        ..writeln('下一镜头动态：${next['video_prompt'] ?? ''}')
        ..writeln('当前镜头结尾必须为下一镜头留下可衔接的动作状态。');
    }

    buffer
      ..writeln('硬性要求：不得让人物无解释地反向移动、瞬移、换服装、换道具或改变场景方位。')
      ..writeln('请在本镜头中明确“起始状态 -> 动作过程 -> 结束状态”。');
    return buffer.toString();
  }

  /// Extracts character / location / prop consistency anchors from the script
  /// assets, indexed BY NAME so each shot can pull only the references it
  /// actually contains. Carries both text descriptions (for prompt enhancement)
  /// and canonical image URLs (from the asset design stage, if available).
  Map<String, dynamic> _extractConsistencyAnchors(AgentContext context) {
    final scriptData = context.data['script'];

    final characterNames = <String>[];
    final characterDescByName = <String, String>{};
    final characterImageByName = <String, String>{};
    final locationNames = <String>[];
    final locationImages = <String>[]; // global, ordered
    final locationImageByName = <String, String>{};
    final locationDescByName = <String, String>{};
    final sceneLocationText = <int, String>{};
    final propNames = <String>[];
    final propDescByName = <String, String>{};
    final propImageByName = <String, String>{};

    Map<String, dynamic>? scriptMap;
    if (scriptData is Map<String, dynamic>) {
      scriptMap = scriptData;
    } else if (scriptData is Map) {
      scriptMap = Map<String, dynamic>.from(scriptData);
    }

    if (scriptMap != null) {
      final rawAssets = scriptMap['assets'];
      if (rawAssets is List) {
        for (final a in rawAssets) {
          final m = _asStringDynamicMap(a);
          if (m == null) continue;
          final type = m['type']?.toString() ?? '';
          final name = m['name']?.toString().trim() ?? '';
          final desc = m['description']?.toString() ?? '';
          final refImage = m['reference_image_url']?.toString();
          final hasImage = refImage != null &&
              (refImage.startsWith('http://') ||
                  refImage.startsWith('https://'));
          if (name.isEmpty) continue;

          if (type == 'character') {
            characterNames.add(name);
            if (desc.isNotEmpty) characterDescByName[name] = desc;
            if (hasImage) characterImageByName[name] = refImage;
          } else if (type == 'location') {
            locationNames.add(name);
            if (desc.isNotEmpty) locationDescByName[name] = desc;
            if (hasImage) {
              locationImages.add(refImage);
              locationImageByName[name] = refImage;
            }
          } else if (type == 'prop') {
            propNames.add(name);
            if (desc.isNotEmpty) propDescByName[name] = desc;
            if (hasImage) propImageByName[name] = refImage;
          }
        }
      }

      // Map scene_num -> location text from the scenes array (for prompt text).
      final rawScenes = scriptMap['scenes'];
      if (rawScenes is List) {
        for (int i = 0; i < rawScenes.length; i++) {
          final sm = _asStringDynamicMap(rawScenes[i]);
          if (sm == null) continue;
          final sceneNum = (sm['scene_num'] as num?)?.toInt() ?? (i + 1);
          final loc = sm['location']?.toString() ?? '';
          final desc = sm['description']?.toString() ?? '';
          if (loc.isNotEmpty || desc.isNotEmpty) {
            sceneLocationText[sceneNum] = '$loc. $desc'.trim();
          }
        }
      }
    }

    return {
      'characterNames': characterNames,
      'characterDescByName': characterDescByName,
      'characterImageByName': characterImageByName,
      'locationNames': locationNames,
      'locationImages': locationImages,
      'locationImageByName': locationImageByName,
      'locationDescByName': locationDescByName,
      'sceneLocationText': sceneLocationText,
      'propNames': propNames,
      'propDescByName': propDescByName,
      'propImageByName': propImageByName,
    };
  }

  /// Names of the characters that actually appear in this shot, detected by
  /// matching each character's script name against the shot's own text. Order
  /// follows the script's asset order so selection is deterministic.
  List<String> _charactersInShot(
      Map<String, dynamic> anchors, String shotText) {
    final names =
        (anchors['characterNames'] as List?)?.cast<String>() ?? const [];
    return [
      for (final n in names)
        if (n.isNotEmpty && shotText.contains(n)) n
    ];
  }

  /// Choose ≤3 reference images for a shot — THE core consistency mechanism.
  ///
  /// Qwen-Image-Edit-2509 accepts at most 3 reference images, so passing every
  /// character's sheet (the old behaviour) both overflowed the limit and bled
  /// the wrong faces into single-character shots. Instead we pass only what is
  /// in frame, prioritised so the most identity-critical anchors win the slots:
  ///   1. the characters actually present (script order)
  ///   2. this scene's location sheet (scene/look anchor)
  ///   3. props present in the shot
  /// Deduplicated and capped at 3.
  ///
  /// Note we deliberately do NOT use the previous shot's keyframe as a scene
  /// anchor: when consecutive shots have different casts (e.g. a two-person
  /// shot followed by a one-person close-up), the previous keyframe would drag
  /// the absent character back into frame — the exact bleed we are removing.
  /// Cross-shot continuity is instead carried by the shared character/location
  /// sheets plus the global style lock.
  List<String> _selectRefsForShot(
    Map<String, dynamic> anchors,
    int sceneNum,
    String shotText,
  ) {
    const maxRefs = 3;
    final out = <String>[];
    void add(String? url) {
      if (url == null) return;
      if (!(url.startsWith('http://') || url.startsWith('https://'))) return;
      if (out.length >= maxRefs || out.contains(url)) return;
      out.add(url);
    }

    // 1. Characters present in this shot.
    final charImages =
        (anchors['characterImageByName'] as Map?)?.cast<String, String>() ??
            const {};
    for (final name in _charactersInShot(anchors, shotText)) {
      add(charImages[name]);
    }

    // 2. Scene/look anchor: this scene's location sheet.
    add(_locationImageForShot(anchors, shotText));

    // 3. Props present in this shot.
    final propImages =
        (anchors['propImageByName'] as Map?)?.cast<String, String>() ??
            const {};
    final propNames =
        (anchors['propNames'] as List?)?.cast<String>() ?? const [];
    for (final name in propNames) {
      if (name.isNotEmpty && shotText.contains(name)) add(propImages[name]);
    }

    return out;
  }

  /// Best location sheet for a shot: prefer a location whose name is mentioned
  /// in the shot, otherwise fall back to the only/first known location sheet.
  String? _locationImageForShot(Map<String, dynamic> anchors, String shotText) {
    final byName =
        (anchors['locationImageByName'] as Map?)?.cast<String, String>() ??
            const {};
    for (final entry in byName.entries) {
      if (entry.key.isNotEmpty && shotText.contains(entry.key)) {
        return entry.value;
      }
    }
    final all =
        (anchors['locationImages'] as List?)?.cast<String>() ?? const [];
    return all.isNotEmpty ? all.first : null;
  }

  /// Character description lines to inject into a prompt — only for the
  /// characters present in this shot (fallback: all) so the generator is not
  /// told about people who shouldn't be in frame.
  String _characterDescsForShot(Map<String, dynamic> anchors, String shotText) {
    final descByName =
        (anchors['characterDescByName'] as Map?)?.cast<String, String>() ??
            const {};
    var present = _charactersInShot(anchors, shotText);
    if (present.isEmpty) present = descByName.keys.toList();
    final lines = [
      for (final n in present)
        if (descByName[n] != null) '$n: ${descByName[n]}'
    ];
    return lines.join('\n');
  }

  /// Enhance the image generation prompt with consistency anchors, scoped to
  /// the characters/location/props that appear in this shot.
  String _enhanceImagePrompt(
    Map<String, dynamic> anchors,
    int sceneNum,
    String firstFramePrompt,
    String shotDescription,
    String shotText,
  ) {
    if (firstFramePrompt.isEmpty) return '';

    final buffer = StringBuffer();

    // ACTION FIRST. The keyframe becomes the first frame of the i2v clip, so it
    // must already show the shot's action/pose — not a neutral standing pose.
    // The character reference sheets are clean standing shots, and image-edit
    // tends to copy that pose; left unchecked the keyframe shows the character
    // standing and the video then has to invent the motion from a static frame,
    // which produces melting limbs / objects appearing from nowhere. So we lead
    // with the action and explicitly scope the references to identity only.
    buffer.writeln('[本镜头画面与动作 — 最高优先级，必须据此决定人物姿态、动作与构图]');
    if (shotDescription.isNotEmpty) buffer.writeln(shotDescription);
    buffer.writeln(firstFramePrompt);
    buffer.writeln('');

    final charDescs = _characterDescsForShot(anchors, shotText);
    if (charDescs.isNotEmpty) {
      buffer.writeln('[本镜头出场角色 — 参考图/描述仅用于保持长相、发型、服装一致]');
      buffer.writeln('（仅限以下角色，不要加入其他角色；人物的姿态、动作、朝向、镜头角度必须按上面的画面描述，'
          '不要套用参考图里的站立或静止姿势。）');
      buffer.writeln(charDescs);
      buffer.writeln('');
    }

    final sceneLocations =
        (anchors['sceneLocationText'] as Map?)?.cast<int, String>();
    if (sceneLocations != null && sceneLocations.containsKey(sceneNum)) {
      buffer.writeln('[场景环境参考]');
      buffer.writeln(sceneLocations[sceneNum]);
      buffer.writeln('');
    }

    final propDescs = _propDescsForShot(anchors, shotText);
    if (propDescs.isNotEmpty) {
      buffer.writeln('[道具参考]');
      buffer.writeln(propDescs);
    }

    return buffer.toString();
  }

  /// Prop description lines for the props present in this shot.
  String _propDescsForShot(Map<String, dynamic> anchors, String shotText) {
    final descByName =
        (anchors['propDescByName'] as Map?)?.cast<String, String>() ?? const {};
    final lines = [
      for (final e in descByName.entries)
        if (e.key.isNotEmpty && shotText.contains(e.key)) '${e.key}: ${e.value}'
    ];
    return lines.join('\n');
  }

  /// Enhance the video generation prompt with visual context, scoped to this
  /// shot's characters/location/props.
  String _enhanceVideoPrompt(
    Map<String, dynamic> anchors,
    int sceneNum,
    String videoPrompt,
    String shotDescription,
    String shotText,
  ) {
    if (videoPrompt.isEmpty) return shotDescription;

    final buffer = StringBuffer();

    final charDescs = _characterDescsForShot(anchors, shotText);
    if (charDescs.isNotEmpty) {
      buffer.writeln('本镜头出场角色外观参考（仅限以下角色）：$charDescs');
    }

    final sceneLocations =
        (anchors['sceneLocationText'] as Map?)?.cast<int, String>();
    if (sceneLocations != null && sceneLocations.containsKey(sceneNum)) {
      buffer.writeln('场景环境参考：${sceneLocations[sceneNum]}');
    }

    final propDescs = _propDescsForShot(anchors, shotText);
    if (propDescs.isNotEmpty) {
      buffer.writeln('道具参考：$propDescs');
    }

    if (shotDescription.isNotEmpty) {
      buffer.writeln('镜头画面：$shotDescription');
    }

    buffer.writeln('动画要求：$videoPrompt');

    return buffer.toString();
  }
}
