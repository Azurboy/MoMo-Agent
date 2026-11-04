# 本地语音依赖

SenseVoice、FunASR Nano 和 X-ASR 共用 sherpa-onnx 1.13.8、ONNX Runtime 1.28.2。应用不再依赖 FluidAudio。手表只录音和同步，不链接识别运行库。

| 模型 | 发布文件 | 执行方式 |
| --- | --- | --- |
| SenseVoice Small | sherpa 官方 INT8 ONNX，随 App 提供 | 支持的静态子图使用 Core ML，其余由 ORT 执行；归档识别每次最多两个窗口 |
| FunASR Nano | `Fun-ASR-Nano-2512` 完整 Core ML MLProgram（INT8 权重），设置中下载，约 1.01 GB | `FunASREncoderAdaptor.mlmodelc` + 多函数有状态 `FunASRLlm.mlmodelc`（`MLState` KV cache）原生运行于 Core ML ANE，`embedding.int8.bin` 由 `mmap` 按行反量化 |
| X-ASR-zh-en（离线 Zipformer transducer，带标点） | sherpa 发布的 INT8 ONNX，设置中下载，约 176 MB | ORT CPU，逐窗识别；只支持普通话、英文及中英混说 |
| Silero VAD 6.2.3 | Silero 官方原版 ONNX，固定 tag 与 SHA256 | ORT CPU，使用 sherpa 已有的 v5/v6 状态接口 |
| DiariZen WavLM-Base-s80-md | 随 App 提供的 FP32 ONNX（默认分段模型） | ORT CPU，16 秒 / 8 秒滑窗 11 类 4 说话人 powerset 解码 |
| PyAnnote Community-1 | 随 App 提供的 FP32 ONNX（设置中可切换） | ORT CPU，10 秒 / 5 秒滑窗 7 类 3 说话人 powerset 解码 |
| 3D-Speaker ERes2NetV2 | sherpa 官方中文 16k FP32 ONNX（192 维） | sherpa 动态时长特征提取 + ORT CPU |

ASR、VAD、声纹与分段权重均按上游发布的文件和固定 SHA256 使用，不重新量化，来源见 `manifest.json` 与 `speaker-manifest.json`。Core ML EP 允许不支持的算子留在 ORT，不能据此声称整个模型都在 ANE 上运行。Nano 的发布编码器固定 batch=1；其归档队列复用同一组模型逐窗识别，不宣称张量批处理。输入框语音始终逐段处理，不等待凑批。

归档处理由 Silero v6 选择语音范围，不对未检出的声音额外补做 ASR。连续长句保留句首句尾与跨片段上下文；正文按时间戳及相邻窗口对齐。升级继承此前已完成历史，不补跑旧录音。取舍和验证范围见 [常规语音选择策略](../../docs/implementation/normal-speech-selection-20261023.md)。

## 模型文件

SenseVoice 与 VAD 的固定哈希见 [manifest.json](manifest.json)。FunASR Nano Core ML 包的十四个文件、大小、哈希和固定下载 revision 见 [下载清单](../../Packages/MoMoAgentKit/Sources/MoMoSpeech/Resources/funasr-nano-coreml-v1.json)（导出脚本见 `Tools/FunASRNanoCoreML/export_funasr_nano_coreml.py`）。X-ASR 的四个文件见 [下载清单](../../Packages/MoMoAgentKit/Sources/MoMoSpeech/Resources/x-asr-zh-en-onnx-v1.json)。下载目录只有在全部文件校验成功后才写入完成凭证。

```sh
uv run Native/SpeechVendor/prepare-models.py Models/Speech --scratch-directory tmp_agent_output/speech-model-download
```

App 的 `Speech/` 包含 `model.int8.onnx`、`tokens.txt`、`silero_vad.onnx`、`manifest.json` 和 `Speakers/` 下的三份声纹/分段模型（`eres2netv2.onnx`、`diarizen-wavlm-base-s80-md.onnx`、`segmentation-community-1.onnx`），由 `prepare-models.py` 统一校验与准备到 `Models/Speech/`。许可放在 `SpeechLicenses/`。生产资源检查器拒绝清单外模型、旧 Core ML 资源和测试音频。公开音频由 `Tests/Support/prepare-fixtures.py` 单独准备。

说话人归属、声纹反馈和验证边界见 [说话人与声纹](../../docs/implementation/speaker-voiceprints-20261029.md)。

