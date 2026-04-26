# 在 Windows 下使用 VS Code 编译 Storyforge

本文档介绍如何在 Windows 系统上使用 VS Code 编译 Storyforge Flutter 应用。

---

## 一、安装 Flutter SDK

### 1.1 下载

访问 [Flutter 安装页](https://docs.flutter.dev/get-started/install/windows)，点击 **Download the Flutter SDK**。

### 1.2 解压

将下载的 `.zip` 解压到一个固定目录，例如 `C:\flutter`。

> **注意**：路径中不要包含中文或空格。

### 1.3 添加到系统 PATH

1. 按 `Win + S`，搜索 **环境变量**，打开 **编辑系统环境变量**
2. 点击 **环境变量** 按钮
3. 在 **用户变量** 中找到 `Path`，点击 **编辑**
4. 点击 **新建**，添加 `C:\flutter\bin`
5. 依次点击 **确定** 保存

### 1.4 验证

打开新的命令提示符（`cmd`）或 PowerShell，运行：

```powershell
flutter doctor
```

---

## 二、安装 VS Code 和 Flutter 插件

### 2.1 安装 VS Code

访问 [VS Code 下载页](https://code.visualstudio.com/)，下载并安装。

### 2.2 安装 Flutter 插件

1. 打开 VS Code
2. 按 `Ctrl + Shift + X` 打开扩展面板
3. 搜索 **Flutter**，点击 **Install**
4. 安装后会自动同时安装 **Dart** 插件
5. 安装完成后点击 **Reload** 重启 VS Code

### 2.3 验证

按 `Ctrl + Shift + P`，输入 `Flutter: New Project`，如果能看到这个命令，说明插件安装成功。

---

## 三、安装构建工具链

根据你的目标平台，选择安装对应的工具链。

### 3.1 Android 版（需要 Android SDK）

#### 方式一：通过 Android Studio 安装（推荐）

1. 安装 [Android Studio](https://developer.android.com/studio)
2. 首次启动选择 **Standard** 安装，会自动下载 Android SDK
3. 打开 **Settings → Appearance & Behavior → System Setting → Android SDK**，记下 SDK 路径（通常为 `%LOCALAPPDATA%\Android\Sdk`）
4. 设置环境变量：
   ```powershell
   [Environment]::SetEnvironmentVariable("ANDROID_SDK_ROOT", "$env:LOCALAPPDATA\Android\Sdk", "User")
   ```

#### 方式二：仅安装命令行工具（轻量）

1. 下载 [Command line tools](https://developer.android.com/studio#command-line-tools-only)
2. 解压到 `%LOCALAPPDATA%\Android\cmdline-tools\latest`
3. 安装 SDK：
   ```powershell
   cd %LOCALAPPDATA%\Android\cmdline-tools\latest\bin
   sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0"
   ```
4. 接受许可证：
   ```powershell
   flutter doctor --android-licenses
   ```

### 3.2 Windows 桌面版（需要 MSVC 工具链）

1. 下载 [Build Tools for Visual Studio 2022](https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022)
2. 安装时勾选：
   - ✅ **使用 C++ 的桌面开发**
   - ✅ **Windows 10 SDK**
   - ✅ **C++ CMake 工具**
3. 完成安装后运行 `flutter doctor` 验证

---

## 四、打开项目

### 4.1 克隆项目

打开 VS Code，按 `Ctrl + ` ` 打开终端：

```powershell
cd $env:USERPROFILE\Documents
git clone https://github.com/xtangxtang/storyforge-app.git
```

### 4.2 打开文件夹

1. **File → Open Folder**
2. 选择 `storyforge-app` 文件夹
3. 如果弹出提示，点击 **Yes, I trust the authors**

---

## 五、安装依赖并运行

### 5.1 安装 Flutter 依赖

在终端中运行：

```powershell
flutter pub get
```

### 5.2 选择目标设备

点击 VS Code 右下角的状态栏中的设备名称，选择目标平台。

或者按 `Ctrl + Shift + P`，输入 `Flutter: Select Device`。

可用设备包括：

| 设备 | 前置条件 |
|------|----------|
| Windows (desktop) | 已安装 VS Build Tools |
| Android 模拟器 | 已安装 Android SDK 并创建模拟器 |
| Android 真机 | USB 调试已开启并连接 |

### 5.3 运行项目

**方式一：快捷键**

按 `F5` 直接运行。

**方式二：菜单**

**Run → Start Debugging**。

**方式三：终端**

```powershell
flutter run -d windows     # Windows 桌面
flutter run -d <device_id> # 其他设备
```

### 5.4 热重载

修改代码后保存（`Ctrl + S`），应用会自动更新，无需重新编译。

按 `Ctrl + F5` 可以执行完整重启（热重启）。

---

## 六、构建发布版本

在终端中运行：

```powershell
# Windows 桌面版
flutter build windows --release
# 输出：build\windows\x64\runner\Release\

# Android APK
flutter build apk --release
# 输出：build\app\outputs\flutter-apk\app-release.apk

# Android App Bundle
flutter build appbundle --release
```

---

## 七、配置 API Key

应用首次运行后，进入 **设置** 页面：

1. 输入 DashScope LLM API Key
2. 输入 DashScope 图视频 API Key
3. 点击 **保存**

配置完成后即可开始创建项目。

---

## 八、VS Code 快捷键参考

| 快捷键 | 功能 |
|--------|------|
| `F5` | 启动调试 |
| `Ctrl + F5` | 不调试启动 |
| `Ctrl + S` | 热重载 |
| `Ctrl + Shift + P` | 命令面板 |
| `Ctrl + Shift + X` | 扩展面板 |
| `Ctrl + ` ` ` | 打开终端 |
| `Ctrl + Shift + B` | 运行构建任务 |

---

## 九、常见问题

### Q: flutter doctor 显示 Flutter SDK not found

确保 `C:\flutter\bin` 已添加到 PATH。重启终端后运行：

```powershell
where flutter
```

应该输出 `C:\flutter\bin\flutter`。

### Q: VS Code 右下角没有设备可选

运行 `flutter doctor` 查看哪些工具链未安装。常见问题：

- **Android SDK not found**：设置 `ANDROID_SDK_ROOT` 环境变量
- **Visual Studio not found**：安装 Build Tools 并勾选 C++ 桌面开发

### Q: 编译报 Gradle build failed

```powershell
flutter clean
flutter pub get
flutter run
```

如果仍然失败，检查 Android SDK 是否完整安装。

### Q: Windows 编译报 MSB8020 错误

说明 MSVC 工具链未正确安装。确保 VS Build Tools 已安装 **使用 C++ 的桌面开发** 和 **Windows 10 SDK**。

### Q: 模拟器无法启动

在 BIOS 中启用虚拟化（VT-x / AMD-V），然后重启电脑。

### Q: VS Code 没有 Flutter 代码提示

1. 确认已安装 **Flutter** 和 **Dart** 两个插件
2. 按 `Ctrl + Shift + P` → `Dart: Restart Analysis Server`
3. 重启 VS Code

---

## 十、与 Android Studio 的对比

| | VS Code | Android Studio |
|---|---|---|
| 内存占用 | ~500MB | ~1.5GB+ |
| 启动速度 | 快 | 较慢 |
| 代码补全 | 好 | 更好 |
| UI 预览 | 基础 | 完整（Layout Inspector）|
| 调试器 | 完整 | 完整 |
| 适合场景 | 快速开发、轻量编辑 | 大型项目、深度调试 |

如果你只需要编译和编写代码，VS Code 完全够用。

---

*2026-04-26*
