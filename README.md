# DeepSeek Harness Launcher

DeepSeek Harness Web 的 Windows 原生启动器。单 EXE 运行，无需安装；启动后常驻系统托盘，用于启动、停止、重启 DeepSeek Harness，并可直接打开 Web 界面和日志。

> 本项目为独立工具，不是 DeepSeek 官方产品。

## 功能

- 原生 Windows 托盘程序，无 PowerShell/VBS 外壳依赖
- 双击 EXE：
  - 已有 Launcher 实例时，复用现有实例
  - DSH 已运行时直接打开 Web 界面
  - DSH 未运行时启动服务，服务就绪后打开 Web 界面
- 托盘右键菜单：
  - 打开 Web 界面
  - 查看日志
  - 启动服务
  - 停止服务
  - 重启服务
  - 开机自动启动
  - 退出并停止服务
- 启动、停止、重启过程中三个操作菜单统一置灰，操作完成后自动恢复正确状态
- 鼠标悬停托盘图标时显示应用名称和当前状态，例如：
  - `DeepSeek Harness Launcher - 运行中（:3080）`
  - `DeepSeek Harness Launcher - 已停止（:3080）`
- 自动识别 `dsh.cmd`
- 自动选择兼容的 Node.js
- 自动读取 Windows 当前代理设置并传递给 DSH 子进程
- 隐藏 DSH/插件间接启动 PowerShell 时产生的黑色控制台窗口
- 支持开机自启动，并自动迁移旧的注册表启动项名称

## 下载

直接从 GitHub Releases 下载最新版本：

https://github.com/SculptureTime/deepseek_harness_launcher/releases/latest

下载 `DeepSeek-Harness-Launcher.zip`，解压后得到 `DeepSeek Harness Launcher.exe`，双击即可运行，不需要安装。

> GitHub 会自动清洗 Release 资产文件名中的空格，因此正式发布使用 ZIP，确保压缩包内的 EXE 始终保持精确文件名 `DeepSeek Harness Launcher.exe`。

## 环境要求

- Windows 10 / Windows 11
- 已安装 DeepSeek Harness
- `dsh.cmd` 已加入 `PATH`
- Node.js 满足以下任一条件：
  - Node.js 22.19+
  - Node.js 24+

Launcher 会优先使用 `dsh.cmd` 自己绑定的兼容 Node；如果没有，再从 NVM 和系统 `PATH` 中寻找可用版本。

## 使用

### 启动

双击：

```text
DeepSeek Harness Launcher.exe
```

Launcher 会自动常驻系统托盘。

### 托盘菜单

右键托盘图标可以执行：

```text
打开 Web 界面
查看日志
----------------
启动服务
停止服务
重启服务
----------------
开机自动启动
----------------
退出（停止服务）
```

### 双击行为

- DSH 正在运行：打开 `http://127.0.0.1:3080/`
- DSH 尚未运行：启动 DSH，等待服务真正可用后打开浏览器
- Launcher 已经运行：不会再启动第二个托盘实例，而是通知现有实例处理

## 状态与日志

默认 DSH Web 端口：

```text
3080
```

Launcher 日志位于当前用户临时目录：

```text
%TEMP%\dsh-tray.out.log
%TEMP%\dsh-tray.err.log
```

运行状态文件及 Launcher 生成的本地辅助文件位于：

```text
%LOCALAPPDATA%\DeepSeek Harness\
```

## 源码结构

```text
native/
  dsh-tray.c               原生 Launcher 主程序
  dsh-tray.rc              Windows 资源与版本信息
  dsh-tray.manifest        应用 manifest
  dsh-tray-padded.ico      EXE / 托盘图标

tests/
  native-tray.tests.ps1    原生 Launcher 回归测试
assets/
  dsh-tray.ps1             早期 PowerShell 实现，保留作历史兼容参考
```

当前正式版本以 `native/dsh-tray.c` 为准。

## 本地测试

使用 PowerShell 7：

```powershell
pwsh -NoProfile -File .\tests\native-tray.tests.ps1
```

如需同时验证早期 PowerShell 版本：

```powershell
pwsh -NoProfile -File .\tests\dsh-tray.tests.ps1
```

## 编译

正式构建使用 Microsoft Visual C++（MSVC），与已验证可正常启动的本地版本保持同一编译器链。

在 x64 Native Tools Command Prompt 中执行：

```bat
cd native
rc /nologo /fo dsh-tray.res dsh-tray.rc
cl /nologo /W4 /O2 /MT /DUNICODE /D_UNICODE /Fe:"..\DeepSeek Harness Launcher.exe" dsh-tray.c dsh-tray.res /link /SUBSYSTEM:WINDOWS ws2_32.lib shell32.lib advapi32.lib iphlpapi.lib
```

正式 Release 使用源码中的 Windows 版本资源生成，当前版本为 `1.0.7`。

## License

MIT License，详见 [LICENSE](LICENSE)。
