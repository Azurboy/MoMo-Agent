import { Volatile } from "@deepseek-ai/cordis";
import { z } from "zod";
import s from "@deepseek-ai/schemastery";
import "@deepseek-ai/dsh-subprocess";
//#region src/deployment.d.ts
/** Plugin configuration of the dsh-superagent entry. Volatile fields apply without a restart because dsh-superagent reads them on each use; changing `stateDir` remounts the plugin. */
declare const Config: s<Schemastery.ObjectS<NoInfer<{
  stateDir: s<string, string, "defined">;
  promptMaxChars: s<number, number, "volatile-defined">;
  admissionContextMaxPages: s<number, number, "volatile-defined">;
  admissionContextTimeoutMs: s<number, number, "volatile-defined">;
}>>, Schemastery.ObjectT<NoInfer<{
  stateDir: s<string, string, "defined">;
  promptMaxChars: s<number, number, "volatile-defined">;
  admissionContextMaxPages: s<number, number, "volatile-defined">;
  admissionContextTimeoutMs: s<number, number, "volatile-defined">;
}>>, "plain">;
type DeploymentConfig = ReturnType<typeof Config>;
interface Machine {
  stateDir: string;
  promptMaxChars: Volatile<number>;
  admissionContextMaxPages: Volatile<number>;
  admissionContextTimeoutMs: Volatile<number>;
}
interface Deployment extends Machine {
  repository: string;
  github: {
    cli: string;
    login: string;
    noreply: string;
  };
  feishu?: FeishuBot;
}
interface FeishuBot {
  cli: string;
  appId: string;
  brand: 'feishu' | 'lark';
  botId: string;
  name: string;
}
//#endregion
//#region src/core/reasons.d.ts
/**
 * Structured reason codes and templates for decisions, filtered triggers, and ended assignments.
 * Policy gates and source scopes may also emit their own literal reason codes.
 */
declare const REASONS: {
  readonly said: "{text}";
  readonly timeout: "Assessment timed out";
  readonly policyChanged: "Policy changed during assessment";
  readonly noAdmissible: "No admissible trigger";
  readonly startedTicket: "Already started ticket {ticket}";
  readonly acceptedBefore: "Trigger {trigger} was accepted before";
  readonly routed: "Routed to ticket {ticket}";
  readonly explicitRouted: "Explicit request from an allowed sender routed by the orchestrator";
  readonly humanStop: "Human asked to stop";
  readonly legacyImport: "Imported from the pre-domain-model task record";
  readonly forwarded: "Forwarded to the worker of the Ticket already on this Thread";
  readonly senderNotMember: "The sender is not on the Source's list";
  readonly retried: "Retried by a person";
  readonly hostRestarted: "dsh-superagent restarted";
  readonly stopUnknown: "Stop target is unknown or already ended";
  readonly stopNotExplicit: "A stop needs an explicit request from a sender on the list";
  readonly directionUnsettled: "Implementation intent or target direction is not established, or a product/design decision is still required";
  readonly noRuleMatched: "No enabled admission rule matched";
  readonly ignoredFromCard: "Ignored from its card, without a rule assessment";
  readonly observed: "Observe mode: would accept ({text})";
};
type ReasonCode = keyof typeof REASONS;
/** Reason code and template values; `triggerId` identifies the trigger in a batch that the reason applies to. */
interface Reason {
  code: ReasonCode | (string & {});
  values?: Record<string, string>;
  triggerId?: string;
}
declare const said: (text: string) => Reason;
/** Formats reasons in English (prefixed by `triggerId` when present) for agent consumption. */
declare function reasonText(reasons: readonly Reason[] | Reason | undefined): string;
//#endregion
//#region src/core/model.d.ts
/** Actor identity in the source's own vocabulary; Policy decides which actors may originate work on that Source. */
interface ActorRef {
  source: string;
  id: string;
}
/** Thread identity; the rule that derives `id` from a native event belongs to the source. */
interface ThreadRef {
  source: string;
  id: string;
}
/** Write-only address on a thread; the address format belongs to the source. */
interface ChannelRef {
  source: string;
  thread: string;
  address: Record<string, string>;
}
/** Stable key of a thread across the whole domain. */
declare const threadKey: (ref: ThreadRef) => string;
/**
 * Normalizes valid timestamps to `Date#toISOString` form so stored timestamps compare lexicographically in memory and SQL;
 * values that do not parse as a timestamp are returned unchanged.
 */
