import { $ as settled, A as MandateBasis, B as TicketEndBy, C as Decision, D as Follow, E as Execution, F as Thread, G as followupOwners, H as TicketOutcome, I as ThreadFact, J as latestReport, K as isoTime, L as ThreadFacts, M as ReportState, N as Strength, O as FollowupRecords, P as Text, Q as runningAssignment, R as ThreadRef, S as ChannelRef, T as Evaluation, U as Trigger, V as TicketInput, W as TriggerDisposition, X as reached, Y as liveTicket, Z as readUntil, _ as ActorRef, a as DomainEvent, at as ReasonCode, b as AssignmentState, c as GateResult, ct as Config, d as Policy, et as threadKey, f as ReplyStatus, g as AcceptMode, h as SourceScope, i as Candidate, it as Reason, j as PolicyEffect, k as Mandate, l as OutboundMessage, lt as Deployment, m as ScopeResult, n as AssessmentOutcome, nt as waitsForPerson, o as DomainEvents, ot as reasonText, p as Repositories, q as latestAssignment, r as Assessor, rt as REASONS, s as Executor, st as said, t as ReceiveResult, tt as ticketOutcome, u as Outbox, ut as DeploymentConfig, v as AdmissionCell, w as DecisionKind, x as Attention, y as Assignment, z as Ticket } from "./intake-Bcto_iUq.js";
import { Context } from "@deepseek-ai/cordis";
//#region src/core/part.d.ts
interface EngineOptions {
  repo: Repositories;
  policy: () => Policy;
  /** Decides whether a Source listens to a trigger; one it does not listen to is stored with a `filtered` disposition. */
  scope: SourceScope;
  assessor: Assessor;
  executor: Executor;
  outbox: Outbox;
  prepareTicket?: (ticket: Ticket, outcome: Extract<AssessmentOutcome, {
    kind: 'accept';
  }>) => Ticket;
  now?: () => string;
  emit?: (event: DomainEvent) => void;
}
//#endregion
//#region src/core/replies.d.ts
/**
 * A message for a Channel, by purpose: an Executor's acknowledgement of a person's request it works on, the answer to a
 * person's question once the worker reported it, the result of a ticket that is `ready`, `completed`, `merged`, or `dropped`,
 * or the ticket's current `question` for a person (`attention`). When `ticketId` is omitted, the ticket that `triggerId` reached is used.
 */
type ReplyRequest = {
  purpose: 'acknowledgement';
  ticketId: string;
  triggerId: string;
  text: string;
} | {
  purpose: 'answer' | 'result' | 'attention';
  ticketId?: string;
  triggerId?: string;
  question?: string;
  text: string;
};
/** A queued message: its id, whether it went out, and whether an earlier request had queued it already. */
interface Reply {
  id: string;
  status: ReplyStatus;
  reused: boolean;
}
//#endregion
//#region src/core/assignments.d.ts
/** What an Assignment reports: a worker's report, or the Executor's own (`waiting` after an idle turn, `failed` after an error). */
interface WorkerReport {
  state: ReportState;
  summary: string;
  /** Open question for a person: a string asks it, `null` clears an open one, and `undefined` keeps the current one. */
  question?: string | null;
  /** The person's message whose request raised the question; routes the question to the channel where it was written. */
  askedBy?: string;
  /** The person's question this report answers, which the worker thereby takes up; authorizes the main Session to send an answer reply. */
  answers?: string;
}
//#endregion
//#region src/core/evals.d.ts
/** An outcome for the Eval that holds a Trigger; `evalId` names the Eval it was judged for, so a later Eval refuses it. */
type Outcome = AssessmentOutcome & {
  evalId?: string;
};
//#endregion
//#region src/core/engine.d.ts
/**
 * Single transactional entry point for mutating Triggers, Threads, Decisions, Tickets, and Assignments.
 * Coordinates Intake, Evals, Tickets, Assignments, and Replies inside synchronous repository transactions while queuing side
 * effects through ports. Callers receive role-scoped `Pick` interfaces rather than the full engine.
 */
