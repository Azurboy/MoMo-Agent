# Mac 内置运行环境

设置中的“运行组件”原指 Python 3.14、Hermes 的 mcp/messaging 依赖和 aiohttp/aiortc 连接适配器；开发包依赖本机 uv 与源码路径。用户要求改为 App 自带。

发布包在 `Contents/Resources/AgentRuntime` 中携带独立 Python、锁定依赖、MoMo 后台源码和 Hermes 源码。Python 来自构建机上的 python-build-standalone（本次为项目锁定的 3.14.7，SQLite 3.53.1）；依赖使用仓库锁文件重新构建，不复制个人 venv、配置、密钥或数据。Claude 入口所需 anthropic SDK 也随包附带。Tailscale 继续使用现有内嵌 framework。

Mac 优先从 bundle 读取后台和解释器，初始化只在 Application Support 创建个人身份与配置，不调用 uv 或下载依赖。已有身份、模型配置、聊天、配对和旧 venv 保留；旧 venv 不再作为发布包的执行环境。依赖 manifest 与源码不匹配或解释器缺失时明确失败，不回退到开发机环境。后台及其 MCP 子进程的字节码放在个人 runtime/bytecode，避免改变签名资源。

设置显示“运行组件 · 已内置”，首次使用为“开始设置”。未打包的源码开发模式继续支持既有 uv 准备流程。

## 打包

先用正常配置构建 Mac Release，再运行：

```sh
uv run --no-project python Scripts/bundle-mac-runtime.py \
  --app '/path/to/MoMo Agent.app' \
  --python-home '/path/to/standalone-python-3.14' \
  --sign 'Apple signing certificate SHA1'
uv run --no-project python Tests/Support/verify-mac-runtime.py '/path/to/MoMo Agent.app'
```

构建机需要 uv、Xcode 和签名证书；用户机器不需要。脚本改写 Python/第三方 dylib 的构建路径，逐个签名 Mach-O 后签 App，去除 `MoMoRepositoryRoot`。使用与安装版相同的证书和 designated requirement。保留上游许可证和 Python 包的 dist-info。

打包器拒绝 SQLite 早于 3.51.3 的解释器。当前产物面向 Apple Silicon；Intel 必须在对应架构的构建环境产生独立 runtime，不能把 arm64 解释器宣传成通用版。外部模型调用仍联网；额外用户工具和可选第三方集成不属于核心初始化的离线保证。

## 默认引擎打包补充（2026-11-02）

默认引擎改为 SuperAgent 后，Mac 打包器同时复制 `Vendor/SuperAgent` 与上游清单，包含已编译的 JS、提示词、技能与语言资源；否则安装包缺少默认引擎的源文件。SuperAgent 的 Node runner 仍由已有的 `prepare_superagent` 流程准备，需要本机 Node 和 pnpm。

离线包检查显式选择 Hermes 来验证内置 Python 路径，并独立验证 SuperAgent 清单和编译产物。报告分别标记这两项，不能把 Hermes 离线初始化成功视为 SuperAgent 不需要 Node 或额外准备。

## 验证边界

单元测试覆盖离线分支、重复准备保留配置、依赖/架构/版本不匹配和缺失解释器。真实包检查通过进程沙盒禁网、隐藏开发工具路径来执行初始化、重复准备和原生扩展导入，前后验证签名。构建、安装、实际 Agent 恢复分别记录在本次交付 evidence 中，不把禁网初始化当成离线大模型或跨设备验收。
