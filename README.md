# Storyforge

> AI 驱动的短视频制作工具。输入一个创意，自动生成 1-2 分钟的短片。

[用户手册](doc/user-manual.md) · [Releases](https://github.com/xtangxtang/storyforge-app/releases)

---

## 工作原理

Storyforge 通过 5 个 AI Agent 协作，将创意转化为短片：

```
输入创意 → 策划 → 编剧 → 分镜 → 生成视频 → 成片
```

每个阶段由独立的 Agent 负责，DirectorAgent 作为总导演自动审阅每步输出质量，
打分不合格时带上反馈要求重做（最多 3 次）。

| 阶段 | Agent | 模型 |
|------|-------|------|
| 策划 | PlanningAgent | qwen3.6-plus |
| 编剧 | ScriptAgent | qwen3.6-plus |
| 分镜 | ProductionAgent | qwen3.6-plus |
| 质量审阅 | DirectorAgent | qwen3.6-plus |
| 图像生成 | DashScope Service | wan2.7-image |
| 视频生成 | DashScope Service | wan2.7-i2v |

## 快速开始

### 前置条件

- [DashScope API Key](https://bailian.console.aliyun.com/)（需开通 qwen3.6-plus、wan2.7-image、wan2.7-i2v）
- Flutter 3.27+（仅源码编译需要）

### 从源码编译

```bash
git clone https://github.com/xtangxtang/storyforge-app.git
cd storyforge-app
flutter pub get

# 运行开发版
flutter run -d windows    # Windows 桌面
flutter run -d <device>   # 其他平台

# 构建发布版本
flutter build windows --release
flutter build apk --release
```

各平台详细安装步骤请参考 [用户手册](doc/user-manual.md)。

## 项目结构

```
lib/
├── main.dart                     # 入口
├── config/
│   └── app_config.dart           # API Key 管理
├── core/
│   ├── agent.dart                # Agent 基类
│   ├── agents.dart               # Planning / Script / Production Agent
│   └── director_agent.dart       # DirectorAgent + LLM 审阅环
├── services/
│   ├── llm_service.dart          # LLM 调用（qwen3.6-plus）
│   └── dashscope_service.dart    # wan2.7 图像/视频生成
├── models/
│   └── models.dart               # 数据模型
├── db/
│   ├── database.dart             # SQLite 初始化
│   └── dao/dao.dart              # DAO 层
└── screens/
    ├── settings_screen.dart          # 设置
    ├── project_list_screen.dart      # 项目列表
    ├── create_project_screen.dart    # 创建项目 + 全流程
    └── project_detail_screen.dart    # 项目详情 + 视频生成
```

## 技术栈

- **框架**：Flutter 3.27 / Dart 3.6
- **状态管理**：Riverpod
- **本地存储**：SQLite (sqflite + sqflite_common_ffi)
- **路由**：go_router
- **HTTP**：http
- **LLM 端点**：`coding.dashscope.aliyuncs.com`（OpenAI 兼容模式）
- **图像/视频端点**：`dashscope.aliyuncs.com`（REST API）

## 许可证

MIT
