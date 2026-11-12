"""Render the complete captured prompt as a readable local review document."""
import argparse
from html import escape
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def render(directory):
    sections = [
        ("product", "01 · MoMo 产品规则全文", (ROOT / "Tests/AgentRuntime/fixtures/legacy_gateway/prompt_plugin/policy.md").read_text()),
        ("system", "02 · 完整 system prompt · 实际装配示例", (directory / "system-prompt.txt").read_text()),
        ("turn", "03 · 本轮用户输入 + 近期转录资料 · 实际请求", (directory / "current-turn.txt").read_text()),
        ("ingestion", "04 · 独立的转录记忆整理 prompt", (directory / "transcript-ingestion.txt").read_text()),
    ]
    parts = json.loads((directory / "system-parts.json").read_text())
    upstream = json.loads((ROOT / "Vendor/HermesAgent.UPSTREAM.json").read_text())
    request = json.loads((directory / "request.json").read_text())
    tools = [t["function"]["name"] for t in request.get("tools", [])]
    body = ''.join(f'<section id="{key}"><h2>{title}</h2><pre>{escape(content)}</pre></section>'
                   for key, title, content in sections)
    html = f'''<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>MoMo · Prompt 构成与全文</title>
<style>body{{margin:0;background:#f5f4f0;color:#242424;font:16px/1.75 system-ui,-apple-system,sans-serif}}
main{{max-width:1000px;margin:auto;padding:48px 24px 96px}}h1{{font-size:38px;line-height:1.2;letter-spacing:-1px}}
h2{{font-size:23px}}a{{color:#275343;text-underline-offset:4px}}small{{color:#656565}}nav{{display:flex;gap:16px;flex-wrap:wrap;margin:24px 0}}
section{{margin-top:48px}}pre{{white-space:pre-wrap;overflow-wrap:anywhere;background:white;border:1px solid #e0dfda;border-radius:12px;padding:24px;font:14px/1.8 ui-monospace,SFMono-Regular,monospace}}
table{{width:100%;border-collapse:collapse}}th,td{{text-align:left;padding:14px 10px;border-bottom:1px solid #d5d5ce;vertical-align:top}}
aside{{border-left:3px solid #557263;padding:4px 20px;margin:24px 0}}code{{overflow-wrap:anywhere}}@media(max-width:600px){{main{{padding:28px 16px}}h1{{font-size:30px}}pre{{padding:16px}}}}
</style><main><small>MOMOAGENT · 1.28.0 · 2026-10-23</small><h1>MoMo 的 Prompt</h1>
<p>Hermes 原生装配 + MoMo 产品规则 + 本轮资料。下面所有正文完整展示，没有折叠省略。</p>
<aside><strong>这是隔离环境的实际请求捕获。</strong>录音、用户画像和记忆均为合成示例；模型是本地脚本服务，用于验证传递和装配，不能证明真实模型一定遵循每条规则。没有使用手机、真实健康数据或用户私有记忆。</aside>
<nav>{''.join(f'<a href="#{key}">{title.split(" · ",1)[1]}</a>' for key,title,_ in sections)}<a href="request.json">完整请求 JSON（含工具 schema）</a></nav>
<table><thead><tr><th>层</th><th>内容与更新方式</th></tr></thead><tbody>
<tr><td>Hermes 身份与行为</td><td>SOUL 首句改为 MoMo；其余上游行为规范完整保留。已有用户自定义人格保留。工具执行、完成标准、技能、环境、记忆装配不改写。</td></tr>
<tr><td>MoMo 固定规则</td><td>Hermes 原生插件的 after_memory section；涵盖对话与后台任务、设备、录音、健康边界、原生记忆。完整规则见下方。</td></tr>
<tr><td>Hermes 记忆和历史</td><td>MEMORY.md / USER.md、memory、session_search 继续由 Hermes 管理，没有第二套长期记忆。工具按当前配置发现，部分通过 tool_search / tool_describe / tool_call 延迟暴露。</td></tr>
<tr><td>近期转录</td><td>原生 pre_llm_call 钩子每轮读取 Mac 副本，放入用户侧资料。最近 24 小时，最多 3 场 / 20 段、每场 12 段、每段 1200 UTF-8 字节，整个 JSON ≤10,000 字节。按录音时间选取，不按上传时间。</td></tr>
<tr><td>健康</td><td>本版接线未完成，明确 unavailable，不注入虚构数值。未来使用时仍需真实授权、实际工具、时间范围和单位。</td></tr>
<tr><td>自动记忆整理</td><td>已有独立投递批次，每 60 秒最多接纳一个新批次；最多 24 段 / 32 KB。仅来源读取与原生 memory；不额外注入近期聊天快照。</td></tr>
</tbody></table>
<p>转录遗漏数量、片段偏移、完整来源长度、版本和引用均随资料提供。需要全文时固定版本分页读至 next_offset=null。已删除或被“忘记”机制排除的来源不进入后续快照；历史会话中此前已接收的资料仍按 Hermes 的历史规则保留，不声称已全端擦除。</p>
<p>固定规则沿用 Hermes 会话缓存：部署后重启 Mac Agent，新会话使用新规则；已有会话在原生上下文重建时更新。近期资料每轮刷新，后台委派会话只使用明确交接的资料。不会为更新 prompt 清空聊天或记忆。</p>
<p><small>对齐基线：{escape(upstream['commit'])}，仓库固定版本。agent/system_prompt.py、agent/prompt_builder.py 和上游 SOUL.md 均未修改；不是升级到今日上游最新提交。</small></p>
<p><small>此次 system 层：stable {len(parts['stable'])} 字符、context {len(parts['context'])} 字符、volatile {len(parts['volatile'])} 字符。模型、工具、环境、技能和用户记忆不同，完整装配内容也会变化；这里展示的是这次请求的全部内容。</small></p>
<p><small>本例首轮工具：{escape(', '.join(tools))}。</small></p>
{body}<section><h2>原始文件与验证</h2><p><a href="system-prompt.txt">System 全文</a> · <a href="current-turn.txt">当前轮次全文</a> · <a href="transcript-ingestion.txt">整理全文</a> · <a href="system-parts.json">分层 JSON</a> · <a href="request.json">完整请求与工具 schema</a> · <a href="validation.json">原生链路检查</a></p></section></main></html>'''
    (directory / "index.html").write_text(html)
    # Keep every captured section verbatim in the artifact; HTML escaping is reversible.
    for _, _, content in sections:
        assert escape(content) in html


if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--directory", type=Path, required=True)
    render(parser.parse_args().directory.resolve())
