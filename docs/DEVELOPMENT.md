# 开发、构建与真机部署指南

本文写给下一位维护者——无论是人还是 AI。目标：在不破坏用户数据的前提下，完成环境搭建、编译、签名、安装、启动、抓日志、修改代码和验证。

> **最短路径（已配好环境时）**
>
> ```bash
> bash Scripts/build-ipa.sh
> bash Scripts/device.sh install
> bash Scripts/device.sh launch
> bash Scripts/device.sh logs
> ```
>
> `Scripts/device.sh` 会自动从设备读取真实 Bundle ID；也可以用 `bash Scripts/device.sh doctor` 检查整条链路。
>
> 若 `logs` 报 `InstallationLookupFailed`（部分 iOS 26 + 免费签名环境），改用 App 内「设置 → 诊断 → 导出运行日志」，详见 5.3。
>
> 首次接手请至少读完第 0、2、3、4、5 节。

---

## 0. 先读：数据安全红线

1. **不要在用户手机上做破坏性实验。** 下列环境变量会删除片库或文件，调试前必须先备份，确认设备上没有真实数据再使用：
   - `SHIYING_TEST_RESET_ALL=1`：删除全部片库条目和媒体文件。
   - `SHIYING_TEST_CLEANUP=1`：删除所有失败任务和 `-autoplay-test` 副本及其文件。
   - `SHIYING_TEST_CLONE=1`：会复制媒体文件（占用空间，但不是删除）。
2. **不要为了排障先卸载 App。** 卸载会删除沙盒内的片库、视频、TDLib 会话与日志。
3. **同一 Bundle ID 覆盖安装通常保留数据。** 免费签名过期后直接重新构建、覆盖安装；换 Bundle ID、换签名 Team 或卸载重装都会得到一个新的数据容器。
4. **不要修改运行中的 `library.json`。** 片库以内存中的 `AppStore` 为准，App 会原子覆盖该文件。
5. **不要把设备 UDID、Team ID、Apple ID、证书、API Key 写进仓库。** 本仓库的 `.gitignore` 已排除本机调试脚本、日志、截图和构建产物；提交前仍要检查 `git diff`。
6. **App Store 上架不在本文范围。** 免费 Apple ID 只能做 7 天有效的开发签名。

数据位置（App 沙盒内）：

| 内容 | 路径 |
| --- | --- |
| 片库索引 | `Library/Application Support/Shiying/library.json` |
| 视频 / 音频 / 封面 / 分片 | `Library/Application Support/Shiying/Videos/<UUID>/` |
| TDLib 数据库与缓存 | `Library/Application Support/Shiying/Telegram/` |
| 运行日志 | `Documents/ShiyingLogs/shiying.log`（超过 512KB 自动重建） |
| Telegram API 凭证、访问密码摘要 | Keychain |

---

## 1. 仓库与构建模型

- `Shiying/` 是一个 **SwiftPM 包**，不是 `.xcodeproj`。`xtool` 直接构建 SwiftPM product。
- `Shiying/Package.swift` 声明两个 library product：
  - `Shiying`：主 App；
  - `ShiyingShare`：分享扩展。
- `Shiying/xtool.yml` 指定主 product、Bundle ID、Info.plist、图标和扩展：

  ```yaml
  version: 1
  bundleID: com.ibas.shiying
  product: Shiying
  infoPath: AppInfo.plist
  iconPath: Resources/AppIcon.png
  extensions:
    - product: ShiyingShare
      infoPath: ShareInfo.plist
      bundleID: com.ibas.shiying.share
  ```

- `Package.swift` 使用 `swift-tools-version: 6.0`，但 target 设为 Swift 5 语言模式（`.swiftLanguageMode(.v5)`）。不要随意切到 Swift 6 严格并发模式，现有代码大量使用 `@MainActor` 单例与回调。
- `AppInfo.plist` / `ShareInfo.plist` 是**部分 plist**，xtool 会与默认 plist 合并。只写需要覆盖或新增的键，不要复制整份默认 plist。
- **源码是唯一事实来源。** `Shiying/.build/`、`Shiying/xtool/`、`Shiying/.ipa-check/` 都是生成物，不要直接修改。

目录职责：

```
Shiying/Sources/Shiying/
├── ShiyingApp.swift        @main、AppDelegate、后台 URLSession 完成回调
├── ContentView.swift       RootView：Tab、sheet、scenePhase、启动测试钩子
├── Models/                 VideoItem、MediaSource、DownloadQuality、链接解析
├── Services/               业务与系统能力
└── Views/                  SwiftUI 页面与组件
```

