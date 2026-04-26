# Storyforge 用户手册

> Storyforge 是一款 AI 驱动的短视频制作工具。输入一个创意，系统自动生成 1-2 分钟的短片。

---

## 目录

1. [功能概述](#1-功能概述)
2. [获取 API Key](#2-获取-api-key)
3. [Windows 桌面版](#3-windows-桌面版)
4. [Android 版](#4-android-版)
5. [iOS 版](#5-ios-版)
6. [从源码编译](#6-从源码编译)
7. [设置与使用](#7-设置与使用)
8. [制作流程](#8-制作流程)
9. [常见问题](#9-常见问题)

---

## 1. 功能概述

Storyforge 通过 5 个阶段的 AI Agent 协作，将创意转化为短片：

```
输入创意 → 策划 → 编剧 → 分镜 → 生成视频 → 成片
```

- **策划**：AI 分析创意，生成类型、风格、故事大纲
- **编剧**：生成场景剧本，自动提取角色和场景资产
- **分镜**：将剧本拆分为分镜镜头，生成画面描述
- **生成视频**：调用 DashScope wan2.7 模型，为每个分镜生成视频片段
- **成片**：将所有片段拼接为最终视频

### 技术特点

| 功能 | 模型 |
|------|------|
| 文本生成（策划/编剧/分镜） | qwen3.6-plus |
| 图像生成 | wan2.7-image |
| 视频生成 | wan2.7-i2v（图生视频） |
| 质量审阅 | qwen3.6-plus（DirectorAgent 自动评分） |

---

## 2. 获取 API Key

使用 Storyforge 需要阿里云 DashScope 的 API Key。

### 2.1 注册 DashScope

1. 访问 [阿里云百炼平台](https://bailian.console.aliyun.com/)
2. 使用阿里云账号登录（如未注册需先注册）
3. 进入 **API-KEY 管理** 页面

### 2.2 创建 API Key

1. 点击 **创建 API Key**
2. 复制生成的 Key（格式：`sk-xxxxxxxxxxxxxxxx`）
3. 此 Key 需要同时支持文本生成和图像/视频生成

> **注意**：部分 Key 仅支持特定模型。如果文本生成正常但图像/视频生成报错，请检查您的 Key 是否开通了 wan2.7 系列模型权限。

### 2.3 模型开通

在百炼平台确保以下模型已开通：
- `qwen3.6-plus`（文本生成）
- `wan2.7-image`（图像生成）
- `wan2.7-i2v`（视频生成）

---

## 3. Windows 桌面版

### 3.1 预编译版本（推荐）

1. 前往 [Releases 页面](https://github.com/xtangxtang/storyforge-app/releases)
2. 下载最新版本中的 `Storyforge-Windows-x64.zip`
3. 解压到任意目录（如 `C:\Storyforge\`）
4. 双击 `storyforge_app.exe` 启动

### 3.2 系统要求

- Windows 10/11（64 位）
- 至少 4GB 内存
- 网络连接（用于调用 AI 模型）

### 3.3 安装后首次运行

1. 启动应用后，点击底部导航栏的 **设置**
2. 输入 DashScope API Key
3. （可选）如有企业代理，输入代理地址
4. 点击 **保存**

---

## 4. Android 版

### 4.1 APK 安装

1. 前往 [Releases 页面](https://github.com/xtangxtang/storyforge-app/releases)
2. 下载 `Storyforge-Android.apk`
3. 在手机上允许 **安装未知应用**
4. 点击 APK 文件完成安装

### 4.2 系统要求

- Android 8.0（API 26）及以上
- 至少 4GB 内存
- 网络连接

### 4.3 首次设置

同 Windows 版：进入设置页面，输入 API Key。

---

## 5. iOS 版

### 5.1 安装

iOS 版本通过 TestFlight 分发：

1. 在 App Store 安装 **TestFlight**
2. 打开 TestFlight，输入邀请码或点击邀请链接
3. 安装 Storyforge

### 5.2 系统要求

- iOS 15.0 及以上
- iPhone / iPad
- 网络连接

---

## 6. 从源码编译

如果你希望从源码编译应用，请按以下步骤操作。

### 6.1 安装 Flutter SDK

#### Windows

```powershell
# 下载 Flutter SDK
git clone https://github.com/flutter/flutter.git -b stable C:\flutter

# 添加到 PATH
setx PATH "%PATH%;C:\flutter\bin"

# 验证
flutter doctor
```

#### macOS

```bash
# 使用 Homebrew
brew install --cask flutter

# 或手动安装
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
export PATH="$PATH:$HOME/flutter/bin"

# 验证
flutter doctor
```

#### Linux

```bash
# 下载并解压
wget https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.27.4-stable.tar.xz
tar xf flutter_linux_3.27.4-stable.tar.xz
export PATH="$PWD/flutter/bin:$PATH"

# 验证
flutter doctor
```

### 6.2 配置各平台工具链

#### Windows 桌面

安装 **Visual Studio 2022**（社区版即可）：
1. 下载 [Visual Studio 2022](https://visualstudio.microsoft.com/downloads/)
2. 安装时勾选 **使用 C++ 的桌面开发**
3. 确保勾选 **Windows 10 SDK**

#### Android

1. 安装 [Android Studio](https://developer.android.com/studio)
2. 打开 Android Studio → Tools → SDK Manager
3. 安装 **Android SDK**（API 34 推荐）
4. 接受 Android SDK 许可证：
   ```bash
   flutter doctor --android-licenses
   ```
5. 连接真机或启动模拟器

#### iOS（仅 macOS）

1. 安装 [Xcode](https://developer.apple.com/xcode/)（App Store）
2. 打开 Xcode，同意许可协议
3. 安装命令行工具：
   ```bash
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -runFirstLaunch
   ```
4. 安装 CocoaPods：
   ```bash
   brew install cocoapods
   ```

### 6.3 克隆项目并编译

```bash
# 克隆仓库
git clone https://github.com/xtangxtang/storyforge-app.git
cd storyforge-app

# 安装依赖
flutter pub get

# 添加平台支持（如需要）
flutter create --platforms=windows,android,ios .

# 运行开发版
flutter run -d windows    # Windows 桌面
flutter run -d <device>   # 其他平台
```

### 6.4 构建发布版本

```bash
# Windows
flutter build windows --release
# 输出：build\windows\x64\runner\Release\

# Android
flutter build apk --release
# 输出：build\app\outputs\flutter-apk\app-release.apk

# Android (App Bundle，上架用)
flutter build appbundle --release

# iOS
flutter build ios --release
# 然后在 Xcode 中 Archive 并导出
```

### 6.5 编译后目录结构

```
storyforge_app/build/
├── windows/x64/runner/Release/     # Windows 可执行文件
├── app/outputs/flutter-apk/        # Android APK
└── ios/iphoneos/                   # iOS 产物（需 Xcode）
```

---

## 7. 设置与使用

### 7.1 设置页面

启动应用后，点击底部导航栏的 **设置** 图标：

| 设置项 | 说明 | 必填 |
|--------|------|------|
| DashScope LLM API Key | 用于文本生成（策划/编剧/分镜） | 是 |
| DashScope 图视频 API Key | 用于图像和视频生成 | 是 |
| 代理地址 | 企业网络代理（如 `http://proxy.company.com:912`） | 否 |

> 两个 Key 可以是同一个，取决于你的 DashScope 账户配置。

### 7.2 数据存储

- **设置数据**：API Key 等配置保存在本地加密存储中
- **项目数据**：策划、剧本、分镜等保存在本地 SQLite 数据库
- **视频文件**：生成的视频链接存储在云端（DashScope），应用仅保存引用

### 7.3 删除数据

- 删除单个项目：在项目列表页左滑或点击删除图标
- 清除所有数据：在设置页面底部点击 **清除本地数据**（如有）

---

## 8. 制作流程

### 8.1 创建项目

1. 点击底部导航栏 **项目**
2. 点击右下角 **+** 按钮
3. 输入创意描述（例如：*一个都市白领女孩在咖啡店遇到了她的初恋*）
4. 点击 **开始生成**

### 8.2 自动生成阶段

系统自动依次执行：

```
策划 → 编剧 → 分镜
```

每个阶段：
1. AI 生成内容
2. DirectorAgent 自动审阅（质量评分 1-10）
3. 如果评分低于 6，自动带上反馈重做（最多 3 次）
4. 通过后进入下一阶段

> 文本生成通常每个阶段需要 30-120 秒，取决于网络状况。

### 8.3 查看结果

生成完成后自动进入项目详情页，可以看到：

- **策划卡片**：类型、时长、情绪、故事大纲
- **资产列表**：自动提取的角色和场景
- **分镜列表**：每个镜头的画面描述、运镜方式
- **视频片段**：每个分镜对应的视频生成状态

### 8.4 生成视频

1. 在分镜数据加载完成后，项目详情页顶部出现 **生成视频** 按钮
2. 点击后系统为每个分镜：
   - 先生成首帧图（wan2.7-image）
   - 再根据首帧图生成视频（wan2.7-i2v）
3. 每个视频片段约需 1-3 分钟
4. 生成完成后可以在分镜列表中查看视频状态

> **提示**：视频生成耗时较长，建议在 WiFi 环境下进行。

### 8.5 状态说明

| 状态 | 含义 |
|------|------|
| 策划 | 正在生成策划方案 |
| 编剧 | 正在生成剧本 |
| 分镜 | 正在生成分镜 |
| 生成视频 | 可以开始生成视频片段 |
| 完成 | 所有阶段已完成 |

---

## 9. 常见问题

### Q: 提示 "API key not configured"

前往 **设置** 页面，确保已填写 LLM API Key 和图视频 API Key。

### Q: 策划/编剧/分镜生成超时

- 检查网络连接是否正常
- 确认 API Key 有效且有足够额度
- 如果使用代理，检查代理地址是否正确
- qwen3.6-plus 响应较慢时属正常现象，单个请求可能需要 1-2 分钟

### Q: 视频生成失败

- 确认 API Key 已开通 wan2.7-image 和 wan2.7-i2v 权限
- 视频生成是异步任务，整个过程可能需要 3-10 分钟
- 如果提示 "Response stream timeout"，可以稍后重试
- 部分提示词可能触发内容审核，建议调整描述

### Q: wan2.7 生成的图片/视频质量不好

- wan2.7 对 **中文 prompt** 支持更好，系统已自动使用中文
- 可以在分镜页面查看生成的 prompt，如有需要可以手动调整
- 可以尝试重新生成（视频生成支持重试）

### Q: 项目数据丢失

- 所有数据保存在本地 SQLite 数据库中
- 卸载应用或删除应用数据会导致数据丢失
- 建议重要项目保存截图或导出分镜内容

### Q: 支持离线使用吗？

不支持。所有 AI 模型调用都需要网络连接。

### Q: 视频生成后的片段如何拼接？

当前版本为每个分镜单独生成视频片段，拼接功能（Final Cut）在后续版本中实现。

### Q: 支持其他 AI 模型吗？

当前版本仅支持 DashScope 系列模型。后续版本计划支持 OpenAI、Midjourney 等更多供应商。

---

## 附录：权限说明

| 平台 | 所需权限 | 用途 |
|------|----------|------|
| Windows | 无特殊权限 | 网络访问、本地文件存储 |
| Android | 网络权限、存储权限 | 网络访问、保存视频到相册 |
| iOS | 网络权限、相册权限 | 网络访问、保存视频到相册 |

---

## 附录：技术架构

```
┌─────────────────────────────────────┐
│           UI (Flutter)              │
│  项目列表 │ 创建 │ 详情 │ 设置       │
├─────────────────────────────────────┤
│       DirectorAgent（编排 + 审阅）    │
│  ┌────────┬────────┬──────────┐     │
│  │Planning│ Script │Production│     │
│  │ Agent  │ Agent  │  Agent   │     │
│  └────────┴────────┴──────────┘     │
├─────────────────────────────────────┤
│       服务层                          │
│  LLM Service │ DashScope Service    │
├─────────────────────────────────────┤
│       数据层                          │
│  SQLite (sqflite) │ SharedPreferences│
└─────────────────────────────────────┘
```

---

*Storyforge v1.0.0 | Flutter 3.27.4 | 2026-04-26*
