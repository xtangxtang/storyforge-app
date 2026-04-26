# 在 Linux 上编译 Android 版 Storyforge

本文档介绍如何在 Linux 系统上编译、测试和发布 Storyforge 的 Android 版本。

> Linux 是 Flutter Android 开发的最佳平台之一，无需虚拟机即可完整构建和测试。

---

## 一、安装 Flutter SDK

### 1.1 下载

```bash
cd ~
wget -O flutter.tar.xz https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.27.4-stable.tar.xz
```

### 1.2 解压

```bash
mkdir -p ~/sdk
tar xf flutter.tar.xz -C ~/sdk
rm flutter.tar.xz
```

### 1.3 添加到 PATH

将以下行添加到 `~/.bashrc` 或 `~/.zshrc`：

```bash
export PATH="$HOME/sdk/flutter/bin:$PATH"
```

使配置生效：

```bash
source ~/.bashrc
```

---

## 二、安装 Android SDK（命令行方式）

不需要安装 Android Studio，仅安装 SDK 命令行工具即可。

### 2.1 下载 Command-line Tools

```bash
mkdir -p ~/Android/cmdline-tools
cd ~/Android/cmdline-tools

# 下载
wget -O cmdline-tools.zip "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
unzip cmdline-tools.zip
mv cmdline-tools latest
rm cmdline-tools.zip
```

### 2.2 设置环境变量

添加到 `~/.bashrc` 或 `~/.zshrc`：

```bash
export ANDROID_HOME="$HOME/Android"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
```

使配置生效：

```bash
source ~/.bashrc
```

### 2.3 安装 SDK 组件

```bash
# 接受所有许可证
yes | sdkmanager --licenses

# 安装必要组件
sdkmanager "platform-tools" \
           "platforms;android-34" \
           "build-tools;34.0.0" \
           "system-images;android-34;google_apis;x86_64"
```

### 2.4 接受 Android 许可证

```bash
flutter doctor --android-licenses
```

---

## 三、安装依赖库

### Ubuntu / Debian

```bash
sudo apt update
sudo apt install -y \
    clang cmake git ninja-build pkg-config \
    libgtk-3-dev liblzma-dev libstdc++-12-dev \
    openjdk-17-jdk
```

### Fedora

```bash
sudo dnf install -y \
    clang cmake git ninja-build pkg-config \
    gtk3-devel xz-devel libstdc++-static \
    java-17-openjdk-devel
```

---

## 四、验证环境

```bash
flutter doctor -v
```

应看到以下绿色对勾：

```
[✓] Flutter (Channel stable)
[✓] Android toolchain - develop for Android devices
[✓] Android Studio (not required, command-line only is fine)
```

---

## 五、连接真机测试

### 5.1 手机端设置

1. 进入 **设置 → 关于手机**，连续点击 **版本号** 7 次
2. 返回 **设置 → 开发者选项**，开启 **USB 调试**

### 5.2 电脑端设置

```bash
# 安装 adb 工具（如果 sdkmanager 未安装）
sudo apt install adb -y

# 查看设备
adb devices
```

手机弹出 **允许 USB 调试** 时点击 **允许**。

### 5.3 运行

```bash
cd ~/storyforge-ws/storyforge_app
flutter pub get
flutter run -d <device_id>
```

`<device_id>` 来自 `adb devices` 输出。

---

## 六、使用模拟器测试（无真机）

### 6.1 创建模拟器

```bash
# 列出可用系统镜像
sdkmanager --list | grep system-images

# 创建模拟器（AVD）
avdmanager create avd \
    --name pixel_7 \
    --package "system-images;android-34;google_apis;x86_64" \
    --device "pixel_7"
```

### 6.2 启动模拟器

```bash
# 方式一：通过 Flutter
flutter emulators --launch pixel_7

# 方式二：直接启动
emulator -avd pixel_7
```

### 6.3 运行项目

```bash
flutter run -d pixel_7
```

> **注意**：Linux 上的模拟器需要 KVM 硬件虚拟化支持。如果启动很慢或失败，运行：
> ```bash
> sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils
> sudo usermod -aG kvm $USER
> # 重新登录后生效
> ```

---

## 七、构建发布版本

### 7.1 生成签名密钥（首次）

