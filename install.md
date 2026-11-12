# 真机连接恢复与安装指南

供维护本仓库的开发者和 AI agent 使用。**装不进去时，先查设备连接，再查开发服务，最后查签名与安装。** 不要把所有失败都当成 Wi-Fi 问题。

快速入口：[这次怎么连上的](#connection-recovery-20261027) · [以后连接失败按什么顺序查](#connection-checklist) · [Mac 更换应用后保住连接](#mac-connection-migration) · [Tailscale 与代理](#mac-proxy-recovery) · [按错误阶段恢复](#5-按错误阶段恢复)。后面的原有安装流程保留作为查阅资料。

## Mac 内置运行环境（2026-10-30）

内置运行环境的 Mac 包自带 Python、Agent 和连接依赖，用户无需安装 Homebrew、uv 或克隆源码。首次启动点击“开始设置”后配置模型与设备；设置中的运行组件显示“已内置”。模型服务仍需要网络。

开发者打包和无网络初始化检查见 [Mac 内置运行环境](docs/implementation/mac-bundled-runtime-20261030.md)。当前交付为 Apple Silicon；Intel 需要单独构建对应运行环境。下面的旧安装记录用于历史排障，不能据此要求内置包用户再次下载运行组件。

<a id="mac-proxy-recovery"></a>

## Mac Tailscale 与代理（2026-10-28）

**设置 → 通用 → 网络代理 → Tailscale**，默认「跟随系统」。只有需要覆盖系统设置时才选「手动」，填写 HTTP/HTTPS 代理地址和端口后应用；「不使用代理」是用户显式选择。该项管理内嵌 Tailscale 的控制与中继连接，不更改全系统代理或MoMo 的模型代理。

本次 1.39.1 登录超时的根因是启动环境残留：系统代理在 `127.0.0.1:7890` 正常工作，App 却带着已关闭的 `7897`。日志包含 `proxyconnect tcp: socks connect ... connection refused`，表明正确的 HTTP 代理外面又被套了一层旧 SOCKS 代理。清理磁盘未删除运行依赖，Agent 服务本身在线。

1. 分别检查当前系统代理（`scutil --proxy`）、代理端口是否监听，以及 App **实际进程**的代理变量；当前终端环境不能代替 App 环境。只输出代理协议/主机/端口，别粘贴完整进程环境。
2. 1.39.2 起，默认每次控制连接解析都查询当前系统设置；启动器遗留的 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` 不再覆盖 App 选择，也不再形成双层 SOCKS。代理切换/恢复由现有连接重试取用新设置，不要求退出账号、清空节点或重新配对。设置变更只重建网络节点，保持保存的身份。
3. 系统代理尚未启动时仍会连接失败；等待它恢复或在 App 中选择正确的配置。不会因代理失败偷偷改为直连。手动入口当前支持无账号密码的 HTTP/HTTPS；PAC 脚本和需认证的代理未接入。
4. 交付后同时确认界面「远程访问可用」、本地服务 `agent_online=true` 与 `tunnel.state=connected`。登录链接探针只证明官方控制面可达，不能冒充手机跨网聊天验收。

详细实现和测试见 [代理自动恢复](docs/implementation/tailscale-proxy-recovery-20261028.md)。

<a id="connection-recovery-20261027"></a>

## 这次怎么连上的（2026-10-27）

这次交付的手机、Apple Watch SE（watchOS 26.6）和 Mac 均为 **1.35.1**。以下记录的是当时的 MoMoAgent 安装；产品后来更名为 MoMo Agent，Bundle ID、可执行文件名和数据目录继续保留原标识。

| 实际发生的事 | 说明与下一步 |
| --- | --- |
| 手机已连 Mac，手表已连 Wi-Fi；用户重启并解锁手表后，首次 CLI 重试仍返回 `CoreDevice 4000 → RemotePairing 1001` | 仍停在开发隧道握手。连接同名 Wi-Fi、重启完成都不能证明开发连接可用。 |
| 打开 Xcode 的 **Device Hub**，选中这块实体 Watch，等待开发服务准备 | 随后设备状态变为 `connected`，Developer Mode 为 `enabled`；继续等到 `ddiServicesAvailable=true`。不是仅看到设备名称就开始重试。 |
| 串行运行只读 `ddiServices --no-auto-mount-ddis` 检查 | 返回 `contentIsCompatible=true`、`isUsable=true`，确认开发镜像服务已就绪。 |
| 再安装时改为 `0xe8008012: This provisioning profile cannot be installed on this device` | 已经越过连接阶段。实际检查发现 Watch 和 Widget 的描述文件没有包含这块手表，应该处理签名，继续重启或改 Wi-Fi 没有意义。 |
| 针对真实 Watch 重新注册设备、刷新签名后重试 | 安装成功，腕上版本独立读回为 1.35.1，普通启动成功。手机版本也独立读回为 1.35.1。 |

可复用的顺序是：**结束旧请求 → 重启后首次解锁 → Device Hub 选中 Watch 并等待准备 → 只读确认 DDI 可用 → 再试一次 → 根据新的错误阶段处理。** 本轮没有取消手机与手表的配对，没有抹除设备或删除录音，也没有重启 Mac 的连接服务。

这是本次观察到的恢复过程；不能证明“重启”或“打开 Device Hub”单独就能修复所有连接超时。也没有证据证明必须用某个 Wi-Fi 名称或关闭 VPN 才能成功。

本次依据：[合并交付记录](docs/implementation/hermes-main-promotion-20261027.md#验证) 中登记的本机证据目录里的 `DELIVERY.md`、`device-delivery-final.json`、`mac-installation-final.json`；排查日志名为 `momo-watch-after-restart-install`、`momo-watch-ready-status`、`momo-watch-ddi`、`momo-watch-ready-install`、`momo-watch-signed-install`。原始日志只在本机保留，不将设备标识或凭据提交到仓库。安装与启动成功不等于已验收全天录音能耗、后台同步或远程控制。

<a id="connection-checklist"></a>

## 以后连接失败按什么顺序查

1. **先分清是哪条连接。** Xcode / `devicectl` 到手机、手表的开发连接负责安装；手机 App 到 Mac 的 Tailscale 连接负责聊天和控制电脑；WatchConnectivity 负责手表与手机的业务同步。这三条连接分开排查。安装日志里的 `RemotePairing` 隧道不是 App 内的 Tailscale。
2. **结束上一条设备请求。** 等现有命令退出再继续；不要同时安装、查应用列表、挂载 DDI。长时间无输出时看该次日志，不重复启动多个安装进程。
3. **确认实体设备准备好。** iPhone 连接 Mac 并解锁；首次连接由用户完成“信任”。手表放在配对手机旁，保持解锁，重启后先输入一次密码，Wi-Fi、蓝牙可用。先排除锁屏、设备没开机、USB 未识别这些具体问题；同一可互通局域网可作为排查基线，但不证明链路已通。
4. **让 Xcode 完成开发服务准备。** 打开 Xcode 的设备管理界面（本机 Xcode 27 为 Device Hub），选中实际 Watch，等准备结束，检查 Developer Mode、连接和 DDI 状态。本机独立入口为 `/Applications/Xcode.app/Contents/Applications/DeviceHub.app`；其他 Xcode 版本以其实际设备管理入口为准。若仍未连上，保留错误再定位，不取消已有配对。
5. **串行做下面的只读检查。** 设备详情命令可能返回缓存信息；退出码为 0、列表里有设备或 `available (paired)` 都不是当前可安装的充分证据。DDI 检查成功且可用后，再进行一次安装。

```sh
# 在仓库根目录执行；只查询连接，不触发安装。
momo_check="$(mktemp -d "${TMPDIR:-/tmp}/momo-connection-XXXXXX")"
xcrun devicectl list devices --timeout 30 \
  --json-output "$momo_check/devices.json"

# 从刚才的实体设备清单填写；不要复制历史 UDID。
momo_watch_id='替换为当前 Watch UDID'
xcrun devicectl device info details --device "$momo_watch_id" --timeout 30 \
  --json-output "$momo_check/watch-details.json"

# 上一步结束、Device Hub 准备完成后，单独执行这一条。
xcrun devicectl device info ddiServices --device "$momo_watch_id" \
  --no-auto-mount-ddis --timeout 60 \
  --json-output "$momo_check/watch-ddi.json" \
  --log-output "$momo_check/watch-ddi.log"
```

`details` 对应当前设备应显示连接已建立；DDI 结果需确认 `contentIsCompatible` 与 `isUsable`。显式写 `--no-auto-mount-ddis`，因为默认检查会尝试挂载。若需要挂载，等所有请求结束后只让一个操作准备镜像，再验证结果。

6. **按新的失败阶段切换排查。** 仍是 tunnel timeout，就查连接日志；进入 `AppInstall` 后报 profile / signature 错误，就查签名；安装成功后报 locked，就解锁再启动。不要把较早一次的网络结论沿用到后续所有错误。具体分支见[错误表](#5-按错误阶段恢复)。
7. **以设备结果收尾。** 安装成功后逐端正常启动、独立读取实际版本；手机内嵌 Watch App 不代表腕上的版本已经更新。没有读回就写“未确认”，不把本地构建成功当作设备成功。

<a id="mac-connection-migration"></a>

## Mac 更新

在 Mac「设置 → 通用 → 应用更新 → 获取更新」打开[最新安装包](https://github.com/Miri-Labs/MoMo-Agent/releases/latest)。Mac App 管理 DeepSeek Harness 和 Python 连接服务的版本，首次准备时会安装所需依赖。

退出 MoMo Agent，等后台退出后，用新包替换「应用程序」中的 MoMo Agent，再打开。保留 `~/Library/Application Support/MoMoAgent`，不要删除聊天、配对或模型配置。当前公开版本保持 0.0.1，下载页用发布日期和内部构建号区分更新。Apple Silicon 包不能用于 Intel Mac；签名和公证状态以该次下载页为准。

## Mac 更换应用后，怎样保住原来的连接

本轮从桌面 Beta 切到正式版，重点是延续原 Mac 身份，而不是重新创建一个空 Agent：

- 先确认旧 App 和 Agent 没有在写数据，再将 `Application Support/MoMoAgent Beta` 中的完整数据迁到 `Application Support/MoMoAgent`。保留连接配置、API key、配对库、Tailscale 节点状态、聊天与个人记忆；不只复制界面设置。
- 迁移已有 onboarding / 自动恢复设置，并为旧目录保留兼容符号链接，因为既有 Python 环境可能仍引用旧路径。**这是本次迁移措施，不是日常重连步骤；不要在服务运行中重复搬目录或删除旧路径链接。**
- 启动正式 App 后，实际核对 `agent_online=true`、内嵌 Tailscale `state=connected`，以及已配对设备的近期请求。本轮这些检查通过，才移走旧 Beta 应用。
- 保持稳定的 Apple 签名身份，避免每次更新都改变权限识别依据；不同 Bundle ID 的系统授权仍需实际核对，不能靠复制数据继承。手机正式版和 Beta 的 Keychain 身份不同，手机切换身份可能需要重新配对，这与 Mac 开发连接无关。

这些状态证明 Mac 服务和连接已恢复，不代替一次真实的手机发消息或跨网控制验收。不要因为临时断线清空配对、节点密钥或用户数据库。

## 更早的连接记录

- [2026-10-21 手表连接重试](#watch-connection-retry)：说明同一 `1001` 错误可能出现在不同握手阶段。
- [2026-10-22 安装记录](docs/implementation/watch-battery-20261022.md#设备交付)：当时手机已更新，手表 DDI 传输失败；关闭 Mac 增强模式也未消除蓝牙握手超时。不要把这次未完成状态误当成最新结果。
- [2026-10-23 退出诊断](docs/implementation/watch-crash-investigation-20261023.md)：旧描述文件中的证书已撤销，文件未过期不代表签名仍有效。

## 1. 执行约定

- 先读 [AGENTS.md](AGENTS.md)，确认用户要求的版本与设备。已有安装授权继续沿用；用户要求只写代码或暂不安装时，停在对应阶段。
- 使用干净的任务 worktree，保留其他目录的未提交修改。安装任务使用已确认的源码提交；拉取新 main 后若产物来源不再匹配，就重新构建。
- 已有来源、版本和签名均符合要求的冻结包时，直接复用。连接超时本身不需要重新编译。
- 同一手表一次只运行一个设备操作。安装期间读取本地日志，不并行启动 `lockState`、`ddiServices`、应用列表查询或第二个安装请求。不同构建也不要共用同一个正在写入的 DerivedData。
- 采用覆盖安装，保留应用容器。卸载、清库、取消配对、设备抹除、吊销其他机器的证书不属于普通安装重试，需要用户对该操作的明确授权。
- 命令返回的会话仍在运行时，继续跟踪该会话。为每次尝试保留独立日志，避免覆盖失败证据。AI 的单次等待以 30～60 秒为宜，期间向用户报告实际阶段；命令自身可保留 600 秒上限。
- 本文不要求先跑模拟器。按代码变更选择验证；用户要求直接安装时，记录尚未完成的测试，不把它们标记为通过。

## 2. 确认设备、账号与工作目录

以下命令从仓库根目录执行。命令块按步骤运行，每一步成功后再继续。变量在同一个 shell 中保留；换 shell 时重新设置。所有日志放在本轮独立目录：

```sh
git rev-parse --show-toplevel
git status --short --branch
xcode-select -p
xcodebuild -version

momo_run="$PWD/tmp_agent_output/$(date +%Y%m%d-%H%M%S)-device-install"
mkdir -p "$momo_run"
xcrun devicectl list devices --timeout 30 \
  --json-output "$momo_run/devices.json"
```

从实际枚举结果选择 `physical` 的手机和手表。不要使用名字相同的模拟器。手表显示 `available (paired)` 表示已发现且已配对，开发通道仍需建立。

```sh
momo_phone_id='替换为实际 iPhone UDID'
momo_watch_id='替换为实际 Watch UDID'
momo_phone_bundle='com.momoagent.ios'
momo_watch_bundle='com.momoagent.ios.watchkitapp'
```

安装前确认：

1. Xcode Settings 的 Apple Accounts 中已登录目标账号。当前 Mac 的钥匙串持有可用开发证书及其私钥。
2. 手机与手表已建立正常配对，两端已启用 Developer Mode。需要注册新设备时，先在 Xcode Device Hub 完成注册与信任。
3. 手机与手表已解锁，手表安装期间保持可操作。刚重启的手表先完成首次解锁。
4. Mac 与设备的 Wi-Fi、蓝牙可用。已建立无线开发连接时可直接安装；USB 可用于手机首次信任与连接诊断，不是本次成功更新手表的必要条件。

开发者模式及自动签名的系统步骤以 [Apple：Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device) 和 [Apple：在设备上运行应用](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices) 为准。

## 3. 准备签名和 Release 包

### 已有合格产物

核对产物对应的源码提交、版本、构建号和签名，沿用该包保存的源码记录。将 `momo_phone_app`、`momo_watch_app` 指向该轮冻结包的绝对路径，跳到产物检查。不要仅凭文件名为 `Release` 或文件修改时间判断版本。

### 需要重新构建

在已忽略的 `Config/Local.xcconfig` 配置自己的团队，保留已有必要配置，不将该文件提交到 Git：

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
CODE_SIGN_STYLE = Automatic
```

`Config/App.xcconfig` 统一管理手机、手表与 Widget 的版本。用户看到的版本为 `x.x.x`；内部构建号用于系统识别。交付新产物时按 [版本规则](AGENTS.md#应用版本管理) 更新，不通过命令行临时覆盖。

首次构建先准备 sherpa 运行库，再准备模型。运行库脚本通过已登录的 GitHub CLI 下载本仓库的固定发行附件；CI 使用只读 `GH_TOKEN`。两份脚本都会校验和复用有效资源，说明见[语音依赖](Native/SpeechVendor/README.md)：

```sh
uv run Native/SpeechVendor/prepare-runtime.py --scratch-directory "$momo_run/runtime-download"
uv run Native/SpeechVendor/prepare-models.py Models/Speech \
  --scratch-directory "$momo_run/model-download"
```

仓库已保存生成的 Xcode 工程。只有修改工程配置或文件组织时，才按项目约定用 XcodeGen 2.46.0 重新生成。普通安装无需重新生成工程。

提交本轮交付改动后再构建，构建期间固定源码。下面使用本轮独立构建目录。已有缓存可以复用，但先确认没有其他构建正在使用它；不要把其他 worktree 的旧产品误当成本轮输出。先检查磁盘空间，空间不足时保留录音、源码及未提交工作，只处理已确认可删除的构建缓存。

```sh
momo_derived="$momo_run/DerivedData"
momo_packages="$momo_run/PackageCache"
df -h .
git rev-parse HEAD > "$momo_run/source-commit.txt"
git status --short > "$momo_run/source-status.txt"

xcodebuild build -jobs 2 \
  -project MoMoAgent.xcodeproj \
  -scheme MoMoAgent \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$momo_derived" \
  -clonedSourcePackagesDirPath "$momo_packages" \
  -skipPackageUpdates \
  -allowProvisioningUpdates \
  > "$momo_run/release-build.log" 2>&1
```

这个 scheme 同时构建手机、手表和 Widget。使用 generic 目标可以先完成构建，不必让构建等待手表连接。构建必须退出成功；真机包不能使用 `CODE_SIGNING_ALLOWED=NO`。

构建成功后，将两个 App 复制到全新的冻结目录。后续安装始终使用冻结副本，避免 DerivedData 被下一次构建覆盖：

```sh
momo_products="$momo_run/Products-Verified"
mkdir "$momo_products"
ditto "$momo_derived/Build/Products/Release-iphoneos/MoMoAgent.app" \
  "$momo_products/MoMoAgent.app"
ditto "$momo_derived/Build/Products/Release-watchos/MoMoAgentWatch.app" \
  "$momo_products/MoMoAgentWatch.app"

momo_phone_app="$momo_products/MoMoAgent.app"
momo_watch_app="$momo_products/MoMoAgentWatch.app"
```

### 检查实际安装包

```sh
uv run Tests/Support/verify-release-bundle.py \
  --app "$momo_phone_app" \
  --output "$momo_run/release-bundle.json"

codesign --verify --deep --strict "$momo_phone_app"
codesign --verify --deep --strict "$momo_watch_app"

diff -qr "$momo_phone_app/Watch/MoMoAgentWatch.app" "$momo_watch_app"

/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$momo_phone_app/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$momo_phone_app/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$momo_watch_app/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$momo_watch_app/Info.plist"
```

若本地 `Config/Local.xcconfig` 沿用已安装正式版身份 `com.watchmylife.ios`，上述验证命令增加 `--variant local-upgrade`，同时核对设备上的原 Bundle ID。默认检查仍要求 `com.momoagent.ios`，不能为了通过检查改变现有应用身份或卸载数据。冻结包请放在普通本地目录，避免同步文件夹附加 Finder 元数据破坏签名检查。

上述检查全部通过后再安装。静态检查覆盖模型、版本及打包约束；独立 Watch 包与手机内嵌版本应逐文件一致，包括 Widget。另核对三份描述文件的有效期、目标设备、团队和签名身份，包含 Watch 内的 Widget。必要时用 `security cms -D -i <embedded.mobileprovision>` 解码到本地诊断目录。复用旧包时，检查器应在与该包匹配的源码版本运行。

`codesign` 验证本地完整性，设备还会校验签名身份是否有效。证书被吊销时，即使本地校验通过、描述文件尚未到期，设备仍可能拒绝安装或启动。

## 4. 串行安装两端

如果手机已有 MoMo Agent（原 MoMoAgent），先保存资料基线。初次安装或尚未生成诊断文件时，记录为无基线，继续安装；连接错误则先解决连接，不能记为无资料：

```sh
xcrun devicectl device copy from --device "$momo_phone_id" \
  --domain-type appDataContainer --domain-identifier "$momo_phone_bundle" \
  --source 'Library/Application Support/MoMoAgent/sync-receive-diagnostic.json' \
  --destination "$momo_run/receive-before.json" --timeout 60
```

先安装手机。成功后再对手表直接安装独立的 `Release-watchos` App；手机包内含 Watch App 不能证明腕上已完成更新。

```sh
xcrun devicectl device install app \
  --device "$momo_phone_id" "$momo_phone_app" --timeout 600 \
  --json-output "$momo_run/phone-install-01.json" \
  --log-output "$momo_run/phone-install-01.log"
```

确认手机安装结果成功，再执行：

```sh
xcrun devicectl device install app \
  --device "$momo_watch_id" "$momo_watch_app" --timeout 600 \
  --json-output "$momo_run/watch-install-01.json" \
  --log-output "$momo_run/watch-install-01.log"
```

手表的开发通道、调试镜像（DDI）准备及应用安装都可能包含在这一个命令内。让当前请求结束；安装期间不要再运行 DDI 挂载命令，也不要重启 `CoreDeviceService` / `remotepairingd`。

无新增终端输出时，可读取本地日志，或将 Mac 上两个连接服务的近期系统日志保存到任务目录。按设备过滤后查看以下阶段：`Establishing tunnel` → `Connected` → DDI 挂载 → `AppInstall`。其中 DDI 挂载后的服务重连可能属于正常准备过程，应结合后续成功或错误判断。

600 秒是命令总上限，内部网络握手可能提前超时。需要重试时，先确认前一个进程退出，按下一节处理实际错误，再用 `-02` 等新日志名发起一次请求。

## 5. 按错误阶段恢复

保留完整的 **error domain、code、underlying error、时间和操作阶段**。不要只记一个数字。

| 证据 | 下一步 |
| --- | --- |
| Xcode `No Accounts` 或账号认证失败 | 在 Xcode 完成登录，再刷新签名。CLI 重试不能替代账号认证。 |
| `Not in Keychain` | 当前 Mac 缺少该证书的私钥。使用本机有效签名身份，或由证书所有者安全导入对应私钥。不要把其他机器证书的名称当成本机可签名身份。 |
| `0xe8008012` / `MIInstallerErrorDomain 13`，明确提示描述文件不能安装到此设备 | 已到安装验证阶段，先查描述文件是否包含实际 Watch UDID，Watch 与 Widget 都要查。2026-10-27 本例确认为漏注册设备；刷新对应设备签名后成功，不再排查 Wi-Fi。不能仅凭同一个外层错误码认定证书被吊销。 |
| `0xe8008018` / `MIInstallerErrorDomain 13`，明确提示签名身份失效 | 检查证书与描述文件。使用当前 Mac 的有效身份重新签名构建，不先卸载 App。 |
| CoreDevice `10003`，底层明确提示设备锁定 | 解锁错误所指的设备，确认前一次请求结束，再重试一次。手机解锁不能代表手表解锁。 |
| `RemotePairingError 1001`，建立隧道超时 | 属于 Mac 到设备的开发连接。检查现有配对、唤醒状态和网络后，串行重试一次。再次失败则检查连接日志具体停在哪个阶段，避免无限重复安装。 |
| `RemotePairingError 1007`，底层 `1034` | 蓝牙操作超过内部时限，开发通道尚未建立。读取对应连接日志；`xcdevice` 显示网络可用也不能代替实际连接验证。本次关闭 Mac 增强模式后仍复现，不能仅凭虚拟网卡或 fake-IP 就认定超时原因。 |
| CoreDevice `12040`、`kAMDReadError` 或 DDI 准备失败 | 先读取底层错误。安装进程结束后，才单独检查 DDI 状态；不要同时启动多次镜像挂载。 |
| CoreDevice `10004`，未取得启动 PID | 查看设备进程和对应时间的崩溃、签名拒绝、Jetsam 记录。仅凭此码不能认定是应用代码崩溃或内存超限。 |
| `WCErrorDomain 7001 / 7007 / 7012` | 属于应用内 WatchConnectivity 同步。转到录音、队列、投递和回执诊断，不用反复挂载开发镜像处理。 |

如果自动签名仍复用已吊销证书，先备份并核对**本项目对应**的旧描述文件，再移出这些确切文件，让 Xcode 重新获取。不要批量清空所有 provisioning profiles 或钥匙串。其他机器证书的吊销必须有对应的明确授权。

2026-10-22 的后续尝试中，用户重启手表后开发通道恢复，只读检查返回开发镜像服务未启用。首次挂载因锁定返回 `10003`；解锁后安装请求与单独挂载请求均返回 `12040 → 0xe8000004 / kAMDReadError`。日志明确为镜像传输读取失败，并伴随开发通道心跳未获响应。此时不能继续归因于锁屏，也不能依据通用的更新 Xcode 提示就认定版本不兼容。Mac 上已有约 20 MB 的本地镜像，复用文件仍需要向手表传输并挂载；“镜像已下载”“连接成功”“镜像可用”“应用安装成功”须分别验证。

<a id="watch-connection-retry"></a>

### 手表连接重试经验（2026-10-21）

本次在用户确认 Wi-Fi 对齐后，首次安装仍返回 `RemotePairingError/1001`、`CoreDeviceError/4000`。日志显示它已从此前的 Bonjour 解析超时推进到 TCP/TLS 连接成功，随后在开发隧道握手等待响应时超时。**相同错误码可能对应不同的失败阶段。** 按蓝牙配对、Bonjour 解析、TCP/TLS、隧道握手、DDI、安装和启动逐段查看日志。

最终成功的顺序是：**上一条请求退出 → 只读 DDI 检查成功 → 安装同一冻结包 → 立即正常启动 → 单独查询版本**。DDI 检查、安装与启动成功，后续版本查询仍超时。具体结果见[本次安装记录](docs/implementation/watch-capture-energy-20261021.md#17-时同一-wi-fi-下重试)。

以下命令沿用第 2、3 节设置的设备 ID、bundle ID 和冻结包路径。逐个执行，每一步满足条件后再继续；不要并行运行，也不要一次粘贴全部命令。

1. 确认手机、手表已解锁，Mac、手机与手表连接同一可互通的 Wi-Fi，蓝牙可用。确认前一条设备命令已经退出。每次重试创建独立证据目录：

```sh
momo_retry="$(mktemp -d "$momo_run/watch-retry-XXXXXX")"
```

2. 只读检查开发镜像。显式关闭自动挂载，避免把状态查询变成另一次准备操作：

```sh
xcrun devicectl device info ddiServices --device "$momo_watch_id" \
  --no-auto-mount-ddis --timeout 60 \
  --json-output "$momo_retry/ddi-check.json" \
  --log-output "$momo_retry/ddi-check.log"
```

只有命令成功，且结果中 `contentIsCompatible=true`、`isUsable=true`，才进入下一步。查询超时则保存日志，回到连接阶段排查。确有镜像准备需要时，可单独使用 `--auto-mount-ddis`，待其结束再安装；镜像已兼容且可用时，沿用现有镜像。`ddiServices` 默认会自动挂载，不能省略只读参数。

3. 使用已核对来源、版本、哈希与签名的同一份冻结手表包，直接覆盖安装：

```sh
xcrun devicectl device install app --device "$momo_watch_id" \
  "$momo_watch_app" --timeout 600 \
  --json-output "$momo_retry/install.json" \
  --log-output "$momo_retry/install.log"
```

安装失败时停止后续启动步骤，记录实际失败阶段。600 秒是命令总上限，不能消除本次约 16 秒的内部隧道握手超时。连接错误本身不要求重新编译、重签名或重新下载镜像。

4. 安装结果成功后，立即正常启动 App：

```sh
xcrun devicectl device process launch --device "$momo_watch_id" \
  "$momo_watch_bundle" --timeout 90 \
  --json-output "$momo_retry/launch.json" \
  --log-output "$momo_retry/launch.log"
```

核对启动结果中的 `processIdentifier`，以及 `executable` 是否位于本次安装结果的 `installationURL` 下。本次返回 PID 2112，路径对应新安装容器，确认新安装包已启动。PID 和容器路径每次都会变化，不照抄本次值。

5. 启动命令结束后，单独读取实际安装版本：

```sh
xcrun devicectl device info apps --device "$momo_watch_id" \
  --bundle-id "$momo_watch_bundle" --timeout 60 \
  --json-output "$momo_retry/version.json" \
  --log-output "$momo_retry/version.log"
```

版本查询成功时，与冻结包分别核对版本和内部构建号。本次两次版本查询均超时，应记录为“已验证 1.18.5 包安装、启动成功；腕上版本独立读回未完成”。后续查询失败不推翻已有安装证据，也不能记成版本读取成功。继续验收时按第 6 节分别检查运行、资料保留及业务同步。

本次复用了已有配对和开发镜像，未重置设备或清理录音。Wi-Fi 对齐后连接推进、只读检查后安装成功，是这次观察到的时序，尚不能证明同一 Wi-Fi 或 DDI 查询是所有超时的通用修复。网络排障每次只调整一项并核对日志；不要因日志中出现 `proxy` 字样就判定 VPN 是原因，也不要把开发连接错误与应用内 `WCErrorDomain` 同步错误混为一谈。

## 6. 独立验收两端

安装成功后立即逐端启动，再查询腕上和手机中的实际版本。保持命令串行，以下命令一个结束后再执行下一个：

```sh
xcrun devicectl device process launch --device "$momo_phone_id" \
  --timeout 120 --json-output "$momo_run/phone-launch.json" "$momo_phone_bundle"
xcrun devicectl device process launch --device "$momo_watch_id" \
  --timeout 120 --json-output "$momo_run/watch-launch.json" "$momo_watch_bundle"

xcrun devicectl device info apps --device "$momo_phone_id" \
  --filter "bundleIdentifier == '$momo_phone_bundle'" --timeout 60 \
  --json-output "$momo_run/phone-version.json"
xcrun devicectl device info apps --device "$momo_watch_id" \
  --filter "bundleIdentifier == '$momo_watch_bundle'" --timeout 60 \
  --json-output "$momo_run/watch-version.json"
```

确认两端版本及内部构建号均与冻结包一致。隔约 30 秒，再检查进程，比较启动结果中的 `processIdentifier`：

```sh
xcrun devicectl device info processes --device "$momo_phone_id" \
  --search "MoMo Agent" --timeout 60 \
  --json-output "$momo_run/phone-processes.json"
xcrun devicectl device info processes --device "$momo_watch_id" \
  --search "MoMo Agent" --timeout 60 \
  --json-output "$momo_run/watch-processes.json"
```

Watch Widget 进程与 Watch App 进程分别识别。`--search` 可以搜索可执行路径；不要对 JSON 中的 URL 对象使用字符串 `CONTAINS` 过滤，当前 CLI 会返回类型错误。

取回安装后的接收诊断，与第 4 节保存的基线比较资料库身份，以及按日期、来源划分的片段 ID：

```sh
xcrun devicectl device copy from --device "$momo_phone_id" \
  --domain-type appDataContainer --domain-identifier "$momo_phone_bundle" \
  --source 'Library/Application Support/MoMoAgent/sync-receive-diagnostic.json' \
  --destination "$momo_run/receive-after.json" --timeout 60
```

核对 `observedAt` 为本轮启动后的时间。旧诊断可能尚未刷新；保留此限制，不能把旧文件当成新版本的运行证据。首装尚无诊断时，记录为无基线，不以此判定资料丢失。通常无需为了安装验证复制整库或全部音频。

交付时分别报告：

- **安装**：每端安装结果、实际版本及构建号与交付包一致。向用户展示版本时只写 `x.x.x`。
- **启动**：普通启动成功，后续同一 App PID 仍存在；可操作设备时再检查实际页面。
- **资料保留**：诊断刷新时间、资料库身份、既有片段是否仍在；新增同步片段不算不一致。
- **同步或性能**：仅在本轮实际测量后报告。录音需核对手机收到文件、入库、回执及两端状态；安装和启动成功不能替代这些结果。

原始设备 JSON、描述文件、证书资料、系统日志和录音留在已忽略的 `tmp_agent_output/`。GitHub 只提交操作说明与必要的脱敏结论，不上传私钥、账号凭据、完整设备诊断或用户音频。