关键服务：

| 文件 | 职责 |
| --- | --- |
| `Services/AppStore.swift` | 唯一状态源：片库、下载队列、进度/速度、废纸篓、重试、设置持久化 |
| `Services/DownloadManager.swift` | 后台 `URLSession`、Range 分片、断点续传、进度回调 |
| `Services/YouTubeService.swift` | 用 YouTubeKit 选择 MP4/H.264 流，处理音视频分离与画质升级 |
| `Services/YouTubePlaylistService.swift` | 播放列表条目解析 |
| `Services/MetadataService.swift` | 标题、封面、时长等元数据补全与缩略图下载 |
| `Services/TelegramService.swift` | 解析 `t.me` 公开网页预览（约 20MB 限制） |
| `Services/TelegramSession.swift` | TDLibKit 登录、会话、文件下载、二维码认证 |
| `Services/BackgroundDownloadKeeper.swift` | 退到后台时保活进程（静音音频 + background task） |
| `Services/PlaybackAssetBuilder.swift` | 用 `AVMutableComposition` 合成分离的音视频 |
| `Services/TelegramAccessPassword.swift` | Telegram 访问密码（加盐 SHA-256，仅存 Keychain） |
| `Services/TelegramAccessGate.swift` | 记住锁定 / 解锁 / 演示状态与上次错误密码 |
| `Services/AppPaths.swift` | 沙盒路径与体积/速度格式化 |
| `Services/AppLog.swift` | 写入文件 + `NSLog`，日志格式 `HH:mm:ss.SSS [I/E] message` |

---

## 2. 一次性环境

### 2.1 机器与账号

推荐组合：

- Windows 10/11 + WSL2 Ubuntu；
- iPhone，iOS 17+，开启开发者模式；
- 一个 Apple ID（免费即可）+ `xtool`；
- WSL 内安装 Swift 6+、xtool、Darwin Swift SDK；
- 可选：`pymobiledevice3`（安装、启动、截图、抓日志都更可靠）。

macOS 也可以用 Xcode 工具链运行 xtool，但本文以 Windows + WSL2 为主。

### 2.2 Windows：Apple 驱动与端口转发

iPhone 必须由 **Windows 的 Apple Mobile Device Service** 接管，**不要用 usbipd 把 USB 设备透传给 WSL**。USB/IP 会破坏 usbmuxd 的大数据包，表现为安装超时或 `message was too large`。

确认服务：

```powershell
Get-Service "Apple Mobile Device Service"
Start-Service "Apple Mobile Device Service"   # 未运行时
```

WSL2 不能直接访问 Windows 的 `127.0.0.1:27015`，需要端口转发。先在 WSL 里查网关：

```bash
ip route show default
# default via 172.x.x.x dev eth0
```

在**管理员 PowerShell** 中（把 `<WSL_GATEWAY>` 换成上面的地址）：

```powershell
$wslGateway = "<WSL_GATEWAY>"

netsh interface portproxy delete v4tov4 listenaddress=$wslGateway listenport=27015

netsh interface portproxy add v4tov4 `
  listenaddress=$wslGateway listenport=27015 `
  connectaddress=127.0.0.1 connectport=27015

New-NetFirewallRule `
  -DisplayName "WSL usbmux 27015" `
  -Direction Inbound -Protocol TCP -LocalPort 27015 -Action Allow
```

验证：

```powershell
netsh interface portproxy show v4tov4
```

> WSL 重启后网关 IP 可能变化，端口转发的 `listenaddress` 也要同步更新。建议准备一个管理员 PowerShell 脚本，每次重启后重跑。

### 2.3 WSL 环境变量

每个新 shell：

```bash
export USBMUXD_SOCKET_ADDRESS="$(ip route show default | awk '{print $3}'):27015"
```

建议写入 `/etc/profile.d/ios-mux.sh`，避免每次手动设置。验证：

```bash
echo "$USBMUXD_SOCKET_ADDRESS"
xtool devices --usb --no-wait
```

如果构建依赖下载超时，设置代理（端口按实际代理修改）：

```bash
export XTL_HTTP_PROXY="http://$(ip route show default | awk '{print $3}'):7890"
export https_proxy="$XTL_HTTP_PROXY"
export http_proxy="$XTL_HTTP_PROXY"
```

注意：

