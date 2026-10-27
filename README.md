# 拾影 Shiying

**把 YouTube 和 Telegram 的视频收进手机，离线播放。**

一个 iOS 17+ 的 SwiftUI 视频下载与管理 App。深色玻璃界面，无账号、无服务端、无统计上报，片库与视频全部保存在本机。

<p align="center">
  <img src="https://img.shields.io/badge/iOS-17%2B-black?style=flat-square" alt="iOS 17+" />
  <img src="https://img.shields.io/badge/Swift-6-orange?style=flat-square" alt="Swift 6" />
  <img src="https://img.shields.io/badge/build-xtool-8A2BFF?style=flat-square" alt="xtool" />
  <img src="https://img.shields.io/badge/storage-on--device-2ea44f?style=flat-square" alt="on-device" />
</p>

<p align="center">
  <img src="docs/images/library.jpg" width="24%" alt="YouTube 片库" />
  <img src="docs/images/telegram-library.jpg" width="24%" alt="Telegram 片库" />
  <img src="docs/images/downloads.jpg" width="24%" alt="下载队列" />
  <img src="docs/images/trash.jpg" width="24%" alt="废纸篓" />
</p>

> 截图为改版前拍摄。当前版本已改为**左滑直接删除**，列表右侧不再有「…」按钮；下载页的批量操作也改成了图标按钮（暂停/播放、垃圾桶），操作区截图见[使用教程](docs/USAGE.md#3-下载队列)。

## 功能

### 导入

- **YouTube 单条视频 / 播放列表**：解析标题、封面、时长与可用画质；音视频分离的流会在播放时自动合成。
- **Telegram 公开帖子 / 频道**：支持 `t.me/...` 链接。网页预览只提供约 20MB 以内的文件；更大的视频可在 App 内登录后通过 TDLib 直接下载。
- **Telegram 扫码登录**：填写自己的 `api_id` / `api_hash`，用已登录 Telegram 的手机扫码；支持两步验证密码。二维码可分享到电脑，再用同一台手机扫描。
- **三种入口**：App 内粘贴链接、剪贴板自动识别、系统分享面板的「拾影」扩展。

### 下载

- **队列与并发**：同时下载 1–4 个，超出自动排队；支持全部暂停 / 继续、单任务取消、失败自动重试 5 次、退出重进后恢复任务。
- **后台继续下载**：YouTube 走系统后台 `URLSession`；Telegram 的 TDLib 传输由静音音频 + 后台任务保活。切到后台或锁屏后仍会继续，长时间后台时 iOS 仍可能暂停，回到 App 会自动续上。
- **画质兜底**：所选画质不可用时，只对当前视频自动升级到更高的可用画质，不影响其他任务。
- **分片加速**：YouTube 支持单连接 / 4 连接 / 8 连接；先探测服务器是否支持 `Range`，不支持时自动回退。
- **实时速度**：每个任务显示速度与总进度，页面标题显示全局总速度。

### 片库与播放

- **按来源分组**：YouTube（Y）与 Telegram（T）分开浏览、分开连播，支持手动排序；设置中可分别自定义两页标题。
- **左滑删除**：滑到行宽约 45% 松手即可删除；废纸篓中右滑恢复。
- **废纸篓**：播放后或手动删除的视频保留 7 天，可批量恢复 / 彻底删除 / 一键清空；可按来源关闭「播放后自动清理」。
- **播放器**：本地文件播放、画中画、拖拽进度、±10 秒快退快进。
- **迷你播放条**：播放页左上角向下收起后，播放器缩成标签栏上方的进度条，可以继续刷片库或看下载进度；点一下恢复全屏。边框用呼吸光表示状态：播放淡绿、暂停淡红。
- **横屏**：播放页右上角的旋转按钮可在横屏 / 竖屏之间切换，横屏视频不用开画中画也能满屏观看。
- **倍速**：全局 0.5×–4×；播放时长按画面可临时再加速 0.5×，松手恢复。

### 隐私

- **Telegram 访问密码**：保护整个 Telegram 模块（群组、会话与已下载列表）；解锁后记住状态，不会反复要求输入。密码只保存加盐 SHA-256 摘要；输错会进入只读的演示对话，不暴露真实内容。
- **本机优先**：无服务端、无统计上报；Telegram API 凭证与访问密码摘要存放在系统钥匙串。
- **剪贴板可控**：仅在打开 / 回到前台时读取文本用于识别链接，可在设置里关闭。

## 快速开始

### 环境要求

- iPhone，iOS 17.0 及以上
- 构建机：**Linux / WSL2（推荐 Ubuntu）** 或 macOS，安装 Swift 6+ 与 [xtool](https://github.com/xtool-org/xtool)
- 一个 Apple ID 用于签名（**免费账号即可**，签名 7 天有效）
- 可选：Telegram API 凭证（下载超过 20MB 的 Telegram 视频时需要）

首次构建会下载 TDLib 预编译框架并编译 TDLibKit，大约需要 **6GB 内存和 10 分钟**。

### 编译并生成 IPA

在仓库根目录：

```bash
bash Scripts/build-ipa.sh
```

脚本会把 `Shiying/` 镜像到 `$HOME/shiying`（保留 `.build` 增量缓存），执行签名 release 构建，并把 IPA 复制到 `Shiying/xtool/`。可用 `SHIYING_BUILD_DIR` 指定其他构建目录。

也可以直接构建：

```bash
cd Shiying
xtool dev build -c release --sign --ipa
```

### 安装到 iPhone

```bash
bash Scripts/device.sh install
```

首次连接需要在 iPhone 上开启**开发者模式**，并在「设置 → 通用 → VPN 与设备管理」中信任开发证书。

> **已知现象**：`xtool install` 有时在 `[Installing] 100%` 后不退出。等待约 25 秒后中断即可，安装通常已经完成；用启动命令验证，不要急着卸载重装。

### 启动

```bash
bash Scripts/device.sh launch
```

脚本会自动从设备读取真实 Bundle ID。iOS 17+ 上 `xtool launch` 可能报 `DebugserverClient.Error.unknown`（安装其实已成功），所以启动统一走 `pymobiledevice3`；也可以直接在主屏幕点图标。

真实 Bundle ID 会被免费签名加上 `XTL-<TeamID>.` 前缀，可用 `bash Scripts/device.sh bundle` 查看。

其它辅助命令：

```bash
bash Scripts/device.sh doctor      # 检查设备/工具链/安装状态
bash Scripts/device.sh screenshot  # 截图到 /tmp/shiying.png
bash Scripts/device.sh logs        # 尝试通过 USB 拉取 shiying.log
bash Scripts/device.sh logstream   # 实时系统日志（syslog live -m Shiying）
```

> 部分 iOS 26 + 免费签名环境不允许 `house_arrest` 读取 App 容器（`apps pull` 报 `InstallationLookupFailed`）。
> 这时用 App 内的 **设置 → 诊断 → 导出运行日志**，不影响 App 功能。

完整的设备连接、签名、日志抓取和排障步骤见 **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)**。

## Telegram 配置

1. 用 Telegram 手机号登录 [my.telegram.org](https://my.telegram.org) → **API development tools** → 创建应用，记下 `api_id` 和 `api_hash`（免费，只需一次；验证码会发到 Telegram App 内）。
2. 打开 App：**设置 → Telegram 登录**，填入 API ID / API Hash，点「保存并扫码登录」。
3. 扫描二维码：同机可直接扫；也可以把二维码分享到电脑，再用手机扫描电脑屏幕。
4. 若账号开启两步验证，按提示输入 Telegram 密码。
5. 之后导入超过网页预览上限的 Telegram 视频时，会自动走登录通道读取并下载。

Telegram 会话数据库与文件缓存位于 App 沙盒的 `Telegram/` 目录；API 凭证只写入 Keychain，不随代码分发。

## 使用教程

完整的图文教程（导入、下载队列、播放、倍速、废纸篓、Telegram 登录与访问密码、常见问题）见 **[docs/USAGE.md](docs/USAGE.md)**。

<p align="center">
  <img src="docs/images/settings.png" width="32%" alt="设置：下载画质与播放速度" />
</p>

## 项目结构

```
.
├── README.md
├── docs/
│   ├── USAGE.md              # 图文使用教程
│   ├── DEVELOPMENT.md        # 开发 / 真机部署 / AI 接手
│   └── images/               # 教程截图
├── Scripts/
│   ├── build-ipa.sh          # WSL 同步 + 签名构建
│   └── device.sh             # 安装 / 启动 / 截图 / 日志辅助
└── Shiying/
    ├── Package.swift         # SwiftPM 清单（App、分享扩展、YouTubeKit）
    ├── Package.resolved      # 依赖锁定
    ├── xtool.yml             # xtool App / 扩展配置
    ├── AppInfo.plist         # App 部分 Info.plist（后台音频、URL Scheme 等）
    ├── ShareInfo.plist       # 分享扩展 Info.plist
    ├── Resources/AppIcon.png
    ├── Packages/YouTubeKit/  # 本地依赖（上游 MIT 许可）
    └── Sources/
        ├── Shiying/
        │   ├── ShiyingApp.swift    # @main 与后台 URLSession 回调
        │   ├── ContentView.swift   # 根视图、Tab、scenePhase、测试钩子
        │   ├── Models/             # VideoItem、来源、画质、链接解析
        │   ├── Services/           # 片库、下载、元数据、TDLib、Keychain 等
        │   └── Views/              # 片库、下载、设置、播放器、Telegram
        └── ShiyingShare/           # 分享扩展
```

> `Shiying/Scripts/`、`Shiying/screens/`、`Shiying/testdata/`、`.build/`、`xtool/` 等属于本机调试产物，已在 `.gitignore` 中排除；仓库只保留可复现的源码与 `Scripts/` 下的通用脚本。

## 架构简述

- **UI**：SwiftUI + `ObservableObject`。`AppStore` 是唯一状态源，负责片库、队列、废纸篓、重试与持久化；`RootView` 只负责 Tab 与场景切换。
- **YouTube**：内置 [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) 解析播放器信息，`YouTubeService` 选择 MP4/H.264 流（最高 1080p），必要时同时下载视频与音频。下载走 `DownloadManager` 的后台 `URLSession`，支持按 `Range` 分片、断点续传和失败回退。
- **Telegram**：`TelegramService` 先解析公开网页预览；超出限制时由 `TelegramSession`（TDLibKit）下载原文件。访问密码与演示视图由 `TelegramAccessPassword` / `TelegramAccessGate` 管理。
- **后台保活**：`BackgroundDownloadKeeper` 在退到后台且有下载任务时播放 1 秒静音循环并持有 `beginBackgroundTask`，让 TDLib 与解析流程继续运行。
- **播放**：`PlaybackAssetBuilder` 用 `AVMutableComposition` 合成分离的音视频轨；`PlayerScreen` 负责画中画、倍速、长按加速与连播。
- **分享扩展**：识别链接后通过 `shiyin://add?url=...` 深链交给主 App 导入。

## 数据与隐私

所有内容都保存在 App 沙盒内：

| 内容 | 位置 |
| --- | --- |
| 片库索引 | `Library/Application Support/Shiying/library.json` |
| 视频 / 音频 / 封面 | `Library/Application Support/Shiying/Videos/<UUID>/` |
| TDLib 会话与缓存 | `Library/Application Support/Shiying/Telegram/` |
| 运行日志 | `Documents/ShiyingLogs/shiying.log` |
| Telegram API 凭证、访问密码摘要 | 系统钥匙串 |

- 没有服务端，也不会上传观看记录、片库或剪贴板内容。
- 剪贴板只读取文本并交给本地正则识别，可随时关闭。
- **卸载 App 会清空全部数据**；同一 Bundle ID 覆盖安装通常保留数据。免费签名过期后请直接覆盖安装，不要先卸载。

## 已知限制

- 只下载 iPhone 原生播放稳定的 **MP4 / H.264，最高 1080p**；1440p / 4K 通常是 VP9 / AV1，未纳入。
- YouTube 的 `googlevideo` 域名在部分网络下不可达，需要自行解决网络环境；App 不内置代理服务。
- Telegram 大文件必须先在 App 内完成扫码登录。
- 后台下载受 iOS 调度限制，极长时间后台仍可能被暂停，回到 App 后会继续。
- 免费 Apple ID 签名 7 天过期，需要重新构建覆盖安装；无法用于 App Store / TestFlight 上架。

## 开发与 AI 接手

如果你是把项目交给 AI 继续开发，请让它先阅读 **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)**。文档包含：

- WSL2 + xtool + Apple ID 的完整环境搭建与 usbmuxd 端口转发
- 构建、签名、安装、启动、截图、抓日志的实际命令与已知坑
- 代码地图、数据格式、修改代码时需要注意的兼容性
- 测试环境变量（含**会删除数据**的钩子，务必先读）
- 常见故障排查表与交付检查清单

## 依赖

- [TDLibKit](https://github.com/Swiftgram/TDLibKit) + TDLibFramework 1.8.68（Telegram 客户端库，静态链接，因此 IPA 体积较大）
- [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit)（已内置在 `Shiying/Packages/`，MIT License）

## 许可

本仓库目前未附带开源许可证，源代码版权归作者所有；如需复用请先联系作者。第三方依赖遵循各自许可证：YouTubeKit（MIT）、TDLibKit（MIT）、TDLib（BSL-1.0）。

## 免责声明

本项目仅供个人学习与备份使用。请遵守 YouTube、Telegram 的服务条款及所在地版权法规，仅下载你有权保存的内容。
