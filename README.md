# DJI AutoCall · 大疆自动打电话方案

把大疆第一代 4G 模块变成 Mac 上的通话终端，提供拨号、通话字幕、文字代说与双向监听，供听障辅助沟通、客服咨询和经用户授权的代办场景使用。

本项目基于 [DJOneHub-mac-enhanced](https://github.com/rogerbush007-a11y/DJOneHub-mac-enhanced)，保留原始 Git 历史、许可证及第三方声明。当前代码基线为 `5b15eaec0e97dd9fa7b2abe54d0d1289c1e93054`。上游说明保存在 [README.upstream.md](README.upstream.md)。

## 已实现

- **电话控制** — 拨号、接听、挂断、DTMF 按键及最近通话。
- **自动字幕** — 通话音频连接后自动启动本机语音识别，只显示最近三条已识别字幕和当前一句。识别语言可选普通话、英语。
- **文字代说** — 系统中文声音、Samantha / Karen 英语声音，以及本地 Pocket TTS Alba。输入中文时自动使用中文声音，避免英语声音生成空音频。
- **代说耳返** — 同一份合成音频同时送到模块和电脑当前声音输出，统一起播。“停止代说”同时终止生成和两路播放。
- **独立监听与接管** — “播放对方声音”和“代说耳返”独立控制。用户可以切回麦克风沟通。
- **客服流程辅助** — 可编辑的转人工、说明诉求、核验交接、请求主管复核和确认结果短句。
- **Wi-Fi 保持优先** — 安装器默认禁止模块提供 Mac 上网流量，后台会尊重 `force_off` 设置并跳过自动启用网卡。
- **本机服务** — 后台默认监听 `127.0.0.1:7575`，不开放到局域网。

**自动化边界** — 当前应用负责通话与音频能力，逐轮理解和回应需要用户或外部 AI agent 操作。仓库尚未内置可独立运行的完整自主对话代理。“真人接听提醒”曾通过外部 agent 的本地字幕检测完成，未作为常驻后台服务发布。

## 硬件和环境

- macOS 13+，已在 Apple Silicon Mac 上进行开发验证。
- 大疆第一代 4G 模块，支持识别 DJI `2ca3:4006` 和百望 / Quectel `2c7c:0125`。
- 已启用语音通话的 SIM、VoLTE，以及支持数据传输的 USB 线。
- 双向音频需要模块 USB Audio、ADB 和匹配的模块侧语音运行时。首次启用按上游设置页检查。部分固件另需 ADB 授权，本安装器不代替该步骤。
- 源码构建需要 Xcode Command Line Tools、Go 1.26.3+、libusb 和 pkg-config。Intel 代码沿用上游，新增功能未在 Intel 真机验证。

```sh
xcode-select --install
brew install go libusb pkg-config
```

## 从源码安装

```sh
git clone https://github.com/hackermengzhi/DJI-AutoCall.git
cd DJI-AutoCall

# 可选，下载并逐文件核对 Pocket TTS 的 SHA-256
python3 scripts/setup-pocket-tts.py

# 编译并安装到当前用户目录
./scripts/install-autocall-macos.sh
```

Pocket TTS 使用固定版本的原生 macOS 程序和公开的预设声音模型。模型约 219 MB，另有声音嵌入等文件。下载目录 `.local/pocket-tts` 已被 Git 忽略。生成时从本机文件加载，不需要 API key。

安装后的 App 叫 **DJOneHub**，位于 `~/Applications/DJOneHub.app`。后台沿用 `com.jamie.djonehub` 的用户 LaunchAgent。安装会更新同一位置的 DJOneHub，并保留其已有数据。正在通话时安装器会退出。

仅构建可以运行以下命令。

```sh
./scripts/build-macos.sh
./macos/DJOneHubNotifier/build-app.sh
```

`CONFIGURATION=debug` 可以加快本机调试。`POCKET_TTS_DIR` 可指定已准备好的 Pocket TTS 目录。`CODE_SIGN_IDENTITY` 可指定长期使用的代码签名证书，默认使用临时签名，macOS 在程序更新后可能重新要求权限。

## 使用

1. 打开 DJOneHub，按设置页提示确认模块、SIM 和语音路由已就绪。
2. 在“辅助通话”选择识别语言和英语声音，检查麦克风 / 语音识别权限。
3. 拨号或接听后，等待“通话音频已连接”，字幕自动开始。
4. 开启“文字代说”，输入文字并发送。默认开启的“代说耳返”让本机听到相同语音。
5. “停止代说”立即终止本轮合成或播放。“本人接管”恢复麦克风和对方声音监听。

字幕使用本机识别，识别不可用时显示原因，不会自动切换到云端。通话字幕、代说内容仅保存在应用内存中，独立开启的录音及其他上游持久化功能除外。

## 接入外部流程

兼容后台的本机 HTTP 接口。

| 动作 | 接口 |
| --- | --- |
| 查询通话 | `GET /api/calls/status` |
| 拨号 | `POST /api/calls/dial`，JSON 包含 `number` |
| 接听 / 挂断 | `POST /api/calls/answer`、`POST /api/calls/hangup` |
| 菜单按键 | `POST /api/calls/dtmf`，JSON 包含单个 `digit` |
| 模块语音状态 | `GET /api/voice/status` |

字幕读取和文字代说目前位于 Swift App，由界面操作，不提供 HTTP 文本代说接口。外部 agent 可结合上述接口和 App 界面控制完成逐轮通话。流程应根据实际菜单和回复推进，身份核验资料由用户提供。

## 验证状态

- 源码构建、自检、通话日期解码、语音语言选择和代说停止控制已验证。
- 本机已验证实际拨号、电话菜单、英文字幕、人工客服转接和本地预设声音生成。
- Pocket TTS 本机短句生成及模块输出已测试，耳返双路播放测试通过。
- 不同运营商、固件、声音在真实电话中的清晰度和延迟仍需逐项验收。音频仍属于实验性能力，保留用户接管入口。
- 会员资料、真实联系人、通话记录、录音、模型权重和本机签名私钥均不包含在本仓库中。

## 来源与许可证

根目录 [LICENSE](LICENSE) 沿用 **PolyForm Noncommercial 1.0.0**，包含上游要求保留的版权声明。当前代码不授予商业使用许可。第三方依赖适用各自许可证，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

- DJOneHub 源码来自 [rogerbush007-a11y/DJOneHub-mac-enhanced](https://github.com/rogerbush007-a11y/DJOneHub-mac-enhanced)。
- 模块语音运行时按上游逻辑从 [moluncn/mavo](https://github.com/moluncn/mavo) 的固定提交下载和校验。
- Pocket TTS 来自 [Kyutai](https://github.com/kyutai-labs/pocket-tts)，程序许可证为 MIT。公开预设声音模型来自 [kyutai/pocket-tts-without-voice-cloning](https://huggingface.co/kyutai/pocket-tts-without-voice-cloning)，模型许可证为 CC BY 4.0。
