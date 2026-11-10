import { U as Trigger, l as OutboundMessage } from "./intake-BntR4bhz.js";
import { _ as SourceRegistry, i as SourceContext, n as SourceKind, r as ThreadContext, t as ChannelLink } from "./kind-CBntL-Jz.js";
import { Context } from "@deepseek-ai/cordis";
import { z } from "zod";
//#region src/sources/momo.d.ts
declare const SOURCE = "momo";
declare const momoTriggerId: (messageId: string) => string;
declare const MomoStreamSchema: z.ZodEnum<{
  chat: "chat";
  transcripts: "transcripts";
  life_signals: "life_signals";
}>;
type MomoStream = z.infer<typeof MomoStreamSchema>;
declare const MomoConfigSchema: z.ZodObject<{
  bridgeUrl: z.ZodDefault<z.ZodString>;
  pollIntervalMs: z.ZodDefault<z.ZodNumber>;
  waitMs: z.ZodDefault<z.ZodNumber>;
  readPageSize: z.ZodDefault<z.ZodNumber>;
  chat: z.ZodDefault<z.ZodBoolean>;
  transcripts: z.ZodDefault<z.ZodEnum<{
    none: "none";
    all: "all";
  }>>;
  lifeSignals: z.ZodDefault<z.ZodEnum<{
    none: "none";
    all: "all";
  }>>;
}, z.core.$strict>;
type MomoConfig = z.infer<typeof MomoConfigSchema>;
declare const MomoBridgeEventSchema: z.ZodObject<{
  cursor: z.ZodString;
  id: z.ZodString;
  stream: z.ZodEnum<{
    chat: "chat";
    transcripts: "transcripts";
    life_signals: "life_signals";
  }>;
  thread_id: z.ZodString;
  actor_id: z.ZodString;
  actor_name: z.ZodOptional<z.ZodString>;
  human: z.ZodDefault<z.ZodBoolean>;
  addressed: z.ZodOptional<z.ZodEnum<{
    direct: "direct";
    mention: "mention";
  }>>;
  at: z.ZodString;
  text: z.ZodString;
  title: z.ZodOptional<z.ZodString>;
  source_id: z.ZodOptional<z.ZodString>;
  parent_id: z.ZodOptional<z.ZodString>;
  channel_id: z.ZodOptional<z.ZodString>;
  reply_allowed: z.ZodDefault<z.ZodBoolean>;
}, z.core.$loose>;
type MomoBridgeEvent = z.infer<typeof MomoBridgeEventSchema>;
/** Converts a MoMo bridge event into a normalized dsh-superagent Trigger. */
declare function momoTrigger(event: MomoBridgeEvent, bridgeUrl: string): Trigger;
/** Sends an outbound reply or acknowledgement back to MoMo's local conversation gateway idempotently by `message.id`. */
declare function sendMomo(host: Pick<SourceContext, 'commands'>, message: OutboundMessage): Promise<'sent' | 'gone'>;
declare function momoLink(address: Record<string, string>): ChannelLink;
declare const momoThreadContext: ThreadContext<MomoConfig>;
/** Ingests one batch of triggers from the local MoMo bridge and advances the durable cursor. */
declare function pollMomoOnce(ctx: SourceContext, config: MomoConfig, signal: AbortSignal): Promise<number>;
/** Background polling loop connecting `dsh-superagent` to the local MoMo runtime bridge. */
declare function runMomo(ctx: SourceContext, signal: AbortSignal): Promise<void>;
declare const momoKind: SourceKind<MomoConfig>;
/** Returns the MoMo Source's settings, falling back to schema defaults while the MoMo plugin is disabled. */
declare const momoSettings: (sources: SourceRegistry) => MomoConfig;
declare const name = "dsh-superagent-momo";
declare const inject: string[];
declare function apply(ctx: Context): void;
//#endregion
export { MomoBridgeEvent, MomoBridgeEventSchema, MomoConfig, MomoConfigSchema, MomoStream, MomoStreamSchema, SOURCE, apply, inject, momoKind, momoLink, momoSettings, momoThreadContext, momoTrigger, momoTriggerId, name, pollMomoOnce, runMomo, sendMomo };