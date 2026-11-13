import { n as health, r as sourceContext, t as KV, v as threadKey } from "./kv-BKzBGVb4.js";
import { join, resolve } from "node:path";
import { z } from "zod";
import { readFile } from "node:fs/promises";
//#region src/sources/momo.ts
const SOURCE = "momo";
const momoTriggerId = (messageId) => `${SOURCE}:${messageId}`;
const LoopbackBridgeUrlSchema = z.string().url().refine((raw) => {
	try {
		const parsed = new URL(raw);
		return (parsed.protocol === "http:" || parsed.protocol === "https:") && [
			"127.0.0.1",
			"localhost",
			"::1",
			"[::1]"
		].includes(parsed.hostname);
	} catch {
		return false;
	}
}, "MoMo bridgeUrl must be an HTTP(S) loopback URL (127.0.0.1, localhost, or ::1)");
const MomoStreamSchema = z.enum([
	"chat",
	"transcripts",
	"life_signals"
]);
const MomoConfigSchema = z.object({
	bridgeUrl: LoopbackBridgeUrlSchema.default("http://127.0.0.1:8787"),
	pollIntervalMs: z.number().int().min(100).max(6e4).default(500),
	waitMs: z.number().int().min(0).max(3e4).default(5e3),
	readPageSize: z.number().int().min(1).max(50).default(20),
	chat: z.boolean().default(true),
	transcripts: z.enum(["none", "all"]).default("all"),
	lifeSignals: z.enum(["none", "all"]).default("all")
}).strict();
const MomoBridgeEventSchema = z.object({
	cursor: z.string().min(1),
	id: z.string().min(1),
	stream: MomoStreamSchema,
	chat_mode: z.enum(["standard", "creator"]).optional(),
	thread_id: z.string().min(1),
	actor_id: z.string().min(1),
	actor_name: z.string().optional(),
	human: z.boolean().default(true),
	addressed: z.enum(["direct", "mention"]).optional(),
	at: z.string().min(1),
	text: z.string(),
	title: z.string().optional(),
	source_id: z.string().optional(),
	parent_id: z.string().optional(),
	channel_id: z.string().optional(),
	reply_allowed: z.boolean().default(true)
}).passthrough();
const TriggerBatchSchema = z.object({
	events: z.array(MomoBridgeEventSchema).default([]),
	next_cursor: z.string().nullish()
}).passthrough();
const ContextMessageSchema = z.object({
	id: z.string().min(1),
	from: z.string().min(1),
	at: z.string().min(1),
	text: z.string(),
	bot: z.literal(true).optional(),
	deleted: z.literal(true).optional(),
	reply_to: z.string().optional(),
	url: z.string().optional()
}).strict();
const ContextResponseSchema = z.object({
	messages: z.array(ContextMessageSchema).default([]),
	next: z.string().optional(),
	body: z.record(z.string(), z.unknown()).default({})
}).passthrough();
async function bridgeHeaders(stateDir) {
	try {
		const raw = JSON.parse(await readFile(join(stateDir, "momo-bridge.json"), "utf8"));
		if (typeof raw.secret === "string" && raw.secret.trim()) return { "x-momo-bridge": raw.secret.trim() };
	} catch {}
	return {};
}
/** Converts a MoMo bridge event into a normalized dsh-superagent Trigger. */
function momoTrigger(event, bridgeUrl) {
	const thread = {
		source: SOURCE,
		id: event.thread_id
	};
	const address = {
		bridgeUrl,
		stream: event.stream,
		threadId: event.thread_id,
		messageId: event.id,
		...event.channel_id ? { channelId: event.channel_id } : {},
		...event.source_id ? { sourceId: event.source_id } : {}
	};
	return {
		id: momoTriggerId(event.id),
		source: SOURCE,
		threads: [thread],
		actor: {
			source: SOURCE,
			id: event.actor_id
		},
		human: event.human,
		...event.addressed ? { addressed: event.addressed } : {},
		at: event.at,
		text: event.text,
		...event.reply_allowed ? { channel: {
			source: SOURCE,
			thread: event.thread_id,
			address
		} } : {},
		meta: {
			stream: event.stream,
			...event.stream === "chat" && event.chat_mode ? { chatMode: event.chat_mode } : {},
			messageId: event.id,
			threadId: event.thread_id,
			...event.actor_name ? { actorName: event.actor_name } : {},
			...event.parent_id ? { parentId: event.parent_id } : {},
			...event.source_id ? { sourceId: event.source_id } : {},
			...event.title ? { title: event.title } : {}
		}
	};
}
/** Sends an outbound reply or acknowledgement back to MoMo's local conversation gateway idempotently by `message.id`. */
async function sendMomo(host, message) {
	const bridgeUrl = LoopbackBridgeUrlSchema.parse(message.channel.address.bridgeUrl ?? "http://127.0.0.1:8787");
	const headers = {
		"content-type": "application/json",
		...await bridgeHeaders(host.commands.deployment.stateDir)
	};
	const response = await fetch(new URL("/momo/internal/superagent/outbound", bridgeUrl), {
		method: "POST",
		headers,
		body: JSON.stringify({
			id: message.id,
			kind: message.kind,
			ticket_id: message.ticketId ?? null,
			attention_id: message.attentionId,
			text: message.text,
			channel: message.channel
		}),
		signal: AbortSignal.timeout(15e3)
	});
	if (response.status === 404 || response.status === 410) return "gone";
	if (!response.ok) {
		const detail = (await response.text().catch(() => "")).slice(0, 300);
		throw new Error(`MoMo outbound HTTP ${response.status}${detail ? `: ${detail}` : ""}`);
	}
	return (await response.json().catch(() => ({ status: "sent" }))).status === "gone" ? "gone" : "sent";
}
function momoLink(address) {
	return {
		url: "",
		label: address.stream === "transcripts" ? {
			zh: "随身录音主动推送",
			en: "Voice transcript proactive channel"
		} : address.stream === "life_signals" ? {
			zh: "生活上下文主动推送",
			en: "Life signal proactive channel"
		} : {
			zh: "MoMo 对话",
			en: "MoMo chat"
		}
	};
}
const momoThreadContext = {
	messageId: (trigger) => String(trigger.meta.messageId ?? trigger.id),
	async read(commands, trigger, part, cursor, config) {
		const url = new URL("/momo/internal/superagent/context", config.bridgeUrl);
		url.searchParams.set("thread_id", trigger.threads[0]?.id ?? "");
		url.searchParams.set("message_id", String(trigger.meta.messageId ?? trigger.id));
		url.searchParams.set("part", part);
		url.searchParams.set("limit", String(config.readPageSize));
		if (trigger.meta.sourceId) url.searchParams.set("source_id", String(trigger.meta.sourceId));
		if (cursor) url.searchParams.set("cursor", cursor);
		const headers = await bridgeHeaders(commands.deployment.stateDir);
		const response = await fetch(url, {
			headers,
			signal: AbortSignal.timeout(15e3)
		});
		if (!response.ok) throw new Error(`MoMo context HTTP ${response.status}`);
		const parsed = ContextResponseSchema.parse(await response.json());
		return {
			messages: parsed.messages,
			...parsed.next ? { next: parsed.next } : {},
			body: parsed.body
		};
	}
};
async function sleep(ms, signal) {
	if (signal.aborted || ms <= 0) return;
	await new Promise((resolve) => {
		const onAbort = () => {
			clearTimeout(timer);
			resolve();
		};
		const timer = setTimeout(() => {
			signal.removeEventListener("abort", onAbort);
			resolve();
		}, ms);
		timer.unref?.();
		signal.addEventListener("abort", onAbort, { once: true });
	});
}
/** Ingests one batch of triggers from the local MoMo bridge and advances the durable cursor. */
async function pollMomoOnce(ctx, config, signal) {
	const after = ctx.state.get(KV.momo.cursor) ?? "";
	const url = new URL("/momo/internal/superagent/triggers", config.bridgeUrl);
	if (after) url.searchParams.set("after", after);
	if (config.waitMs > 0) url.searchParams.set("wait_ms", String(config.waitMs));
	const headers = await bridgeHeaders(ctx.deployment.stateDir);
	const timeout = AbortSignal.timeout(Math.max(15e3, config.waitMs + 1e4));
	const response = await fetch(url, {
		headers,
		signal: AbortSignal.any([signal, timeout])
	});
	if (!response.ok) {
		const detail = (await response.text().catch(() => "")).slice(0, 240);
		throw new Error(`MoMo bridge HTTP ${response.status}${detail ? `: ${detail}` : ""}`);
	}
	const batch = TriggerBatchSchema.parse(await response.json());
	let count = 0;
	for (const event of batch.events) {
		if (signal.aborted) break;
		const trigger = momoTrigger(event, config.bridgeUrl);
		await ctx.receive(trigger);
		if (event.title) ctx.threads.describe(threadKey(trigger.threads[0]), { label: event.title });
		ctx.state.set(KV.momo.cursor, event.cursor);
		count += 1;
	}
	if (batch.next_cursor && batch.events.length === 0 && batch.next_cursor !== after) ctx.state.set(KV.momo.cursor, batch.next_cursor);
	return count;
}
/** Background polling loop connecting `dsh-superagent` to the local MoMo runtime bridge. */
async function runMomo(ctx, signal) {
	await ctx.ready.catch(() => {});
	let failures = 0;
	while (!signal.aborted) {
		if (!ctx.configured()) {
			ctx.report("momo", {
				...health("paused", "setupPending"),
				at: (/* @__PURE__ */ new Date()).toISOString()
			});
			await sleep(1e3, signal);
			continue;
		}
		const config = ctx.config(SOURCE);
		if (!config) {
			ctx.report("momo", {
				...health("paused", "sourceOff"),
				at: (/* @__PURE__ */ new Date()).toISOString()
			});
			await sleep(1e3, signal);
			continue;
		}
		try {
			const received = await pollMomoOnce(ctx, config, signal);
			failures = 0;
			ctx.report("momo", {
				state: "ready",
				detail: `Connected to MoMo bridge (${config.bridgeUrl})`,
				at: (/* @__PURE__ */ new Date()).toISOString()
			});
			if (received === 0 && config.waitMs === 0) await sleep(config.pollIntervalMs, signal);
			else if (received === 0) await sleep(Math.min(config.pollIntervalMs, 250), signal);
		} catch (error) {
			if (signal.aborted) break;
			failures += 1;
			const message = error instanceof Error ? error.message : String(error);
			ctx.report("momo", {
				...health("error", "pollFailures", {
					count: String(failures),
					error: message
				}),
				at: (/* @__PURE__ */ new Date()).toISOString()
			});
			await sleep(Math.min(15e3, 500 * 2 ** Math.min(failures, 5)), signal);
		}
	}
}
const momoKind = {
	kind: SOURCE,
	title: {
		zh: "MoMo 随身助手",
		en: "MoMo Personal Agent"
	},
	description: {
		zh: "接入 MoMo 随身录音转写、手机上下文信号与主对话流，支持明确指令派工与主动规则研判。",
		en: "Receives MoMo voice transcripts, phone context signals, and direct chat messages for explicit tasks and proactive rule evaluation."
	},
	schema: MomoConfigSchema,
	fields: [
		{
			key: "bridgeUrl",
			type: "text",
			label: {
				zh: "本地桥接地址",
				en: "Local bridge URL"
			},
			hint: {
				zh: "MoMo Gateway 的本机回环地址（仅支持 127.0.0.1 / localhost）。",
				en: "Loopback URL of the local MoMo Gateway (127.0.0.1 or localhost only)."
			}
		},
		{
			key: "chat",
			type: "switch",
			label: {
				zh: "接收 MoMo 对话消息",
				en: "Receive MoMo chat messages"
			}
		},
		{
			key: "transcripts",
			type: "select",
			label: {
				zh: "随身录音转写流",
				en: "Voice transcript stream"
			},
			options: [{
				value: "none",
				label: {
					zh: "不观察",
					en: "Off"
				}
			}, {
				value: "all",
				label: {
					zh: "主动观察全部转写片段",
					en: "Observe all transcript passages"
				}
			}],
			hint: {
				zh: "开启后，手表/iPhone 同步的录音转写将作为未点名候选交给主动评估（受评估模式 observe/auto 与准入规则约束）。",
				en: "When enabled, synced Watch/iPhone voice transcripts become unaddressed candidates for proactive assessment under the Policy rules."
			}
		},
		{
			key: "lifeSignals",
			type: "select",
			label: {
				zh: "手机日程与状态信号",
				en: "Phone schedule & context signals"
			},
			options: [{
				value: "none",
				label: {
					zh: "不观察",
					en: "Off"
				}
			}, {
				value: "all",
				label: {
					zh: "主动观察全部状态信号",
					en: "Observe all life signals"
				}
			}]
		},
		{
			key: "pollIntervalMs",
			type: "number",
			advanced: true,
			min: 100,
			max: 6e4,
			label: {
				zh: "轮询间隔 / 毫秒",
				en: "Poll interval / ms"
			}
		},
		{
			key: "waitMs",
			type: "number",
			advanced: true,
			min: 0,
			max: 3e4,
			label: {
				zh: "长轮询等待 / 毫秒",
				en: "Long-poll wait / ms"
			}
		},
		{
			key: "readPageSize",
			type: "number",
			advanced: true,
			min: 1,
			max: 50,
			label: {
				zh: "上下文每页条数",
				en: "Context page size"
			}
		}
	],
	health: ["momo"],
	scope({ meta }, config) {
		const stream = meta.stream;
		if (stream === "transcripts") return config.transcripts === "all" ? {
			listened: true,
			observed: true,
			row: "transcripts"
		} : {
			listened: false,
			reason: "momo_stream_disabled"
		};
		if (stream === "life_signals") return config.lifeSignals === "all" ? {
			listened: true,
			observed: true,
			row: "life_signals"
		} : {
			listened: false,
			reason: "momo_stream_disabled"
		};
		return config.chat ? {
			listened: true,
			observed: false,
			row: "chat"
		} : {
			listened: false,
			reason: "momo_stream_disabled"
		};
	},
	channel: {
		allowed: (address, config) => momoKind.scope({ meta: { stream: address.stream ?? "chat" } }, config).listened,
		send: sendMomo,
		link: momoLink
	},
	threadContext: momoThreadContext,
	find: (query) => {
		return {
			threads: [...new Set(query.match(/\bmomo:[A-Za-z0-9:_-]+/g) ?? [])],
			terms: []
		};
	},
	repliesTo: (trigger) => typeof trigger.meta.parentId === "string" ? momoTriggerId(trigger.meta.parentId) : void 0,
	policy: {
		unnamed: {
			person: {
				zh: "MoMo 用户",
				en: "MoMo user"
			},
			bot: {
				zh: "MoMo 采集器",
				en: "MoMo sensor"
			}
		},
		schema: z.object({
			allowed: z.array(z.object({
				id: z.string().trim().min(1).max(120),
				name: z.string().trim().max(100).optional()
			}).strict()).refine((users) => new Set(users.map((user) => user.id)).size === users.length, "Duplicate MoMo user IDs").default([]),
			bots: z.array(z.object({
				id: z.string().trim().min(1).max(120),
				name: z.string().trim().max(100).optional()
			}).strict()).refine((bots) => new Set(bots.map((bot) => bot.id)).size === usersUnique(bots), "Duplicate MoMo bot IDs").optional()
		}).strict(),
		fields: [{
			key: "allowed",
			type: "rows",
			label: {
				zh: "授权发起与主动服务的用户 ID",
				en: "MoMo user IDs authorized to originate work"
			},
			columns: [{
				key: "id",
				type: "text",
				label: {
					zh: "用户 ID",
					en: "User ID"
				}
			}, {
				key: "name",
				type: "text",
				label: {
					zh: "名字",
					en: "Name"
				},
				optional: true
			}]
		}],
		explicit: {
			zh: "授权用户在 MoMo 对话中直接发送的消息始终作为明确请求（explicit）处理；随身录音与生活信号不点名智能体，按准入规则做主动推断（inferred）。",
			en: "Direct messages in MoMo chat from an allowed user are always explicit requests; voice transcripts and life signals are unaddressed and evaluated proactively under the rules."
		},
		rows(stored) {
			const config = MomoConfigSchema.parse(stored);
			return [
				{
					id: "transcripts",
					label: {
						zh: "随身录音转写",
						en: "Voice transcripts"
					},
					note: config.transcripts === "all" ? {
						zh: "主动观察",
						en: "Observed"
					} : {
						zh: "关闭",
						en: "Off"
					},
					cells: {
						listedUnaddressed: config.transcripts === "all",
						unlistedAddressed: false,
						unlistedUnaddressed: false
					}
				},
				{
					id: "life_signals",
					label: {
						zh: "手机日程与状态信号",
						en: "Phone & schedule signals"
					},
					note: config.lifeSignals === "all" ? {
						zh: "主动观察",
						en: "Observed"
					} : {
						zh: "关闭",
						en: "Off"
					},
					cells: {
						listedUnaddressed: config.lifeSignals === "all",
						unlistedAddressed: false,
						unlistedUnaddressed: false
					}
				},
				{
					id: "chat",
					label: {
						zh: "MoMo 对话",
						en: "MoMo chat"
					},
					note: config.chat ? {
						zh: "接收",
						en: "Received"
					} : {
						zh: "关闭",
						en: "Off"
					},
					cells: {
						listedUnaddressed: false,
						unlistedAddressed: config.chat,
						unlistedUnaddressed: false
					}
				}
			];
		}
	},
	environment: {
		variables: [
			{
				key: "DSH_SUPERAGENT_MOMO_BRIDGE",
				description: {
					zh: "MoMo 本地桥接地址",
					en: "Loopback URL of the local MoMo bridge"
				}
			},
			{
				key: "DSH_SUPERAGENT_MOMO_CLI",
				description: {
					zh: "读取录音、日程与长期记忆的本地 CLI 路径",
					en: "Path to the local momo-cli helper for recordings, phone context, and memories"
				}
			},
			{
				key: "DSH_SUPERAGENT_MOMO_WORKSPACE",
				description: {
					zh: "MoMo 结果文件夹路径（用于落盘交付脚本、报告与产物）",
					en: "Path to the MoMo workspace / results directory for user-facing artifacts and deliverables"
				}
			},
			{
				key: "DSH_SUPERAGENT_MOMO_THREAD",
				description: {
					zh: "触发当前工单的 MoMo 线程 ID；非 MoMo 工单为空",
					en: "MoMo thread ID that started this ticket; empty when the ticket did not start on MoMo"
				}
			},
			{
				key: "DSH_SUPERAGENT_MOMO_SOURCE_ID",
				description: {
					zh: "触发当前工单的录音或上下文 source_id；无则为空",
					en: "Recording or context source_id that triggered this ticket, or empty"
				}
			}
		],
		values: ({ deployment, config, trigger }) => ({
			DSH_SUPERAGENT_MOMO_BRIDGE: config.bridgeUrl,
			DSH_SUPERAGENT_MOMO_CLI: join(deployment.stateDir, "momo-cli"),
			DSH_SUPERAGENT_MOMO_WORKSPACE: resolve(process.env.MOMO_DATA_DIR ? join(process.env.MOMO_DATA_DIR, "workspace") : join(deployment.stateDir, "..", "..", "workspace")),
			DSH_SUPERAGENT_MOMO_THREAD: trigger?.source === "momo" ? trigger.threads[0]?.id ?? "" : "",
			DSH_SUPERAGENT_MOMO_SOURCE_ID: trigger?.source === "momo" ? String(trigger.meta.sourceId ?? "") : ""
		})
	}
};
function usersUnique(items) {
	return items.length;
}
/** Returns the MoMo Source's settings, falling back to schema defaults while the MoMo plugin is disabled. */
const momoSettings = (sources) => sources.instance("momo")?.config ?? MomoConfigSchema.parse({});
const name = "dsh-superagent-momo";
const inject = ["orchestrator"];
function apply(ctx) {
	ctx.effect(() => ctx.orchestrator.sources.register(momoKind), "momo: source kind");
	ctx.effect(() => {
		const controller = new AbortController();
		const running = runMomo(sourceContext(ctx.orchestrator, momoKind), controller.signal);
		return async () => {
			controller.abort();
			await running;
		};
	});
}
//#endregion
export { MomoBridgeEventSchema, MomoConfigSchema, MomoStreamSchema, SOURCE, apply, inject, momoKind, momoLink, momoSettings, momoThreadContext, momoTrigger, momoTriggerId, name, pollMomoOnce, runMomo, sendMomo };