declare function isoTime(value: string): string;
/** One immutable event produced by a source. `text` and `meta` are untrusted external data. */
interface Trigger {
  id: string;
  source: string;
  /** Every thread the trigger belongs to; the first (`threads[0]`) is the primary thread that hosts its evaluation. */
  threads: ThreadRef[];
  actor: ActorRef;
  /** Source-declared: the event was written by a person rather than a bot, CI, or this agent. */
  human: boolean;
  /** Source-declared: the sender addressed the agent, by mentioning it or in a direct message to it. */
  addressed?: 'mention' | 'direct';
  at: string;
  text: string;
  channel?: ChannelRef;
  url?: string;
  /** Source-native details for adapters; the core never interprets them. */
  meta: Record<string, unknown>;
}
/** Where a trigger went after intake; it grants nothing, but decides who decides a person's follow-up (see `followupOwners`). */
interface TriggerDisposition {
  /** Rejected by the source scope filter before entering the domain, for the Source's reason. */
  filtered?: Reason;
  evalId?: string;
  decisionId?: string;
  /**
   * The tickets it reached, by subscription fan-out or attached by the main Session; a ticket that ended or could not resume
   * without its worker taking it up no longer counts.
   */
  fanout: string[];
  /** The tickets of `fanout` it reached only on a Thread their Executor follows for context, which makes it none of theirs. */
  context?: string[];
  /** A person, or the main Session for a message no ticket decides, sent it to Eval again; a hand-back does not set it. */
  requeued?: true;
  /** The tickets whose Executor handed it back as beyond the ticket, each once, with why; it goes to Eval once none decides it. */
  handbacks?: {
    ticketId: string;
    reason: string;
    at: string;
  }[];
  /** The tickets whose Executor acknowledged it or answered it, taking it up as within the ticket. */
  acked?: string[];
  at: string;
}
/** What deciding a follow-up's owners reads: the stored tickets, Threads and dispositions, as the Store and the core keep them. */
interface FollowupRecords {
  tickets: {
    get(id: string): Ticket | undefined;
  };
  threads: {
    get(key: string): Thread | undefined;
  };
  triggers: {
    disposition(id: string): TriggerDisposition | undefined;
  };
}
/**
 * The tickets whose worker decides a person's follow-up: those it reached on their own Threads that can still decide it
 * and did not hand it back. A ticket can while it is live, also once a person dropped its Subscription to the Thread, and
 * while it is ended, not by a person, with the Trigger waiting to resume it. None once a person sent it to Eval, or while
 * an Eval holds it, which an earlier version may have queued. While a ticket owns it, the message goes to no Eval, and the
 * main Session may only stop the work on it.
 */
declare function followupOwners(trigger: Pick<Trigger, 'id' | 'human' | 'threads'>, records: FollowupRecords): string[];
/**
 * Whether a Decision settled what a person's message asks for: a stop on it, taken or refused, decides only that ticket's
 * work, routing it to a ticket leaves it to that ticket's worker, and an unavailable one decided nothing.
 */
declare const settled: (decision: Pick<Decision, "kind" | "reason">) => boolean;
type Strength = 'explicit' | 'inferred';
/** The cells of a receiving scope's row in the admission table, by whether the sender is listed and addresses the agent. */
type AdmissionCell = 'listedUnaddressed' | 'unlistedAddressed' | 'unlistedUnaddressed';
/**
 * Whether proactive candidates are assessed and accepted (`auto`), still assessed so Decisions record what they would accept
 * (`would_accept`) without accepting (`observe`), or not admitted (`off`).
 */