- `xtool` 自己的 HTTP 客户端不一定读取 `https_proxy`，需要 `XTL_HTTP_PROXY`；
- SwiftPM 读取 `https_proxy` / `http_proxy`；
- WSL NAT 模式下不能写 Windows 的 `localhost`，要用 WSL 网关 IP；
- `Scripts/build-ipa.sh` 会 **unset `XTL_HTTP_PROXY`**，适用于本机可直连依赖的网络。如果你的网络必须走代理，请临时修改脚本或先 `swift package resolve`。

### 2.4 xtool / Swift / SDK

```bash
xtool --version
swift --version

xtool auth login          # 首次登录 Apple ID，可能要求双重认证
xtool auth status
xtool sdk install /path/to/Xcode.xip
xtool sdk status
```

首次安装 SDK 需要数 GB 磁盘。`xtool setup` 是 auth + sdk 的合并入口。

### 2.5 pymobiledevice3

建议放进独立 venv，避免污染系统 Python：

```bash
python3 -m venv ~/.venvs/pmd3
~/.venvs/pmd3/bin/pip install -U pymobiledevice3
```

后文用 `PMD3="$HOME/.venvs/pmd3/bin/pymobiledevice3"` 代指。

### 2.6 iPhone 检查清单

- 数据线连接，手机已解锁、亮屏；
- 设置 → 隐私与安全性 → 开发者模式已开启（切换后通常要重启）；
- 首次安装后，设置 → 通用 → VPN 与设备管理 → 信任对应开发证书；
- 没有锁屏、没有拔线、没有停在“信任此电脑”弹窗。

---

## 3. 编译

### 3.1 推荐：使用构建脚本

在仓库根目录：

```bash
bash Scripts/build-ipa.sh
```

脚本行为：

1. 把 `Shiying/` 镜像到 `$HOME/shiying`（默认；可用 `SHIYING_BUILD_DIR` 覆盖）；
2. 保留镜像目录里的 `.build`，实现增量编译；
3. 执行 `xtool dev build -c release --sign --ipa`；
4. 把最新 IPA 复制到 `Shiying/xtool/`。

> 编译放在 Linux 文件系统（ext4）里，而不是 `/mnt/e/...`。在 9P 文件系统上编译大量 Swift 文件会明显变慢，严重时会拖垮 WSL VM。

### 3.2 直接构建

```bash
cd Shiying
xtool dev build                          # 只验证编译（debug）
xtool dev build -c release --sign        # 签名 release .app
xtool dev build -c release --sign --ipa  # 额外输出 IPA
```

首次构建会下载 TDLib 预编译框架并编译 TDLibKit：

- 约 6GB 内存、10 分钟；
- IPA 体积较大，因为 TDLib 是静态链接；
- `Package.resolved` 已锁定 `TDLibKit 1.5.2-tdlib-1.8.68-f381f4b3`，不要随意升级。

### 3.3 清理

先尝试：

```bash
cd "$HOME/shiying"
swift package clean
```

仍无法解释构建异常时，才删除 `.build/`。**不要删除源码、plist、xtool.yml 或 `Package.resolved`。**

### 3.4 检查产物

```bash
ls -lt Shiying/xtool/*.ipa | head
```

可以解压 IPA 检查 `Info.plist` 与扩展，但不要把解压目录当作源码修改。

---

## 4. 安装到 iPhone

### 4.1 找到真实 Bundle ID

免费签名会自动加前缀。实际安装后的 ID 可能是：

```text
XTL-<TeamID>.<原 Bundle ID>
```

某些情况下前缀会被应用两次。**不要凭记忆写死**，一律以设备输出为准：

```bash
$PMD3 apps list | grep -i shiying
```

### 4.2 安装

```bash
bash Scripts/device.sh install
# 等价于：xtool install --usb Shiying/xtool/Shiying.ipa
```

已知现象：`xtool install` 有时在 `[Installing] 100%` 后长时间不退出。

处理方式：

1. 看到 100% 后再等 **20–30 秒**；
2. 仍不退出就 `Ctrl-C`；
3. 不要立刻重装或卸载；
4. 用启动命令或 `apps list` 验证是否已安装成功。

### 4.3 证书撤销提示

免费账号的证书数量有限，xtool 可能提示：

```text
The following certificates must be revoked
```

- 在交互式终端里会等待确认；
- 在 CI / 非 TTY 环境里会直接取消，表现为安装失败；
- 撤销会影响使用同一免费账号签名的旧 App；
- 需要自动确认时可以用 `expect` 维持 pty 并发送 `yes`，但这是**破坏性操作**，确认后再继续。