declare class Engine {
  private readonly options;
  private readonly repo;
  private readonly replies;
  private readonly tickets;
  private readonly assignments;
  private readonly evals;
  private readonly intake;
  constructor(options: EngineOptions);
  /**
   * A Source's request to take in a Trigger: store it once, fan it out to the tickets that subscribe to its Threads (to an
   * ended one only a person's message, which resumes it at once unless processing is paused, and to none a person stopped),
   * and queue it for Eval on its primary Thread unless a ticket's worker decides it (see `followupOwners`).
   * Triggers that arrive while an Eval of that Thread runs wait together for the next one.
   */
  receive(trigger: Trigger): ReceiveResult;
  /**
   * A Source's request to make an open ticket follow one of its Threads, such as a pull request's, `own` when the ticket
   * opened it: the ticket subscribes to it, and a ready report ends it only once `followsDone` holds (see `Tickets.followsDone`).
   * @throws UserError when the ticket is unknown or has ended.
   */
  bindThread(ticketId: string, thread: ThreadRef, own: boolean): Ticket;
  /**
   * A Source's fact that a Thread closed, such as its pull request's merge, at the time it happened. An open ticket that
   * follows it ends once it is done with the Threads it follows, unless work resumed since the close has not finished, or
   * its worker took up a person's message the ticket decides after its latest report.
   */
  threadClosed(thread: ThreadRef, outcome: 'merged' | 'closed', at: string): void;
  /**
   * Requeues overdue Evals up to `REQUEUES` times before recording `unavailable` (undelivered Evals never expire), starts the
   * Evals of Threads whose queued Triggers wait, and resumes ended tickets a person's message reached while processing was
   * paused. While processing is paused, nothing expires: each Eval in progress notes when the pause began, and its deadline
   * moves forward by the pause's length once processing resumes. Each Eval and each ticket update takes one transaction.
   */
  evaluateDue(): void;
  /** The candidate of the Eval that holds a Trigger, as its assessor sees it; undefined while no Eval holds it. */
  candidate(triggerId: string): Candidate | undefined;
  /**
   * Decide a Trigger: the Eval that holds it, or a direct Eval of it alone when none does, such as a person's explicit
   * request the main Session routes. A proactive candidate is accepted only in `auto` mode with enabled rules its assessment
   * matched, and a Trigger that already started a ticket returns that ticket's Decision. An invalid stop is recorded as
   * `ignore`; one judged under an older Policy as `unavailable`.
   * @throws UserError when the Trigger is unknown or not admissible, `outcome.evalId` names an Eval that has finished, a
   * ticket's worker still decides the Trigger and the outcome is not a stop, or an inferred candidate is accepted outside `auto`
   * mode or without enabled matching rules.
   */
  decide(triggerId: string, outcome: Outcome): Decision;
  /**
   * Attach a Trigger to a ticket that the message points at: the ticket follows the Trigger's Threads and receives it as an
   * Input with the routing note, and the Eval that holds the Trigger ends, since the ticket has it now; the other Triggers of
   * its batch wait for a fresh Eval. A note for an Input the worker already received goes out as a new Input, and so does a
   * message the ticket let go, read for context only, or had before it ended. An ended ticket resumes under its Mandate, at
   * once unless processing is paused.
   * @throws UserError for a ticket a person stopped, which withdrew its Mandate, or one whose Mandate the Policy no longer holds.
   */
  attach(ticketId: string, triggerId: string, note?: string, replyToSender?: string): Ticket;
  /**
   * Ask a running worker that waits in `waiting` state for its status; any other worker is left alone.
   * @returns whether the worker was asked.
   * @throws UserError when the ticket is unknown.
   */
  requestStatus(ticketId: string): boolean;
  /**
   * Queue a message for the Channel its purpose names: an acknowledgement or an answer goes where the person's message was
   * written, attention where the message that raised the question was, else, like a result, to the conversation the ticket
   * started in. A message queued before is not queued again (see `Replies.reply`).
   * @throws UserError when the ticket or trigger is unknown or the purpose's rule refuses it, such as a result of a ticket that
   * is not ready, completed, merged, or dropped.
   */
  reply(request: ReplyRequest): Reply;
  /** The assessor delivered an Eval's candidate to its Session: the Eval's deadline counts from now. */
  candidateDelivered(evalId: string): void;
  /**
   * Queue a stored Trigger for a fresh Eval, such as a person's replay; returns false while an Eval holds it.
   * @throws UserError when the trigger is unknown.
   */
  reevaluate(triggerId: string): boolean;
  /**
   * A person dismisses the problem an unavailable Decision shows: the overview lists it no more.
   * @throws UserError for a Decision that is unknown or not unavailable.
   */
  dismiss(decisionId: string): Decision;
  /**
   * Drop every ticket's Subscription to a Thread, until a new Decision subscribes one again.
   * @returns whether a Subscription was dropped.
   */
  unsubscribe(thread: string): boolean;
  /**
   * A person stops a ticket, which withdraws its Mandate: it ends and receives nothing more.
   * @throws UserError when the ticket is unknown.
   */
  stopTicket(ticketId: string, reason?: string): Ticket;
  /**
   * A person retries a ticket whose worker reported failed or blocked (or whose input delivery failed): the stalled
   * Assignment ends and a new one starts under the same Mandate.
   * @throws UserError when the ticket is unknown, has ended, or is not retryable.
   */
  retryTicket(ticketId: string): Ticket;
  /**
   * The Executor's fact that an Assignment runs; the Inputs that wait for it go out.
   * @throws UserError when the ticket is unknown.
   */
  assignmentStarted(ticketId: string, assignmentId: string): void;
  /**
   * The Executor's fact that Inputs reached the Assignment that runs the ticket, which clears a failed delivery. A fact about
   * an Assignment that no longer runs is dropped. Its worker reads each once its Session takes it into a step (`inputsRead`).
   */
  inputsDelivered(ticketId: string, assignmentId: string, inputIds: string[]): void;
  /**
   * The Executor's fact that the worker's Session of an open ticket took the messages that carried Inputs into a step, from
   * which its model reads them: a report or the end of a turn after that counts them as read at the ticket's end.
   * @throws UserError when the ticket is unknown.
   */
  inputsRead(ticketId: string, inputIds: string[]): void;
  /** The Executor's fact that a turn of the worker of the Assignment that runs the ticket ended, after a report too. */
  turnEnded(ticketId: string, assignmentId: string): void;
  /** The Executor's fact that delivering Inputs to the Assignment that runs the ticket failed; the ticket shows it until a delivery succeeds. */
  deliveryFailed(ticketId: string, assignmentId: string, error: string): void;
  /**
   * A worker's request, through its Executor, to mark a Thread attached to its ticket unrelated, for `reason`: only that
   * ticket's Subscription drops, until a new Decision subscribes it again.
   * @throws UserError when the ticket is unknown, or for the Thread the ticket started on, one a Source bound it to (such as
   * its pull request's), or one it does not follow.
   */
  markUnrelated(ticketId: string, thread: string, reason: string): void;
  /**
   * An Executor's Subscription to a Thread it found related, for context: see `Tickets.followForContext` and `Thread.context`.
   * @returns false when the ticket already follows the Thread.
   * @throws UserError when the ticket is unknown or has ended.
   */
  followForContext(ticketId: string, thread: ThreadRef): boolean;
  /**
   * A fact the main Session gives an open ticket's Executor: see `Tickets.note`.
   * @throws UserError when the ticket is unknown or has ended.
   */
  note(ticketId: string, text: string): Ticket;
  /**
   * An Executor's hand-back of a message that reached its ticket but asks for more than it: see `Evals.handback`.
   * @returns whether it was queued for Eval: false while another ticket still decides it, and for one this ticket did not decide (see `Evals.handback`).
   * @throws UserError when the ticket or trigger is unknown, the trigger did not reach the ticket, or the ticket already handed it back.
   */
  handback(ticketId: string, triggerId: string, reason: string): boolean;
  /**
   * Record a report on an open ticket's current Assignment. Its question for a person (`attention`) is asked, kept, or
   * cleared (`null` or a `ready` report), and a replaced attention question whose reply has not been sent yet is withdrawn
   * from the outbox. A `blocked` or `failed` report holds back automated inputs until a human message arrives. A `dropped`
   * report ends the ticket, and a `ready` report ends it: `completed` without followed Threads, else with the `followsDone`
   * outcome once `followsDone` holds.
   * @throws UserError for an unknown or ended ticket, an ended assignment, a question that comes with a ready result or an
   * answer, or a question or answer that names a message that is not a person's or did not reach the ticket.
   */
  report(ticketId: string, report: WorkerReport): Ticket;
  /**
   * Handles an assignment that was running when the host stopped: restarts it with a recovery note unless its latest report is
   * `waiting`, `ready`, `blocked`, or `failed` and no Input reached its worker after that report, in which case it keeps its
   * Session and state and gets the Inputs that wait for it.
   */
  assignmentInterrupted(ticketId: string, assignmentId: string): void;
  /**
   * The Policy changed: each open ticket in `effects` is told how the change bears on it, and Evals in progress start again
   * under the new version.
   */
  policyChanged(from: string, to: string, effects?: ReadonlyMap<string, PolicyEffect>): void;
}
/** What Sources ask and tell the Engine. */
type EngineForSources = Pick<Engine, 'receive' | 'bindThread' | 'threadClosed'>;
/** What the main Session asks of the Engine. */
type EngineForMainSession = Pick<Engine, 'candidate' | 'candidateDelivered' | 'decide' | 'attach' | 'reply' | 'requestStatus' | 'note'>;
/** What people ask of the Engine, through the panel or the main Session. */
type EngineForPeople = Pick<Engine, 'stopTicket' | 'retryTicket' | 'reevaluate' | 'unsubscribe' | 'dismiss'>;
/** What Settings tells the Engine. */
type EngineForSettings = Pick<Engine, 'policyChanged'>;
/** What the Executor tells the Engine, and what its workers ask of it. */
type EngineForExecutor = Pick<Engine, 'assignmentStarted' | 'inputsDelivered' | 'inputsRead' | 'turnEnded' | 'deliveryFailed' | 'assignmentInterrupted' | 'report' | 'markUnrelated' | 'handback' | 'followForContext' | 'reply'>;
//#endregion
//#region src/core/errors.d.ts
/** User-facing error codes mapped to their category ('missing' or 'refused') and English message template. */
declare const USER_ERRORS: {
  readonly unknownTicket: readonly ["missing", "Unknown ticket"];
  readonly unknownProblem: readonly ["missing", "Unavailable Eval not found"];
  readonly unknownTrigger: readonly ["missing", "Unknown trigger"];
  readonly unknownAssignment: readonly ["missing", "Unknown assignment"];
  readonly unknownBlock: readonly ["missing", "Unknown settings block: {block}"];
  readonly unknownPromptRevision: readonly ["missing", "Unknown prompt revision {revision}"];
  readonly unknownPromptPart: readonly ["refused", "Unknown built-in prompt part {part}"];
  readonly ticketEnded: readonly ["refused", "Ticket has ended"];
  readonly assignmentEnded: readonly ["refused", "Assignment has ended; a newer assignment owns this ticket"];
  readonly evalFinished: readonly ["refused", "Eval {eval} has finished or a later eval replaced it; decide the trigger's current eval"];
  readonly notAdmissible: readonly ["refused", "Trigger is not admissible: {reason}"];
  readonly notExplicit: readonly ["refused", "An accept through orchestrator_route is for explicit requests from allowed senders; assess proactive candidates with orchestrator_eval and orchestrator_eval_decide"];
  readonly ticketStopped: readonly ["refused", "A person stopped this ticket; new work needs an accept through orchestrator_route"];
  readonly mandateRevoked: readonly ["refused", "The current policy no longer holds this ticket's mandate; new work needs an accept through orchestrator_route"];
  readonly notRetryable: readonly ["refused", "Only an open ticket can be retried, and only when its worker last reported failed or blocked and no person has sent a message since, or when delivering an Input to its worker failed"];
  readonly sourceThread: readonly ["refused", "This is the thread the ticket started on; it stays subscribed"];
  readonly followedThread: readonly ["refused", "This thread is the ticket's own, such as its pull request's; it stays subscribed"];
  readonly notFollowing: readonly ["refused", "This ticket does not follow that thread"];
  readonly questionWithResult: readonly ["refused", "A question for a person cannot also be a ready result or an answer; report it separately"];
  readonly askerWithoutQuestion: readonly ["refused", "The message that raised a question needs the question it raised"];
  readonly notAsker: readonly ["refused", "A question must name the person's message that raised it, which reached this ticket"];
  readonly notAnswerable: readonly ["refused", "An answer must name the person's question it answers, which reached this ticket"];
  readonly ackEnded: readonly ["refused", "Ticket ended; do not acknowledge historical requests"];
  readonly notReached: readonly ["refused", "Trigger does not belong to this worker"];
  readonly handedBack: readonly ["refused", "This ticket handed that trigger back already"];
  readonly handedBackHere: readonly ["refused", "The worker of this ticket handed that trigger back as beyond it: accept it as new work, attach it to another ticket, or ignore it"];
  readonly workerDecides: readonly ["refused", "This message reached ticket {tickets} on its thread: its worker decides whether it belongs there and hands back what does not, which then arrives as a candidate. Only a stop goes through orchestrator_route, with kind stop"];
  readonly ackNoChannel: readonly ["refused", "Acknowledgement requires an assigned human source message"];
  readonly ackNotPerson: readonly ["refused", "Use the original human trigger, not a bot, CI or worker report"];
  readonly notReady: readonly ["refused", "Ticket is not ready for delivery. Keep progress internal and wait for a verified ready report; do not relabel progress as an answer or send it through another channel."];
  readonly notAttention: readonly ["refused", "Attention requires the ticket's current attention question in human_action. Routine unfinished work stays internal."];
  readonly notQuestion: readonly ["refused", "An answer must target the original human question, not a worker report or automated trigger"];
  readonly noAnswer: readonly ["refused", "No worker answer is ready for this human trigger. Wait for the worker's report, or request one with orchestrator_ticket_request_status, which acts only on a worker that reported waiting; ordinary progress cannot be relabelled as an answer."];
  readonly noChannel: readonly ["refused", "No reply channel for this ticket or trigger"];
  readonly panelOnlyEnvironment: readonly ["refused", "The execution environment (ticket directory, prepare command, blocked commands) can only be changed in the management panel"];
  readonly panelOnlyAccounts: readonly ["refused", "Source fields that setup reads, such as account CLIs, can only be changed in the management panel"];
  readonly setupComplete: readonly ["refused", "Setup is complete"];
  readonly modelUnavailable: readonly ["refused", "The {block} model is not available: {error}"];
  readonly promptTooLong: readonly ["refused", "Prompt configuration exceeds {limit} characters"];
  readonly promptPlaceholders: readonly ["refused", "The “{part}” template must keep {placeholders}, which the system fills in"];
  readonly promptPartEmpty: readonly ["refused", "The “{part}” part cannot be empty; reset it to follow its built-in text"];
  readonly sourceNotInstalled: readonly ["refused", "The {source} Source kind is not installed"];
  readonly noLabels: readonly ["refused", "This Source has no names to refresh"];
  readonly nothingToSync: readonly ["refused", "The {source} Source's part of the Policy has nothing to sync from, or the Source is off or waiting for setup"];
};
type UserErrorCode = keyof typeof USER_ERRORS;
/**
 * Structured error thrown by Engine parts and application services when a caller request is invalid or references missing state.
 * Tool handlers and HTTP routes inspect its code and missing flag to return appropriate status responses, while the web panel localizes the code.
 */