type AcceptMode = 'off' | 'observe' | 'auto';
/** Where a Mandate's Trigger was received: its Source, its receiving scope as the Source recorded it, and its admission row. */
interface Received {
  source?: string;
  scope?: Record<string, unknown>;
  row?: string;
}
/**
 * How the gate admitted the Trigger a Mandate came from, which `revalidate` re-checks (see `docs/002`):
 * - `addressed`: a sender on the Source's list addressed the agent;
 * - `followup`: a message on a Thread that has tickets;
 * - `admission`: the cell of the receiving scope's admission row; `observation` when it made an inferred candidate under
 *   an accept mode;
 * - `listed`: accepted before Mandates recorded their basis, from a sender who must still be on the list; `authority` is
 *   what an earlier version recorded instead.
 * `sender` names the allowed sender at acceptance time, and `rules` the rules an assessment matched.
 */
type MandateBasis = Received & {
  sender?: string;
  rules?: string[];
} & ({
  via: 'addressed';
  addressed: 'mention' | 'direct';
} | {
  via: 'followup';
  authority?: string;
} | {
  via: 'admission';
  cell: AdmissionCell;
  addressed?: 'mention' | 'direct';
  observation?: {
    mode: AcceptMode;
  };
} | {
  via: 'listed';
  addressed?: 'mention' | 'direct';
  observation?: {
    mode?: AcceptMode;
  };
  authority?: string;
} |
/** A message of a bot on its Source's bot list: an inferred candidate at most, never an explicit request or a stop. */
{
  via: 'bot';
  addressed?: 'mention' | 'direct';
  observation: {
    mode: AcceptMode;
  };
});
/** Immutable authorization produced by an accept decision; execution is bounded by it and it never changes. */
interface Mandate {
  strength: Strength;
  policyVersion: string;
  /** How the gate admitted it, for re-validation and audit. */
  basis: MandateBasis;
  actor: ActorRef;
  scope: string;
}
/** Active trigger evaluation on a thread; at most one exists per thread. */
interface Evaluation {
  id: string;
  threadKey: string;
  triggerIds: string[];
  /** The admissible Trigger that gave the batch its strength, which a ticket the Eval starts takes as its origin. */
  primary?: string;
  strength: Strength;
  /** Actor and gate basis of the strongest admissible trigger; they seed the mandate on accept. */
  actor: ActorRef;
  basis: MandateBasis;
  policyVersion: string;
  startedAt: string;
  /** Timestamp when the candidate reached the assessor's Session; it cannot expire before, and its deadline counts from then. */
  delivered?: string;
  /** Expiration timestamp, counted from delivery (or from start until delivered); a processing pause shifts it forward by the pause duration. */
  deadline: string;
  /** Timestamp when processing pause began; resuming shifts `deadline` forward by the pause duration; cleared on resume. */
  pausedAt?: string;
}
/** Thread aggregate: consistency boundary of eval, holder of subscriptions and decision history. */
interface Thread {
  key: string;
  ref: ThreadRef;
  createdAt: string;
  /** Time of the newest trigger on the thread. */
  lastAt?: string;
  /** Tickets subscribed to this thread; live ones receive every trigger as context through fan-out. */
  subscriptions: string[];
  /**
   * The subscribed tickets whose Executor follows the thread for read-only context, such as an Issue or another pull request
   * it found: its messages reach them, but grant nothing, and a person's message there resumes none of them that ended.
   */
  context?: string[];
  /** Keys of threads that shared a trigger with this one; context only. */
  correlated: string[];
  /** Triggers waiting for the next eval (debounce buffer). */
  pending: string[];
  evaluating?: Evaluation;
  /** How many Evals of its queued Triggers expired in a row, each of which queued them again; a Decision clears it. */
  expired?: number;
  /**
   * Source-native attributes needed by channels or readers (for example a Feishu thread id). Its Source may also describe
   * the thread for people: `label`, a display name, and `facts`, a {@link ThreadFacts} map.
   */
  meta: Record<string, unknown>;
}
/** Text in both interface languages, or the same text in both. */
type Text = string | {
  zh: string;
  en: string;
};
/** One fact a Source states about its thread, such as an issue number or a CI result; `problem` marks one that needs a person. */
interface ThreadFact {
  label?: Text;
  value: Text;
  problem?: true;
}
/** A thread's facts by id, ordered for display; each writer owns its fact ids. */
type ThreadFacts = Record<string, ThreadFact>;
type DecisionKind = 'ignore' | 'accept' | 'reopen' | 'stop' | 'unavailable';
/** Outcome of one eval, recorded on the thread. */
interface Decision {
  id: string;
  evalId: string;
  threadKey: string;
  triggerIds: string[];
  policyVersion: string;
  at: string;
  kind: DecisionKind;
  /** Why, by code: one reason, or one for each Trigger of the batch it concerns. */
  reason: Reason[];
  strength: Strength;
  ticketId?: string;
  mandate?: Mandate;
  /** Assessor-supplied audit data (rule assessments, direction, evidence). */
  audit?: Record<string, unknown>;
  /** A person dismissed the problem an unavailable Decision shows. */
  dismissed?: true;
}
type AssignmentState = 'pending' | 'running' | 'ended';
/**
 * What an Assignment reports: work is in progress (`progress`), its worker waits for a Trigger (`waiting`), a result is
 * ready (`ready`), a person must act to unblock or recover it (`blocked` or `failed`), or nothing is left to do (`dropped`).
 */