### 4.4 数据注意事项

- **覆盖安装**（相同 Bundle ID、相同 Team）：通常保留数据；
- **卸载重装**：清空数据；
- **修改 `bundleID` / 换 Team**：等于安装另一个 App，新容器、空数据；
- 重新安装后数据容器 UUID 可能变化，这是 iOS 的容器迁移，不代表数据丢失；以 App 内片库和日志 `library loaded count=...` 为准。

---

## 5. 启动、截图、日志

### 5.1 启动

```bash
bash Scripts/device.sh launch
# 等价于：
# BUNDLE="<从 apps list 取得的真实 Bundle ID>"
# $PMD3 developer dvt launch "$BUNDLE" --kill-existing
```

带测试环境变量：

```bash
bash Scripts/device.sh launch \
  --env SHIYING_OPEN_TAB=downloads \
  --env SHIYING_PLAYER_DEBUG=1
```

`--env` 可重复，只在本次进程启动时生效。

iOS 17+ 的注意事项：

- `xtool launch` 可能报 `DebugserverClient.Error.unknown`，这**不代表安装失败**；
- 优先用 `pymobiledevice3 developer dvt launch`，或直接在手机主屏幕点图标；
- 启动失败先检查：手机是否解锁/亮屏、App 是否因签名过期退出、证书是否已信任；
- `--userspace` 在部分 iOS 17+ 环境需要，遇到隧道问题时可以追加。

查看进程：

```bash
$PMD3 developer dvt proclist | grep -i shiying
```

### 5.2 截图

```bash
bash Scripts/device.sh screenshot /tmp/shiying.png
# 等价于：$PMD3 developer dvt screenshot /tmp/shiying.png
```

- 截图全黑通常表示 **锁屏、息屏或启动失败**，先解锁并确认 App 在前台；
- 刚启动时等 1–3 秒再截；
- 部分 iOS 17+ 环境需要 `--userspace`。

### 5.3 拉取 App 日志

最可靠的方式是 **App 内导出**：

```text
设置 → 诊断 → 导出运行日志 → 分享到“文件”/微信/邮件
```

日志文件位于 `Documents/ShiyingLogs/shiying.log`（超过 512KB 自动重建），`AppLog` 同时会写 `NSLog`。

也可以通过 USB 尝试拉取：

```bash
bash Scripts/device.sh logs ./shiying.log
# 等价于：$PMD3 apps pull "$BUNDLE" "ShiyingLogs/shiying.log" ./shiying.log --documents
```

> 已知限制：部分 iOS 26 + 免费签名环境（尤其是 Bundle ID 被叠加成 `XTL-xxx.XTL-xxx.com...` 的安装）会让 `house_arrest` 返回
> `InstallationLookupFailed`，此时 `apps pull` / `apps afc` / `apps webdav` 都不可用，
> `developer core-device read-file` 也会报 “Apple removed this service”。
> 这不影响 App 运行，改用上面的 App 内导出即可。

实时看系统日志（包含进程启动、网络、崩溃等，但不包含 AppLog 的 `NSLog` 行）：

```bash
bash Scripts/device.sh logstream
# 等价于：$PMD3 syslog live -m Shiying
```

`developer dvt oslog --userspace` 也能抓统一日志，但对 AppLog 行不稳定，且该子命令在部分版本会以
`AttributeError: 'message' object has no attribute 'name'` 退出；排障时优先用 `syslog live`。

日志里常见的起点：

- `library loaded count=...`：片库加载成功；
- `download started` / `download finished`：下载生命周期；
- `background keeper started/stopped`：后台保活；
- `tdlib connection state: ...`：Telegram 连接状态；
- `tdlib file <id> <n>% ...`：TDLib 文件进度（每 10% 或 15 秒一条）；
- `telegram access password rejected; showing decoy`：访问密码进入演示视图。

### 5.4 查看 / 备份数据容器

在 `house_arrest` 可用的环境里，可以拉单个文件：

```bash
$PMD3 apps pull "$BUNDLE" "Library/Application Support/Shiying/library.json" ./library.backup.json
```

挂载整个容器（按需）：

```bash
$PMD3 apps webdav "$BUNDLE"
```

也可以在 `apps pull` 后加 `--documents` 只访问 `Documents/`。

