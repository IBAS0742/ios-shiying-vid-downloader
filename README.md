# 拾影 Shiying

一个 iOS 17+ 的 SwiftUI 视频下载与管理 App，支持 YouTube 与 Telegram。界面为深色玻璃风格，所有数据保存在本机。

## 功能

- **导入 YouTube**：单条视频、播放列表；可选画质，音视频分离时自动合并准备播放。
- **导入 Telegram**：公开帖子和频道（`t.me/...`）。超过网页预览约 20MB 上限的视频，可通过内置 TDLib 登录后直接下载。
- **Telegram 扫码登录**：在 App 内填写自己的 `api_id` / `api_hash`，用 Telegram 扫描二维码完成授权；支持两步验证密码。二维码可分享到电脑，再用同一台手机扫描。
- **下载队列**：可配置并发数，支持暂停 / 继续、取消、失败自动重试、退出重进后续传。
- **片库管理**：按来源分组、批量删除；删除后进入废纸篓，7 天后自动清理。
- **播放**：内置播放器，支持本地文件播放。
- **剪贴板导入**：打开 App 或回到前台时，自动识别剪贴板里的 YouTube / Telegram 链接。
- **分享扩展**：从其他 App 的分享面板直接发送链接到拾影。

## 环境要求

- iOS 17.0 及以上
- 构建：Linux / WSL2 + [xtool](https://github.com/xtool-org/xtool)（无需 Mac；需要 Apple ID 用于免费签名）
  - 也可以用 macOS + Xcode 工具链运行 xtool
  - 首次构建会下载 TDLib 预编译框架并编译 TDLibKit，约需 6GB 内存与 10 分钟
- Telegram 大视频下载需要自备 API 凭证：用 Telegram 手机号登录 [my.telegram.org](https://my.telegram.org) → API development tools → 创建应用，得到 `api_id` 和 `api_hash`

## 构建

在 WSL / Linux 中安装 xtool 并准备好签名后：

```bash
cd Shiying
xtool dev build -c release --sign --ipa
```

仓库根目录提供了一个同步 + 构建脚本（会把源码镜像到 `$HOME/shiying`，保留 `.build` 增量缓存，并把 IPA 复制回 `Shiying/xtool/`）：

```bash
bash Scripts/build-ipa.sh
```

## Telegram 登录说明

1. 设置 → Telegram 登录，填入 `api_id` 与 `api_hash`（保存在系统钥匙串）。
2. 点「扫码登录」，用已登录 Telegram 的手机扫描二维码；同账号多设备扫码即可授权。
3. 若账号开启两步验证，按提示输入密码。
4. 之后导入超过网页预览上限的 Telegram 视频时，会自动走登录通道读取并下载。

TDLib 的会话数据库与文件缓存位于 App 沙盒的 `Telegram/` 目录下；API 凭证只写入 Keychain，不随代码分发。

## 项目结构

```
.
├── README.md
├── Scripts/
│   └── build-ipa.sh          # WSL 同步 + 签名构建
└── Shiying/
    ├── Package.swift         # SwiftPM 清单（App、分享扩展、YouTubeKit）
    ├── Package.resolved      # 依赖锁定
    ├── xtool.yml             # xtool App 配置
    ├── AppInfo.plist
    ├── ShareInfo.plist
    ├── Resources/AppIcon.png
    ├── Packages/YouTubeKit/  # 本地依赖（上游 MIT 许可）
    └── Sources/
        ├── Shiying/
        │   ├── Models/       # VideoItem、来源、画质、链接解析
        │   ├── Services/     # 片库、下载、元数据、TDLib、Keychain 等
        │   └── Views/        # 片库、下载、设置、播放器、Telegram 登录
        └── ShiyingShare/     # 分享扩展
```

> `Shiying/Scripts/`、`Shiying/screens/`、`Shiying/testdata/` 等目录属于本机调试产物，已在 `.gitignore` 中排除。

## 依赖

- [TDLibKit](https://github.com/Swiftgram/TDLibKit) + TDLibFramework 1.8.68（Telegram 客户端库，静态链接，因此 IPA 体积较大）
- [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit)（已内置在 `Shiying/Packages/`，MIT License）

## 隐私

- 无服务端、无统计上报；片库索引、缩略图、视频均保存在本机。
- Telegram API 凭证存 Keychain；Telegram 登录态仅在设备本地。
- 剪贴板仅读取文本用于识别受支持链接，可在设置中关闭。

## 免责声明

本项目仅供个人学习与备份使用。请遵守 YouTube、Telegram 的服务条款及所在地版权法规，仅下载你有权保存的内容。