type ReportState = 'progress' | 'waiting' | 'ready' | 'blocked' | 'failed' | 'dropped';
/** Binding between a ticket and one executor instance. */
interface Assignment {
  id: string;
  state: AssignmentState;
  createdAt: string;
  startedAt?: string;
  endedAt?: string;
  endedReason?: string;
  report?: {
    state: ReportState;
    summary: string;
    at: string;
  };
  /** When Inputs last reached the worker; one at or after `report.at` means the worker has been busy with Inputs since that report. */
  deliveredAt?: string;
  /**
   * When a turn of its worker last ended with nothing left to run for it and nothing waiting for it: what its Session took
   * into a step before, the worker read.
   */
  idleAt?: string;
}
type TicketInput =
/** A Trigger on one of its Threads, or attached to it; `human` when a person wrote it. */
{
  id: string;
  kind: 'trigger';
  triggerId: string;
  at: string;
  note?: string;
  human?: true;
  /** It reached the ticket only on a Thread its Executor follows for context. */
  context?: true;
  /**
   * When the worker's Session took the message that carried it into a step, from which its model reads it; `null` while
   * it waits in the Session. One delivered before reads were recorded has none, and counts as read from `deliveredAt`.
   */
  readAt?: string | null;
  /** The Assignment it was last delivered to. */
  deliveredTo?: string;
  /** When an earlier version handed it to the worker. */
  deliveredAt?: string;
} |
/** The Policy changed in a way that bears on the ticket, as `effect` says; Inputs written before effects have none. */
{
  id: string;
  kind: 'policy-changed';
  from: string;
  to: string;
  at: string;
  effect?: PolicyEffect;
} |
/** A Decision reopened the ticket; written before ended tickets resumed on their own. */
{
  id: string;
  kind: 'reopen';
  decisionId: string;
  at: string;
} |
/** A human's message on one of its Threads resumed the ended ticket under its unchanged Mandate. */
{
  id: string;
  kind: 'resumed';
  triggerId: string;
  at: string;
} | {
  id: string;
  kind: 'text';
  text: string;
  at: string;
} |
/** A fact the main Session gave the ticket from other work: context, which asks for nothing and grants nothing. */
{
  id: string;
  kind: 'note';
  text: string;
  at: string;
};
/**
 * How a Policy change bears on a ticket: the rules it was accepted under that changed, with their instruction now, or no
 * longer apply; `proactive: false` once inferred work is no longer accepted, as when the accept mode leaves `auto`; and
 * `requesterAllowed: false` once the sender it is for, `requester`, a person or a bot, may no longer start work there.
 */