> 若上面命令返回 `InstallationLookupFailed`（见 5.3 的已知限制），容器级访问不可用。
> 此时要备份数据，只能用 Finder / iTunes 的整机备份，或
> `pymobiledevice3 backup2 backup --full ./backup`（整机备份包含 App 容器，但恢复粒度很粗）。
> 不要为了“拿到文件”而卸载或重装 App。

> 备份时至少保留 `library.json` 与 `Videos/`；Telegram 登录态在 `Telegram/`，Keychain 中的凭证不在容器里。

---

## 6. 代码地图与修改指南

### 6.1 导入流程

```
AddLinkView / 分享扩展 / 剪贴板
        ↓
AppStore.importInput(_:)
        ↓
LinkExtractor / YouTubeLink / TelegramLink
        ├── YouTube 单条 → MetadataService + YouTubeService.prepare → DownloadManager
        ├── YouTube 播放列表 → YouTubePlaylistService → 批量入队
        ├── Telegram 公开网页 → TelegramService.fetch → addTelegramVideos
        └── Telegram 大文件 → TelegramSession (TDLib) → 文件下载
```

- 新增链接类型：先改 `Models/` 的解析，再在 `AppStore.importInput` 分支接入。
- 去重逻辑在入队前，按平台 ID / `telegramChatID + telegramMessageID` 判断。

### 6.2 下载流程

1. `AppStore.pumpDownloadQueue()` 按并发数启动任务；
2. `resolveAndDownload` 解析直链（YouTube 用 `YouTubeService`，Telegram 用网页直链或 TDLib）；
3. `DownloadManager.start(...)` 创建后台 `URLSession` 任务；
4. 分片模式下先发 `Range: bytes=0-0` 探测总大小与 `Accept-Ranges`，成功则拆成 1/4/8 段，失败回退单连接；
5. 完成后 `finalizeDownload` 校验文件、读取时长、写入 `library.json`、发通知、启动下一个任务。

修改下载行为时注意：

- `DownloadManager.sessionIdentifier` 必须与 `AppDelegate.handleEventsForBackgroundURLSession` 中的判断一致；
- 后台 session 的完成回调只调用一次，必须转交给 `setBackgroundCompletionHandler`；
- 取消 / 重试用 `attemptTokens` 防止旧任务回调污染新任务；
- Telegram 文件过小会被判定为失败（防止 stale file id 命中错误缓存），不要移除这个保护。

### 6.3 后台保活

`RootView` 监听 `scenePhase`：

- `.background` → `BackgroundDownloadKeeper.start { store.hasActiveDownloadWork }`；
- `.active` → `stop`，并重新 bootstrap Telegram、检查剪贴板。

`BackgroundDownloadKeeper` 用 1 秒静音 WAV 循环 + `beginBackgroundTask` + 3 秒轮询。它依赖 `AppInfo.plist` 的 `UIBackgroundModes: audio`。不要删除这个键，否则 Telegram 后台下载会停。

### 6.4 播放

- `PlayerScreen` → `PlaybackAssetBuilder.makeAsset(for:)`；
- 音视频分离时用 `AVMutableComposition` 合成，不落盘；
- 倍速：`AVPlayer.defaultRate` + `playImmediately(atRate:)`；
- 长按加速：在当前基准速率上临时 +0.5，松手恢复；
- 播放开始后由 `AppStore.markPlayed` 决定是否进入废纸篓（按来源的自动清理开关）。

播放器不再用 `fullScreenCover`，而是由 `RootView` 持有的 `PlaybackSession` 管理：

- `PlaybackSession.model` 是唯一的 `PlayerViewModel`，`PlayerScreen` 和底部 `MiniPlayerBar` 共用它，所以最小化不会销毁播放器；
- 最小化时 `PlayerScreen` 仍然挂在视图树里（`opacity 0` + 禁止点击），自动连播、进度回调继续工作；
- 只有 `close()` 才会把 `request` 置空并 `stop()`；`minimize()` 只改变 `isMinimized`；
- 迷你播放条放在 `safeAreaInset` 里、`BottomTabBar` 上方，因此各页面会自然让出高度；
- 横竖屏由 `OrientationController` + `AppDelegate.application(_:supportedInterfaceOrientationsFor:)` 控制：默认锁竖屏，只有播放页允许横屏；旋转按钮调用 `requestGeometryUpdate`。

### 6.5 Telegram

