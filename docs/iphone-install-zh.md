# 在 Windows 上安装 Amperfy 测试版

需要 iOS 26 或更新版本的 iPhone、Windows 电脑、数据线和普通 Apple ID。
无需购买 Mac 或 Apple 开发者会员。

## 中文、封面与图标

- 支持简体中文和英语，默认跟随 iPhone 的语言。应用内的 **Settings / 设置 → Language / 语言** 可打开系统应用设置，选择偏好的语言。
- Navidrome 歌单使用服务器返回的 `coverArt`，包含自定义封面；服务器未提供封面时，保留歌曲封面拼图。刷新歌单后会读取新的封面 ID，成功下载的封面可离线显示。
- 应用图标和启动页 Logo 使用本地 Feishin 项目的红紫渐变音符原图。
- 修复了封面保存失败仍被标记为已缓存，以及失败请求无法重试的问题。更新后重新打开对应列表可触发重试。

若更新后仍只有占位图，请确认 **设置 → 封面 → 封面下载** 未选“从不”，然后查看 **设置 → 帮助与支持 → 事件日志** 中的下载错误。服务器或代理返回的错误页不会再被当作封面缓存。

本版本包含数据库迁移，保留原有歌单和资料库。覆盖安装时保持原来的签名账号和应用标识，避免卸载造成已下载内容丢失。

## 获取测试包

1. 打开本仓库的 **Actions → Build iPhone IPA**。
2. 等待对应提交的运行显示绿色成功标记。
3. 下载 **Amperfy-iPhone-unsigned-数字** artifact 并解压。
4. 找到 `Amperfy-unsigned.ipa`，不要把外层 artifact ZIP 当成 IPA。

首次推送 `codex/apple-music-sideload` 分支会自动构建。如果 fork 的 Actions 被暂停，
先在 Actions 页面启用，再推送一次提交。工作流合入默认分支后，也可以通过
**Run workflow** 手动打包。只有成功的云端构建才会生成可用 IPA。

此工作流使用公开仓库免费的标准 macOS runner，并在私有仓库中跳过执行。
下载文件保留 7 天，过期后可重新构建。`build-info.txt` 记录源码提交和 Xcode 版本，
`SHA256SUMS` 可用于核对 IPA 下载完整性。

## 爱思助手免费签名安装

1. 从 [爱思助手官网](https://www.i4.cn/) 安装或更新 Windows 客户端。
2. 用数据线连接 iPhone，解锁手机，按提示选择“信任此电脑”。
3. 进入爱思助手的 **工具箱 → IPA 签名**（具体名称可能随版本变化）。
4. 添加 `Amperfy-unsigned.ipa`，选择 **使用 Apple ID 签名**，选择连接的设备。
5. 在你本机填写 Apple ID 并完成验证，等待签名成功。
6. 打开签名文件保存目录，将**签名后的 IPA**安装到 iPhone。
7. 按系统提示在“设置 → 通用 → VPN 与设备管理”中信任开发者。
8. 如果系统要求，在“设置 → 隐私与安全性 → 开发者模式”开启并重启确认。
9. 打开 **qMusic**，配置你的 Ampache / Subsonic 音乐服务器。

签名由爱思助手在你本机处理，不需要在 GitHub Secrets 中填写 Apple ID、密码或证书。
免费个人签名通常有效 7 天，到期需要重新签名安装；保留 Apple ID 和应用标识一致，
不要为了续签先卸载应用。实际签名能否成功还取决于爱思助手版本及 Apple 账号状态。

官方参考：[IPA 签名教程](https://helper.i4.cn/news_detail_38195.html)、
[签名常见问题](https://www.i4.cn/news_detail_40956.html)、
[Apple 开发者模式说明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。

## 测试版范围

- 安装名称为 **qMusic**，应用标识带 `.sideload`，与 App Store 版分开存储数据。
- 包含当前分支的播放器和界面修改，支持在手机上测试音乐播放、歌词和播放队列。
- 不包含需要相应授权的 Siri / CarPlay 签名权限。
- 文件名保留 `unsigned`，表示尚未使用个人账号签名。包内已用 Apple 的无证书 ad-hoc 签名预建签名结构，仍须通过爱思使用自己的 Apple ID 重签名，才能安装到真机。它不提供 Xcode 远程断点调试。

## 显示 Logo 后立即退出：检查签名包

如果分析日志出现 `DYLD / Library missing`，并包含 `__LINKEDIT ... extends beyond end of file`，说明系统加载的框架文件长度与文件头不一致。一份实际故障包中，爱思重签后的 AudioStreaming 框架签名区域末尾少了 1 字节；原始包结构正常。

新版在打包时先由 Apple `codesign` 生成签名结构，并检查所有框架的文件边界和代码页哈希。这是对重签名工具的兼容处理，最终仍需检查爱思输出的 IPA。

有 Python 的 Windows 电脑可在本项目目录运行（将路径替换成爱思签名后的文件）：

```powershell
python BuildTools/verify_ipa.py --require-signature "C:\签名目录\Amperfy-unsigned.ipa"
```

检查脚本只读取文件；它不能验证证书信任、描述文件授权或真机运行。检查失败时不要继续安装，也不要直接向已签名的文件补字节，这会破坏上层资源签名。保留错误文字，重新签名后再检查。覆盖安装时继续使用原来的 Apple ID 和应用标识，无需卸载或清空资料库。

构建失败时下载 **Amperfy-build-log**，或打开失败步骤的日志查看首个 `error:`。
安装失败时记录爱思助手的完整错误文字及 iOS 版本，方便定位签名或兼容性问题。