interface PolicyEffect {
  rules?: {
    id: string;
    name: string;
    change: 'changed' | 'disabled';
    instruction?: string;
  }[];
  proactive?: false;
  requesterAllowed?: false;
  requester?: ActorRef;
}
type TicketEndBy = 'executor' | 'human';
/** How a ticket ended: with its result, with its pull request merged or closed unmerged, with nothing to do, or stopped by a person. */
type TicketOutcome = 'completed' | 'merged' | 'closed' | 'dropped' | 'stopped';
/** A question for a person; `triggerId` is the human message that raised it, whose conversation it goes back to. */
interface Attention {
  id: string;
  question: string;
  triggerId?: string;
}
/** Ticket aggregate: an authorized work item with its assignments, channels, thread bindings, and inputs. */
interface Ticket {
  id: string;
  title: string;
  decisionId: string;
  mandate: Mandate;
  /** The Channels of the messages it was accepted from, which its replies go to. */
  channels: ChannelRef[];
  /** When, by whom, and how the ticket ended, with a person's or the host's reason beyond the outcome; an open ticket has none. */
  ended?: {
    at: string;
    by: TicketEndBy;
    outcome: TicketOutcome;
    reason?: string;
  };
  /** Open question for a person; cleared by the executor or when the ticket ends. */
  attention?: Attention;
  assignments: Assignment[];
  inputs: TicketInput[];
  /** Inputs not yet handed to a running assignment. */
  undelivered: string[];
  /**
   * Threads a Source made the ticket follow, such as its pull requests': a `ready` report ends the ticket only once
   * `followsDone` holds; the close that makes it hold ends the ticket with that outcome unless its work has not finished (see
   * `Tickets.unfinished`), and then its next `ready` or `dropped` report ends it.
   */
  follows?: Follow[];
  /** People's questions the worker answered, whose answers the main Session may send. */
  answers?: string[];
  createdAt: string;
  updatedAt: string;
  /** The Triggers it was accepted from: the one that started it, and the batch its Eval held. */
  origin: {
    triggerId: string;
    triggerIds: string[];
  };
  /** What its Executor chose: its short name, directory and assignment text. */
  execution?: Execution;
  /** The latest failed delivery of an Input to its worker, until a delivery succeeds. */
  delivery?: {
    error: string;
    at: string;
  };
}
/**
 * A Thread a ticket follows, by its key: `own` when the ticket opened it, such as its own pull request, and when and how it
 * closed. `followsDone` holds once no Thread of its own is open, or, when the ticket has no `own` Thread, once every followed
 * Thread closed; the ticket then ends unless its work has not finished (see `Tickets.unfinished`).
 */
interface Follow {
  thread: string;
  own: boolean;
  closed?: {
    at: string;
    outcome: 'merged' | 'closed';
  };
}
interface Execution {
  name: string;
  directory: string;
  assignment: string;
}
/** Whether a ticket is open: it has not ended. */
declare const liveTicket: (ticket: Pick<Ticket, "ended">) => boolean;
/** How a ticket ended. */
declare const ticketOutcome: (ticket: Pick<Ticket, "ended">) => TicketOutcome | undefined;
declare const runningAssignment: (ticket: Ticket) => Assignment | undefined;
/**
 * Whether a Trigger reached a ticket: it started the ticket, came to it as an Input, or is on a Thread the ticket subscribes
 * to; with `context` false, not a Thread the ticket follows only for context, where its worker may read but not write.
 */
declare function reached(ticket: Ticket, trigger: Trigger, thread: (key: string) => Thread | undefined, context?: boolean): boolean;
declare const latestAssignment: (ticket: Ticket) => Assignment | undefined;
/** The latest report any of a ticket's Assignments made, which is what the ticket last said. */
declare const latestReport: (ticket: Pick<Ticket, "assignments">) => Assignment["report"];
/**
 * Until when a ticket's worker had a turn to read what reached it: its latest report, but a progress report when `progress`
 * is false, or the end of its latest turn, whichever is later.
 */
declare function readUntil(ticket: Pick<Ticket, 'assignments'>, progress?: boolean): string;
/**
 * Whether a ticket waits for a person: its latest Assignment reported blocked or failed, and no person's message reached it
 * since. A later report that is neither, a person's message, or a retry, which starts a new Assignment, lifts it.
 */