- 公开网页预览：`TelegramService` 解析 HTML，拿到直链后走 `DownloadManager`；
- 大文件：`TelegramSession`（TDLibKit）登录后按 `chatID + messageID` 取文件，`updateFile` 回调写进度，完成后复制到 `AppPaths`；
- 登录：QR 登录 + 两步验证密码，不支持短信验证码；
- 访问密码：`TelegramAccessPassword` 只存加盐摘要；`TelegramAccessGate` 持久化 locked/unlocked/decoy 状态；
- 错误密码规则：第一次错误进入演示视图并记住该密码；第二次必须输入正确密码或同一个错误密码，否则只提示重新输入，不再次进入演示视图。修改门禁逻辑时不要破坏这个状态机；
- App 进入后台时 `clearTransientContent()` 会清空输入框、搜索词、会话和 sheet，但保留门禁状态。

### 6.6 UI 与设置

- 主题：`Views/AppTheme.swift` 的 `Palette`、`AppBackground`、`glassPanel`、`ScaleButtonStyle`；
- 页面：`Views/` 下按功能拆分；`RootView` 负责 Tab 与全屏播放；
- 新增设置项的标准做法：
  1. `AppStore` 加 `@Published` 属性与 `UserDefaults` key；
  2. `SettingsView` 加区块；
  3. 明确“只影响之后的任务”还是“立即生效”；
- 新增 `VideoItem` 字段：
  1. 加到 struct；
  2. 加到 `CodingKeys`；
  3. 在 `init(from:)` 用 `decodeIfPresent` 给默认值。
  > 漏掉第 3 步会让旧 `library.json` 整体解码失败，用户会看到空片库——这是最危险的数据事故之一。
- 手势：行内左滑删除使用 `simultaneousGesture` + 轴锁；不要在父视图再加会抢占点击判定的 `onTapGesture`，否则会出现“滑不动 / 松手跳一下”。

### 6.7 页面标题与展示偏好

`AppStore.youtubePageTitle` 与 `AppStore.telegramPageTitle` 使用 `UserDefaults` 保存本机自定义标题。空白值回退到 `MediaSource.title`；页面标题只影响展示，不改变来源、播放队列或数据结构。

### 6.8 预留但未接入的代码

`Services/SnapAnyService.swift` 预留了 SnapAny 的 YouTube 代理下载 API（Keychain service `com.ibas.shiying.snapany`），适合手机无法直连 `googlevideo` 时使用。**当前没有任何调用点，设置里也没有入口**，不要误以为它是已启用功能。若要接入：

1. 在 `SettingsView` 增加 API Key 输入与保存（调用 `SnapAnyCredentials.save`）；
2. 在 `AppStore.resolveAndDownload` 的 YouTube 分支中，于原生解析失败时尝试 `SnapAnyService.prepare`；
3. 保持 `PreparedMedia` 的字段语义一致，让 `DownloadManager` 无需改动；
4. 在 README / USAGE 中说明这是可选的第三方服务及其额度限制。

### 6.8 构建后验证

```bash
bash Scripts/build-ipa.sh
xtool install --usb Shiying/xtool/Shiying.ipa
$PMD3 developer dvt launch "$BUNDLE" --userspace --kill-existing
$PMD3 developer dvt screenshot /tmp/verify.png --userspace
# 日志：设置 → 诊断 → 导出运行日志（USB 拉取在部分 iOS 26 环境不可用，见 5.3）
```

至少人工确认：

- 片库数量与升级前一致（看 `library loaded count=`）；
- 能打开一条已下载视频；
- 左滑删除 → 废纸篓 → 右滑恢复；
- 下载队列能启动、暂停、继续；
- 退到后台后日志仍有下载进度。

---

## 7. 测试环境变量

全部通过启动参数传入：

```bash
$PMD3 developer dvt launch "$BUNDLE" --kill-existing --env KEY=VALUE
```

### 导航 / 界面（安全）