下载中断时保留完整的 HTTP 分块；重试从已保存位置继续。下载、校验和模型加载均不在主线程运行。模型成功加载后才保存选择；切换不重跑已有转录。历史的 FluidAudio 实施记录及模型清单只用于追溯旧版本。

## sherpa 接口补丁

首次打开 Xcode 或运行依赖 MoMoAgentKit 的 SwiftPM 命令前，先准备固定运行库。仓库为私有仓库，脚本通过 `gh` 的登录身份下载发行附件；CI 使用仓库只读 token。脚本校验 ZIP 和解压后的逐文件清单，已有正确文件会复用。

```sh
uv run Native/SpeechVendor/prepare-runtime.py --scratch-directory tmp_agent_output/speech-runtime
```

版本与哈希见 [runtime-manifest.json](runtime-manifest.json)，构建来源见 [runtime-build-provenance.json](runtime-build-provenance.json)。构建缓存位于已忽略的 `Vendor/SherpaOnnx/Binaries/`。不能用未经补丁的官方库直接替换该目录。

上游 commit 固定为 `11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf`。`build-coreml-runtime.py` 校验上游 XCFramework 的 SHA256，然后只重编并替换两个同名对象文件：

- `session.cc`：使用 ORT 的现代 Core ML provider 配置接口，传递模型缓存、执行设备和静态形状选项；让空闲线程休眠。
- `offline-funasr-nano-model.cc`：为 Nano 的编码器和解码器分别选择 provider。

SenseVoice 的动态形状子图，以及 Nano 的量化 LLM，在当前 ORT/Core ML 组合下会产生无法加载的 MIL 执行计划。因此 SenseVoice 设置 `RequireStaticInputShapes=1`，Nano 仅对编码器请求 Core ML。Swift 桥接层捕获 C++ 异常，把加载或解码失败返回给队列，避免异常穿过 C API 导致闪退。

重建需要 Xcode 和固定版本的 sherpa 源码。示例中的输出目录须不存在：

```sh
git clone --filter=blob:none https://github.com/k2-fsa/sherpa-onnx tmp_agent_output/sherpa-source
git -C tmp_agent_output/sherpa-source checkout 11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf
uv run Native/SpeechVendor/build-coreml-runtime.py \
  --source tmp_agent_output/sherpa-source \
  --scratch tmp_agent_output/sherpa-coreml-build \
  --output tmp_agent_output/sherpa-coreml-artifacts
```

脚本优先复用已校验的 SwiftPM 下载缓存，否则下载固定的官方发行文件。输出包括 iOS 真机、iOS 模拟器、Mac 的静态库和 `build-provenance.json`。该文件记录源代码、补丁、上游包哈希和 Xcode 版本。

## 来源和许可

`MoMoAcousticVAD` 的历史源码、[清单](acoustic-vad-manifest.json)和许可仍保留在仓库，但已从 SwiftPM 产品、目标和依赖中移除，`AcousticActivity.swift` 也已排除编译。当前 App 不包含这层补检。

- [SenseVoice 官方转换包](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2)：压缩包 SHA256 `7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e`。权重遵循 [FunASR 模型许可 v1.1](Licenses/FunASR-MODEL-LICENSE-v1.1.txt)，不能将它标为 Apache/MIT。
- [FunASR Nano 发布文件](https://huggingface.co/csukuangfj/sherpa-onnx-funasr-nano-int8-2025-12-30/tree/6f16bd378457e13f36ccf3910df9017f96c346fb)；[原模型](https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-2512)使用 Apache 2.0。
- [Silero VAD 6.2.3 原版 ONNX](https://github.com/snakers4/silero-vad/blob/v6.2.3/src/silero_vad/data/silero_vad.onnx) 使用 [MIT](Licenses/Silero-MIT.txt)。SHA256 为 `1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3`。
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 使用 [Apache 2.0](Licenses/sherpa-onnx-APACHE-2.0.txt)；ORT 及其组件的许可随固定 XCFramework 保留。
- [libfvad](https://github.com/dpirch/libfvad/tree/532ab666c20d3cfda38bca63abbb0f152706c369) 使用 [BSD 3-Clause](Licenses/libfvad-LICENSE.txt)，历史源码附有 AUTHORS 和 PATENTS；当前 App 不编译该组件。
- [ONNX Runtime Core ML EP 配置](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html)。

Mac 测试验证模型调用和数据处理；手机上的速度、后台运行和能耗须另做真机测试。