declare function waitsForPerson(ticket: Ticket): boolean;
//#endregion
//#region src/core/ports.d.ts
/** Gate admission result: either inadmissible with a reason code, or admissible with strength and MandateBasis. */
type GateResult = {
  admissible: false;
  reason: string;
} | {
  admissible: true;
  strength: Strength;
  basis: MandateBasis;
};
/** Whether a Source receives a Trigger; `observed` when it also receives messages not addressed to the agent, and `row` the receiving scope the Policy's admission table names, such as a chat. */
type ScopeResult = {
  listened: true;
  observed: boolean;
  row?: string;
} | {
  listened: false;
  reason: string;
};
/** Source configuration as the domain sees it: listening scope per trigger or per recorded Mandate basis. */
interface SourceScope {
  scope(input: {
    source: string;
    meta: Record<string, unknown>;
  }): ScopeResult;
}
/** Versioned rules; `gate` decides who may originate work. Source scope is not part of Policy. */
interface Policy {
  version: string;
  paused: boolean;
  gate(trigger: Trigger, thread: Thread, tickets: Ticket[]): GateResult;
  /** Re-check a mandate's gate-layer basis under this policy, such as before an ended ticket resumes. */
  revalidate(mandate: Mandate): boolean;
  /** Whether an inferred candidate may be accepted on the rules its assessment matched: assessments accept, and each rule is enabled. */
  admitsInferred(rules: readonly string[]): boolean;
  /** How long an assessor may take before an eval is recorded as unavailable. */
  evalTimeoutMs: number;
}
/** What the assessor receives: bounded facts, never authority. */
interface Candidate {
  evalId: string;
  thread: Thread;
  triggers: Trigger[];
  strength: Strength;
  policyVersion: string;
  /** Every ticket on the thread, including ended ones, for duplicate judgement. */
  tickets: Ticket[];
}
type AssessmentOutcome = {
  kind: 'ignore';
  reason: string | Reason;
  audit?: Record<string, unknown>;
} | {
  kind: 'unavailable';
  reason: string | Reason;
  audit?: Record<string, unknown>;
} |
/** An accept: `rules` the assessment matched, `name` the ticket's requested short name, and `note` a routing note for its worker. */
{
  kind: 'accept';
  title: string;
  scope: string;
  reason: string | Reason;
  acknowledgement?: string;
  rules?: string[];
  audit?: Record<string, unknown>;
  name?: string;
  note?: string;
} | {
  kind: 'stop';
  ticketId: string;
  reason: string | Reason;
  audit?: Record<string, unknown>;
};
/** Semantic judgement. `request` queues the assessment, idempotently per `evalId`; the outcome returns through `Engine.decide`. */
interface Assessor {
  request(candidate: Candidate): void;
  /** Called whenever an eval ends, decided or not, so the assessor drops what it kept for it. */
  release?(evalId: string): void;
}
/**
 * Executes assignments; concurrency and workspace management are its own concern. The Engine calls it inside its
 * commands, so each method only queues work, which reports back through the Engine's callbacks.
 */