| 变量 | 值 | 作用 |
| --- | --- | --- |
| `SHIYING_OPEN_TAB` | `telegram` / `downloads` / `trash` | 启动后切到指定 Tab |
| `SHIYING_OPEN_TRASH` | `1` | 打开废纸篓（等价于 `OPEN_TAB=trash`，保留旧钩子） |
| `SHIYING_OPEN_SETTINGS` | `1` | 350ms 后打开设置 sheet |
| `SHIYING_OPEN_ADD` | `1` | 350ms 后打开添加链接 sheet |
| `SHIYING_OPEN_FIRST` | `1` | 自动打开片库/废纸篓中第一条可播放视频 |
| `SHIYING_OPEN_SOURCE` | `youtube` / `telegram` | 与 `OPEN_FIRST` 搭配，只在该来源里挑第一条 |
| `SHIYING_KEEP_AWAKE` | `1` | 关闭系统自动锁屏；最小化后也强制保持屏幕常亮，便于截图验证 |
| `SHIYING_SKIP_CLIPBOARD` | `1` | 跳过启动时的剪贴板导入 |
| `SHIYING_SET_QUALITY` | `best` / `p1080` / `p720` / `p480` / `p360` | 覆盖下载画质 |
| `SHIYING_SET_RATE` | `0.5` … `4` | 覆盖全局播放速度（必须是允许值） |

### 导入 / 下载

| 变量 | 值 | 作用 |
| --- | --- | --- |
| `SHIYING_IMPORT_URL` | URL | 启动后自动导入该链接 |
| `SHIYING_AUTO_PAUSE` | 秒数 | 延时后全部暂停 |
| `SHIYING_AUTO_RESUME` | 秒数 | 延时后全部继续 |
| `SHIYING_TEST_SEGMENTS` | 整数 | 强制 Telegram 直链使用 N 段 Range 下载（测试分片） |
| `SHIYING_TG_DEBUG` | `1` | Telegram 页显示 TDLib 连接/下载调试卡 |
| `SHIYING_TG_DECOY` | `1` | 强制进入演示（decoy）视图 |
| `SHIYING_TG_CHAT_ID` | 整数 | 自动打开指定 Telegram 会话 |
| `SHIYING_TG_OPEN_FIRST` | `1` | 自动打开第一个 Telegram 会话 |
| `SHIYING_TG_AUTO_DOWNLOAD` | `1` | 自动把当前会话第一条视频加入下载 |

### 播放器

| 变量 | 值 | 作用 |
| --- | --- | --- |
| `SHIYING_PLAYER_DEBUG` | `1` | 播放器显示调试 HUD |
| `SHIYING_TEST_SEEK_END` | `1` | 首次加载后跳到接近结尾，测试连播/自动清理 |
| `SHIYING_TEST_PIP` | `1` | 画中画可用时自动进入 PiP |
| `SHIYING_TEST_BOOST` | 秒数 | 延时后自动触发长按加速 |
| `SHIYING_TEST_MINIMIZE` | 秒数 | 延时后自动最小化为底部播放条 |
| `SHIYING_TEST_LANDSCAPE` | `1` | 打开播放页 1.2 秒后自动切到横屏 |
| `SHIYING_TEST_PAUSE` | 秒数 | 延时后自动暂停/继续，用于验证迷你条暂停态 |

### 破坏性（先备份！）

| 变量 | 作用 |
| --- | --- |
| `SHIYING_TEST_CLONE=1` | 复制第一条可播放视频为 `-autoplay-test` 副本，用于测试连播 |
| `SHIYING_TEST_CLEANUP=1` | 删除所有失败任务与测试副本，**连同媒体文件** |
| `SHIYING_TEST_RESET_ALL=1` | 删除全部片库条目与媒体文件 |

> 这些钩子只应出现在测试设备上。看到用户设备里有真实片库时，禁止使用后三个。

---

## 8. 数据格式与迁移

`library.json` 是 `[VideoItem]` 数组，ISO8601 日期，pretty-printed：

```json
[
  {
    "id": "UUID",
    "videoID": "YouTube ID 或 tg:<username|chatID>:<postID>:<index>",
    "sourceURL": "原始链接",
    "title": "标题",
    "channel": "频道",
    "duration": 123.4,
    "resolution": 720,
    "addedAt": "2026-10-27T08:00:00Z",
    "status": "ready",
    "hasSeparateAudio": false,
    "fileSize": 1234567,
    "isTrashed": false,
    "source": "youtube",
    "telegramChatID": null,
    "telegramMessageID": null
  }
]
```

- 状态：`queued` / `resolving` / `downloading` / `retrying` / `ready` / `failed`；
- 媒体目录按 `item.id` 命名，文件固定为 `media-video.mp4`、`media-audio.m4a`、`thumbnail.jpg`；
- 分片临时目录为 `parts-video/`、`parts-audio/`；
- `AppStore.save()` 原子写入，`load()` 解码失败只记日志，不会自动修复；
- 新增字段必须提供默认值（见 6.6）；
- 用户级偏好存 `UserDefaults`，键名统一以 `shiying.` 开头。

