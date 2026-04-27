# Scripts 使用说明

本文档说明如何执行以下两个 PowerShell 脚本：

1. setup-windows-build-env.ps1：配置 Windows 编译环境
2. build-windows.ps1：一键编译 Windows Release

---

## 前置条件

1. 操作系统：Windows
2. 终端：PowerShell
3. 当前目录建议在项目根目录：

   C:\Users\xtang29\storyforge-app

---

## 国内镜像（可选但推荐）

如果访问 `pub.dev` 不稳定，可设置以下两个环境变量：

1. `PUB_HOSTED_URL=https://pub.flutter-io.cn`（Dart/Flutter 包下载镜像）
2. `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`（Flutter 构建依赖下载镜像）

仅当前 PowerShell 会话生效：

```powershell
$env:PUB_HOSTED_URL="https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
```

永久生效（写入用户环境变量，需重开终端）：

```powershell
setx PUB_HOSTED_URL "https://pub.flutter-io.cn"
setx FLUTTER_STORAGE_BASE_URL "https://storage.flutter-io.cn"
```

---

## 代理设置（网络不稳定时推荐）

如果 `flutter doctor -v` 或 `flutter pub get` 提示 socket error，可在当前 PowerShell 会话设置代理：

```powershell
$env:HTTP_PROXY="http://127.0.0.1:7890"
$env:HTTPS_PROXY="http://127.0.0.1:7890"
```

说明：

1. `127.0.0.1:7890` 只是示例，请替换为你自己的代理地址和端口。
2. 该设置只对当前终端生效，关闭终端后失效。

取消当前会话代理：

```powershell
Remove-Item Env:HTTP_PROXY -ErrorAction SilentlyContinue
Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue
```

---

## 一、执行环境配置脚本

脚本路径：scripts\win\setup-windows-build-env.ps1

### 1. 仅检测环境并输出状态

powershell -ExecutionPolicy Bypass -File .\scripts\win\setup-windows-build-env.ps1

### 2. 自动安装缺失项（推荐）

powershell -ExecutionPolicy Bypass -File .\scripts\win\setup-windows-build-env.ps1 -InstallFlutterIfMissing -InstallVsBuildToolsIfMissing

说明：

1. Flutter 自动安装方式为 git clone stable 分支到 FlutterSdkPath（默认 C:\flutter）。
2. VS Build Tools 自动安装方式为 winget。

### 3. 指定 Flutter 安装目录（可选）

powershell -ExecutionPolicy Bypass -File .\scripts\win\setup-windows-build-env.ps1 -InstallFlutterIfMissing -FlutterSdkPath C:\flutter

说明：

1. 如果首次安装 VS Build Tools，建议安装完成后重启系统。
2. 如果脚本提示 flutter 未找到，重开终端后再执行。

---

## 二、执行一键构建脚本

脚本路径：scripts\win\build-windows.ps1

### 1. 最简构建（Release）

powershell -ExecutionPolicy Bypass -File .\scripts\win\build-windows.ps1

### 2. 先清理再构建

powershell -ExecutionPolicy Bypass -File .\scripts\win\build-windows.ps1 -Clean

### 3. 构建并打包 ZIP

powershell -ExecutionPolicy Bypass -File .\scripts\win\build-windows.ps1 -Clean -Zip

### 4. 指定版本号（可选）

powershell -ExecutionPolicy Bypass -File .\scripts\win\build-windows.ps1 -BuildName 1.0.1 -BuildNumber 2

输出目录：

1. exe 目录：build\windows\x64\runner\Release（文件名不一定是 runner.exe，例如可能是 storyforge_app.exe）
2. zip 目录（启用 -Zip 时）：build\dist

构建脚本会自动识别 Release 目录中的 `*.exe`，并在成功后输出可执行文件完整路径。

---

## 常见问题

### 1) 提示脚本无法运行（执行策略限制）

用以下命令执行（已包含临时绕过策略）：

powershell -ExecutionPolicy Bypass -File .\scripts\win\setup-windows-build-env.ps1

### 2) 提示找不到 flutter

1. 确认 Flutter 已安装。
2. 关闭并重新打开 PowerShell。
3. 运行 where flutter 检查是否在 PATH 中。

### 3) Windows 构建报 MSVC/SDK 相关错误

执行环境配置脚本并带上自动安装参数：

powershell -ExecutionPolicy Bypass -File .\scripts\win\setup-windows-build-env.ps1 -InstallVsBuildToolsIfMissing

### 4) 提示 Building with plugins requires symlink support

这是 Windows 符号链接权限问题，处理方式二选一：

1. 启用 Windows 开发者模式（推荐，一次设置长期生效）：
   start ms-settings:developers
2. 使用管理员身份运行 PowerShell 再执行构建。

### 5) 只想确认 ZIP 是否生成成功

```powershell
Get-ChildItem .\build\dist\*.zip
```

---

## 推荐执行顺序

1. 先执行 setup-windows-build-env.ps1。
2. 确认 flutter doctor -v 无关键报错。
3. 再执行 build-windows.ps1 进行发布构建。
