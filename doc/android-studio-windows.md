# 在 Windows 下使用 Android Studio 编译 Storyforge

本文档介绍如何在 Windows 系统上使用 Android Studio 编译 Storyforge Flutter 应用，
包括桌面版（Windows）和移动版（Android）。

---

## 一、安装 Android Studio

### 1.1 下载安装包

访问 [Android Studio 下载页](https://developer.android.com/studio)，点击 **Download Android Studio**，运行安装程序。

### 1.2 安装步骤

1. 运行下载的 `.exe` 文件
2. 保持默认选项，一路点击 **Next**
3. 安装路径建议保持默认（如 `C:\Program Files\Android\Android Studio`）
4. 安装完成后启动 Android Studio
5. 首次启动会弹出 **Android Studio Setup Wizard**，选择 **Standard** 安装
6. 等待下载 Android SDK 和相关组件完成

---

## 二、安装 Flutter 插件

### 2.1 打开插件市场

1. 打开 Android Studio
2. 进入 **File → Settings**（或 `Ctrl + Alt + S`）
3. 左侧选择 **Plugins**
4. 点击顶部的 **Marketplace** 标签

### 2.2 安装 Flutter

1. 搜索 **Flutter**，点击 **Install**
2. 安装 Flutter 插件后会自动提示安装 **Dart** 插件，点击 **Install**
3. 安装完成后点击 **Restart IDE** 重启 Android Studio

### 2.3 验证

重启后，新建项目时应该能看到 **Create New Flutter Project** 选项，说明插件安装成功。

---

## 三、配置 Flutter SDK

### 3.1 下载 Flutter SDK

1. 访问 [Flutter 安装页](https://docs.flutter.dev/get-started/install/windows)
2. 点击 **Download the Flutter SDK**，下载 `.zip` 文件
3. 解压到一个固定目录，例如 `C:\flutter`

> **注意**：路径中不要包含中文或空格，推荐直接使用 `C:\flutter`。

### 3.2 添加到系统 PATH

1. 按 `Win + S`，搜索 **环境变量**，打开 **编辑系统环境变量**
2. 点击 **环境变量** 按钮
3. 在 **用户变量** 中找到 `Path`，点击 **编辑**
4. 点击 **新建**，添加 `C:\flutter\bin`
5. 依次点击 **确定** 保存

### 3.3 在 Android Studio 中配置

1. 打开 **File → Settings → Languages & Frameworks → Flutter**
2. **Flutter SDK path** 填写 `C:\flutter`（或你的实际路径）
3. 点击 **Apply**

### 3.4 验证

打开 Android Studio 底部的 **Terminal**，运行：

```powershell
flutter doctor
```

查看各工具链的安装状态。

---

## 四、安装 Windows 桌面工具链（可选）

如果你需要编译 Windows 桌面版应用，需要安装 Visual Studio 的编译工具。
如果只编译 Android 版，可跳过本节。

### 4.1 下载 Build Tools

前往 [Visual Studio Build Tools 下载页](https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022)，
找到 **Build Tools for Visual Studio 2022**，点击下载。

### 4.2 选择工作负载

运行安装程序，在 **工作负载** 页勾选：

- ✅ **使用 C++ 的桌面开发**
- ✅ 右侧的 **Windows 10 SDK**（或 Windows 11 SDK）
- ✅ **C++ CMake 工具**

其余默认即可，点击 **安装**。

### 4.3 验证

```powershell
flutter doctor
```

`Visual Studio - develop for Windows` 应显示绿色对勾。

---

## 五、安装 Android 工具链

安装 Android Studio 时已自动安装 SDK，但还需要以下配置。

### 5.1 安装 Android SDK

1. 打开 **File → Settings → Appearance & Behavior → System Settings → Android SDK**
2. 确认 SDK 路径存在（通常为 `%LOCALAPPDATA%\Android\Sdk`）
3. 切换到 **SDK Platforms** 标签，勾选一个 Android 版本（如 **Android 14.0 "UpsideDownCake"**）
4. 切换到 **SDK Tools** 标签，勾选 **Android SDK Command-line Tools**
5. 点击 **Apply** 下载安装

### 5.2 接受许可证

在 Android Studio 底部 **Terminal** 中运行：

```powershell
flutter doctor --android-licenses
```

一路输入 `y` 接受所有许可证。

---

## 六、连接设备或模拟器

### 6.1 Android 模拟器

1. 在 Android Studio 中点击顶部工具栏的 **Device Manager** 图标（手机图标）
2. 点击 **Create Device**
3. 选择一个设备型号（如 **Pixel 7**），点击 **Next**
4. 选择一个系统镜像（推荐 **Tiramisu / Android 14**），点击 **Next**
5. 点击 **Finish**
6. 点击模拟器旁的 **▶** 按钮启动

### 6.2 Android 真机

1. 在手机上打开 **开发者选项**
   - 进入 **设置 → 关于手机**，连续点击 **版本号** 7 次，启用开发者模式
2. 进入 **设置 → 开发者选项**，开启 **USB 调试**
3. 用 USB 数据线连接电脑
4. 手机上弹出 **允许 USB 调试** 时，点击 **允许**
5. 运行 `flutter devices` 应能看到你的设备

### 6.3 Windows 桌面

如果使用 Build Tools 安装了桌面工具链，`Windows (desktop)` 会自动出现在设备列表中：

```powershell
flutter devices
```

---

## 七、打开项目并编译

### 7.1 克隆项目

在 Android Studio 底部 **Terminal** 中运行：

```powershell
cd %USERPROFILE%\Documents
git clone https://github.com/xtangxtang/storyforge-app.git
```

### 7.2 打开项目

1. **File → Open**
2. 选择 `storyforge-app` 文件夹
3. 等待 Android Studio 索引项目

### 7.3 安装依赖

在 Terminal 中运行：

```powershell
cd storyforge-app
flutter pub get
```

### 7.4 运行项目

1. 在顶部工具栏选择目标设备（如 **Windows (desktop)** 或你的模拟器/真机）
2. 点击顶部的 **▶（Run）** 按钮，或按 `Shift + F10`
3. 首次运行会自动编译，后续支持热重载（修改代码后按 `Ctrl + S` 即可）

### 7.5 构建发布版本

在 Terminal 中运行：

```powershell
# Windows 桌面版（生成 exe）
flutter build windows --release
# 输出位置：build\windows\x64\runner\Release\

# Android APK
flutter build apk --release
# 输出位置：build\app\outputs\flutter-apk\app-release.apk

# Android App Bundle（上架 Google Play 用）
flutter build appbundle --release
# 输出位置：build\app\outputs\bundle\release\app-release.aab
```

---

## 八、配置应用图标和名称

### 8.1 修改应用名称

打开 `lib/main.dart`，修改 `MaterialApp` 的 `title` 参数：

```dart
MaterialApp(
  title: 'Storyforge',  // 这里改名称
  ...
)
```

### 8.2 修改应用图标

- **Windows**：替换 `windows/runner/resources/app_icon.ico`
- **Android**：替换 `android/app/src/main/res/mipmap-*/ic_launcher.png`

然后重新运行 `flutter pub run flutter_launcher_icons`（需安装 `flutter_launcher_icons` 插件）。

---

## 九、常见问题

### Q: flutter doctor 显示 Cannot find Flutter SDK at the specified path

检查 `C:\flutter\bin` 是否在 PATH 中。运行以下命令确认：

```powershell
where flutter
```

应该输出 `C:\flutter\bin\flutter`。

### Q: flutter doctor 显示 Android SDK not found

1. 打开 **File → Settings → Appearance & Behavior → System Settings → Android SDK**
2. 确认 SDK 路径存在（通常为 `%LOCALAPPDATA%\Android\Sdk`）
3. 设置环境变量 `ANDROID_SDK_ROOT`：
   ```powershell
   [Environment]::SetEnvironmentVariable("ANDROID_SDK_ROOT", "$env:LOCALAPPDATA\Android\Sdk", "User")
   ```
4. 重启终端后运行 `flutter doctor`

### Q: 编译时报错 Gradle build failed

1. 确保 Java JDK 已安装（Android Studio 自带 JRE 通常够用）
2. 运行 `flutter clean` 再 `flutter pub get`
3. 如仍有问题，尝试升级 Gradle 版本

### Q: Windows 编译时报错 MSB8020 / MSB8040

说明 Visual Studio 工具链未正确安装。确保已安装 **使用 C++ 的桌面开发** 和 **Windows 10 SDK**。

### Q: 模拟器无法启动

确保电脑开启了 **虚拟化**（VT-x / AMD-V），在 BIOS 中启用后重启。

---

## 十、设置页面配置

应用首次运行后，进入 **设置** 页面：

1. 输入 DashScope LLM API Key（文本生成用）
2. 输入 DashScope 图视频 API Key（图像/视频生成用）
3. （可选）输入代理地址
4. 点击 **保存**

配置完成后即可开始创建项目。

---

*2026-04-26*