declare class UserError extends Error {
  readonly code: UserErrorCode;
  readonly values: Record<string, string>;
  readonly missing: boolean;
  constructor(code: UserErrorCode, values?: Record<string, string>);
}
//#endregion
//#region src/core/memory.d.ts
/**
 * In-memory implementation of the Repositories port backed by cloned Map entries so caller mutations do not affect stored state.
 * Provides snapshot-based atomic rollback and matches the ordering semantics of the SQLite store for Engine tests.
 */
declare class MemoryRepositories implements Repositories {
  private readonly triggerRows;
  private readonly dispositions;
  private readonly threadRows;
  private readonly ticketRows;
  private readonly decisionRows;
  atomic<T>(work: () => T): T;
  readonly triggers: {
    get: (id: string) => Trigger | undefined;
    save: (trigger: Trigger) => void;
    disposition: (id: string) => TriggerDisposition | undefined;
    saveDisposition: (id: string, value: TriggerDisposition) => void;
  };
  readonly threads: {
    get: (key: string) => Thread | undefined;
    save: (thread: Thread) => void;
    list: () => Thread[];
    active: () => Thread[];
  };
  readonly tickets: {
    get: (id: string) => Ticket | undefined;
    save: (ticket: Ticket) => void;
    /** Newest first, matching the SQLite Store's order. */
    list: () => Ticket[];
    open: () => Ticket[];
    active: () => Ticket[];
  };
  readonly decisions: {
    get: (id: string) => Decision | undefined;
    save: (decision: Decision) => void;
    byThread: (key: string) => Decision[];
  };
}
//#endregion
//#region src/core/stage.d.ts
/** High-level execution stage of a ticket: waiting on a person, actively working or queued, idle between turns, or ended. */
type TicketStage = {
  stage: 'person';
  action: 'delivery' | 'answer' | 'review' | 'blocked' | 'failed';
} | {
  stage: 'working';
  action?: 'queued';
} | {
  stage: 'idle';
} | {
  stage: 'ended';
};
/** Classifies a ticket's stage; the rules follow the table in docs/003 in order, where the first matching row wins. */
declare function ticketStage(ticket: Ticket): TicketStage;
/** True when an open ticket is stalled on a blocked/failed report without a newer human follow-up, or has a failed input delivery. */
declare function canRetry(ticket: Ticket): boolean;
//#endregion
//#region src/core/ids.d.ts
declare function key(...values: string[]): string;
//#endregion
//#region src/index.d.ts
declare const name = "dsh-superagent";
declare const inject: string[];
declare function apply(ctx: Context, config: DeploymentConfig): Promise<void>;
//#endregion
export { AcceptMode, ActorRef, AdmissionCell, AssessmentOutcome, Assessor, Assignment, AssignmentState, Attention, Candidate, ChannelRef, Config, Decision, DecisionKind, type Deployment, type DeploymentConfig, DomainEvent, DomainEvents, Engine, type EngineForExecutor, type EngineForMainSession, type EngineForPeople, type EngineForSettings, type EngineForSources, type EngineOptions, Evaluation, Execution, Executor, Follow, FollowupRecords, GateResult, Mandate, MandateBasis, MemoryRepositories, OutboundMessage, Outbox, type Outcome, Policy, PolicyEffect, REASONS, type Reason, type ReasonCode, type ReceiveResult, type Reply, type ReplyRequest, ReplyStatus, ReportState, Repositories, ScopeResult, SourceScope, Strength, Text, Thread, ThreadFact, ThreadFacts, ThreadRef, Ticket, TicketEndBy, TicketInput, TicketOutcome, type TicketStage, Trigger, TriggerDisposition, USER_ERRORS, UserError, type UserErrorCode, type WorkerReport, apply, canRetry, followupOwners, inject, isoTime, key, latestAssignment, latestReport, liveTicket, name, reached, readUntil, reasonText, runningAssignment, said, settled, threadKey, ticketOutcome, ticketStage, waitsForPerson };