---

## 9. 常见故障

| 现象 | 根因 | 处理 |
| --- | --- | --- |
| `xtool devices` 卡在等待 | 手机锁屏/拔线、Apple 服务未运行、WSL 网关变了、`USBMUXD_SOCKET_ADDRESS` 错 | 解锁重插；启动 Apple Mobile Device Service；重做端口转发；重设环境变量 |
| `AFCClient.Error.muxError` / `message was too large` | 用了 usbipd 或 usbmuxd 链路损坏 | 不要用 usbipd；让 Windows Apple 驱动接管；重启服务 |
| 依赖下载 `HTTPClientError.deadlineExceeded` | xtool/SwiftPM 没走代理 | 设置 `XTL_HTTP_PROXY` 与 `https_proxy`；必要时用 `proxychains4` |
| 证书撤销提示后直接 `Cancelled` | 非 TTY 读不到确认 | 在交互终端运行，或用 `expect` 提供 pty |
| 安装卡在 100% | xtool 已知问题 | 等 20–30 秒后中断，直接验证是否已安装 |
| `DebugserverClient.Error.unknown` | iOS 17+ 旧调试协议限制 | 安装通常已成功；改用 `pymobiledevice3` 启动或点图标 |
| App 点开就退出 | 免费签名过期、证书未信任、开发者模式关闭、锁屏 | 覆盖重装；检查 VPN 与设备管理；解锁后启动 |
| 截图全黑 | 锁屏/息屏/启动失败 | 解锁、等待、重截；不要据此判断 UI 崩溃 |
| 片库变空 | 换了 Bundle ID、卸载重装、`library.json` 解码失败 | 先拉日志看 `library loaded count` 与 `library decode failed`；不要重置 |
| `apps pull` 报 `InstallationLookupFailed` | iOS 26 + XTL 叠加前缀下 `house_arrest` 不可用 | 不影响运行；日志改用 App 内导出，实时日志用 `syslog live -m Shiying` |
| 构建很慢 / WSL 卡死 | 在 `/mnt/*` 上编译 | 用 `Scripts/build-ipa.sh` 镜像到 ext4 后构建 |
| Telegram 一直“连接中” | 网络、代理或 TDLib 未初始化 | 看 `tdlib connection state` 日志；设置 `SHIYING_TG_DEBUG=1` |
| Telegram 下载 0% 很久 | 文件大、进度按字节/百分比取整 | 拉日志看 `tdlib file ...%`；确认 `isDownloadingActive` |
| YouTube 解析/下载失败 | `googlevideo` 网络不可达、视频无 H.264 流 | 换网络/代理；确认画质与编码限制，不要误判为代码 bug |
| 无法自动点击/滑动 | 无 HID 触控自动化，WDA 需额外 runner | 用截图 + 人工测试；AX 树只能检查结构，不能代替手势 |

---

## 10. 交付检查清单

构建前：

- [ ] `git status` 中没有意外文件（尤其是日志、截图、`Shiying/Scripts/`、`.ipa`）；
- [ ] 没有把 UDID / Team ID / Apple ID / API Key / 证书写进源码或文档；
- [ ] `library.json` 新字段有解码默认值；
- [ ] 新增/修改的 Swift 文件在 `Shiying/Sources/Shiying/` 下（SwiftPM 自动收集）。

构建与安装：

- [ ] `bash Scripts/build-ipa.sh` 成功；
- [ ] IPA 在 `Shiying/xtool/`；
- [ ] `xtool install --usb ...` 完成（含 100% 卡住的处理）；
- [ ] `apps list` 能看到真实 Bundle ID；
- [ ] 启动成功，截图不是黑屏。

功能回归：

- [ ] 导入 YouTube 单条 / 播放列表；
- [ ] 导入 Telegram 公开链接；
- [ ] 下载队列暂停 / 继续 / 取消 / 重试；
- [ ] 退到后台后下载继续（日志有进度）；
- [ ] 播放、画中画、倍速、长按加速；
- [ ] 左滑删除 → 废纸篓 → 右滑恢复；
- [ ] Telegram 访问密码正确/错误/下拉重新输入；
- [ ] 分享扩展能把链接交给主 App。

发布后：

- [ ] 记录本次真实 Bundle ID 与构建时间；
- [ ] 免费签名 7 天后覆盖重装；
- [ ] 提醒用户不要卸载 App 来“修复”问题。
