import { F as Thread, U as Trigger } from "./intake-BntR4bhz.js";
import { _ as SourceRegistry, i as SourceContext, n as SourceKind, v as Tally } from "./kind-CBntL-Jz.js";
import { Context } from "@deepseek-ai/cordis";
import { z } from "zod";
//#region src/sources/feishu-read.d.ts
/** Retained source message reference anchoring context reads; `at` is the timestamp around which `chatAround` queries. */
interface FeishuRef {
  triggerId: string;
  chatId: string;
  messageId: string;
  at?: string;
}
//#endregion
//#region src/sources/feishu-trigger.d.ts
declare const SOURCE = "feishu";
/** A message as the live event consumer prints it; the history and topic-page paths normalize what they read into this shape. */
declare const EventSchema: z.ZodObject<{
  message_id: z.ZodString;
  chat_id: z.ZodString;
  chat_type: z.ZodEnum<{
    p2p: "p2p";
    group: "group";
  }>;
  sender_id: z.ZodString;
  sender_type: z.ZodEnum<{
    user: "user";
    bot: "bot";
  }>;
  content: z.ZodString;
  create_time: z.ZodString;
  mentions: z.ZodDefault<z.ZodArray<z.ZodObject<{
    id: z.ZodString;
    key: z.ZodOptional<z.ZodString>;
    name: z.ZodOptional<z.ZodString>;
  }, z.core.$strip>>>;
  root_id: z.ZodOptional<z.ZodString>;
  parent_id: z.ZodOptional<z.ZodString>;
  thread_id: z.ZodOptional<z.ZodString>;
  message_app_link: z.ZodOptional<z.ZodURL>;
}, z.core.$strip>;
type FeishuEvent = z.infer<typeof EventSchema>;
declare const feishuThreadId: (chatId: string, rootId: string | undefined, messageId: string) => string;
/** Deterministic trigger ID for a Feishu message; every read path for this message produces the same ID. */
declare const feishuTriggerId: (messageId: string) => string;
declare const withMentionNames: (text: string, mentions: {
  key?: string | undefined;
  name?: string | undefined;
}[]) => string;
/**
 * Parses a Feishu message timestamp into an ISO-8601 string: live events and the history API return epoch milliseconds as a
 * string, whereas topic/thread pages return a local timestamp string such as `2026-09-11 12:00`.
 */
declare function feishuTime(value: string): string;
/** Converts a normalized Feishu event into a Trigger, returning undefined for messages sent by the bot itself. */
declare function feishuTrigger(input: unknown, botId: string, botAppId: string): Trigger | undefined;
declare function feishuRef(trigger: Trigger): FeishuRef | undefined;
/** A message from the history API; a deleted message may have no body/content. */
declare const HistoricalMessageSchema: z.ZodObject<{
  message_id: z.ZodString;
  chat_id: z.ZodString;
  create_time: z.ZodString;
  root_id: z.ZodOptional<z.ZodString>;
  parent_id: z.ZodOptional<z.ZodString>;
  thread_id: z.ZodOptional<z.ZodString>;
  deleted: z.ZodOptional<z.ZodBoolean>;
  message_app_link: z.ZodOptional<z.ZodString>;
  sender: z.ZodObject<{
    id: z.ZodDefault<z.ZodString>;
    sender_type: z.ZodString;
  }, z.core.$loose>;
  body: z.ZodOptional<z.ZodObject<{
    content: z.ZodString;
  }, z.core.$loose>>;
  mentions: z.ZodOptional<z.ZodArray<z.ZodObject<{
    id: z.ZodString;
    key: z.ZodOptional<z.ZodString>;
    name: z.ZodOptional<z.ZodString>;
  }, z.core.$loose>>>;
}, z.core.$loose>;
type HistoricalMessage = z.infer<typeof HistoricalMessageSchema>;
declare function historyEvent(message: HistoricalMessage, chatId: string, direct: boolean): unknown;
//#endregion
//#region src/sources/feishu-loops.d.ts
/** Wait before restarting the event consumer: 1s after a run that stayed up for a minute, otherwise exponential backoff up to 60s. */
declare const consumerRetry: (previous: number | undefined, ranMs: number) => number;
/** Refreshes the map of joined chats (`chat_id -> name`); throws on failure so the previously stored list remains intact. */
declare function refreshChatNames(ctx: SourceContext, signal?: AbortSignal): Promise<Record<string, string>>;
/**
 * Backfills chat messages and active topic replies between `since` and `until` before the caller advances the chat cursor.
 * Topics are stored as `{ id: lastSeenAt }`, and unsubscribed topics older than the polling horizon are pruned.
 */
declare function backfillChat(ctx: SourceContext, chatId: string, direct: boolean, since: string, until: string, signal: AbortSignal, tally?: Tally): Promise<void>;
/** Resolves the retained source message reference for polling a subscribed thread. */
declare function threadRef(ctx: SourceContext, thread: Thread): FeishuRef | undefined;
/** Polls subscribed Feishu threads within the polling horizon so replies missed by the live stream become triggers. */
declare function pollThreads(ctx: SourceContext, signal?: AbortSignal, tally?: Tally): Promise<void>;
//#endregion
//#region src/sources/feishu.d.ts
declare const FeishuConfigSchema: z.ZodObject<{
  cli: z.ZodDefault<z.ZodString>;
  readPageSize: z.ZodDefault<z.ZodNumber>;
  linkTimeoutMs: z.ZodDefault<z.ZodNumber>;
  chats: z.ZodDefault<z.ZodArray<z.ZodObject<{
    chatId: z.ZodString;
    name: z.ZodOptional<z.ZodString>;
    listen: z.ZodEnum<{
      mentions: "mentions";
      all: "all";
    }>;
  }, z.core.$strict>>>;
  directMessages: z.ZodDefault<z.ZodBoolean>;
  otherChats: z.ZodDefault<z.ZodEnum<{
    mentions: "mentions";
    none: "none";
  }>>;
}, z.core.$strict>;
type FeishuConfig = z.infer<typeof FeishuConfigSchema>;
declare const feishuKind: SourceKind<FeishuConfig>;
/** Returns the Feishu Source's settings, falling back to schema defaults while the Feishu plugin is disabled. */
declare const feishuSettings: (sources: SourceRegistry) => FeishuConfig;
declare const name = "dsh-superagent-feishu";
declare const inject: string[];
declare function apply(ctx: Context): void;
//#endregion
export { FeishuConfig, type FeishuEvent, SOURCE, apply, backfillChat, consumerRetry, feishuKind, feishuRef, feishuSettings, feishuThreadId, feishuTime, feishuTrigger, feishuTriggerId, historyEvent, inject, name, pollThreads, refreshChatNames, threadRef, withMentionNames };