```bash
keytool -genkey -v \
    -keystore ~/upload-keystore.jks \
    -storetype JKS \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -alias upload
```

按提示输入：
- 密钥库密码（记住这个密码）
- 姓名、组织等基本信息
- 确认信息（输入 `yes`）

### 7.2 配置签名

创建 `android/key.properties`：

```bash
cat > android/key.properties << EOF
storePassword=<你设置的密钥库密码>
keyPassword=<你设置的密钥密码>
keyAlias=upload
storeFile=/home/$USER/upload-keystore.jks
EOF
```

编辑 `android/app/build.gradle`，在 `android {` 之前添加：

```groovy
def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}
```

将 `buildTypes { release { ... } }` 替换为：

```groovy
signingConfigs {
    release {
        keyAlias keystoreProperties['keyAlias']
        keyPassword keystoreProperties['keyPassword']
        storeFile file(keystoreProperties['storeFile'])
        storePassword keystoreProperties['storePassword']
    }
}
buildTypes {
    release {
        signingConfig signingConfigs.release
    }
}
```

### 7.3 构建 APK

```bash
flutter build apk --release
```

输出位置：`build/app/outputs/flutter-apk/app-release.apk`

### 7.4 构建 App Bundle（上架用）

```bash
flutter build appbundle --release
```

输出位置：`build/app/outputs/bundle/release/app-release.aab`

---

## 八、CI/CD 自动构建（可选）

在 Linux 服务器上配置 GitHub Actions 自动构建 Android 版本。

### 8.1 创建工作流文件

```bash
mkdir -p .github/workflows
```

创建 `.github/workflows/build-android.yml`：

```yaml
name: Build Android
on:
  push:
    tags:
      - 'v*'

jobs:
  build-android:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: subosito/flutter-action@v2
        with:
          channel: stable

      - name: Install dependencies
        run: flutter pub get

      - name: Build APK
        run: flutter build apk --release

      - name: Upload APK
        uses: actions/upload-artifact@v4
        with:
          name: Storyforge-Android
          path: build/app/outputs/flutter-apk/app-release.apk

      - name: Create Release
        uses: softprops/action-gh-release@v2
        with:
          files: build/app/outputs/flutter-apk/app-release.apk
          generate_release_notes: true
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### 8.2 触发构建

```bash
git tag v1.0.0
git push origin v1.0.0
```

GitHub Actions 会自动构建并生成 Release，包含 APK 文件。

---

## 九、在 Linux 上能否编译 Windows 版？

**不能直接编译**。Flutter Windows 平台需要 Windows 主机和 MSVC 工具链。

但在 Linux 上可以：

- ✅ 编写和调试代码（热重载）
- ✅ 运行 Linux 桌面版（`flutter run -d linux`）
- ✅ 构建 Android APK
- ❌ 构建 Windows exe（需要 Windows 环境）

如需在 Linux 上生成 Windows 版，可使用：

1. **GitHub Actions**（推荐）：在云端 Windows Runner 上编译
2. **Wine + Cross-compilation**（复杂且不推荐）

---

## 十、常见问题

### Q: flutter doctor 显示 Android SDK not found

确保 `ANDROID_HOME` 环境变量已正确设置：

```bash
echo $ANDROID_HOME
# 应输出 /home/你的用户名/Android
```

### Q: adb devices 显示无权限

```bash
# 创建 udev 规则
sudo bash -c 'cat > /etc/udev/rules.d/51-android.rules << EOF
SUBSYSTEM=="usb", ATTR{idVendor}=="*", MODE="0666", GROUP="plugdev"
EOF'
sudo chmod a+r /etc/udev/rules.d/51-android.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

### Q: 模拟器启动失败：KVM not found

```bash
# 检查是否支持虚拟化
egrep -c '(vmx|svm)' /proc/cpuinfo
# 输出 > 0 表示支持

# 加载 KVM 模块
sudo modprobe kvm
sudo modprobe kvm_intel  # Intel CPU
# 或
sudo modprobe kvm_amd    # AMD CPU
```

### Q: 构建 APK 失败：Gradle out of memory

编辑 `android/gradle.properties`，增加内存：

```properties
org.gradle.jvmargs=-Xmx4g -XX:MaxMetaspaceSize=512m
```

---

*2026-04-26*