interface Executor {
  /** Queue a pending assignment for launch; reports back through `Engine.assignmentStarted` or a `failed` report. */
  start(ticket: Ticket, assignment: Assignment): void;
  /**
   * Queue delivery of the ticket's waiting Inputs to its running assignment; reports back through `Engine.inputsDelivered`
   * or `Engine.deliveryFailed`, and through `Engine.inputsRead` once its worker's Session takes them into a step.
   */
  deliver(ticket: Ticket, assignment: Assignment): void;
  /** End an assignment's work, such as cancelling its Session's turn; called after the ticket or assignment has already ended in the domain. */
  stop(ticket: Ticket, assignment: Assignment, reason: string): void;
}
/** A message for a Channel; `ticketId` names the Ticket it is for, when there is one. */
interface OutboundMessage {
  id: string;
  channel: ChannelRef;
  text: string;
  kind: 'acknowledgement' | 'reply' | 'notice';
  ticketId?: string;
  attentionId?: string;
}
/** A queued message waits (`pending`), went out (`sent`), or was dropped because its conversation can never receive it (`dropped`). */
type ReplyStatus = 'pending' | 'sent' | 'dropped';
/** The messages queued for Channels; the Engine queues them inside its commands, and a sender delivers them later. */
interface Outbox {
  /** Queue a message idempotently; an id queued before keeps its first message. */
  send(message: OutboundMessage): void;
  /** Whether a message was queued, and what became of it. */
  status(id: string): ReplyStatus | undefined;
  /** Withdraw a message that has not gone out. */
  withdraw(id: string): void;
}
/** What the Engine reports after a change, by event type. */
interface DomainEvents {
  'trigger.received': {
    triggerId: string;
    threads: string[];
  };
  'eval.started': {
    evalId: string;
    threadKey: string;
    triggerIds: string[];
    strength: Strength;
  };
  'decision.recorded': {
    decisionId: string;
    kind: DecisionKind;
    threadKey: string;
  };
  'ticket.created': {
    ticketId: string;
    decisionId: string;
    strength: Strength;
  };
  'ticket.resumed': {
    ticketId: string;
    triggerId: string;
  };
  'ticket.ended': {
    ticketId: string;
    by: TicketEndBy;
    outcome: TicketOutcome;
    reason?: string;
  };
  'assignment.started': {
    ticketId: string;
    assignmentId: string;
  };
  'assignment.ended': {
    ticketId: string;
    assignmentId: string;
    reason: string;
  };
  'thread.subscribed': {
    threadKey: string;
    ticketId: string;
  };
  /** A person dropped every ticket's Subscription, or a ticket's Executor its own, for `reason`. */
  'thread.unsubscribed': {
    threadKey: string;
    ticketId: string;
    by: 'person' | 'executor';
    reason?: string;
  };
  'trigger.requeued': {
    triggerId: string;
  };
  /** A person's follow-up that reached tickets and that an earlier version also queued for Eval left the queue. */
  'trigger.followup': {
    triggerId: string;
  };
  'policy.changed': {
    from: string;
    to: string;
  };
}
type DomainEvent = { [K in keyof DomainEvents]: {
  type: K;
  at: string;
  data: DomainEvents[K];
}; }[keyof DomainEvents];
/** Durable state. Every method is synchronous so `atomic` can wrap a unit of work. */
interface Repositories {
  atomic<T>(work: () => T): T;
  triggers: {
    get(id: string): Trigger | undefined;
    save(trigger: Trigger): void;
    disposition(id: string): TriggerDisposition | undefined;
    saveDisposition(id: string, value: TriggerDisposition): void;
  };
  threads: {
    get(key: string): Thread | undefined;
    save(thread: Thread): void;
    list(): Thread[];
    /** Threads with Triggers queued for Eval or an Eval in progress. */
    active(): Thread[];
  };
  tickets: {
    get(id: string): Ticket | undefined;
    save(ticket: Ticket): void;
    list(): Ticket[];
    open(): Ticket[];
    /** Tickets with undelivered Inputs or a pending or running Assignment, which is always the latest. */
    active(): Ticket[];
  };
  decisions: {
    get(id: string): Decision | undefined;
    save(decision: Decision): void;
    byThread(key: string): Decision[];
  };
}
//#endregion
//#region src/core/intake.d.ts
type ReceiveResult = 'stored' | 'duplicate' | 'filtered';
//#endregion
export { settled as $, MandateBasis as A, TicketEndBy as B, Decision as C, Follow as D, Execution as E, Thread as F, followupOwners as G, TicketOutcome as H, ThreadFact as I, latestReport as J, isoTime as K, ThreadFacts as L, ReportState as M, Strength as N, FollowupRecords as O, Text as P, runningAssignment as Q, ThreadRef as R, ChannelRef as S, Evaluation as T, Trigger as U, TicketInput as V, TriggerDisposition as W, reached as X, liveTicket as Y, readUntil as Z, ActorRef as _, DomainEvent as a, ReasonCode as at, AssignmentState as b, GateResult as c, Config as ct, Policy as d, threadKey as et, ReplyStatus as f, AcceptMode as g, SourceScope as h, Candidate as i, Reason as it, PolicyEffect as j, Mandate as k, OutboundMessage as l, Deployment as lt, ScopeResult as m, AssessmentOutcome as n, waitsForPerson as nt, DomainEvents as o, reasonText as ot, Repositories as p, latestAssignment as q, Assessor as r, REASONS as rt, Executor as s, said as st, ReceiveResult as t, ticketOutcome as tt, Outbox as u, DeploymentConfig as ut, AdmissionCell as v, DecisionKind as w, Attention as x, Assignment as y, Ticket as z };