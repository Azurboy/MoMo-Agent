import { _ as settled, b as waitsForPerson, c as wordCount, d as latestAssignment, f as latestReport, g as runningAssignment, h as readUntil, i as checkedImText, l as followupOwners, m as reached, n as health, p as liveTicket, s as sameName, t as KV, u as isoTime, v as threadKey, y as ticketOutcome } from "./kv-BKzBGVb4.js";
import { D as LIMITS, E as SetupError, O as key, S as writeEnvironment, _ as runAsWorker, b as withoutDirectory, d as resolveDeployment, f as resolveFeishuBot, g as applyEnvironment, h as agentVariables, l as SETUP_FIELDS, m as WORKER_COMMANDS, o as Config, p as workerProbe, u as machineOf, v as verifyDirectory, w as Commands, x as workerBin, y as verifyEnvironment } from "./poll-C_VP4DGT.js";
import { i as pullOf, m as readRepositoryPath, o as readPull, p as readGithub, r as pullEndNotices, t as claimPull } from "./github-pull-C3KAqERt.js";
import { b as feishuTriggerId, d as feishuChatLink, f as feishuRead, g as feishuRef, m as readFeishuLink, p as feishuReferences, r as feishuSettings } from "./feishu-DZfozmN4.js";
import { Service } from "@deepseek-ai/cordis";
import { chmodSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { lockSync } from "proper-lockfile";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import { mkdir, readFile, rmdir, stat } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { MessageId, ReasoningEffortId, freezeMessage } from "@deepseek-ai/dsh-llm";
import { scopeParentOf } from "@deepseek-ai/dsh-scope";
//#region src/core/errors.ts
/** User-facing error codes mapped to their category ('missing' or 'refused') and English message template. */
const USER_ERRORS = {
	unknownTicket: ["missing", "Unknown ticket"],
	unknownProblem: ["missing", "Unavailable Eval not found"],
	unknownTrigger: ["missing", "Unknown trigger"],
	unknownAssignment: ["missing", "Unknown assignment"],
	unknownBlock: ["missing", "Unknown settings block: {block}"],
	unknownPromptRevision: ["missing", "Unknown prompt revision {revision}"],
	unknownPromptPart: ["refused", "Unknown built-in prompt part {part}"],
	ticketEnded: ["refused", "Ticket has ended"],
	assignmentEnded: ["refused", "Assignment has ended; a newer assignment owns this ticket"],
	evalFinished: ["refused", "Eval {eval} has finished or a later eval replaced it; decide the trigger's current eval"],
	notAdmissible: ["refused", "Trigger is not admissible: {reason}"],
	notExplicit: ["refused", "An accept through orchestrator_route is for explicit requests from allowed senders; assess proactive candidates with orchestrator_eval and orchestrator_eval_decide"],
	ticketStopped: ["refused", "A person stopped this ticket; new work needs an accept through orchestrator_route"],
	mandateRevoked: ["refused", "The current policy no longer holds this ticket's mandate; new work needs an accept through orchestrator_route"],
	notRetryable: ["refused", "Only an open ticket can be retried, and only when its worker last reported failed or blocked and no person has sent a message since, or when delivering an Input to its worker failed"],
	sourceThread: ["refused", "This is the thread the ticket started on; it stays subscribed"],
	followedThread: ["refused", "This thread is the ticket's own, such as its pull request's; it stays subscribed"],
	notFollowing: ["refused", "This ticket does not follow that thread"],
	questionWithResult: ["refused", "A question for a person cannot also be a ready result or an answer; report it separately"],
	askerWithoutQuestion: ["refused", "The message that raised a question needs the question it raised"],
	notAsker: ["refused", "A question must name the person's message that raised it, which reached this ticket"],
	notAnswerable: ["refused", "An answer must name the person's question it answers, which reached this ticket"],
	ackEnded: ["refused", "Ticket ended; do not acknowledge historical requests"],
	notReached: ["refused", "Trigger does not belong to this worker"],
	handedBack: ["refused", "This ticket handed that trigger back already"],
	handedBackHere: ["refused", "The worker of this ticket handed that trigger back as beyond it: accept it as new work, attach it to another ticket, or ignore it"],
	workerDecides: ["refused", "This message reached ticket {tickets} on its thread: its worker decides whether it belongs there and hands back what does not, which then arrives as a candidate. Only a stop goes through orchestrator_route, with kind stop"],
	ackNoChannel: ["refused", "Acknowledgement requires an assigned human source message"],
	ackNotPerson: ["refused", "Use the original human trigger, not a bot, CI or worker report"],
	notReady: ["refused", "Ticket is not ready for delivery. Keep progress internal and wait for a verified ready report; do not relabel progress as an answer or send it through another channel."],
	notAttention: ["refused", "Attention requires the ticket's current attention question in human_action. Routine unfinished work stays internal."],
	notQuestion: ["refused", "An answer must target the original human question, not a worker report or automated trigger"],
	noAnswer: ["refused", "No worker answer is ready for this human trigger. Wait for the worker's report, or request one with orchestrator_ticket_request_status, which acts only on a worker that reported waiting; ordinary progress cannot be relabelled as an answer."],
	noChannel: ["refused", "No reply channel for this ticket or trigger"],
	panelOnlyEnvironment: ["refused", "The execution environment (ticket directory, prepare command, blocked commands) can only be changed in the management panel"],
	panelOnlyAccounts: ["refused", "Source fields that setup reads, such as account CLIs, can only be changed in the management panel"],
	setupComplete: ["refused", "Setup is complete"],
	modelUnavailable: ["refused", "The {block} model is not available: {error}"],
	promptTooLong: ["refused", "Prompt configuration exceeds {limit} characters"],
	promptPlaceholders: ["refused", "The “{part}” template must keep {placeholders}, which the system fills in"],
	promptPartEmpty: ["refused", "The “{part}” part cannot be empty; reset it to follow its built-in text"],
	sourceNotInstalled: ["refused", "The {source} Source kind is not installed"],
	noLabels: ["refused", "This Source has no names to refresh"],
	nothingToSync: ["refused", "The {source} Source's part of the Policy has nothing to sync from, or the Source is off or waiting for setup"]
};
/**
* Structured error thrown by Engine parts and application services when a caller request is invalid or references missing state.
* Tool handlers and HTTP routes inspect its code and missing flag to return appropriate status responses, while the web panel localizes the code.
*/
var UserError = class extends Error {
	code;
	values;
	missing;
	constructor(code, values = {}) {
		const [kind, text] = USER_ERRORS[code];
		super(text.replace(/\{(\w+)\}/g, (match, name) => values[name] ?? match));
		this.code = code;
		this.values = values;
		this.missing = kind === "missing";
	}
};
//#endregion
//#region src/core/part.ts
/** Shared base class and configuration for Engine domain parts. */
/**
* Base class for Intake, Evals, Tickets, Assignments, and Replies providing shared access to repositories, policy, clock, and event emission.
* Each subclass mutates its own domain aggregates and delegates cross-aggregate changes to sibling parts within the transaction opened by Engine.
*/
var EnginePart = class {
	options;
	repo;
	constructor(options) {
		this.options = options;
		this.repo = options.repo;
	}
	now() {
		return this.options.now?.() ?? (/* @__PURE__ */ new Date()).toISOString();
	}
	policy() {
		return this.options.policy();
	}
	/** The tickets whose worker decides a person's follow-up: see `followupOwners`. */
	owners(trigger) {
		return followupOwners(trigger, this.repo);
	}
	/** Refuse a main-Session routing of a follow-up a ticket's worker still decides. */
	leftToWorkers(trigger) {
		const owners = this.owners(trigger);
		if (owners.length) throw new UserError("workerDecides", { tickets: owners.join(", ") });
	}
	/**
	* Record that a ticket's worker hands back a Trigger that reached the ticket, with why, and queue it for Eval when the
	* ticket decided it and no other ticket still does. One the ticket did not decide, such as a bot's, one a person sent to
	* Eval or one on a Thread it follows for context, went to Eval without it.
	* @returns whether it was queued.
	*/
	handBack(ticketId, trigger, reason) {
		const decided = this.owners(trigger).includes(ticketId);
		const disposition = this.repo.triggers.disposition(trigger.id) ?? {
			fanout: [],
			at: this.now()
		};
		const handbacks = [...disposition.handbacks ?? [], {
			ticketId,
			reason,
			at: this.now()
		}];
		this.repo.triggers.saveDisposition(trigger.id, {
			...disposition,
			handbacks
		});
		return decided && !this.owners(trigger).length && this.queueForEval(trigger);
	}
	/** Record that a ticket's worker took a person's message up as within the ticket, by acknowledging or answering it. */
	takeUp(ticketId, triggerId) {
		const disposition = this.repo.triggers.disposition(triggerId);
		if (disposition && !disposition.acked?.includes(ticketId)) this.repo.triggers.saveDisposition(triggerId, {
			...disposition,
			acked: [...disposition.acked ?? [], ticketId]
		});
	}
	/** Queue a Trigger on its primary Thread for the next Eval, unless it waits there already or an Eval holds it. */
	queueForEval(trigger) {
		const primary = this.thread(trigger.threads[0]);
		if (primary.pending.includes(trigger.id) || primary.evaluating?.triggerIds.includes(trigger.id)) return false;
		primary.pending.push(trigger.id);
		this.repo.threads.save(primary);
		return true;
	}
	emit(type, data) {
		this.options.emit?.({
			type,
			at: this.now(),
			data
		});
	}
	require(ticketId) {
		const ticket = this.repo.tickets.get(ticketId);
		if (!ticket) throw new UserError("unknownTicket");
		return ticket;
	}
	/** Returns the stored Thread or an unsaved empty Thread aggregate. */
	thread(ref) {
		const k = threadKey(ref);
		return this.repo.threads.get(k) ?? {
			key: k,
			ref: {
				source: ref.source,
				id: ref.id
			},
			createdAt: this.now(),
			subscriptions: [],
			correlated: [],
			pending: [],
			meta: {}
		};
	}
	ticketsOnThread(thread) {
		return thread.subscriptions.flatMap((id) => {
			const ticket = this.repo.tickets.get(id);
			return ticket ? [ticket] : [];
		});
	}
	source(ticket) {
		return this.repo.triggers.get(ticket.origin.triggerId);
	}
	reaches(ticket, trigger, context = true) {
		return reached(ticket, trigger, (k) => this.repo.threads.get(k), context);
	}
};
//#endregion
//#region src/core/stage.ts
/** Ticket stage classification and retry eligibility (docs/003). */
/** Classifies a ticket's stage; the rules follow the table in docs/003 in order, where the first matching row wins. */
function ticketStage(ticket) {
	if (ticket.ended) return { stage: "ended" };
	if (ticket.delivery) return {
		stage: "person",
		action: "delivery"
	};
	if (ticket.attention) return {
		stage: "person",
		action: "answer"
	};
	const assignment = latestAssignment(ticket);
	const report = assignment?.report?.state;
	if (report === "ready") return {
		stage: "person",
		action: "review"
	};
	if ((report === "blocked" || report === "failed") && waitsForPerson(ticket)) return {
		stage: "person",
		action: report
	};
	if (!assignment || assignment.state === "pending") return {
		stage: "working",
		action: "queued"
	};
	if (report === "waiting" || assignment.state === "ended") return { stage: "idle" };
	return { stage: "working" };
}
/** True when an open ticket is stalled on a blocked/failed report without a newer human follow-up, or has a failed input delivery. */
function canRetry(ticket) {
	return !ticket.ended && (waitsForPerson(ticket) || !!ticket.delivery);
}
//#endregion
//#region src/core/tickets.ts
/** Tickets: their lifecycle from an accept to their end, their Subscriptions and their Inputs. */
const sameChannel = (a, b) => JSON.stringify(a) === JSON.stringify(b);
/** Whether an Input is a message no person wrote, such as CI's, a bot's, or the main Session's note. */
const automatic = (input) => input?.kind === "note" || input?.kind === "trigger" && !input.human;
/**
* Whether a ticket's worker read a Trigger Input before `until`, its latest report or turn end: its Session took the message
* into a step before then. One delivered before reads were recorded counts as read once it reached the worker by then.
*/
const readBefore = (input, until) => input.readAt === void 0 ? (input.deliveredAt && input.deliveredAt > input.at ? input.deliveredAt : input.at) <= until : !!input.readAt && input.readAt < until;
const STATUS_REQUEST = "Report the current ticket status with orchestrator_report. This is a status-only request: do not resume implementation or perform external actions.";
/**
* Manages each ticket's lifecycle: creates the ticket for an accept decision with its Mandate, Subscriptions, and first
* Assignment, binds and attaches Threads, adds Inputs, resumes, retries, restarts, and ends tickets, and drops Subscriptions.
* Coordinates with Replies for the acknowledgement an accept carries and with Executor to start, deliver to, and stop assignments.
* Intake, Evals, Assignments, and Engine delegate ticket and subscription mutations here.
*/
var Tickets = class extends EnginePart {
	replies;
	constructor(options, replies) {
		super(options);
		this.replies = replies;
	}
	/**
	* Create the ticket an accept decided, under `mandate`, with the Channels and Threads of the Eval's Triggers, its first
	* Assignment, and the acknowledgement the accept carries, and queue its launch. Its origin is the admissible Trigger that
	* gave the Eval its strength, or the Eval's last Trigger for an Eval recorded before `primary` existed.
	*/
	create(id, decisionId, mandate, evaluation, outcome, at) {
		const { triggerIds } = evaluation;
		const primary = this.repo.triggers.get(evaluation.primary ?? triggerIds.at(-1));
		const origin = {
			triggerId: primary?.id ?? triggerIds[0],
			triggerIds
		};
		let ticket = {
			id,
			title: outcome.title,
			decisionId,
			mandate,
			channels: [],
			assignments: [],
			inputs: [],
			undelivered: [],
			createdAt: at,
			updatedAt: at,
			origin
		};
		for (const triggerId of triggerIds) {
			const channel = this.repo.triggers.get(triggerId)?.channel;
			if (channel && !ticket.channels.some((item) => sameChannel(item, channel))) ticket.channels.push(channel);
		}
		ticket = this.options.prepareTicket?.(ticket, outcome) ?? ticket;
		const assignment = this.newAssignment(ticket);
		this.repo.tickets.save(ticket);
		for (const triggerId of triggerIds) for (const ref of this.repo.triggers.get(triggerId)?.threads ?? []) this.subscribe(id, ref);
		if (outcome.acknowledgement && primary) this.replies.acknowledgeAccepted(id, primary, outcome.acknowledgement);
		this.options.executor.start(this.require(id), assignment);
		this.emit("ticket.created", {
			ticketId: id,
			decisionId,
			strength: mandate.strength
		});
	}
	/**
	* Subscribes an open ticket to `thread` and records it in `ticket.follows` (`own` when opened by the ticket).
	* @throws UserError when the ticket is unknown or has ended.
	*/
	bind(ticketId, thread, own) {
		if (!liveTicket(this.require(ticketId))) throw new UserError("ticketEnded");
		this.subscribe(ticketId, thread);
		const ticket = this.require(ticketId);
		const followed = threadKey(thread);
		const follow = ticket.follows?.find((item) => item.thread === followed);
		if (follow) {
			follow.own ||= own;
			delete follow.closed;
		} else ticket.follows = [...ticket.follows ?? [], {
			thread: followed,
			own
		}];
		ticket.updatedAt = this.now();
		this.repo.tickets.save(ticket);
		return ticket;
	}
	/**
	* Record that a Thread open tickets follow closed, and end each one done with its Threads (see `followsDone`), unless its
	* work has not finished (see `unfinished`); such work ends the ticket once it reports ready.
	*/
	threadClosed(thread, outcome, at) {
		const closed = threadKey(thread);
		for (const ticket of this.repo.tickets.open()) {
			const follow = ticket.follows?.find((item) => item.thread === closed && !item.closed);
			if (!follow) continue;
			follow.closed = {
				at,
				outcome
			};
			this.repo.tickets.save(ticket);
			const done = this.followsDone(ticket);
			if (!done || this.unfinished(ticket, at)) continue;
			const resumed = Date.parse(latestAssignment(ticket)?.createdAt ?? "") > Date.parse(at);
			this.end(ticket.id, "executor", done.outcome, resumed ? this.now() : done.at);
		}
	}
	/**
	* How a ticket that follows Threads is done with them: once no Thread it opened (`own`) is still open, or, when it opened none,
	* once every one it follows closed. It ends as the latest close among those Threads did; undefined while it is not done.
	*/
	followsDone(ticket) {
		const follows = ticket.follows ?? [];
		const own = follows.filter((item) => item.own);
		const counted = own.length ? own : follows;
		if (!counted.length || counted.some((item) => !item.closed)) return void 0;
		return counted.map((item) => item.closed).sort((a, b) => a.at.localeCompare(b.at)).at(-1);
	}
	/**
	* The Trigger to attach to a ticket, once the ticket may take it.
	* @throws UserError when the trigger or ticket is unknown, a ticket's worker still decides the trigger, a person stopped the ticket, or an ended ticket's Mandate no longer revalidates.
	*/
	attachable(ticketId, triggerId) {
		const trigger = this.repo.triggers.get(triggerId);
		if (!trigger) throw new UserError("unknownTrigger");
		this.leftToWorkers(trigger);
		const current = this.require(ticketId);
		if (current.ended?.by === "human") throw new UserError("ticketStopped");
		if (!liveTicket(current) && !this.policy().revalidate(current.mandate)) throw new UserError("mandateRevoked");
		return trigger;
	}
	/**
	* Subscribe a ticket to an attached Trigger's Threads and add the Trigger as an Input, with its note. The ticket's worker
	* then decides it, as it decides a message that reached the ticket on its own Thread; a worker that does not hold the
	* message as its ticket's takes it as a new Input, which wakes an ended ticket as any attached message does.
	*/
	attach(ticketId, trigger, note) {
		for (const ref of trigger.threads) this.subscribe(ticketId, ref);
		const current = this.repo.triggers.disposition(trigger.id) ?? {
			fanout: [],
			at: this.now()
		};
		const { context, requeued, ...disposition } = current;
		const followed = context?.filter((id) => id !== ticketId);
		this.repo.triggers.saveDisposition(trigger.id, {
			...disposition,
			fanout: [.../* @__PURE__ */ new Set([...disposition.fanout, ticketId])],
			...followed?.length ? { context: followed } : {}
		});
		const ticket = this.require(ticketId);
		const id = key("input", ticketId, "trigger", trigger.id);
		const existing = ticket.inputs.find((input) => input.id === id);
		const at = this.now();
		const input = (inputId) => ({
			id: inputId,
			kind: "trigger",
			triggerId: trigger.id,
			at,
			...note ? { note } : {},
			...trigger.human ? { human: true } : {}
		});
		if (existing?.kind !== "trigger") this.addInput(ticket, input(id));
		else if (note && ticket.undelivered.includes(id)) {
			existing.note = note;
			ticket.updatedAt = at;
			this.repo.tickets.save(ticket);
		} else if (requeued || !current.fanout.includes(ticketId) || context?.includes(ticketId) || !liveTicket(ticket)) this.addInput(ticket, input(key("input", ticketId, "trigger", trigger.id, "attached", at)));
		else if (note) this.addInput(ticket, input(key("input", ticketId, "trigger", trigger.id, "note", note)));
	}
	/**
	* Ask a running worker whose latest report is `waiting` for a status report; leaves any other ticket alone.
	* @returns whether the status request input was queued.
	* @throws UserError when the ticket is unknown.
	*/
	requestStatus(ticketId) {
		const ticket = this.require(ticketId);
		if (!liveTicket(ticket) || runningAssignment(ticket)?.report?.state !== "waiting") return false;
		this.addInput(ticket, {
			id: `status:${ticketId}:${ticket.updatedAt}`,
			kind: "text",
			text: STATUS_REQUEST,
			at: this.now()
		});
		return true;
	}
	/**
	* Stops a ticket on behalf of a human, ending any active assignments.
	* @throws UserError when the ticket is unknown.
	*/
	stop(ticketId, reason) {
		this.end(ticketId, "human", "stopped", this.now(), reason);
		return this.require(ticketId);
	}
	/**
	* Ends the stalled assignment of a retryable open ticket (`failed`, `blocked`, or failed input delivery) and starts a new one.
	* @throws UserError when the ticket is unknown or not retryable.
	*/
	retry(ticketId) {
		const ticket = this.require(ticketId);
		const latest = latestAssignment(ticket);
		if (!canRetry(ticket) || !latest) throw new UserError("notRetryable");
		this.endAssignment(ticket, latest, "retried");
		this.requeueUntaken(ticket, latest);
		const assignment = this.newAssignment(ticket);
		ticket.updatedAt = this.now();
		this.repo.tickets.save(ticket);
		this.options.executor.stop(ticket, latest, "retried");
		this.options.executor.start(ticket, assignment);
		return ticket;
	}
	/**
	* Drops a ticket's Subscription to a Thread its worker found unrelated, and hands back, with `reason`, the person's messages there that the ticket decides.
	* @throws UserError when the ticket is unknown, or `thread` is an origin thread, a bound `follows` thread, or not subscribed.
	*/
	markUnrelated(ticketId, thread, reason) {
		const ticket = this.require(ticketId);
		if (this.source(ticket)?.threads.some((ref) => threadKey(ref) === thread)) throw new UserError("sourceThread");
		if (ticket.follows?.some((item) => item.thread === thread)) throw new UserError("followedThread");
		if (!this.repo.threads.get(thread)?.subscriptions.includes(ticketId)) throw new UserError("notFollowing");
		this.dropSubscriptions(thread, "executor", ticketId, reason);
		for (const trigger of this.triggersOf(ticket)) if (trigger.threads.some((ref) => threadKey(ref) === thread) && this.owners(trigger).includes(ticketId)) this.handBack(ticketId, trigger, reason);
	}
	/**
	* Tell each open ticket a Policy change bears on how it does, oldest first, so their deliveries queue in the order they
	* were accepted; the others are left alone.
	*/
	policyChanged(from, to, effects) {
		const at = this.now();
		for (const ticket of this.repo.tickets.open().sort((a, b) => a.createdAt.localeCompare(b.createdAt))) {
			const effect = effects.get(ticket.id);
			if (effect) this.addInput(ticket, {
				id: key("input", ticket.id, "policy", from, to, at),
				kind: "policy-changed",
				from,
				to,
				at,
				effect
			});
		}
	}
	/**
	* Drop a Thread's Subscriptions, every ticket's or only `ticketId`'s, and say so; false when none dropped. A ticket that
	* followed the Thread follows it no more, so its close no longer ends the ticket. Each ticket keeps deciding the messages
	* it received from the Thread.
	*/
	dropSubscriptions(thread, by, ticketId, reason) {
		const current = this.repo.threads.get(thread);
		const tickets = current?.subscriptions.filter((id) => ticketId === void 0 || id === ticketId) ?? [];
		if (!current || !tickets.length) return false;
		current.subscriptions = current.subscriptions.filter((id) => !tickets.includes(id));
		this.repo.threads.save(current);
		for (const id of tickets) {
			const ticket = this.repo.tickets.get(id);
			if (!ticket?.follows?.some((item) => item.thread === thread)) continue;
			const { follows: before, ...rest } = ticket;
			const follows = before.filter((item) => item.thread !== thread);
			this.repo.tickets.save(follows.length ? {
				...rest,
				follows
			} : rest);
		}
		for (const id of tickets) this.emit("thread.unsubscribed", {
			threadKey: current.key,
			ticketId: id,
			by,
			...reason ? { reason } : {}
		});
		return true;
	}
	/**
	* Add an Input once (idempotently) and ask the Executor to deliver it, or to launch again a pending Assignment whose launch
	* failed once no person is waited for: a Policy change alone does not launch it again.
	*/
	addInput(ticket, input) {
		if (ticket.inputs.some((existing) => existing.id === input.id)) return;
		ticket.inputs.push(input);
		ticket.updatedAt = this.now();
		const held = liveTicket(ticket) && automatic(input) && waitsForPerson(ticket);
		if (!held) ticket.undelivered.push(input.id);
		this.repo.tickets.save(ticket);
		if (!liveTicket(ticket) || held) return;
		const running = runningAssignment(ticket), latest = latestAssignment(ticket);
		if (running) this.options.executor.deliver(ticket, running);
		else if (latest?.state === "pending" && !waitsForPerson(ticket)) this.options.executor.start(ticket, latest);
	}
	/**
	* Resume an ended ticket under its unchanged Mandate when a person's message on one of its Threads waits for it: no Eval
	* and no Decision, since nothing new is authorized. One whose Mandate the current Policy no longer holds stays ended and
	* takes nothing (see `refuse`). While processing is paused the message waits, and the first pass after the pause resumes
	* the ticket under the Policy then. Reads the ticket afresh, so it is idempotent and leaves an already-resumed ticket alone.
	*/
	wake(ticketId) {
		const ticket = this.repo.tickets.get(ticketId);
		if (!ticket || liveTicket(ticket) || ticket.ended?.by === "human" || !ticket.undelivered.length) return;
		const policy = this.policy();
		if (policy.paused) return;
		if (!policy.revalidate(ticket.mandate)) {
			this.refuse(ticket);
			return;
		}
		const first = ticket.undelivered.map((id) => ticket.inputs.find((input) => input.id === id)).find((input) => input?.kind === "trigger" && input.human);
		if (first?.kind !== "trigger") return;
		const at = this.now();
		delete ticket.ended;
		ticket.updatedAt = at;
		const assignment = this.newAssignment(ticket);
		const resumed = {
			id: key("input", ticket.id, "resumed", first.triggerId),
			kind: "resumed",
			triggerId: first.triggerId,
			at
		};
		ticket.inputs.push(resumed);
		ticket.undelivered.unshift(resumed.id);
		this.repo.tickets.save(ticket);
		this.options.executor.start(ticket, assignment);
		this.emit("ticket.resumed", {
			ticketId,
			triggerId: first.triggerId
		});
	}
	/** The Triggers of a ticket's trigger Inputs, or of those of them whose Input ids are `ids`. */
	triggersOf(ticket, ids) {
		return ticket.inputs.flatMap((input) => input.kind === "trigger" && (!ids || ids.includes(input.id)) ? this.repo.triggers.get(input.triggerId) ?? [] : []);
	}
	/**
	* Whether a ticket's worker took a person's message up, by acknowledging or answering it. A message acknowledged before
	* acknowledgements were recorded on it has only the acknowledgement's message in the outbox.
	*/
	takenUp(ticket, trigger) {
		const acked = this.repo.triggers.disposition(trigger.id)?.acked;
		return acked ? acked.includes(ticket.id) : this.options.outbox.status(key("ack", trigger.id)) !== void 0;
	}
	/** The person's messages among a ticket's Inputs `ids` that it decides and its worker did not take up. */
	untaken(ticket, ids) {
		return this.triggersOf(ticket, ids).filter((trigger) => this.owners(trigger).includes(ticket.id) && !this.takenUp(ticket, trigger));
	}
	/**
	* A ticket that ended, or cannot resume, lets go of the messages its worker never received, `waiting`, and of the person's
	* messages it decided but may not have taken up, `left`: it no longer counts as having reached them, and each of `left`
	* that no other ticket decides goes to Eval, as a person's message that reached no ticket does, unless a ticket took it
	* up, a Decision settled it, or it is the message a stop ended this ticket on.
	*/
	letGo(ticketId, waiting, left) {
		for (const trigger of [...waiting, ...left]) {
			const disposition = this.repo.triggers.disposition(trigger.id);
			if (disposition?.fanout.includes(ticketId)) this.repo.triggers.saveDisposition(trigger.id, {
				...disposition,
				fanout: disposition.fanout.filter((id) => id !== ticketId)
			});
		}
		for (const trigger of left) {
			const disposition = this.repo.triggers.disposition(trigger.id);
			const decision = disposition?.decisionId ? this.repo.decisions.get(disposition.decisionId) : void 0;
			const stopped = decision?.kind === "stop" && decision.ticketId === ticketId && !disposition?.handbacks?.length;
			const decided = !!decision && (settled(decision) || stopped);
			if (!this.owners(trigger).length && !disposition?.acked?.length && !decided) this.queueForEval(trigger);
		}
	}
	/** An ended ticket that cannot resume takes none of the messages that waited for it (see `letGo`). */
	refuse(ticket) {
		const waiting = this.triggersOf(ticket, ticket.undelivered), left = this.untaken(ticket, ticket.undelivered);
		ticket.undelivered = [];
		this.repo.tickets.save(ticket);
		this.letGo(ticket.id, waiting, left);
	}
	/** Replace a ticket's running Assignment with a new one that receives `note` first, and queue it for launch. */
	restart(ticket, running, reason, note) {
		this.endAssignment(ticket, running, reason);
		this.requeueUntaken(ticket, running);
		const assignment = this.newAssignment(ticket);
		const at = this.now();
		const input = {
			id: key("input", ticket.id, "restart", assignment.id),
			kind: "text",
			text: note,
			at
		};
		ticket.inputs.push(input);
		ticket.undelivered.push(input.id);
		ticket.updatedAt = at;
		this.repo.tickets.save(ticket);
		this.options.executor.start(ticket, assignment);
	}
	/**
	* Put back, ahead of what waits, the Trigger Inputs delivered to `replaced` that no step of its worker took: a cancel may
	* have dropped them, or a step that claimed them was cut off, and the new Assignment's launch takes a copy still waiting
	* in the Session out, so its delivery is the only one. An earlier end let go of what earlier Assignments left.
	*/
	requeueUntaken(ticket, replaced) {
		const untaken = ticket.inputs.filter((input) => input.kind === "trigger" && input.readAt === null && input.deliveredTo === replaced.id && !ticket.undelivered.includes(input.id));
		ticket.undelivered.unshift(...untaken.map((input) => input.id));
	}
	/**
	* End a ticket with its outcome. `at` records when the ending fact happened, such as a PR merge, and `reason` says
	* why in words, by default the outcome. The ticket lets go (see `letGo`) of the messages its worker never received, and of
	* the person's messages it decides that its worker did not read before its latest report or turn end, the report that
	* ends the ticket included (see `readBefore`), and neither acknowledged, answered nor handed back: one may have come while
	* the worker wrote the report that ends the ticket, or after its turn ended, and either way it can no longer hand it back.
	*/
	end(ticketId, by, outcome, at = this.now(), reason) {
		const ticket = this.require(ticketId);
		if (!liveTicket(ticket)) return;
		const stopping = ticket.assignments.filter((assignment) => assignment.state !== "ended");
		const why = reason && reason !== outcome ? { reason } : {};
		const until = readUntil(ticket);
		const waiting = this.triggersOf(ticket, ticket.undelivered);
		const left = this.untaken(ticket, ticket.inputs.flatMap((input) => input.kind === "trigger" && (!readBefore(input, until) || ticket.undelivered.includes(input.id)) ? [input.id] : []));
		ticket.ended = {
			at,
			by,
			outcome,
			...why
		};
		ticket.undelivered = [];
		ticket.updatedAt = this.now();
		delete ticket.attention;
		delete ticket.delivery;
		for (const assignment of stopping) {
			assignment.state = "ended";
			assignment.endedAt = at;
		}
		this.repo.tickets.save(ticket);
		this.letGo(ticketId, waiting, left);
		this.emit("ticket.ended", {
			ticketId,
			by,
			outcome,
			...why
		});
		for (const assignment of stopping) this.options.executor.stop(ticket, assignment, reason ?? outcome);
	}
	/**
	* Whether a ticket's work has not finished at a close at `at`: its worker took up a person's message the ticket decides and
	* has not reported other than progress, or ended a turn, since its Session took that message into a step, or work resumed
	* after the close, whose Assignment started after it, has no ready report or Input arrived after that report; a Policy
	* change asks for no work.
	*/
	unfinished(ticket, at) {
		const until = readUntil(ticket, false);
		const taken = this.triggersOf(ticket, ticket.inputs.flatMap((input) => input.kind === "trigger" && !readBefore(input, until) ? [input.id] : [])).some((trigger) => this.owners(trigger).includes(ticket.id) && this.takenUp(ticket, trigger));
		const latest = latestAssignment(ticket);
		if (taken || !(Date.parse(latest?.createdAt ?? "") > Date.parse(at))) return taken;
		const report = latest?.report;
		const later = ticket.inputs.some((input) => input.kind !== "policy-changed" && Date.parse(input.at) > Date.parse(report?.at ?? ""));
		return report?.state !== "ready" || ticket.undelivered.length > 0 || later;
	}
	/** Add a pending Assignment; a failed delivery to the one before it no longer concerns the ticket. */
	newAssignment(ticket) {
		const assignment = {
			id: key("assignment", ticket.id, String(ticket.assignments.length)),
			state: "pending",
			createdAt: this.now()
		};
		ticket.assignments.push(assignment);
		delete ticket.delivery;
		return assignment;
	}
	endAssignment(ticket, assignment, reason) {
		assignment.state = "ended";
		assignment.endedAt = this.now();
		assignment.endedReason = reason;
		this.emit("assignment.ended", {
			ticketId: ticket.id,
			assignmentId: assignment.id,
			reason
		});
	}
	/**
	* Give an open ticket's Executor a fact as a note Input, such as what another ticket found; it grants nothing (see `TicketInput`).
	* @throws UserError when the ticket is unknown or has ended.
	*/
	note(ticketId, text) {
		const ticket = this.require(ticketId);
		if (!liveTicket(ticket)) throw new UserError("ticketEnded");
		const at = this.now();
		this.addInput(ticket, {
			id: key("input", ticketId, "note", at, text),
			kind: "note",
			text,
			at
		});
		return this.require(ticketId);
	}
	/**
	* Subscribe an open ticket to a Thread its Executor found related, for context: see `Thread.context`.
	* @returns false when the ticket follows the Thread already.
	* @throws UserError when the ticket is unknown or has ended.
	*/
	followForContext(ticketId, ref) {
		if (!liveTicket(this.require(ticketId))) throw new UserError("ticketEnded");
		if (this.thread(ref).subscriptions.includes(ticketId)) return false;
		this.subscribe(ticketId, ref);
		const thread = this.thread(ref);
		thread.context = [...thread.context ?? [], ticketId];
		this.repo.threads.save(thread);
		return true;
	}
	/** Subscribe a ticket to a Thread; later Triggers on it reach the ticket as Inputs, as the ticket's own once it was for context. */
	subscribe(ticketId, ref) {
		const thread = this.thread(ref);
		if (!thread.subscriptions.includes(ticketId)) {
			thread.subscriptions.push(ticketId);
			this.emit("thread.subscribed", {
				threadKey: thread.key,
				ticketId
			});
		}
		if (thread.context?.includes(ticketId)) thread.context = thread.context.filter((id) => id !== ticketId);
		this.repo.threads.save(thread);
	}
};
//#endregion
//#region src/core/assignments.ts
/** What the Executor and its workers report about the Assignments that run tickets. */
const RECOVERY_NOTE = "The host restarted during this ticket. Inspect the current worktree, git history and GitHub state before continuing. Do not repeat an already completed external operation. Finish the original assignment and report its status.";
/**
* Assignments records what the Executor and its workers report about the Assignments that run tickets: one started, Inputs
* reached it or failed to, its worker's Session took Inputs into a step, a turn of its worker ended, a host restart
* interrupted it, and a worker's report with its question for a person. It depends on
* Tickets to restart or end a ticket and on Replies to withdraw a question a report replaced; the Engine routes the
* Executor's lifecycle callbacks and its workers' reports here.
*/
var Assignments = class extends EnginePart {
	tickets;
	replies;
	constructor(options, tickets, replies) {
		super(options);
		this.tickets = tickets;
		this.replies = replies;
	}
	/** Marks a non-ended assignment running, queues delivery of waiting undelivered inputs on an open ticket, and emits `assignment.started`. */
	started(ticketId, assignmentId) {
		const ticket = this.require(ticketId);
		const assignment = ticket.assignments.find((item) => item.id === assignmentId);
		if (!assignment || assignment.state === "ended") return;
		assignment.state = "running";
		assignment.startedAt ??= this.now();
		ticket.updatedAt = this.now();
		this.repo.tickets.save(ticket);
		if (liveTicket(ticket) && ticket.undelivered.length) this.options.executor.deliver(ticket, assignment);
		this.emit("assignment.started", {
			ticketId,
			assignmentId
		});
	}
	/**
	* Marks `inputIds` delivered on the ticket's running assignment and clears any prior `delivery` failure; ignored if no
	* longer running. Its worker reads each once its Session takes it into a step (see `read`).
	*/
	delivered(ticketId, assignmentId, inputIds) {
		const ticket = this.running(ticketId, assignmentId);
		if (!ticket) return;
		ticket.undelivered = ticket.undelivered.filter((id) => !inputIds.includes(id));
		ticket.updatedAt = this.now();
		runningAssignment(ticket).deliveredAt = ticket.updatedAt;
		for (const input of ticket.inputs) if (input.kind === "trigger" && inputIds.includes(input.id)) {
			input.readAt ??= null;
			input.deliveredTo = assignmentId;
		}
		delete ticket.delivery;
		this.repo.tickets.save(ticket);
	}
	/** Records when the worker's Session of an open ticket took `inputIds` into a step, from which its model reads them. */
	read(ticketId, inputIds) {
		const ticket = this.require(ticketId);
		if (!liveTicket(ticket)) return;
		for (const input of ticket.inputs) if (input.kind === "trigger" && inputIds.includes(input.id)) input.readAt ||= this.now();
		this.repo.tickets.save(ticket);
	}
	turnEnded(ticketId, assignmentId) {
		const ticket = this.running(ticketId, assignmentId);
		if (!ticket) return;
		runningAssignment(ticket).idleAt = this.now();
		this.repo.tickets.save(ticket);
	}
	deliveryFailed(ticketId, assignmentId, error) {
		const ticket = this.running(ticketId, assignmentId);
		if (!ticket) return;
		ticket.delivery = {
			error: error.slice(0, 300),
			at: this.now()
		};
		this.repo.tickets.save(ticket);
	}
	/**
	* Handles a running assignment interrupted by a host restart: restarts it with a recovery note unless its latest report is
	* `waiting`, `ready`, `blocked`, or `failed` and no input was delivered after that report, in which case it keeps its
	* session and flushes any waiting undelivered inputs.
	*/
	interrupted(ticketId, assignmentId) {
		const ticket = this.running(ticketId, assignmentId);
		const running = ticket && runningAssignment(ticket);
		if (!ticket || !running) return;
		const report = running.report;
		const busy = !!running.deliveredAt && !!report && running.deliveredAt >= report.at;
		if (!(!!report && [
			"waiting",
			"ready",
			"blocked",
			"failed"
		].includes(report.state) && !busy)) this.tickets.restart(ticket, running, "hostRestarted", RECOVERY_NOTE);
		else if (ticket.undelivered.length) this.options.executor.deliver(ticket, running);
	}
	/**
	* Records a worker status report on an open ticket's current assignment, updating `attention`, `answers`, held automated
	* inputs, and ending the ticket when `dropped` or when `ready` and not waiting on followed threads (`followsDone`).
	* @throws UserError for an unknown or ended ticket, an ended assignment, a question combined with a ready result or answer,
	* or a question/answer referencing a non-human or unreached trigger.
	*/
	report(ticketId, report) {
		const ticket = this.require(ticketId);
		if (!liveTicket(ticket)) throw new UserError("ticketEnded");
		if (report.question && (report.state === "ready" || report.answers)) throw new UserError("questionWithResult");
		if (report.askedBy && !report.question) throw new UserError("askerWithoutQuestion");
		const person = (id, channel) => {
			const trigger = this.repo.triggers.get(id);
			return !!trigger?.human && (!channel || !!trigger.channel) && this.reaches(ticket, trigger, false);
		};
		if (report.askedBy && !person(report.askedBy, true)) throw new UserError("notAsker");
		if (report.answers && !person(report.answers, false)) throw new UserError("notAnswerable");
		const assignment = runningAssignment(ticket) ?? latestAssignment(ticket);
		if (!assignment) throw new UserError("unknownAssignment");
		if (assignment.state === "ended") throw new UserError("assignmentEnded");
		const at = this.now();
		const previous = ticket.attention;
		const ask = (question) => ({
			id: key("attention", ticketId, question, at),
			question,
			...report.askedBy ? { triggerId: report.askedBy } : {}
		});
		const asked = report.question && report.question !== previous?.question ? ask(report.question) : previous;
		const attention = report.question === null || report.state === "ready" ? void 0 : asked;
		if (attention) ticket.attention = attention;
		else delete ticket.attention;
		if (previous && previous.id !== attention?.id) this.replies.withdrawAttention(previous.id);
		assignment.report = {
			state: report.state,
			summary: report.summary,
			at
		};
		ticket.updatedAt = at;
		if (report.answers && !ticket.answers?.includes(report.answers)) ticket.answers = [...ticket.answers ?? [], report.answers];
		if (report.answers) this.takeUp(ticketId, report.answers);
		if (report.state === "blocked" || report.state === "failed") ticket.undelivered = ticket.undelivered.filter((id) => !automatic(ticket.inputs.find((input) => input.id === id)));
		this.repo.tickets.save(ticket);
		const ready = !ticket.follows?.length ? "completed" : this.tickets.followsDone(ticket)?.outcome;
		const outcome = report.state === "dropped" ? this.tickets.followsDone(ticket)?.outcome ?? "dropped" : report.state === "ready" ? ready : void 0;
		if (outcome) this.tickets.end(ticketId, "executor", outcome, at);
		return this.require(ticketId);
	}
	/** The ticket, while it is open and `assignmentId` runs it. */
	running(ticketId, assignmentId) {
		const ticket = this.require(ticketId);
		return liveTicket(ticket) && runningAssignment(ticket)?.id === assignmentId ? ticket : void 0;
	}
};
//#endregion
//#region src/core/reasons.ts
/**
* Structured reason codes and templates for decisions, filtered triggers, and ended assignments.
* Policy gates and source scopes may also emit their own literal reason codes.
*/
const REASONS = {
	said: "{text}",
	timeout: "Assessment timed out",
	policyChanged: "Policy changed during assessment",
	noAdmissible: "No admissible trigger",
	startedTicket: "Already started ticket {ticket}",
	acceptedBefore: "Trigger {trigger} was accepted before",
	routed: "Routed to ticket {ticket}",
	explicitRouted: "Explicit request from an allowed sender routed by the orchestrator",
	humanStop: "Human asked to stop",
	legacyImport: "Imported from the pre-domain-model task record",
	forwarded: "Forwarded to the worker of the Ticket already on this Thread",
	senderNotMember: "The sender is not on the Source's list",
	retried: "Retried by a person",
	hostRestarted: "dsh-superagent restarted",
	stopUnknown: "Stop target is unknown or already ended",
	stopNotExplicit: "A stop needs an explicit request from a sender on the list",
	directionUnsettled: "Implementation intent or target direction is not established, or a product/design decision is still required",
	noRuleMatched: "No enabled admission rule matched",
	ignoredFromCard: "Ignored from its card, without a rule assessment",
	observed: "Observe mode: would accept ({text})"
};
const said = (text) => ({
	code: "said",
	values: { text }
});
/** Formats reasons in English (prefixed by `triggerId` when present) for agent consumption. */
function reasonText(reasons) {
	return [reasons ?? []].flat().map((reason) => {
		const text = (REASONS[reason.code] ?? reason.code).replace(/\{(\w+)\}/g, (match, name) => reason.values?.[name] ?? match);
		return reason.triggerId ? `${reason.triggerId}: ${text}` : text;
	}).join("; ");
}
//#endregion
//#region src/core/evals.ts
/** Evals: the Thread-level assessments of queued Triggers, and the Decisions they end with. */
/** An outcome's reason: a code it carries, else the words its assessor or person wrote. */
const reasonOf = (reason) => [typeof reason === "string" ? said(reason) : reason];
const stronger = (a, b) => a === "explicit" || b === "explicit" ? "explicit" : "inferred";
/** How many times in a row an expired Eval queues its Triggers again before it is recorded unavailable. */
const REQUEUES = 2;
/**
* Evals runs the Evals of Threads: it batches a Thread's queued Triggers into one Eval, takes its strength, actor, and basis
* from the gate, asks the assessor, keeps its deadline through a pause, and records the Decision it ends with: accept, stop,
* ignore, or unavailable. It depends on Tickets to create the ticket an accept decides and to end the one a stop names; the
* Engine routes the main Session's decisions, people's replays, worker handbacks, and the pass's Eval work here.
*/
var Evals = class extends EnginePart {
	tickets;
	constructor(options, tickets) {
		super(options);
		this.tickets = tickets;
	}
	/**
	* Expire a Thread's Eval past its deadline (see `expire`), unless processing is paused: then the Eval notes when the
	* processing pause began, and once processing resumes its deadline moves forward by the pause's length. An Eval whose
	* candidate has not reached the assessor's Session does not expire.
	*/
	due(thread, policy) {
		const evaluation = thread.evaluating;
		if (!evaluation || policy.paused && evaluation.pausedAt) return;
		const now = this.now();
		if (policy.paused) evaluation.pausedAt = now;
		else if (evaluation.pausedAt) {
			evaluation.deadline = new Date(Date.parse(evaluation.deadline) + Date.parse(now) - Date.parse(evaluation.pausedAt)).toISOString();
			delete evaluation.pausedAt;
		} else if (evaluation.delivered && evaluation.deadline <= now) {
			this.expire(thread);
			return;
		} else return;
		this.repo.threads.save(thread);
	}
	/** An Eval's candidate reached the assessor's Session: its deadline counts from now. */
	delivered(evalId, policy) {
		const thread = this.repo.threads.active().find((item) => item.evaluating?.id === evalId);
		if (!thread?.evaluating || thread.evaluating.delivered) return;
		const now = this.now();
		thread.evaluating.delivered = now;
		thread.evaluating.deadline = new Date(Date.parse(now) + policy.evalTimeoutMs).toISOString();
		this.repo.threads.save(thread);
	}
	/**
	* An Eval past its deadline queues its Triggers again for a fresh Eval, up to `REQUEUES` times in a row, so a busy
	* assessor does not drop requests; after that it is recorded unavailable.
	*/
	expire(thread) {
		const expired = (thread.expired ?? 0) + 1;
		if (expired > REQUEUES) {
			this.finish(thread, thread.evaluating, {
				kind: "unavailable",
				reason: [{ code: "timeout" }]
			});
			return;
		}
		const { id, triggerIds } = thread.evaluating;
		delete thread.evaluating;
		thread.expired = expired;
		thread.pending = [...triggerIds, ...thread.pending.filter((item) => !triggerIds.includes(item))];
		this.repo.threads.save(thread);
		this.options.assessor.release?.(id);
	}
	/** Start one Eval of the Triggers queued on a Thread, judged by the gate, and ask the assessor for it. */
	start(threadKeyValue, policy) {
		const thread = this.repo.threads.get(threadKeyValue);
		const at = this.now();
		const delivered = (id) => {
			const trigger = this.repo.triggers.get(id);
			return !!trigger && this.owners(trigger).length > 0;
		};
		if (thread.pending.some(delivered)) {
			const followups = thread.pending.filter(delivered);
			thread.pending = thread.pending.filter((id) => !followups.includes(id));
			this.repo.threads.save(thread);
			for (const triggerId of followups) this.emit("trigger.followup", { triggerId });
			if (!thread.pending.length) return;
		}
		const accepted = this.accepted(thread.key);
		const started = thread.pending.filter((id) => accepted.has(id));
		const startedTicket = (id) => ({
			code: "startedTicket",
			triggerId: id,
			values: { ticket: accepted.get(id).ticketId }
		});
		if (started.length) this.ignore(thread, started, started.map(startedTicket), policy, at);
		const triggers = thread.pending.flatMap((id) => {
			const trigger = this.repo.triggers.get(id);
			return trigger ? [trigger] : [];
		});
		const tickets = this.ticketsOnThread(thread);
		const reasons = [];
		let strongest;
		for (const trigger of triggers) {
			const gate = policy.gate(trigger, thread, tickets);
			if (!gate.admissible) {
				reasons.push({
					code: gate.reason,
					triggerId: trigger.id
				});
				continue;
			}
			const later = gate.strength === strongest?.strength && trigger.at >= strongest.trigger.at;
			if (!strongest || stronger(strongest.strength, gate.strength) !== strongest.strength || later) strongest = {
				trigger,
				strength: gate.strength,
				basis: gate.basis
			};
		}
		if (!strongest) {
			if (thread.pending.length) this.ignore(thread, [...thread.pending], reasons.length ? reasons : [{ code: "noAdmissible" }], policy, at);
			this.repo.threads.save(thread);
			return;
		}
		const evalId = key("eval", thread.key, policy.version, at, ...thread.pending);
		const deadline = new Date(Date.parse(at) + policy.evalTimeoutMs).toISOString();
		const { strength, trigger: { actor }, basis } = strongest;
		thread.evaluating = {
			id: evalId,
			threadKey: thread.key,
			triggerIds: thread.pending,
			primary: strongest.trigger.id,
			strength,
			actor,
			basis,
			policyVersion: policy.version,
			startedAt: at,
			deadline
		};
		thread.pending = [];
		this.repo.threads.save(thread);
		for (const trigger of triggers) this.repo.triggers.saveDisposition(trigger.id, {
			...this.repo.triggers.disposition(trigger.id) ?? {
				fanout: [],
				at
			},
			evalId
		});
		this.emit("eval.started", {
			evalId,
			threadKey: thread.key,
			triggerIds: thread.evaluating.triggerIds,
			strength: strongest.strength
		});
		this.options.assessor.request(this.candidateOf(thread));
	}
	/** The candidate of the Eval that holds `triggerId`, or undefined while no Eval holds it. */
	candidate(triggerId) {
		const thread = this.holding(triggerId);
		return thread && this.candidateOf(thread);
	}
	/**
	* Decide a Trigger: the Eval that holds it, or a direct Eval of it alone when none does.
	* @throws UserError when the Trigger is unknown or not admissible, `outcome.evalId` names an Eval that has finished, a
	* ticket's worker still decides the Trigger and the outcome is not a stop, or an inferred candidate is accepted outside `auto`
	* mode or without enabled matching rules.
	*/
	decide(triggerId, outcome) {
		const trigger = this.repo.triggers.get(triggerId);
		if (!trigger) throw new UserError("unknownTrigger");
		const held = this.holding(triggerId);
		if (outcome.evalId && held?.evaluating?.id !== outcome.evalId) throw new UserError("evalFinished", { eval: outcome.evalId });
		const earlier = outcome.kind === "accept" ? this.accepted(threadKey(trigger.threads[0])).get(triggerId) : void 0;
		if (earlier) {
			const others = held?.evaluating?.triggerIds.filter((id) => id !== triggerId) ?? [];
			if (held && others.length) this.reassess(held, {
				code: "acceptedBefore",
				values: { trigger: triggerId }
			}, [triggerId]);
			else if (held) this.finish(held, held.evaluating, {
				kind: "ignore",
				reason: [{
					code: "startedTicket",
					triggerId,
					values: { ticket: earlier.ticketId }
				}]
			});
			return earlier;
		}
		if (outcome.kind !== "stop") this.leftToWorkers(trigger);
		const thread = held ?? this.thread(trigger.threads[0]);
		const evaluation = held?.evaluating ?? this.directEval(thread, trigger, outcome.kind, outcome.kind === "stop" ? outcome.ticketId : void 0);
		if (outcome.kind === "accept" && evaluation.strength !== "explicit" && !this.policy().admitsInferred(outcome.rules ?? [])) throw new UserError("notExplicit");
		return this.decideEval(thread, evaluation, outcome);
	}
	/**
	* Queue a stored Trigger for a fresh Eval on its primary Thread and emit `trigger.requeued`; returns false while an Eval holds it.
	* @throws UserError when the Trigger is unknown.
	*/
	reevaluate(triggerId) {
		if (!this.requeue(triggerId)) return false;
		this.emit("trigger.requeued", { triggerId });
		return true;
	}
	/** Queue a Trigger for a fresh Eval on its primary Thread; false while an Eval holds it. */
	requeue(triggerId) {
		const trigger = this.repo.triggers.get(triggerId);
		if (!trigger) throw new UserError("unknownTrigger");
		if (this.holding(triggerId)) return false;
		this.queueForEval(trigger);
		const disposition = this.repo.triggers.disposition(triggerId) ?? {
			fanout: [],
			at: this.now()
		};
		this.repo.triggers.saveDisposition(triggerId, {
			...disposition,
			requeued: true
		});
		return true;
	}
	/**
	* Record that a ticket's Executor hands back a Trigger that reached it as beyond the ticket, and queue it for a fresh Eval
	* when the ticket decided it and no other ticket still does (see `handBack`): the gate judges it as any message on its
	* Thread, and its candidate carries the reasons, so no requeue notice comes before it. The ticket keeps its Subscription,
	* and hands a Trigger back once.
	* @returns whether it was queued: false while another ticket decides it, and for one the ticket did not decide.
	*/
	handback(ticketId, triggerId, reason) {
		if (!this.require(ticketId).inputs.some((input) => input.kind === "trigger" && input.triggerId === triggerId)) throw new UserError("notReached");
		if (this.repo.triggers.disposition(triggerId)?.handbacks?.some((item) => item.ticketId === ticketId)) throw new UserError("handedBack");
		return this.handBack(ticketId, this.repo.triggers.get(triggerId), reason);
	}
	/**
	* Marks an `unavailable` Decision dismissed so the overview lists it no more.
	* @throws UserError when the Decision is unknown or not `unavailable`.
	*/
	dismiss(decisionId) {
		const decision = this.repo.decisions.get(decisionId);
		if (decision?.kind !== "unavailable") throw new UserError("unknownProblem");
		decision.dismissed = true;
		this.repo.decisions.save(decision);
		return decision;
	}
	/** Take a Trigger out of its Thread's queue because it was routed by hand. */
	withdraw(trigger) {
		const thread = this.repo.threads.get(threadKey(trigger.threads[0]));
		if (!thread?.pending.includes(trigger.id)) return;
		thread.pending = thread.pending.filter((id) => id !== trigger.id);
		this.repo.threads.save(thread);
	}
	/**
	* End the Eval that holds a Trigger routed to a ticket, since the ticket has it now: one that holds other Triggers too
	* queues them again for a fresh Eval without it.
	*/
	routed(triggerId, ticketId) {
		const held = this.holding(triggerId);
		const reason = {
			code: "routed",
			values: { ticket: ticketId }
		};
		if (held?.evaluating?.triggerIds.length === 1) this.finish(held, held.evaluating, {
			kind: "ignore",
			reason: [reason]
		});
		else if (held) this.reassess(held, {
			...reason,
			triggerId
		}, [triggerId]);
	}
	/** Start the Evals in progress again under the new Policy version, and say that it changed. */
	policyChanged(from, to) {
		for (const thread of this.repo.threads.active()) if (thread.evaluating) this.reassess(thread, { code: "policyChanged" });
		this.emit("policy.changed", {
			from,
			to
		});
	}
	/** End a Thread's Eval as unavailable for `reason` and queue its Triggers, except `without`, for a new Eval ahead of the others. */
	reassess(thread, reason, without = []) {
		const ids = thread.evaluating.triggerIds.filter((id) => !without.includes(id));
		const decision = this.finish(thread, thread.evaluating, {
			kind: "unavailable",
			reason: [reason]
		});
		const current = this.repo.threads.get(thread.key);
		current.pending = [...ids, ...current.pending.filter((id) => !ids.includes(id))];
		this.repo.threads.save(current);
		return decision;
	}
	/** The Thread whose Eval holds a Trigger: an Eval runs on the primary Thread of each Trigger it holds. */
	holding(triggerId) {
		const trigger = this.repo.triggers.get(triggerId);
		const thread = trigger && this.repo.threads.get(threadKey(trigger.threads[0]));
		return thread?.evaluating?.triggerIds.includes(triggerId) ? thread : void 0;
	}
	candidateOf(thread) {
		const evaluation = thread.evaluating;
		const triggers = evaluation.triggerIds.flatMap((id) => {
			const trigger = this.repo.triggers.get(id);
			return trigger ? [trigger] : [];
		});
		const { id: evalId, strength, policyVersion } = evaluation;
		return {
			evalId,
			thread,
			triggers,
			strength,
			policyVersion,
			tickets: this.ticketsOnThread(thread)
		};
	}
	/**
	* Record that the queued Triggers `ids` of a Thread start no Eval, for `reason`, and take them out of its queue. Its id
	* differs from an Eval's, so it never replaces the Decision of an earlier Eval of the same Triggers.
	*/
	ignore(thread, ids, reason, policy, at) {
		const evaluation = {
			id: key("eval", thread.key, "ignored", policy.version, at, ...ids),
			threadKey: thread.key,
			triggerIds: ids,
			strength: "inferred",
			actor: {
				source: thread.ref.source,
				id: ""
			},
			basis: { via: "followup" },
			policyVersion: policy.version,
			startedAt: at,
			deadline: at
		};
		this.record(thread, evaluation, {
			kind: "ignore",
			reason
		});
		thread.pending = thread.pending.filter((id) => !ids.includes(id));
		delete thread.expired;
	}
	/**
	* The accept Decisions of the Triggers whose primary Thread is `threadKey`, by Trigger: what each one started. An Eval and
	* its Decision run on its Triggers' primary Thread, so the Thread's Decisions, read by their index, hold them all.
	*/
	accepted(threadKey) {
		const accepted = /* @__PURE__ */ new Map();
		for (const decision of this.repo.decisions.byThread(threadKey)) {
			if (decision.kind !== "accept" || !decision.ticketId) continue;
			for (const id of decision.triggerIds) if (!accepted.has(id)) accepted.set(id, decision);
		}
		return accepted;
	}
	/**
	* A gate-only Eval of one Trigger, for an outcome decided without a queued Eval, such as on a follow-up that reached a
	* ticket. It is decided at once, beside an Eval its Thread may have in progress, and takes the Trigger out of the queue.
	* Its id names the outcome's kind, so a stop and an accept of one message at the same moment are two Decisions.
	*/
	directEval(thread, trigger, kind, ticketId) {
		const policy = this.policy();
		const gate = policy.gate(trigger, thread, this.ticketsOnThread(thread));
		if (!gate.admissible) throw new UserError("notAdmissible", { reason: gate.reason });
		const at = this.now();
		if (thread.pending.includes(trigger.id)) {
			thread.pending = thread.pending.filter((id) => id !== trigger.id);
			this.repo.threads.save(thread);
		}
		return {
			id: key("eval", thread.key, "direct", trigger.id, kind, ...ticketId ? [ticketId] : [], at),
			threadKey: thread.key,
			triggerIds: [trigger.id],
			primary: trigger.id,
			strength: gate.strength,
			actor: trigger.actor,
			basis: gate.basis,
			policyVersion: policy.version,
			startedAt: at,
			deadline: at
		};
	}
	/** Apply an outcome to an Eval of a Thread: the one in progress, or a gate-only one. */
	decideEval(thread, evaluation, outcome) {
		const audit = outcome.audit ? { audit: outcome.audit } : {};
		if (this.policy().version !== evaluation.policyVersion) {
			if (thread.evaluating?.id === evaluation.id) return this.reassess(thread, { code: "policyChanged" });
			return this.finish(thread, evaluation, {
				kind: "unavailable",
				reason: [{ code: "policyChanged" }],
				...audit
			});
		}
		const unassessed = outcome.kind === "ignore" && evaluation.strength !== "explicit" && !outcome.audit ? [{ code: "ignoredFromCard" }] : [];
		if (outcome.kind === "ignore" || outcome.kind === "unavailable") return this.finish(thread, evaluation, {
			kind: outcome.kind,
			reason: [...unassessed, ...reasonOf(outcome.reason)],
			...audit
		});
		if (outcome.kind === "stop") {
			const ticket = this.repo.tickets.get(outcome.ticketId);
			if (!ticket || !liveTicket(ticket)) return this.finish(thread, evaluation, {
				kind: "ignore",
				reason: [{ code: "stopUnknown" }],
				...audit
			});
			if (evaluation.strength !== "explicit") return this.finish(thread, evaluation, {
				kind: "ignore",
				reason: [{ code: "stopNotExplicit" }],
				...audit
			});
			const decision = this.finish(thread, evaluation, {
				kind: "stop",
				reason: reasonOf(outcome.reason),
				ticketId: ticket.id,
				...audit
			});
			this.tickets.end(ticket.id, "human", "stopped", this.now(), typeof outcome.reason === "string" ? outcome.reason : void 0);
			return decision;
		}
		return this.accept(thread, evaluation, outcome);
	}
	/** Record an accept with the Mandate the Eval gives, and have Tickets create its ticket. */
	accept(thread, evaluation, outcome) {
		const at = this.now();
		const basis = {
			...evaluation.basis,
			...outcome.rules ? { rules: outcome.rules } : {}
		};
		const { strength, policyVersion, actor } = evaluation;
		const mandate = {
			strength,
			policyVersion,
			basis,
			actor,
			scope: outcome.scope
		};
		const ticketId = key("ticket", evaluation.id);
		const audit = outcome.audit ? { audit: outcome.audit } : {};
		const decision = this.finish(thread, evaluation, {
			kind: "accept",
			reason: reasonOf(outcome.reason),
			...audit,
			mandate,
			ticketId
		});
		this.tickets.create(ticketId, decision.id, mandate, evaluation, outcome, at);
		return decision;
	}
	/** Record an Eval's Decision; the Thread's own Eval ends with it, while a gate-only one leaves the Thread's Eval going. */
	finish(thread, evaluation, outcome) {
		const decision = this.record(thread, evaluation, outcome);
		if (thread.evaluating?.id !== evaluation.id) return decision;
		delete thread.evaluating;
		delete thread.expired;
		this.repo.threads.save(thread);
		this.options.assessor.release?.(evaluation.id);
		return decision;
	}
	record(thread, evaluation, outcome) {
		const at = this.now();
		const decision = {
			id: key("decision", evaluation.id),
			evalId: evaluation.id,
			threadKey: thread.key,
			triggerIds: evaluation.triggerIds,
			policyVersion: evaluation.policyVersion,
			at,
			kind: outcome.kind,
			reason: outcome.reason,
			strength: evaluation.strength,
			...outcome.ticketId ? { ticketId: outcome.ticketId } : {},
			...outcome.mandate ? { mandate: outcome.mandate } : {},
			...outcome.audit ? { audit: outcome.audit } : {}
		};
		this.repo.decisions.save(decision);
		for (const id of evaluation.triggerIds) {
			const disposition = this.repo.triggers.disposition(id) ?? {
				fanout: [],
				at
			};
			this.repo.triggers.saveDisposition(id, {
				...disposition,
				evalId: evaluation.id,
				decisionId: decision.id
			});
		}
		this.emit("decision.recorded", {
			decisionId: decision.id,
			kind: decision.kind,
			threadKey: thread.key
		});
		return decision;
	}
};
//#endregion
//#region src/core/intake.ts
/** Trigger ingestion, thread correlation, subscription fan-out, and evaluation queuing. */
/**
* Ingests incoming triggers from Sources, deduplicating and filtering them against SourceScope before recording thread correlations.
* Fans listened triggers out to subscribed tickets via Tickets and queues for Eval, on its primary thread, every trigger no
* ticket's worker decides (see `followupOwners`).
* Engine delegates trigger reception to this part.
*/
var Intake = class extends EnginePart {
	tickets;
	constructor(options, tickets) {
		super(options);
		this.tickets = tickets;
	}
	receive(received) {
		const trigger = {
			...received,
			at: isoTime(received.at)
		};
		if (!trigger.threads.length) throw new Error("A trigger must belong to at least one thread");
		if (this.repo.triggers.get(trigger.id)) return "duplicate";
		const at = this.now();
		const filter = this.options.scope.scope(trigger);
		if (!filter.listened) {
			this.repo.triggers.save(trigger);
			this.repo.triggers.saveDisposition(trigger.id, {
				filtered: { code: filter.reason },
				fanout: [],
				at
			});
			return "filtered";
		}
		this.repo.triggers.save(trigger);
		const keys = trigger.threads.map(threadKey);
		const reached = /* @__PURE__ */ new Map();
		for (const ref of trigger.threads) {
			const thread = this.thread(ref);
			if (!thread.lastAt || trigger.at > thread.lastAt) thread.lastAt = trigger.at;
			thread.correlated = [.../* @__PURE__ */ new Set([...thread.correlated, ...keys.filter((other) => other !== thread.key)])];
			for (const ticketId of thread.subscriptions) {
				const ticket = this.repo.tickets.get(ticketId);
				const followed = !!thread.context?.includes(ticketId);
				const resumes = trigger.human && ticket?.ended?.by !== "human" && !followed;
				if (!ticket || !liveTicket(ticket) && !resumes) continue;
				reached.set(ticketId, {
					ticket,
					context: followed && (reached.get(ticketId)?.context ?? true)
				});
			}
			this.repo.threads.save(thread);
		}
		for (const [ticketId, { ticket, context: followed }] of reached) this.tickets.addInput(ticket, {
			id: key("input", ticketId, "trigger", trigger.id),
			kind: "trigger",
			triggerId: trigger.id,
			at,
			...trigger.human ? { human: true } : {},
			...followed ? { context: true } : {}
		});
		const fanout = [...reached.keys()], context = fanout.filter((id) => reached.get(id).context);
		const disposition = {
			fanout,
			...context.length ? { context } : {},
			at
		};
		this.repo.triggers.saveDisposition(trigger.id, disposition);
		if (!this.owners(trigger).length) this.queueForEval(trigger);
		for (const ticketId of fanout) this.tickets.wake(ticketId);
		this.emit("trigger.received", {
			triggerId: trigger.id,
			threads: trigger.threads.map(threadKey)
		});
		return "stored";
	}
};
//#endregion
//#region src/core/replies.ts
/** The Engine's messages to Channels, each by the rule that allows it. */
/**
* Replies writes the Engine's messages to Channels through the Outbox port: an acknowledgement, the answer to a person's
* question, a ticket's result, and its question for a person, each only when its rule allows it, under a deterministic id
* that keeps it from going out twice (idempotent). The Engine routes `reply` here; Tickets asks it for the acknowledgement
* an accept carries, and Assignments asks it to withdraw a question a report replaced.
*/
var Replies = class extends EnginePart {
	/**
	* Queue a message for the Channel its purpose names: an acknowledgement or an answer goes where that person's message was
	* written, attention where the message that raised the question was (or to the ticket's starting conversation), and a
	* result to the conversation where the ticket started (`result` is allowed only for a ticket in `ready`, `completed`,
	* `merged`, or `dropped`). Each message is queued at most once (idempotent). An acknowledgement, even one already queued,
	* records that the ticket's worker took the message up.
	* @throws UserError when the ticket or trigger is unknown or the purpose's rule refuses it, such as a result of a ticket
	* that is not ready, completed, merged, or dropped.
	*/
	reply(request) {
		return request.purpose === "acknowledgement" ? this.acknowledge(request) : this.answer(request);
	}
	/**
	* Queue the acknowledgement an accept carries where the message that started the ticket was written, if it has a Channel
	* and a person wrote it.
	*/
	acknowledgeAccepted(ticketId, trigger, text) {
		if (trigger.channel && trigger.human) this.options.outbox.send({
			id: key("ack", trigger.id),
			channel: trigger.channel,
			text,
			kind: "acknowledgement",
			ticketId
		});
	}
	/** Withdraw a ticket's question for a person from the outbox, unless it went out already. */
	withdrawAttention(attentionId) {
		this.options.outbox.withdraw(key("attention-reply", attentionId));
	}
	acknowledge(request) {
		const ticket = this.require(request.ticketId);
		if (!liveTicket(ticket)) throw new UserError("ackEnded");
		const trigger = this.repo.triggers.get(request.triggerId);
		if (!trigger) throw new UserError("unknownTrigger");
		if (!this.reaches(ticket, trigger, false)) throw new UserError("notReached");
		if (!trigger.channel) throw new UserError("ackNoChannel");
		const id = key("ack", trigger.id);
		const existing = this.options.outbox.status(id);
		if (!existing && !trigger.human) throw new UserError("ackNotPerson");
		if (!existing) this.options.outbox.send({
			id,
			channel: trigger.channel,
			text: request.text,
			kind: "acknowledgement",
			ticketId: ticket.id
		});
		this.takeUp(ticket.id, trigger.id);
		return {
			id,
			status: this.options.outbox.status(id) ?? "pending",
			reused: existing !== void 0
		};
	}
	answer(request) {
		const trigger = request.triggerId ? this.repo.triggers.get(request.triggerId) : void 0;
		if (request.triggerId && !trigger) throw new UserError("unknownTrigger");
		const ticket = request.ticketId ? this.require(request.ticketId) : trigger ? this.repo.tickets.list().find((item) => this.reaches(item, trigger)) : void 0;
		if (request.purpose === "result") {
			const outcome = ticket && ticketOutcome(ticket);
			const reported = !!ticket && liveTicket(ticket) && latestAssignment(ticket)?.report?.state === "ready";
			if (!ticket || !(outcome === "merged" || outcome === "completed" || outcome === "dropped" || reported)) throw new UserError("notReady");
		}
		const attention = request.purpose === "attention" ? ticket?.attention : void 0;
		if (request.purpose === "attention" && (!attention || attention.question !== request.question)) throw new UserError("notAttention");
		if (request.purpose === "answer" && !trigger?.human) throw new UserError("notQuestion");
		const id = attention ? key("attention-reply", attention.id) : key("reply", trigger?.id ?? ticket?.id ?? "", request.text);
		const existing = this.options.outbox.status(id);
		const ready = !ticket || !trigger || ticket.answers?.includes(trigger.id);
		if (request.purpose === "answer" && !ready && !existing) throw new UserError("noAnswer");
		const asker = attention?.triggerId ? this.repo.triggers.get(attention.triggerId) : void 0;
		const channel = request.purpose === "answer" ? trigger.channel : asker?.channel ?? (ticket ? this.sourceChannel(ticket) : void 0);
		if (!channel) throw new UserError("noChannel");
		this.options.outbox.send({
			id,
			channel,
			text: request.text,
			kind: "reply",
			...ticket ? { ticketId: ticket.id } : {}
		});
		if (request.purpose === "answer" && ticket && trigger && ticket.answers?.includes(trigger.id)) {
			ticket.answers = ticket.answers.filter((item) => item !== trigger.id);
			this.repo.tickets.save(ticket);
		}
		return {
			id,
			status: this.options.outbox.status(id) ?? "pending",
			reused: existing !== void 0
		};
	}
	/** The conversation a ticket started in: its origin Trigger's Channel, else its first Channel. */
	sourceChannel(ticket) {
		return this.source(ticket)?.channel ?? ticket.channels[0];
	}
};
//#endregion
//#region src/core/engine.ts
/** The domain Engine: the single entry point of the core, and the role interfaces its callers receive. */
/**
* Single transactional entry point for mutating Triggers, Threads, Decisions, Tickets, and Assignments.
* Coordinates Intake, Evals, Tickets, Assignments, and Replies inside synchronous repository transactions while queuing side
* effects through ports. Callers receive role-scoped `Pick` interfaces rather than the full engine.
*/
var Engine = class {
	options;
	repo;
	replies;
	tickets;
	assignments;
	evals;
	intake;
	constructor(options) {
		this.options = options;
		this.repo = options.repo;
		this.replies = new Replies(options);
		this.tickets = new Tickets(options, this.replies);
		this.assignments = new Assignments(options, this.tickets, this.replies);
		this.evals = new Evals(options, this.tickets);
		this.intake = new Intake(options, this.tickets);
	}
	/**
	* A Source's request to take in a Trigger: store it once, fan it out to the tickets that subscribe to its Threads (to an
	* ended one only a person's message, which resumes it at once unless processing is paused, and to none a person stopped),
	* and queue it for Eval on its primary Thread unless a ticket's worker decides it (see `followupOwners`).
	* Triggers that arrive while an Eval of that Thread runs wait together for the next one.
	*/
	receive(trigger) {
		return this.repo.atomic(() => this.intake.receive(trigger));
	}
	/**
	* A Source's request to make an open ticket follow one of its Threads, such as a pull request's, `own` when the ticket
	* opened it: the ticket subscribes to it, and a ready report ends it only once `followsDone` holds (see `Tickets.followsDone`).
	* @throws UserError when the ticket is unknown or has ended.
	*/
	bindThread(ticketId, thread, own) {
		return this.repo.atomic(() => this.tickets.bind(ticketId, thread, own));
	}
	/**
	* A Source's fact that a Thread closed, such as its pull request's merge, at the time it happened. An open ticket that
	* follows it ends once it is done with the Threads it follows, unless work resumed since the close has not finished, or
	* its worker took up a person's message the ticket decides after its latest report.
	*/
	threadClosed(thread, outcome, at) {
		this.repo.atomic(() => {
			this.tickets.threadClosed(thread, outcome, isoTime(at));
		});
	}
	/**
	* Requeues overdue Evals up to `REQUEUES` times before recording `unavailable` (undelivered Evals never expire), starts the
	* Evals of Threads whose queued Triggers wait, and resumes ended tickets a person's message reached while processing was
	* paused. While processing is paused, nothing expires: each Eval in progress notes when the pause began, and its deadline
	* moves forward by the pause's length once processing resumes. Each Eval and each ticket update takes one transaction.
	*/
	evaluateDue() {
		const policy = this.options.policy();
		for (const thread of this.repo.threads.active()) if (thread.evaluating) this.repo.atomic(() => {
			this.evals.due(thread, policy);
		});
		if (policy.paused) return;
		for (const ticket of this.repo.tickets.active()) if (!liveTicket(ticket) && ticket.undelivered.length) this.repo.atomic(() => {
			this.tickets.wake(ticket.id);
		});
		for (const thread of this.repo.threads.active()) if (thread.pending.length && !thread.evaluating) this.repo.atomic(() => {
			this.evals.start(thread.key, policy);
		});
	}
	/** The candidate of the Eval that holds a Trigger, as its assessor sees it; undefined while no Eval holds it. */
	candidate(triggerId) {
		return this.evals.candidate(triggerId);
	}
	/**
	* Decide a Trigger: the Eval that holds it, or a direct Eval of it alone when none does, such as a person's explicit
	* request the main Session routes. A proactive candidate is accepted only in `auto` mode with enabled rules its assessment
	* matched, and a Trigger that already started a ticket returns that ticket's Decision. An invalid stop is recorded as
	* `ignore`; one judged under an older Policy as `unavailable`.
	* @throws UserError when the Trigger is unknown or not admissible, `outcome.evalId` names an Eval that has finished, a
	* ticket's worker still decides the Trigger and the outcome is not a stop, or an inferred candidate is accepted outside `auto`
	* mode or without enabled matching rules.
	*/
	decide(triggerId, outcome) {
		return this.repo.atomic(() => this.evals.decide(triggerId, outcome));
	}
	/**
	* Attach a Trigger to a ticket that the message points at: the ticket follows the Trigger's Threads and receives it as an
	* Input with the routing note, and the Eval that holds the Trigger ends, since the ticket has it now; the other Triggers of
	* its batch wait for a fresh Eval. A note for an Input the worker already received goes out as a new Input, and so does a
	* message the ticket let go, read for context only, or had before it ended. An ended ticket resumes under its Mandate, at
	* once unless processing is paused.
	* @throws UserError for a ticket a person stopped, which withdrew its Mandate, or one whose Mandate the Policy no longer holds.
	*/
	attach(ticketId, triggerId, note) {
		return this.repo.atomic(() => {
			if (this.repo.triggers.disposition(triggerId)?.handbacks?.some((item) => item.ticketId === ticketId)) throw new UserError("handedBackHere");
			const trigger = this.tickets.attachable(ticketId, triggerId);
			this.evals.withdraw(trigger);
			this.tickets.attach(ticketId, trigger, note);
			this.evals.routed(triggerId, ticketId);
			this.tickets.wake(ticketId);
			return this.repo.tickets.get(ticketId);
		});
	}
	/**
	* Ask a running worker that waits in `waiting` state for its status; any other worker is left alone.
	* @returns whether the worker was asked.
	* @throws UserError when the ticket is unknown.
	*/
	requestStatus(ticketId) {
		return this.repo.atomic(() => this.tickets.requestStatus(ticketId));
	}
	/**
	* Queue a message for the Channel its purpose names: an acknowledgement or an answer goes where the person's message was
	* written, attention where the message that raised the question was, else, like a result, to the conversation the ticket
	* started in. A message queued before is not queued again (see `Replies.reply`).
	* @throws UserError when the ticket or trigger is unknown or the purpose's rule refuses it, such as a result of a ticket that
	* is not ready, completed, merged, or dropped.
	*/
	reply(request) {
		return this.repo.atomic(() => this.replies.reply(request));
	}
	/** The assessor delivered an Eval's candidate to its Session: the Eval's deadline counts from now. */
	candidateDelivered(evalId) {
		this.repo.atomic(() => {
			this.evals.delivered(evalId, this.options.policy());
		});
	}
	/**
	* Queue a stored Trigger for a fresh Eval, such as a person's replay; returns false while an Eval holds it.
	* @throws UserError when the trigger is unknown.
	*/
	reevaluate(triggerId) {
		return this.repo.atomic(() => this.evals.reevaluate(triggerId));
	}
	/**
	* A person dismisses the problem an unavailable Decision shows: the overview lists it no more.
	* @throws UserError for a Decision that is unknown or not unavailable.
	*/
	dismiss(decisionId) {
		return this.repo.atomic(() => this.evals.dismiss(decisionId));
	}
	/**
	* Drop every ticket's Subscription to a Thread, until a new Decision subscribes one again.
	* @returns whether a Subscription was dropped.
	*/
	unsubscribe(thread) {
		return this.repo.atomic(() => this.tickets.dropSubscriptions(thread, "person"));
	}
	/**
	* A person stops a ticket, which withdraws its Mandate: it ends and receives nothing more.
	* @throws UserError when the ticket is unknown.
	*/
	stopTicket(ticketId, reason) {
		return this.repo.atomic(() => this.tickets.stop(ticketId, reason));
	}
	/**
	* A person retries a ticket whose worker reported failed or blocked (or whose input delivery failed): the stalled
	* Assignment ends and a new one starts under the same Mandate.
	* @throws UserError when the ticket is unknown, has ended, or is not retryable.
	*/
	retryTicket(ticketId) {
		return this.repo.atomic(() => this.tickets.retry(ticketId));
	}
	/**
	* The Executor's fact that an Assignment runs; the Inputs that wait for it go out.
	* @throws UserError when the ticket is unknown.
	*/
	assignmentStarted(ticketId, assignmentId) {
		this.repo.atomic(() => {
			this.assignments.started(ticketId, assignmentId);
		});
	}
	/**
	* The Executor's fact that Inputs reached the Assignment that runs the ticket, which clears a failed delivery. A fact about
	* an Assignment that no longer runs is dropped. Its worker reads each once its Session takes it into a step (`inputsRead`).
	*/
	inputsDelivered(ticketId, assignmentId, inputIds) {
		this.repo.atomic(() => {
			this.assignments.delivered(ticketId, assignmentId, inputIds);
		});
	}
	/**
	* The Executor's fact that the worker's Session of an open ticket took the messages that carried Inputs into a step, from
	* which its model reads them: a report or the end of a turn after that counts them as read at the ticket's end.
	* @throws UserError when the ticket is unknown.
	*/
	inputsRead(ticketId, inputIds) {
		this.repo.atomic(() => {
			this.assignments.read(ticketId, inputIds);
		});
	}
	/** The Executor's fact that a turn of the worker of the Assignment that runs the ticket ended, after a report too. */
	turnEnded(ticketId, assignmentId) {
		this.repo.atomic(() => {
			this.assignments.turnEnded(ticketId, assignmentId);
		});
	}
	/** The Executor's fact that delivering Inputs to the Assignment that runs the ticket failed; the ticket shows it until a delivery succeeds. */
	deliveryFailed(ticketId, assignmentId, error) {
		this.repo.atomic(() => {
			this.assignments.deliveryFailed(ticketId, assignmentId, error);
		});
	}
	/**
	* A worker's request, through its Executor, to mark a Thread attached to its ticket unrelated, for `reason`: only that
	* ticket's Subscription drops, until a new Decision subscribes it again.
	* @throws UserError when the ticket is unknown, or for the Thread the ticket started on, one a Source bound it to (such as
	* its pull request's), or one it does not follow.
	*/
	markUnrelated(ticketId, thread, reason) {
		this.repo.atomic(() => {
			this.tickets.markUnrelated(ticketId, thread, reason);
		});
	}
	/**
	* An Executor's Subscription to a Thread it found related, for context: see `Tickets.followForContext` and `Thread.context`.
	* @returns false when the ticket already follows the Thread.
	* @throws UserError when the ticket is unknown or has ended.
	*/
	followForContext(ticketId, thread) {
		return this.repo.atomic(() => this.tickets.followForContext(ticketId, thread));
	}
	/**
	* A fact the main Session gives an open ticket's Executor: see `Tickets.note`.
	* @throws UserError when the ticket is unknown or has ended.
	*/
	note(ticketId, text) {
		return this.repo.atomic(() => this.tickets.note(ticketId, text));
	}
	/**
	* An Executor's hand-back of a message that reached its ticket but asks for more than it: see `Evals.handback`.
	* @returns whether it was queued for Eval: false while another ticket still decides it, and for one this ticket did not decide (see `Evals.handback`).
	* @throws UserError when the ticket or trigger is unknown, the trigger did not reach the ticket, or the ticket already handed it back.
	*/
	handback(ticketId, triggerId, reason) {
		return this.repo.atomic(() => this.evals.handback(ticketId, triggerId, reason));
	}
	/**
	* Record a report on an open ticket's current Assignment. Its question for a person (`attention`) is asked, kept, or
	* cleared (`null` or a `ready` report), and a replaced attention question whose reply has not been sent yet is withdrawn
	* from the outbox. A `blocked` or `failed` report holds back automated inputs until a human message arrives. A `dropped`
	* report ends the ticket, and a `ready` report ends it: `completed` without followed Threads, else with the `followsDone`
	* outcome once `followsDone` holds.
	* @throws UserError for an unknown or ended ticket, an ended assignment, a question that comes with a ready result or an
	* answer, or a question or answer that names a message that is not a person's or did not reach the ticket.
	*/
	report(ticketId, report) {
		return this.repo.atomic(() => this.assignments.report(ticketId, report));
	}
	/**
	* Handles an assignment that was running when the host stopped: restarts it with a recovery note unless its latest report is
	* `waiting`, `ready`, `blocked`, or `failed` and no Input reached its worker after that report, in which case it keeps its
	* Session and state and gets the Inputs that wait for it.
	*/
	assignmentInterrupted(ticketId, assignmentId) {
		this.repo.atomic(() => {
			this.assignments.interrupted(ticketId, assignmentId);
		});
	}
	/**
	* The Policy changed: each open ticket in `effects` is told how the change bears on it, and Evals in progress start again
	* under the new version.
	*/
	policyChanged(from, to, effects = /* @__PURE__ */ new Map()) {
		this.repo.atomic(() => {
			this.tickets.policyChanged(from, to, effects);
			this.evals.policyChanged(from, to);
		});
	}
};
//#endregion
//#region src/core/memory.ts
/** In-memory repository implementation for testing and ephemeral engine instances. */
const clone = (value) => structuredClone(value);
/**
* In-memory implementation of the Repositories port backed by cloned Map entries so caller mutations do not affect stored state.
* Provides snapshot-based atomic rollback and matches the ordering semantics of the SQLite store for Engine tests.
*/
var MemoryRepositories = class {
	triggerRows = /* @__PURE__ */ new Map();
	dispositions = /* @__PURE__ */ new Map();
	threadRows = /* @__PURE__ */ new Map();
	ticketRows = /* @__PURE__ */ new Map();
	decisionRows = /* @__PURE__ */ new Map();
	atomic(work) {
		const maps = [
			this.triggerRows,
			this.dispositions,
			this.threadRows,
			this.ticketRows,
			this.decisionRows
		];
		const snapshot = maps.map((map) => new Map(map));
		try {
			return work();
		} catch (error) {
			maps.forEach((map, index) => {
				map.clear();
				for (const [id, value] of snapshot[index]) map.set(id, value);
			});
			throw error;
		}
	}
	triggers = {
		get: (id) => clone(this.triggerRows.get(id)),
		save: (trigger) => {
			this.triggerRows.set(trigger.id, clone(trigger));
		},
		disposition: (id) => clone(this.dispositions.get(id)),
		saveDisposition: (id, value) => {
			this.dispositions.set(id, clone(value));
		}
	};
	threads = {
		get: (key) => clone(this.threadRows.get(key)),
		save: (thread) => {
			this.threadRows.set(thread.key, clone(thread));
		},
		list: () => [...this.threadRows.values()].map(clone),
		active: () => this.threads.list().filter((thread) => thread.pending.length > 0 || thread.evaluating !== void 0)
	};
	tickets = {
		get: (id) => clone(this.ticketRows.get(id)),
		save: (ticket) => {
			this.ticketRows.set(ticket.id, clone(ticket));
		},
		/** Newest first, matching the SQLite Store's order. */
		list: () => [...this.ticketRows.values()].reverse().map(clone),
		open: () => this.tickets.list().filter((ticket) => !ticket.ended),
		active: () => this.tickets.list().filter((ticket) => ticket.undelivered.length > 0 || ["pending", "running"].includes(latestAssignment(ticket)?.state ?? ""))
	};
	decisions = {
		get: (id) => clone(this.decisionRows.get(id)),
		save: (decision) => {
			this.decisionRows.set(decision.id, clone(decision));
		},
		byThread: (key) => [...this.decisionRows.values()].filter((decision) => decision.threadKey === key).map(clone)
	};
};
//#endregion
//#region src/admission.ts
/** Default admission rules (matching pre-table behavior): unaddressed messages from listed senders are inferred candidates; unlisted senders are ignored. */
const ADMISSION_DEFAULTS = {
	listedUnaddressed: "inferred",
	unlistedAddressed: "ignore",
	unlistedUnaddressed: "ignore"
};
//#endregion
//#region src/policy.ts
/**
* Runtime settings schemas, assessment validation, and policy gate evaluation.
* Who may originate work is configured per Source in that Source's own identities; the Policy never maps a person across Sources.
*/
const RuleIdSchema = z.string().regex(/^[a-zA-Z0-9_-]{1,80}$/);
const RuleAssessmentSchema = z.object({
	rule_id: RuleIdSchema,
	reason: z.string().trim().min(1).max(500)
}).strict().extend({ matched: z.boolean() }).strict();
const AdmissionDirectionSchema = z.object({
	implementation_requested: z.boolean(),
	target_basis: z.enum([
		"specified",
		"existing-standard",
		"exploratory",
		"undetermined"
	]),
	requires_design_decision: z.boolean(),
	evidence: z.string().trim().min(1).max(700)
}).strict();
/** Check whether an assessment established implementation intent and a settled target without open design decisions. */
function settledDirection(value) {
	const result = AdmissionDirectionSchema.safeParse(value);
	return result.success && result.data.implementation_requested && (result.data.target_basis === "specified" || result.data.target_basis === "existing-standard") && !result.data.requires_design_decision;
}
/** Check whether an assessment established an admissible direction (settled implementation, or a grounded exploratory target). */
function directionAllowed(value) {
	const result = AdmissionDirectionSchema.safeParse(value);
	return result.success && result.data.target_basis !== "undetermined";
}
/**
* Validate an assessment against enabled rules and convert it into an engine `AssessmentOutcome`.
* Standard rules require `settledDirection`; rules marked `exploratory: true` also accept grounded exploratory targets
* (`target_basis !== 'undetermined'`, even when product/design choices remain open or no direct code edit was requested).
* @throws when `rule_assessments` does not cover every enabled rule exactly once, or an accept omits `intent_evidence`.
*/
function assessmentOutcome(assessment, settings, strength) {
	const enabled = settings.policy.rules.filter((rule) => rule.enabled);
	const judged = assessment.rule_assessments;
	const ids = new Set(judged.map((item) => item.rule_id));
	if (judged.length !== enabled.length || ids.size !== judged.length || enabled.some((rule) => !ids.has(rule.id))) throw new Error("Exactly one assessment for every enabled rule is required; disabled, unknown or missing rule IDs are not allowed");
	const matches = judged.filter((item) => item.matched).map(({ rule_id, reason }) => ({
		rule_id,
		reason
	}));
	const evidence = assessment.intent_evidence ? { intent_evidence: assessment.intent_evidence } : {};
	const audit = {
		matches,
		rule_assessments: judged,
		direction: assessment.direction,
		...evidence
	};
	if (assessment.decision !== "accept") return {
		kind: assessment.decision,
		reason: assessment.reason,
		audit
	};
	if (!directionAllowed(assessment.direction)) return {
		kind: "ignore",
		audit,
		reason: { code: "directionUnsettled" }
	};
	if (!matches.length) return {
		kind: "ignore",
		audit,
		reason: { code: "noRuleMatched" }
	};
	const settled = settledDirection(assessment.direction);
	const exploratoryIds = new Set(enabled.filter((rule) => rule.exploratory).map((rule) => rule.id));
	const admitted = settled ? matches : matches.filter((item) => exploratoryIds.has(item.rule_id));
	if (!admitted.length) return {
		kind: "ignore",
		audit,
		reason: { code: "directionUnsettled" }
	};
	if (!assessment.intent_evidence) throw new Error("Acceptance requires intent_evidence");
	const { title, scope, worktree_name: name } = assessment;
	if (strength === "inferred" && settings.eval.mode !== "auto") {
		const proposal = {
			title,
			scope,
			worktree_name: name
		};
		return {
			kind: "ignore",
			audit: {
				...audit,
				would_accept: true,
				proposal
			},
			reason: {
				code: "observed",
				values: { text: assessment.reason }
			}
		};
	}
	return {
		kind: "accept",
		title,
		scope,
		reason: assessment.reason,
		...assessment.acknowledgement ? { acknowledgement: assessment.acknowledgement } : {},
		rules: admitted.map((match) => match.rule_id),
		audit,
		...name ? { name } : {}
	};
}
const DEFAULT_RULES = [{
	id: "copy",
	name: "Copy fixes",
	enabled: true,
	instruction: "Explicit requests to correct a typo, wording, punctuation or existing translation. Preserve product promises and business meaning."
}, {
	id: "visual",
	name: "Visual fixes",
	enabled: true,
	instruction: "Explicit implementation requests for local spacing, alignment, overflow or styling, with a specified target or an objectively established existing standard/correct state to restore. Locating an element or calling it inconsistent, unattractive or hard to understand does not establish a target. Do not invent visual style, information hierarchy, rendering or interaction decisions. No redesign, new interaction or behavior. A known spacing defect does not authorize adjacent undefined restyling; assess only a clearly separable authorized scope. If direction or scope is unsettled, observe only: no acknowledgement, worker or unsolicited question."
}];
/** An assessment rule; its instruction may also specify PR reviewers and whether to wait for their approval. */
const RuleSchema = z.object({
	id: RuleIdSchema,
	name: z.string().trim().min(1).max(LIMITS.ruleName),
	enabled: z.boolean(),
	exploratory: z.boolean().optional(),
	instruction: z.string().trim().min(1).max(LIMITS.ruleInstruction)
}).strict();
const RoleModelSchema = z.object({
	provider: z.string().trim().min(1),
	model: z.string().trim().min(1),
	reasoningEffort: z.string().trim().min(1).optional()
}).strict();
const AllowedSchema = z.object({
	id: z.string().trim().min(1).max(200),
	name: z.string().trim().max(100).optional()
}).strict();
const Weak = z.enum(["inferred", "ignore"]);
const AdmissionRowSchema = z.object({
	listedUnaddressed: Weak.optional(),
	unlistedAddressed: z.enum([
		"explicit",
		"inferred",
		"ignore"
	]).optional(),
	unlistedUnaddressed: Weak.optional()
}).strict();
const AdmissionTableSchema = z.record(z.string(), AdmissionRowSchema);
const SourcePolicySchema = z.object({
	allowed: z.array(AllowedSchema).default([]),
	admission: AdmissionTableSchema.default({})
}).catchall(z.unknown());
const PolicyConfigSchema = z.object({
	rules: z.array(RuleSchema).refine((rules) => new Set(rules.map((rule) => rule.id)).size === rules.length, "Duplicate rule IDs").default(DEFAULT_RULES),
	sources: z.record(z.string().regex(/^[a-z][a-z0-9-]*$/), SourcePolicySchema).default({})
}).strict();
const EvalConfigSchema = z.object({
	mode: z.enum([
		"off",
		"observe",
		"auto"
	]).default("observe"),
	timeoutSeconds: z.number().int().min(LIMITS.evalTimeoutSeconds.min).max(LIMITS.evalTimeoutSeconds.max).default(120),
	model: RoleModelSchema.nullable().default(null)
}).strict();
const CommandNameSchema = z.string().regex(/^[A-Za-z0-9._-]+$/).refine((name) => name !== "." && name !== "..", "Not a command name").refine((name) => !WORKER_COMMANDS.includes(name), `${WORKER_COMMANDS.join(", ")} cannot be blocked`);
/** Executor settings: worker model, concurrency, ticket directory root (empty defaults to `<stateDir>/work`), `prepare` command, and blocked commands. */
const ExecutorConfigSchema = z.object({
	model: RoleModelSchema.nullable().default(null),
	maxWorkers: z.number().int().min(LIMITS.maxWorkers.min).max(LIMITS.maxWorkers.max).default(3),
	directory: z.string().trim().refine((path) => path === "" || path.startsWith("/"), "An absolute path, or empty for <stateDir>/work").default(""),
	prepare: z.string().max(LIMITS.prepareCommand).default(""),
	blockedCommands: z.array(CommandNameSchema).default([])
}).strict();
const SourceInstanceSchema = z.object({
	enabled: z.boolean().default(true),
	config: z.record(z.string(), z.unknown()).default({})
}).strict();
const SettingsSchema = z.object({
	paused: z.boolean().default(false),
	sources: z.record(z.string().regex(/^[a-z][a-z0-9-]*$/), SourceInstanceSchema).default({}),
	policy: PolicyConfigSchema.default(() => PolicyConfigSchema.parse({})),
	eval: EvalConfigSchema.default(() => EvalConfigSchema.parse({})),
	executor: ExecutorConfigSchema.default(() => ExecutorConfigSchema.parse({}))
}).strict();
const POLICY_REVISION = "mandate-v3";
/**
* Compute a version hash for settings that affect work authorization.
* Changes to models, concurrency, pause state, or polling intervals do not invalidate existing decisions.
*/
function policyVersion(settings) {
	return key(POLICY_REVISION, JSON.stringify({
		rules: settings.policy.rules,
		mode: settings.eval.mode,
		sources: settings.policy.sources
	}));
}
function allowedSender(settings, actor) {
	return settings.policy.sources[actor.source]?.allowed.find((entry) => sameName(entry.id, actor.id));
}
/** Look up `actor` in the Source's `bots` policy list (validated by the Source's kind), whose messages are admitted as inferred candidates at most. */
function listedBot(settings, actor) {
	return z.array(AllowedSchema).catch([]).parse(settings.policy.sources[actor.source]?.bots ?? []).find((entry) => sameName(entry.id, actor.id));
}
const anyoneAllowed = (settings) => Object.values(settings.policy.sources).some((part) => part.allowed.length > 0);
const senderName = (entry) => entry.name || entry.id;
/** Check whether a thread has tickets of its own (excluding context-only subscriptions). */
const participating = (thread, tickets) => [...thread.subscriptions, ...tickets.map((ticket) => ticket.id)].some((id) => !thread.context?.includes(id));
const listened = (sources, source, meta) => sources.scope({
	source,
	meta
});
function admissionCell(allowed, addressed) {
	return allowed ? addressed ? void 0 : "listedUnaddressed" : addressed ? "unlistedAddressed" : "unlistedUnaddressed";
}
function admissionOf(settings, source, row, cell) {
	return (row === void 0 ? void 0 : settings.policy.sources[source]?.admission[row]?.[cell]) ?? ADMISSION_DEFAULTS[cell];
}
const STRENGTH = {
	ignore: 0,
	inferred: 1,
	explicit: 2
};
/** Compute how a settings change from `old` to `now` affects the authorization or matched rules of each open ticket. */
function policyEffects(tickets, old, now, scope) {
	const before = settingsPolicy(old, scope(old)), after = settingsPolicy(now, scope(now));
	const effects = /* @__PURE__ */ new Map();
	for (const ticket of tickets) {
		const rules = (ticket.mandate.basis.rules ?? []).flatMap((id) => {
			const was = old.policy.rules.find((rule) => rule.id === id), is = now.policy.rules.find((rule) => rule.id === id);
			if (!is?.enabled) return was?.enabled ? [{
				id,
				name: was.name,
				change: "disabled"
			}] : [];
			return JSON.stringify(was) === JSON.stringify(is) ? [] : [{
				id,
				name: is.name,
				change: "changed",
				instruction: is.instruction
			}];
		});
		const effect = rules.length ? { rules } : {};
		if (before.revalidate(ticket.mandate) && !after.revalidate(ticket.mandate)) {
			if (!settingsPolicy({
				...now,
				eval: old.eval,
				policy: {
					...now.policy,
					rules: old.policy.rules
				}
			}, scope(now)).revalidate(ticket.mandate)) Object.assign(effect, {
				requesterAllowed: false,
				requester: ticket.mandate.actor
			});
			else if (ticket.mandate.strength === "inferred" && old.eval.mode === "auto" && now.eval.mode !== "auto") effect.proactive = false;
		}
		if (Object.keys(effect).length) effects.set(ticket.id, effect);
	}
	return effects;
}
/** Build the active Policy for gating incoming Triggers and revalidating existing Ticket Mandates. */
function settingsPolicy(settings, sources) {
	const version = policyVersion(settings);
	const mode = settings.eval.mode;
	/** Gate non-human triggers: only listed bots (as inferred candidates) and senderless system/CI events may pass; other bots are rejected. */
	const machineGate = (trigger) => {
		const bot = trigger.actor.id ? listedBot(settings, trigger.actor) : void 0;
		if (trigger.actor.id && !bot) return {
			admissible: false,
			reason: "not_human"
		};
		const scope = listened(sources, trigger.source, trigger.meta);
		if (!scope.listened || !(trigger.addressed || scope.observed)) return {
			admissible: false,
			reason: "not_human"
		};
		const recorded = {
			source: trigger.source,
			scope: trigger.meta,
			...scope.row === void 0 ? {} : { row: scope.row }
		};
		const addressed = trigger.addressed ? { addressed: trigger.addressed } : {};
		if (bot) {
			if (mode === "off") return {
				admissible: false,
				reason: "admission_ignored"
			};
			return {
				admissible: true,
				strength: "inferred",
				basis: {
					...recorded,
					via: "bot",
					sender: senderName(bot),
					...addressed,
					observation: { mode }
				}
			};
		}
		const cell = "unlistedUnaddressed";
		if (admissionOf(settings, trigger.source, scope.row, cell) !== "inferred" || mode === "off") return {
			admissible: false,
			reason: "admission_ignored"
		};
		return {
			admissible: true,
			strength: "inferred",
			basis: {
				...recorded,
				via: "admission",
				cell,
				observation: { mode }
			}
		};
	};
	return {
		version,
		paused: settings.paused,
		evalTimeoutMs: settings.eval.timeoutSeconds * 1e3,
		gate(trigger, thread, tickets) {
			if (!trigger.human) return machineGate(trigger);
			const allowed = allowedSender(settings, trigger.actor);
			const scope = listened(sources, trigger.source, trigger.meta);
			const row = scope.listened ? scope.row : void 0;
			const recorded = {
				source: trigger.source,
				scope: trigger.meta,
				...row === void 0 ? {} : { row },
				...allowed ? { sender: senderName(allowed) } : {}
			};
			if (allowed && trigger.addressed) return {
				admissible: true,
				strength: "explicit",
				basis: {
					...recorded,
					via: "addressed",
					addressed: trigger.addressed
				}
			};
			const cell = admissionCell(!!allowed, !!trigger.addressed);
			const receivable = !!trigger.addressed || scope.listened && scope.observed;
			const admission = receivable ? admissionOf(settings, trigger.source, row, cell) : "ignore";
			const basis = {
				...recorded,
				via: "admission",
				cell,
				...trigger.addressed ? { addressed: trigger.addressed } : {}
			};
			if (admission === "explicit") return {
				admissible: true,
				strength: "explicit",
				basis
			};
			if (!(trigger.addressed === "direct" && !allowed) && (allowed || mode !== "off") && participating(thread, tickets)) return {
				admissible: true,
				strength: allowed ? "explicit" : "inferred",
				basis: {
					...recorded,
					via: "followup"
				}
			};
			if (admission === "inferred" && mode !== "off") return {
				admissible: true,
				strength: "inferred",
				basis: {
					...basis,
					observation: { mode }
				}
			};
			return {
				admissible: false,
				reason: !allowed ? "not_a_member" : receivable && admission === "ignore" ? "admission_ignored" : "no_mention"
			};
		},
		admitsInferred: (rules) => mode === "auto" && rules.length > 0 && rules.every((id) => settings.policy.rules.some((rule) => rule.enabled && rule.id === id)),
		revalidate(mandate) {
			const { basis } = mandate;
			const { source } = basis;
			const current = source && basis.scope ? listened(sources, source, basis.scope) : void 0;
			if (current && !current.listened) return false;
			const rulesOn = (rules) => (rules ?? []).every((id) => settings.policy.rules.some((rule) => rule.enabled && rule.id === id));
			if (basis.via === "followup") return mandate.strength === "explicit" || mode === "auto" && rulesOn(basis.rules);
			if (basis.via === "bot" && !listedBot(settings, mandate.actor)) return false;
			if (basis.via === "admission") {
				const { cell } = basis;
				const listed = !!allowedSender(settings, mandate.actor);
				if (cell === "unlistedAddressed" && listed) return true;
				const now = cell === "unlistedUnaddressed" && listed ? "listedUnaddressed" : cell;
				if (now === "listedUnaddressed" && !listed) return false;
				const admission = admissionOf(settings, source ?? "", current?.listened ? current.row : void 0, now);
				if (STRENGTH[admission] < STRENGTH[mandate.strength]) return false;
				if (mandate.strength === "explicit") return true;
			} else if (basis.via !== "bot" && !allowedSender(settings, mandate.actor)) return false;
			if ((basis.via === "admission" || basis.via === "listed" || basis.via === "bot") && basis.observation) return mode === "auto" && rulesOn(basis.rules);
			return true;
		}
	};
}
//#endregion
//#region src/infra/health.ts
/**
* Central registry of component health entries, enforcing single-writer ownership per entry name.
* Claimed by Runtime, Effects, Sessions, DshExecutor, Settings, and SourceRegistry, and read by management HTTP routes.
*/
var HealthBoard = class {
	entries = {};
	claimed = /* @__PURE__ */ new Set();
	claim(name, initial) {
		if (this.claimed.has(name)) throw new Error(`The health entry ${name} is reported by another part`);
		this.claimed.add(name);
		if (initial) this.entries[name] = initial;
		let held = true;
		return {
			get: () => this.entries[name],
			set: (health) => {
				if (held) this.entries[name] = health;
			},
			release: () => {
				if (!held) return;
				held = false;
				this.claimed.delete(name);
				delete this.entries[name];
			}
		};
	}
	get all() {
		return this.entries;
	}
};
//#endregion
//#region src/sources/registry.ts
/**
* Manages registered SourceKind plugins, validates their instance and policy configurations, and implements SourceScope for the Engine.
* Claims each registered kind's health entries on HealthBoard and mediates access to source channels, links, environment variables, and thread context readers for Runtime, Settings, Outbox, and MasterAssessor.
*/
var SourceRegistry = class {
	settings;
	board;
	registered;
	kinds = /* @__PURE__ */ new Map();
	health = /* @__PURE__ */ new Map();
	constructor(settings, board = new HealthBoard(), registered = () => () => {}) {
		this.settings = settings;
		this.board = board;
		this.registered = registered;
	}
	/** Registers a SourceKind, claims its health entries on HealthBoard (rejecting `sync:` prefixes owned by Settings), and returns an unregister disposer. */
	register(kind) {
		if (this.kinds.has(kind.kind)) throw new Error(`Source kind already registered: ${kind.kind}`);
		const refused = (name) => /* @__PURE__ */ new Error(`Source kind ${kind.kind} declares the health entry ${name}, which another part reports`);
		const synced = kind.health.find((name) => name.startsWith("sync:"));
		if (synced) throw refused(synced);
		const entries = /* @__PURE__ */ new Map();
		const release = () => {
			for (const [name, entry] of entries) {
				entry.release();
				this.health.delete(name);
			}
		};
		for (const name of kind.health) try {
			entries.set(name, this.board.claim(name, {
				state: "starting",
				detail: ""
			}));
		} catch {
			release();
			throw refused(name);
		}
		for (const [name, entry] of entries) this.health.set(name, entry);
		this.kinds.set(kind.kind, kind);
		const unregistered = this.registered(kind);
		return () => {
			this.kinds.delete(kind.kind);
			release();
			unregistered();
		};
	}
	/**
	* Returns the active health entries for `names`. A Source context writes through the entries it received when built,
	* so reports sent after that registration ended do nothing even if the kind registers again.
	*/
	healthEntries(names) {
		return new Map(names.flatMap((name) => {
			const entry = this.health.get(name);
			return entry ? [[name, entry]] : [];
		}));
	}
	kind(id) {
		return this.kinds.get(id);
	}
	/** Every registered kind's instance ordered by ID, followed by stored instances whose kind is not installed (with their config kept as stored). */
	instances(settings = this.settings()) {
		const installed = [...this.kinds.values()].sort((a, b) => a.kind.localeCompare(b.kind)).map((kind) => ({
			...this.resolve(kind, settings.sources[kind.kind]),
			installed: true
		}));
		const orphaned = Object.entries(settings.sources).filter(([id]) => !this.kinds.has(id)).map(([id, stored]) => ({
			id,
			kind: id,
			enabled: stored.enabled,
			config: stored.config,
			installed: false
		}));
		return [...installed, ...orphaned];
	}
	instance(id, settings = this.settings()) {
		const kind = this.kinds.get(id);
		return kind ? this.resolve(kind, settings.sources[id]) : void 0;
	}
	validate(id, value) {
		const kind = this.kinds.get(id);
		if (!kind) throw new Error(`Source kind not installed: ${id}`);
		return {
			enabled: value.enabled,
			config: kind.schema.parse(value.config)
		};
	}
	/** Validates each Source's part of a submitted Policy against its kind; policy parts for uninstalled Source kinds are kept as stored. */
	validatePolicy(parts) {
		return Object.fromEntries(Object.entries(parts).map(([id, part]) => {
			const policy = this.kinds.get(id)?.policy;
			const { admission, ...rest } = part;
			return [id, policy ? {
				...policy.schema.parse(rest),
				admission: AdmissionTableSchema.parse(admission ?? {})
			} : part];
		}));
	}
	policyPart(id, settings = this.settings()) {
		const policy = this.kinds.get(id)?.policy;
		if (!policy) return void 0;
		const { admission, ...rest } = settings.policy.sources[id] ?? {};
		const parsed = policy.schema.safeParse(rest);
		return {
			...parsed.success ? parsed.data : policy.schema.parse({}),
			admission: AdmissionTableSchema.safeParse(admission ?? {}).data ?? {}
		};
	}
	channelAllowed(channel, settings = this.settings()) {
		const kind = this.kinds.get(channel.source);
		if (!kind) return false;
		const instance = this.resolve(kind, settings.sources[channel.source]);
		return instance.enabled && (kind.channel?.allowed?.(channel.address, instance.config) ?? true);
	}
	/** Environment variable declarations for every installed kind, whether enabled or disabled. */
	declarations() {
		return [...this.kinds.values()].sort((a, b) => a.kind.localeCompare(b.kind)).flatMap((kind) => kind.environment ? [{
			kind: kind.kind,
			variables: kind.environment.variables
		}] : []);
	}
	environments(settings = this.settings()) {
		return [...this.kinds.values()].sort((a, b) => a.kind.localeCompare(b.kind)).flatMap((kind) => {
			const instance = this.resolve(kind, settings.sources[kind.kind]);
			return kind.environment && instance.enabled ? [{
				kind,
				environment: kind.environment,
				config: instance.config
			}] : [];
		});
	}
	/**
	* Sends a message idempotently through its Channel's kind; returns `'waiting'` while the kind is not installed, or
	* `'gone'` when the target (or a kind without channels) can never receive it.
	*/
	async send(message, commands) {
		const kind = this.kinds.get(message.channel.source);
		if (!kind) return "waiting";
		return kind.channel ? kind.channel.send({ commands }, message) : "gone";
	}
	link(channel, links) {
		return this.kinds.get(channel.source)?.channel?.link(channel.address, links) ?? {
			url: "",
			label: {
				zh: channel.source,
				en: channel.source
			}
		};
	}
	find(query) {
		const found = [...this.kinds.values()].flatMap((kind) => kind.find ? [kind.find(query)] : []);
		return {
			threads: [...new Set(found.flatMap((item) => item.threads))],
			terms: [...new Set(found.flatMap((item) => item.terms))]
		};
	}
	repliesTo(trigger) {
		return this.kinds.get(trigger.source)?.repliesTo?.(trigger);
	}
	threadContext(trigger, settings = this.settings()) {
		const kind = this.kinds.get(trigger.source);
		const context = kind?.threadContext;
		if (!kind || !context) return void 0;
		const { config } = this.resolve(kind, settings.sources[kind.kind]);
		return {
			messageId: context.messageId(trigger),
			read: (commands, part, cursor) => context.read(commands, trigger, part, cursor, config),
			images: (text) => context.images?.(text) ?? [],
			image: async (agent, commands, message, key, stateDir, signal) => {
				if (!context.image) throw new Error(`The ${kind.kind} Source has no images`);
				return context.image(agent, commands, trigger, message, key, stateDir, signal);
			}
		};
	}
	scope(input, settings = this.settings()) {
		const kind = this.kinds.get(input.source);
		const stored = settings.sources[input.source];
		if (!kind) return stored ? {
			listened: false,
			reason: "source_not_installed"
		} : {
			listened: true,
			observed: false
		};
		const instance = this.resolve(kind, stored);
		if (!instance.enabled) return {
			listened: false,
			reason: "source_disabled"
		};
		return kind.scope ? kind.scope({ meta: input.meta }, instance.config) : {
			listened: true,
			observed: false
		};
	}
	/** Falls back to schema defaults and disables the instance when stored configuration fails validation. */
	resolve(kind, stored) {
		const parsed = kind.schema.safeParse(stored?.config ?? {});
		return {
			id: kind.kind,
			kind: kind.kind,
			enabled: parsed.success && (stored?.enabled ?? true),
			config: parsed.success ? parsed.data : kind.schema.parse({})
		};
	}
};
//#endregion
//#region src/app/execution-environment.ts
/** Execution environment variables exposed to prepare commands and documented in worker Session instructions; never contains credentials. */
/** Variables registered by the Executor; `ticket` entries are populated only when a ticket is present. */
const EXECUTOR_VARIABLES = [
	{
		key: "DSH_SUPERAGENT_DIR",
		ticket: true,
		description: {
			zh: "这个工单的执行目录；执行器 Session 在其中工作",
			en: "This ticket's directory; the executor Session works in it"
		}
	},
	{
		key: "DSH_SUPERAGENT_NAME",
		ticket: true,
		description: {
			zh: "工单的短名，也是执行目录的名字",
			en: "The ticket's short name, also its directory's name"
		}
	},
	{
		key: "DSH_SUPERAGENT_TICKET",
		ticket: true,
		description: {
			zh: "工单 id",
			en: "The ticket id"
		}
	},
	{
		key: "DSH_SUPERAGENT_BLOCKED_COMMANDS",
		description: {
			zh: "这个执行环境禁止调用的命令，以空格分隔；不要运行它们",
			en: "Commands blocked in this execution environment, separated by spaces; never run them"
		}
	}
];
const executionRoot = (settings, stateDir) => settings.executor.directory || join(stateDir, "work");
/** Lists all declared variables grouped by owner; `enabled` is false for Sources that are currently switched off. */
function declaredVariables(sources, settings) {
	const on = new Set(sources.environments(settings).map((item) => item.kind.kind));
	return [{
		owner: "executor",
		enabled: true,
		variables: EXECUTOR_VARIABLES
	}, ...sources.declarations().map(({ kind, variables }) => ({
		owner: kind,
		enabled: on.has(kind),
		variables
	}))];
}
function environmentOf(input) {
	const { deployment, sources, settings, ticket, trigger } = input;
	const executor = {
		DSH_SUPERAGENT_BLOCKED_COMMANDS: settings.executor.blockedCommands.join(" "),
		...ticket ? {
			DSH_SUPERAGENT_DIR: ticket.directory,
			DSH_SUPERAGENT_NAME: ticket.name,
			DSH_SUPERAGENT_TICKET: ticket.id
		} : {}
	};
	const result = EXECUTOR_VARIABLES.filter((spec) => !spec.ticket || ticket).map((spec) => ({
		key: spec.key,
		value: executor[spec.key] ?? "",
		description: spec.description,
		owner: "executor"
	}));
	for (const { kind, environment, config } of sources.environments(settings)) {
		const values = environment.values({
			deployment,
			config,
			...trigger ? { trigger } : {}
		});
		for (const spec of environment.variables) result.push({
			key: spec.key,
			value: values[spec.key] ?? "",
			description: spec.description,
			owner: kind.kind
		});
	}
	return result;
}
/** Combines a ticket's fixed directory, name, and origin trigger with the deployment's current settings. */
function ticketEnvironment(input) {
	const { ticket, trigger, ...rest } = input;
	const values = {
		id: ticket.id,
		name: ticket.execution?.name ?? "",
		directory: ticket.execution?.directory ?? ""
	};
	return environmentOf({
		...rest,
		ticket: values,
		...trigger ? { trigger } : {}
	});
}
function environmentLines(variables) {
	return variables.map((variable) => `- ${variable.key} = ${JSON.stringify(variable.value)}: ${variable.description.en}.`).join("\n");
}
//#endregion
//#region src/app/effects.ts
/**
* Signals that an effect cannot run right now, such as when processing is paused or all worker slots are full.
* Effects reschedules the row after the initial retry delay without incrementing its failure count, and DshExecutor throws it from launch and delivery handlers.
*/
var Later = class extends Error {};
/**
* Durable SQLite-backed queue that persists side effects inside command transactions and dispatches them after commit.
* Coordinates per-kind handlers, concurrency limits, exponential backoff, and health reporting for MasterAssessor, DshExecutor, Sessions, and Outbox.
*/
var Effects = class {
	store;
	board;
	now;
	handlers = /* @__PURE__ */ new Map();
	health = /* @__PURE__ */ new Map();
	tasks = /* @__PURE__ */ new Set();
	/** Kinds whose last dispatch failed; the next dispatch that succeeds refreshes their health. */
	broken = /* @__PURE__ */ new Set();
	seq;
	scheduled = false;
	/** Effects run only between `start` and `drain`; rows queued before `start` wait, such as while setup is incomplete. */
	started = false;
	stopped = false;
	constructor(store, board, now = () => Date.now()) {
		this.store = store;
		this.board = board;
		this.now = now;
		this.seq = Number(store.db.prepare("SELECT IFNULL(MAX(seq), 0) AS seq FROM effect").get()?.seq ?? 0);
	}
	/** Upserts an effect in the caller's transaction, coalescing with any waiting row of the same kind and key while keeping its queue position. */
	enqueue(kind, key, payload) {
		this.store.db.prepare(`INSERT INTO effect (kind, key, value, seq, due, since) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(kind, key) DO UPDATE
      SET value = excluded.value, generation = generation + 1, attempts = 0, error = '', due = excluded.due`).run(kind, key, JSON.stringify(payload), ++this.seq, this.now(), new Date(this.now()).toISOString());
		this.kick();
	}
	handle(kind, run, options = {}) {
		if (this.handlers.has(kind)) throw new Error(`The ${kind} effects already have a handler`);
		this.health.set(kind, this.board.claim(kind));
		const { limit = () => 1, retry = [2e3, 6e4], ordered = false, quiet = false } = options;
		this.handlers.set(kind, {
			run,
			limit: ordered ? () => Math.min(1, limit()) : limit,
			retry,
			ordered,
			quiet
		});
		this.report(kind);
		this.kick();
	}
	pending(kind, key) {
		return key === void 0 ? !!this.store.db.prepare("SELECT 1 FROM effect WHERE kind = ? LIMIT 1").get(kind) : !!this.store.db.prepare("SELECT 1 FROM effect WHERE kind = ? AND key = ?").get(kind, key);
	}
	/** Drops a queued row by kind and key; if it is already running, that attempt finishes normally. */
	cancel(kind, key) {
		this.store.db.prepare("DELETE FROM effect WHERE kind = ? AND key = ?").run(kind, key);
		this.store.afterCommit(() => {
			this.report(kind);
		});
	}
	start() {
		this.started = true;
		this.kick();
	}
	kick() {
		if (this.scheduled) return;
		this.scheduled = true;
		queueMicrotask(() => {
			this.scheduled = false;
			this.dispatch();
		});
	}
	/** Resolves once no effect of `kind` (or of any kind) is running and none can start because none is due or `limit()` has no room. */
	async idle(kind) {
		for (;;) {
			this.dispatch();
			const running = [...this.tasks].filter((task) => kind === void 0 || task.kind === kind).map((task) => task.done);
			if (!running.length) return;
			await Promise.allSettled(running);
		}
	}
	/** Stops starting new effects and waits for running ones; waiting rows remain in SQLite for the next start. */
	async drain() {
		this.stopped = true;
		await Promise.allSettled([...this.tasks].map((task) => task.done));
	}
	dispatch() {
		if (!this.started || this.stopped) return;
		for (const [kind, handler] of this.handlers) try {
			const running = new Set([...this.tasks].filter((task) => task.kind === kind).map((task) => task.key));
			const rows = handler.ordered ? this.store.db.prepare("SELECT key, value, seq, generation, attempts, due FROM effect WHERE kind = ? ORDER BY seq LIMIT 1").all(kind) : this.store.db.prepare("SELECT key, value, seq, generation, attempts, due FROM effect WHERE kind = ? AND due <= ? ORDER BY seq LIMIT ?").all(kind, this.now(), 16 + running.size);
			const ready = handler.ordered && running.size ? [] : rows.filter((row) => row.due <= this.now() && !running.has(row.key));
			let room = ready.length ? handler.limit() - running.size : 0;
			for (const row of ready) {
				if (room-- <= 0) break;
				this.run(kind, handler, row);
			}
			if (this.broken.delete(kind)) this.report(kind);
		} catch (error) {
			this.failed(kind, error);
		}
	}
	run(kind, handler, row) {
		const task = {
			kind,
			key: row.key,
			done: Promise.resolve()
		};
		task.done = this.attempt(kind, handler, row).catch((error) => {
			this.failed(kind, error);
		}).finally(() => {
			this.tasks.delete(task);
			this.kick();
		});
		this.tasks.add(task);
	}
	async attempt(kind, handler, row) {
		let failure;
		try {
			await handler.run(JSON.parse(row.value), row.key);
		} catch (error) {
			failure = { error };
		}
		const own = "kind = ? AND key = ? AND seq = ? AND generation = ?", ownRow = [
			kind,
			row.key,
			row.seq,
			row.generation
		];
		if (!failure) this.store.db.prepare(`DELETE FROM effect WHERE ${own}`).run(...ownRow);
		else if (this.stopped) return;
		else if (failure.error instanceof Later) this.store.db.prepare(`UPDATE effect SET due = ? WHERE ${own}`).run(this.now() + handler.retry[0], ...ownRow);
		else {
			const delay = Math.min(handler.retry[1], handler.retry[0] * 2 ** Math.min(row.attempts, 16));
			this.store.db.prepare(`UPDATE effect SET attempts = attempts + 1, error = ?, due = ? WHERE ${own}`).run(String(failure.error).slice(0, 1e3), this.now() + delay, ...ownRow);
		}
		if (!this.stopped) this.report(kind);
	}
	failed(kind, error) {
		this.broken.add(kind);
		this.health.get(kind)?.set({
			state: "error",
			detail: `The effect queue failed: ${String(error)}`,
			at: new Date(this.now()).toISOString()
		});
	}
	report(kind) {
		const row = this.store.db.prepare(`SELECT COUNT(*) AS waiting, MIN(since) AS since, MAX(attempts) AS attempts,
      (SELECT error FROM effect WHERE kind = ? AND attempts > 0 ORDER BY seq DESC LIMIT 1) AS error FROM effect WHERE kind = ?`).get(kind, kind);
		const waiting = Number(row?.waiting ?? 0);
		const failing = Number(row?.attempts ?? 0) >= 3 && !this.handlers.get(kind)?.quiet;
		const detail = waiting ? `${waiting} waiting since ${String(row?.since)}` : "Nothing waiting";
		this.health.get(kind)?.set(failing ? {
			state: "error",
			detail: `${detail}; the last failure: ${String(row?.error)}`,
			at: new Date(this.now()).toISOString()
		} : {
			state: "ready",
			detail,
			at: new Date(this.now()).toISOString()
		});
	}
};
//#endregion
//#region src/sources/admission-context.ts
/** Selects the first five thread messages plus five messages on either side of `sourceId`, recording omitted gap counts. */
function threadWindow(messages, sourceId) {
	const trigger = messages.findIndex((message) => message.id === sourceId);
	const selected = messages.map((message, index) => ({
		message,
		index
	})).filter(({ index }) => index < 5 || trigger >= 0 && Math.abs(index - trigger) <= 5);
	let previous = -1;
	return {
		entries: selected.map(({ message, index }) => {
			const omitted_before = index - previous - 1;
			previous = index;
			return {
				message,
				position: index + 1,
				omitted_before
			};
		}),
		source_found: trigger >= 0,
		loaded_messages: messages.length,
		omitted_after: messages.length - previous - 1
	};
}
/**
* Reads up to `maxPages` of a trigger's thread and builds the bounded message window around the trigger; counts describe
* only this loaded snapshot (never unread history), and `status` reports fallback modes such as `chat_neighbours`.
*/
async function admissionContext(context, commands, maxPages) {
	const messages = [];
	const seen = /* @__PURE__ */ new Set();
	const cursors = /* @__PURE__ */ new Set();
	let next;
	let status;
	let more = true;
	for (let page = 0; more && page < maxPages; page++) {
		const result = await context.read(commands, "thread", next);
		for (const message of result.messages) if (!seen.has(message.id)) {
			seen.add(message.id);
			messages.push(message);
		}
		status ??= result.status;
		next = result.next;
		more = next !== void 0;
		if (next !== void 0 && cursors.has(next)) throw new Error("Thread pagination repeated a cursor; context is incomplete");
		if (next !== void 0) cursors.add(next);
	}
	return {
		messages,
		window: threadWindow(messages, context.messageId),
		complete: !more,
		next: more ? next ?? null : null,
		...status ? { status } : {}
	};
}
//#endregion
//#region src/app/cards.ts
/** Compact, bounded model-facing projections of triggers, tickets, threads, and decisions; full texts stay behind readable resources. */
/** Collapses whitespace and truncates text for display previews while keeping code, angle brackets, and links intact for model readers. */
function preview$1(text) {
	return text.replace(/\s+/g, " ").slice(0, 160);
}
function triggerCard(trigger, disposition) {
	return {
		trigger_id: trigger.id,
		source: trigger.source,
		...trigger.url ? { source_url: trigger.url } : {},
		actor: trigger.actor.id,
		thread: threadKey(trigger.threads[0]),
		human: trigger.human,
		at: trigger.at,
		preview: preview$1(trigger.text),
		chars: trigger.text.length,
		read: `trigger/${trigger.id}`,
		...disposition ? { disposition: {
			...disposition.filtered ? { filtered: reasonText(disposition.filtered) } : {},
			...disposition.decisionId ? { decision_id: disposition.decisionId } : {},
			delivered_to: disposition.fanout
		} } : {}
	};
}
function cardState(ticket) {
	if (ticket.ended) return ticket.ended.outcome;
	const stage = ticketStage(ticket);
	if (stage.stage === "person") return `person/${stage.action}`;
	return stage.stage === "idle" ? "idle" : stage.stage === "working" && stage.action ? "working/queued" : "working";
}
function ticketCard(ticket) {
	const ended = ticket.ended && {
		at: ticket.ended.at,
		by: ticket.ended.by,
		reason: ticket.ended.reason ?? ticket.ended.outcome
	};
	const { attention } = ticket;
	return {
		ticket_id: ticket.id,
		title: ticket.title,
		state: cardState(ticket),
		strength: ticket.mandate.strength,
		...pullOf(ticket) ? { pr_number: pullOf(ticket) } : {},
		...ended ? { ended } : {},
		...attention ? { attention: {
			question: attention.question,
			...attention.triggerId ? { trigger_id: attention.triggerId } : {}
		} } : {},
		preview: preview$1(latestReport(ticket)?.summary ?? ""),
		read: `ticket/${ticket.id}`
	};
}
/** Strips `policyVersion`, an internal hash that callers never query by. */
const mandateOf = ({ policyVersion: _version, ...mandate }) => mandate;
const INPUT_TEXT = 80;
/** Summarizes a ticket input inline for short text or as a resource reference, omitting decision IDs for worker Sessions. */
function inputLine(ticket, input, worker = false) {
	const read = { read: inputResource(ticket.id, input.id) };
	const names = input.kind === "trigger" || input.kind === "resumed" ? { trigger_id: input.triggerId } : input.kind === "reopen" && !worker ? { decision_id: input.decisionId } : input.kind !== "text" ? read : input.text.length <= INPUT_TEXT ? { text: input.text } : {
		preview: preview$1(input.text).slice(0, INPUT_TEXT),
		chars: input.text.length,
		...read
	};
	return {
		kind: input.kind,
		at: input.at,
		...names,
		...ticket.undelivered.includes(input.id) ? { undelivered: true } : {}
	};
}
function assignmentLine(ticket, item) {
	return {
		id: item.id,
		state: item.state,
		at: item.createdAt,
		...item.endedReason ? { ended_reason: reasonText({ code: item.endedReason }) } : {},
		...item.report ? { report: {
			state: item.report.state,
			at: item.report.at,
			preview: preview$1(item.report.summary).slice(0, 100),
			chars: item.report.summary.length,
			read: `ticket/${ticket.id}/report/${item.id}`
		} } : {}
	};
}
function newestPage(items, offset, size, line, next) {
	const newest = items.slice().reverse();
	const more = offset + size < newest.length;
	return {
		items: newest.slice(offset, offset + size).map(line),
		...more ? {
			next_resource: next,
			next_offset: offset + size
		} : {}
	};
}
/** Projects a ticket with its linked triggers, threads, and first pages of assignments and inputs, omitting decision IDs for workers. */
function ticketDetails(ticket, threads, batch, worker = false) {
	const { preview: _preview, ...card } = ticketCard(ticket);
	return {
		...card,
		trigger_id: ticket.origin.triggerId,
		...batch.length ? { batch: batch.map(batchLine) } : {},
		...worker ? {} : { decision_id: ticket.decisionId },
		threads,
		directory: ticket.execution?.directory,
		scope: ticket.mandate.scope,
		requested_by: ticket.mandate.actor.id,
		assignments: newestPage(ticket.assignments, 0, 3, (item) => assignmentLine(ticket, item), `ticket/${ticket.id}/assignments`),
		inputs: newestPage(ticket.inputs, 0, 10, (input) => inputLine(ticket, input, worker), `ticket/${ticket.id}/inputs`),
		assignment: `ticket/${ticket.id}/assignment`,
		result: `ticket/${ticket.id}/result`,
		transcript: `ticket/${ticket.id}/transcript`
	};
}
function threadCard(thread, label) {
	return {
		thread: thread.key,
		label,
		source: thread.ref.source,
		tickets: thread.subscriptions,
		...thread.evaluating ? { evaluating: {
			since: thread.evaluating.startedAt,
			deadline: thread.evaluating.deadline
		} } : {},
		pending: thread.pending.length,
		...thread.meta.pollError ? { error: preview$1(String(thread.meta.pollError)) } : {},
		...thread.meta.url ? { url: thread.meta.url } : {},
		read: `thread/${thread.key}`
	};
}
function decisionCard(decision) {
	return {
		decision_id: decision.id,
		kind: decision.kind,
		reason: reasonText(decision.reason),
		strength: decision.strength,
		thread: decision.threadKey,
		trigger_ids: decision.triggerIds,
		...decision.ticketId ? { ticket_id: decision.ticketId } : {},
		at: decision.at,
		read: `decision/${decision.id}`
	};
}
function decisionDetails(decision) {
	return {
		...decisionCard(decision),
		...decision.mandate ? { mandate: mandateOf(decision.mandate) } : {},
		...decision.audit ? { audit: decision.audit } : {}
	};
}
/** Slices text by UTF-16 code units so concatenated pages reconstruct the exact string. */
function textPage(resource, text, offset, limit) {
	const end = Math.min(text.length, offset + limit);
	return {
		resource,
		offset,
		total_chars: text.length,
		next_offset: end < text.length ? end : null,
		text: text.slice(offset, end)
	};
}
function relatedTickets(tickets) {
	return {
		related_tickets: [...tickets].sort((a, b) => Number(!a.ended) === Number(!b.ended) ? b.createdAt.localeCompare(a.createdAt) : a.ended ? 1 : -1).slice(0, 8).map(ticketCard),
		tickets_total: tickets.length
	};
}
//#endregion
//#region src/infra/paths.ts
/** Resolves packaged asset paths from either the source tree or the compiled lib/ output. */
let cached;
function packageRoot() {
	if (cached) return cached;
	let directory = dirname(fileURLToPath(import.meta.url));
	for (let depth = 0; depth < 6; depth++) {
		const manifest = join(directory, "package.json");
		if (existsSync(manifest)) try {
			if (JSON.parse(readFileSync(manifest, "utf8")).name === "dsh-superagent") return cached = directory;
		} catch {}
		directory = dirname(directory);
	}
	throw new Error("dsh-superagent package root not found");
}
const packagePath = (...parts) => join(packageRoot(), ...parts);
//#endregion
//#region src/app/skill-files.ts
/** Loads packaged built-in skill definitions and prompt templates from disk. */
/**
* Reads a packaged text file with normalized Unix line endings.
* @throws Naming the file when it is missing or whitespace-only, because `dsh-superagent` cannot load without it.
*/
function packaged(...parts) {
	const path = packagePath(...parts);
	let text;
	try {
		text = readFileSync(path, "utf8").replaceAll("\r\n", "\n");
	} catch (error) {
		throw error.code === "ENOENT" ? new Error(`Missing packaged file: ${path}`, { cause: error }) : error;
	}
	if (!text.trim()) throw new Error(`Empty packaged file: ${path}`);
	return {
		path,
		text
	};
}
function load(name) {
	const { path, text } = packaged("skills", `dsh-superagent-${name}`, "SKILL.md");
	const match = /^---\nname: ([^\n]+)\ndescription: ([^\n]+)\n---\n\n([\s\S]*)$/.exec(text);
	if (!match) throw new Error(`Invalid packaged skill: ${path}`);
	return {
		name: match[1],
		description: match[2],
		content: match[3],
		path
	};
}
const bundledSkills = {
	feishu: load("feishu"),
	github: load("github")
};
/**
* Loads a built-in prompt file (`prompts/<name>.md`). Source `.md` files are written one sentence per line for
* readable diffs; `promptFile` joins lines within each paragraph with spaces while keeping blank-line paragraph breaks.
*/
function promptFile(name) {
	return packaged("prompts", `${name}.md`).text.trim().split(/\n(?:[ \t]*\n)+/).map((paragraph) => paragraph.split("\n").map((line) => line.trim()).join(" ")).join("\n");
}
//#endregion
//#region src/app/context.ts
/** Built-in prompt sections, role policies, and transcript projections for orchestrator and worker Sessions. */
/** Built-in host-delivery and tool-usage rules shared by all Sessions; a team may override them (`builtInParts`). */
const sharedPrompt = promptFile("shared");
const masterPrompt = promptFile("orchestrator");
const workerPrompt = promptFile("worker");
/** Built-in policy sections referenced by role prompts; a team may override them. */
const guides = Object.fromEntries([
	"subscriptions",
	"replies",
	"dispatch",
	"work"
].map((name) => [name, promptFile(name)]));
/** Bundled Source skills registered by dsh-superagent; a team may override their text. */
const sourceSkills = {
	feishu: bundledSkills.feishu.content,
	github: bundledSkills.github.content
};
const cliNotes = promptFile("cli");
/** Default text for the team-editable prompt sections (communication, ticket scope, and PR delivery). */
const teamDefaults = {
	communication: promptFile("team/communication"),
	scope: promptFile("team/scope"),
	delivery: promptFile("team/delivery")
};
const mainAdmissionPolicy = promptFile("admission");
const handoff = {
	shared: promptFile("handoff"),
	orchestrator: promptFile("handoff-orchestrator"),
	worker: promptFile("handoff-worker")
};
const handoffPolicy = (role) => `${handoff.shared}\n${handoff[role]}`;
const autoMergeThreshold = (lines) => `it changes fewer than ${lines} lines (additions plus deletions);`;
/** Retains message content while omitting streamed chunks, usage accounting, and reasoning blocks. */
function transcriptEntry(event) {
	if (event.type !== "user/message" && event.type !== "tool/result" && event.type !== "assistant/message") return void 0;
	const message = event.type === "user/message" ? event.data : event.data.message;
	return {
		type: event.type,
		message: {
			role: message.role,
			content: message.content.filter((block) => block.type !== "reasoning")
		}
	};
}
//#endregion
//#region src/app/views/text.ts
/** Text sanitization and formatting helpers for plain-text previews and HTML-free Markdown in views. */
const ENTITIES = {
	amp: "&",
	lt: "<",
	gt: ">",
	quot: "\"",
	"#39": "'",
	nbsp: " "
};
/** Strips HTML comments and tags, decodes basic entities, and strips again to catch entity-encoded tags. */
const withoutHtml = (text) => text.replace(/<!--[\s\S]*?-->/g, "").replace(/<\/?[a-zA-Z][^>]*>/g, "").replace(/&(amp|lt|gt|quot|#39|nbsp);/g, (_match, name) => ENTITIES[name]).replace(/<!--[\s\S]*?-->/g, "").replace(/<\/?[a-zA-Z][^>]*>/g, "");
function plain(text, lines = false) {
	const result = withoutHtml(text).replace(/!\[[^\]]*\]\([^)]*\)|\[Image: [^\]]*\]/g, "[image]").replace(/\[([^\]]+)\]\((?:[^)]*)\)/g, "$1").replace(/^#{1,6}\s+/gm, "").replace(/^\s*[-*]\s+/gm, lines ? "• " : "").replace(/(\*\*|__|`)/g, "");
	return lines ? result.replace(/[ \t]+/g, " ").replace(/\n{3,}/g, "\n\n").trim() : result.replace(/\s+/g, " ").trim();
}
const markdown = (text) => withoutHtml(text).replace(/!\[[^\]]*\]\([^)]*\)|\[Image: [^\]]*\]/g, "[image]").trim();
const scalar = (value) => value === null || typeof value !== "object";
function inline(value) {
	if (scalar(value)) return value === null ? "" : String(value);
	return (Array.isArray(value) ? value : Object.values(value)).map(inline).filter(Boolean).join(Array.isArray(value) ? ", " : " · ");
}
function jsonLines(value) {
	if (Array.isArray(value) && !value.every(scalar)) return value.map((item) => `- ${inline(item)}`);
	if (value && typeof value === "object" && !Array.isArray(value)) return Object.entries(value).flatMap(([name, item]) => scalar(item) || Array.isArray(item) && item.every(scalar) ? [`${name}: ${inline(item)}`] : [`${name}:`, ...jsonLines(item)]);
	return [inline(value)];
}
/** Formats JSON payloads (or `label: <JSON>` notices) as key-value lines; returns non-JSON text unchanged. */
function readable$1(text) {
	const match = /^(?:([^\n{[]{1,200}): )?(\{[\s\S]*\}|\[[\s\S]*\])$/.exec(text.trim());
	if (!match) return text;
	try {
		return [...match[1] ? [match[1]] : [], ...jsonLines(JSON.parse(match[2]))].join("\n");
	} catch (error) {
		return text;
	}
}
function preview(text, length = 160) {
	return plain(readable$1(text)).slice(0, length);
}
const attribute = (value) => typeof value === "string" && value ? value : void 0;
//#endregion
//#region src/app/views/records.ts
/** Shared view projections for triggers, tickets, threads, decisions, and channel links. */
const page = (items, offset, limit) => ({
	items: items.slice(offset, offset + limit),
	total: items.length,
	next_offset: offset + limit < items.length ? offset + limit : null
});
const DAY = 864e5;
const dayAgo = () => (/* @__PURE__ */ new Date(Date.now() - DAY)).toISOString();
const newestFirst = (a, b) => b.updatedAt.localeCompare(a.updatedAt);
/**
* The owners of follow-ups as one request reads them: the rows of a page share their tickets and Threads, so each is read
* once however many rows it decides.
*/
function ownersOf(store) {
	const once = (read) => {
		const seen = /* @__PURE__ */ new Map();
		return (id) => {
			if (!seen.has(id)) seen.set(id, read(id));
			return seen.get(id);
		};
	};
	const records = {
		tickets: { get: once((id) => store.tickets.get(id)) },
		threads: { get: once((key) => store.threads.get(key)) },
		triggers: store.triggers
	};
	return (trigger) => followupOwners(trigger, records);
}
function snapshot(host) {
	const { store, sources } = host;
	let subscribed;
	const threadsOf = (ticketId) => {
		if (!subscribed) {
			subscribed = /* @__PURE__ */ new Map();
			for (const thread of store.read.subscribedThreads()) for (const id of thread.subscriptions) subscribed.set(id, [...subscribed.get(id) ?? [], thread]);
		}
		return subscribed.get(ticketId) ?? [];
	};
	const settings = store.settings();
	const rules = new Map(settings.policy.rules.map((rule) => [rule.id, rule.name]));
	const named = (name) => ({
		zh: name,
		en: name
	});
	const actor = ({ source, id }, human) => {
		if (!id) return {
			source,
			id
		};
		const entry = allowedSender(settings, {
			source,
			id
		}) ?? listedBot(settings, {
			source,
			id
		});
		if (entry) return {
			source,
			id,
			name: named(entry.name || entry.id)
		};
		const unnamed = sources.kind(source)?.policy?.unnamed;
		return {
			source,
			id,
			name: unnamed ? human === false ? unnamed.bot : unnamed.person : named(id)
		};
	};
	return {
		...host,
		threadsOf,
		rule: (id) => ({
			id,
			name: rules.get(id) ?? id
		}),
		actor,
		owners: ownersOf(store)
	};
}
/**
* The Triggers of a Thread's queue that wait for an Eval: a person's follow-up a ticket still decides, which an older
* version queued, leaves the queue with the next Eval without one.
*/
const awaitingEval = ({ store, owners }, thread) => thread.pending.filter((id) => {
	const trigger = store.triggers.get(id);
	return !trigger || !owners(trigger).length;
});
/**
* A trigger with where it went: queued for Eval, the Decision that consumed it, the Tickets it fanned out to, `delivered`
* when it is a person's follow-up that a ticket's worker decides without an Eval, and the Tickets that handed it back for
* a new Eval, with why; `requeue` when a person may send it to Eval, which is where no Eval reached a judgement: its Source
* filtered it, its Eval was unavailable, a ticket's worker still decides it, or it reached a ticket and nothing decided it,
* such as a message a worker neither acknowledged, answered nor handed back, or one only a stop was decided on.
*/
function triggerView(view, trigger, threadDecisions) {
	const { store } = view;
	const disposition = store.triggers.disposition(trigger.id);
	const home = store.threads.get(threadKey(trigger.threads[0]));
	const decision = disposition?.decisionId ? store.decisions.get(disposition.decisionId) : (threadDecisions ?? (home ? store.decisions.byThread(home.key) : [])).filter((item) => item.triggerIds.includes(trigger.id)).at(-1);
	const delivered = view.owners(trigger).length > 0;
	const queued = !!home?.pending.includes(trigger.id) && !delivered;
	const evaluating = !!home?.evaluating?.triggerIds.includes(trigger.id);
	const decided = !!disposition?.acked?.length || !!decision && settled(decision);
	const unjudged = !!disposition?.filtered || decision?.kind === "unavailable" || delivered || !!disposition?.fanout.length && !decided || !!decision && !decided;
	const requeue = trigger.human && !queued && !evaluating && unjudged;
	return {
		id: trigger.id,
		source: trigger.source,
		actor: view.actor(trigger.actor, trigger.human),
		human: trigger.human,
		at: trigger.at,
		text: plain(readable$1(trigger.text), true),
		preview: preview(trigger.text),
		url: trigger.url,
		threads: trigger.threads.map(threadKey),
		actions: { requeue },
		disposition: {
			queued,
			evaluating,
			delivered,
			filtered: disposition?.filtered,
			fanout: disposition?.fanout ?? [],
			handbacks: (disposition?.handbacks ?? []).map((item) => ({
				...item,
				title: store.tickets.get(item.ticketId)?.title ?? item.ticketId
			})),
			decision: decision ? {
				id: decision.id,
				outcome: outcomeOf$1(decision),
				reason: decision.reason,
				ticketId: decision.ticketId
			} : void 0
		}
	};
}
/** Single-line summary of why a ticket in the `person` stage is waiting on human action (omitted once answered and back with the Executor). */
function ticketNote(ticket, stage) {
	if (stage.stage !== "person") return void 0;
	if (stage.action === "answer" && ticket.attention) return {
		text: preview(ticket.attention.question),
		error: false
	};
	if (stage.action === "delivery" && ticket.delivery) return {
		text: preview(ticket.delivery.error),
		error: true
	};
	const summary = latestReport(ticket)?.summary;
	if (stage.action !== "blocked" && stage.action !== "failed" || !summary) return void 0;
	return {
		text: preview(summary.split("\n")[0]),
		error: stage.action === "failed"
	};
}
function ticketSummary(ticket) {
	const stage = ticketStage(ticket);
	const note = ticketNote(ticket, stage);
	const state = liveTicket(ticket) ? "open" : "ended";
	return {
		id: ticket.id,
		title: ticket.title,
		state,
		...stage,
		...note ? { note } : {},
		actions: {
			retry: canRetry(ticket),
			stop: liveTicket(ticket)
		},
		strength: ticket.mandate.strength,
		ended: ticket.ended,
		attention: ticket.attention && {
			...ticket.attention,
			question: markdown(ticket.attention.question)
		},
		assignments: ticket.assignments.length,
		inputs: ticket.inputs.length,
		undelivered: ticket.undelivered.length,
		deliveryError: attribute(ticket.delivery?.error),
		sessionId: ticket.assignments.some((item) => item.startedAt) ? workerSessionId(ticket.id) : "",
		directory: attribute(ticket.execution?.directory),
		summary: latestReport(ticket)?.summary ?? "",
		createdAt: ticket.createdAt,
		updatedAt: ticket.updatedAt
	};
}
function threadUrl(store, thread) {
	return attribute(thread.meta.url) ?? store.read.firstTrigger(thread.key)?.url;
}
function threadFacts(store, thread) {
	const url = threadUrl(store, thread);
	return {
		key: thread.key,
		source: thread.ref.source,
		title: threadTitle(store, thread),
		...url ? { url } : {},
		facts: thread.meta.facts ?? {}
	};
}
const ticketLine = (view, ticket) => ({
	...ticketSummary(ticket),
	threads: view.threadsOf(ticket.id).map((thread) => threadFacts(view.store, thread))
});
function threadTitle(store, thread) {
	const label = attribute(thread.meta.label);
	if (label) return label;
	const first = store.read.firstTrigger(thread.key, true) ?? store.read.firstTrigger(thread.key);
	return first ? preview(first.text, 80) : thread.key;
}
function latestOnThread(view, thread) {
	const trigger = view.store.read.threadTriggers(thread.key, 1)[0];
	if (!trigger) return void 0;
	return {
		actor: view.actor(trigger.actor, trigger.human),
		human: trigger.human,
		at: trigger.at,
		preview: preview(trigger.text, 120)
	};
}
function threadStage(thread, pending, tickets) {
	if (attribute(thread.meta.pollError)) return "error";
	if (thread.evaluating) return "evaluating";
	if (pending) return "queued";
	if (tickets.some((ticket) => ticket.state === "open")) return "subscribed";
	return tickets.length ? "dormant" : "unsubscribed";
}
function threadSummary(view, thread) {
	const { store } = view;
	const tickets = thread.subscriptions.map((id) => {
		const ticket = store.tickets.get(id);
		return {
			id,
			title: ticket?.title ?? id,
			state: !ticket ? "unknown" : liveTicket(ticket) ? "open" : "ended"
		};
	});
	const pending = awaitingEval(view, thread).length;
	return {
		key: thread.key,
		source: thread.ref.source,
		title: threadTitle(store, thread),
		stage: threadStage(thread, pending, tickets),
		latest: latestOnThread(view, thread),
		lastAt: thread.lastAt ?? thread.createdAt,
		createdAt: thread.createdAt,
		subscriptions: thread.subscriptions.length,
		tickets,
		evaluating: thread.evaluating ? {
			id: thread.evaluating.id,
			strength: thread.evaluating.strength,
			triggers: thread.evaluating.triggerIds.length,
			startedAt: thread.evaluating.startedAt,
			deadline: thread.evaluating.deadline
		} : void 0,
		pending,
		pollError: attribute(thread.meta.pollError),
		url: threadUrl(store, thread),
		facts: thread.meta.facts ?? {}
	};
}
/** Resolves a channel link, preferring the specific trigger URL when the source link references a trigger. */
function channelLink({ store, links }, channel) {
	const { url, label, triggerId } = links(channel);
	return {
		source: channel.source,
		url: triggerId && store.triggers.get(triggerId)?.url || url,
		label
	};
}
/** Parses stored assessment audit metadata, tolerating fields omitted or shaped differently by older versions. */
const AuditSchema = z.object({
	would_accept: z.boolean().optional().catch(void 0),
	rule_assessments: z.array(z.object({
		rule_id: z.string(),
		matched: z.boolean(),
		reason: z.string()
	})).optional().catch(void 0),
	matches: z.array(z.object({
		rule_id: z.string(),
		reason: z.string()
	})).optional().catch(void 0),
	direction: z.object({
		implementation_requested: z.boolean(),
		target_basis: z.string(),
		requires_design_decision: z.boolean(),
		evidence: z.string()
	}).optional().catch(void 0)
}).catch({});
const outcomeOf$1 = (decision) => decision.kind === "ignore" && AuditSchema.parse(decision.audit ?? {}).would_accept ? "wouldAccept" : decision.kind;
function decisionView(view, decision) {
	const { store } = view;
	const thread = store.threads.get(decision.threadKey);
	const texts = decision.triggerIds.flatMap((id) => {
		const trigger = store.triggers.get(id);
		return trigger ? [preview(trigger.text)] : [];
	});
	const audit = AuditSchema.parse(decision.audit ?? {});
	const judged = audit.rule_assessments ?? audit.matches?.map((match) => ({
		...match,
		matched: true
	})) ?? [];
	return {
		id: decision.id,
		kind: decision.kind,
		outcome: outcomeOf$1(decision),
		reason: decision.reason,
		at: decision.at,
		strength: decision.strength,
		ticketId: decision.ticketId,
		triggerIds: decision.triggerIds,
		thread: decision.threadKey,
		rules: judged.map((rule) => ({
			...view.rule(rule.rule_id),
			matched: rule.matched,
			reason: rule.reason
		})),
		...audit.direction ? { direction: audit.direction } : {},
		...thread ? { threadTitle: threadTitle(store, thread) } : {},
		preview: texts.join(" / "),
		ticketTitle: decision.ticketId ? store.tickets.get(decision.ticketId)?.title : void 0
	};
}
//#endregion
//#region src/app/links.ts
/** Resolves and caches a trigger's external message URL, falling back to a readable resource path when lookup fails. */
async function sourceLink(host, trigger, signal) {
	if (trigger.url) return { source_url: trigger.url };
	const ref = feishuRef(trigger);
	if (!ref) return {};
	const cacheKey = `${ref.chatId}:${ref.messageId}`;
	const cached = host.links.get(cacheKey);
	if (cached) return { source_url: cached };
	let url;
	try {
		const timeout = AbortSignal.timeout(feishuSettings(host.sources).linkTimeoutMs);
		url = await readFeishuLink(host.commands.withSignal(AbortSignal.any([signal ?? host.lifetime, timeout])), ref);
	} catch {
		host.lifetime.throwIfAborted();
		signal?.throwIfAborted();
		return { source_url_read: `feishu/${trigger.id}/message` };
	}
	host.links.set(cacheKey, url);
	return { source_url: url };
}
function repliedTo({ store, sources }, trigger) {
	const parent = sources.repliesTo(trigger);
	return parent === void 0 ? void 0 : store.triggers.get(parent);
}
/** Finds tickets subscribed to threads referenced in `trigger.text` (such as `#12` or URLs) that are not already in `known`. */
function referencedTickets(host, trigger, known) {
	const threads = (trigger.text.match(/#\d+|https?:\/\/[^\s)>\]]+/g) ?? []).flatMap((reference) => host.sources.find(reference).threads);
	const ids = new Set(threads.flatMap((thread) => host.store.threads.get(thread)?.subscriptions ?? []));
	for (const ticket of known) ids.delete(ticket.id);
	return [...ids].flatMap((id) => host.store.tickets.get(id) ?? []).slice(0, 4);
}
/** Builds the main Session's candidate card with routing metadata, handback history, and related or referenced tickets. */
async function candidateCard(host, candidate) {
	const primary = candidate.triggers.at(-1);
	const settings = host.store.settings();
	const delivered = host.store.triggers.disposition(primary.id)?.fanout ?? [];
	const referenced = referencedTickets(host, primary, candidate.tickets);
	const handedBack = candidate.triggers.flatMap((trigger) => (host.store.triggers.disposition(trigger.id)?.handbacks ?? []).map((item) => ({
		trigger_id: trigger.id,
		ticket_id: item.ticketId,
		reason: item.reason
	})));
	const others = candidate.triggers.filter((trigger) => trigger.id !== primary.id);
	return {
		...triggerMessage(primary, await sourceLink(host, primary), void 0, repliedTo(host, primary)),
		strength: candidate.strength,
		mode: settings.eval.mode,
		...others.length ? { batch: others.map((trigger) => triggerCard(trigger)) } : {},
		...handedBack.length ? { handed_back: handedBack } : {},
		...relatedTickets(candidate.tickets),
		...delivered.length ? { delivered_to: delivered } : {},
		...referenced.length ? { referenced_tickets: referenced.map(ticketCard) } : {},
		next_action: candidate.strength === "explicit" ? "Route it with orchestrator_route as dispatch says: accept, attach, stop or ignore." : "Ignore it with orchestrator_route if the card shows it touches no enabled rule; else assess it with orchestrator_eval, orchestrator_eval_read, then orchestrator_eval_decide."
	};
}
//#endregion
//#region src/app/notices.ts
/** Formats background notices and steering relays delivered to the main Session via the effect queue. */
/** Builds a notice for a saved prompt configuration revision, coalescing under `'prompts'`. */
const promptsNotice = (revision) => [
	"prompts",
	{
		prompt_config_saved: revision,
		effect: "next-request",
		read: `prompts/${revision}`
	},
	`Prompt configuration saved (revision ${revision})`
];
/**
* Builds a notice for a saved settings block with the changed dot-separated paths (coalescing per block under
* `settings:<block>`), or for the whole settings on legacy saves that recorded no block.
*/
const settingsNotice = (block, changed = []) => block ? [
	`settings:${block}`,
	{
		settings_saved: block,
		changed,
		read: `settings/${block}`
	},
	`Settings saved: ${block}`
] : [
	"settings",
	{
		settings_saved: true,
		read: "settings"
	},
	"Settings saved"
];
/** Returns up to 20 dot-separated paths where two values differ (e.g. `eval.mode` or `policy.rules.1.enabled`). */
function changedPaths(before, after, path = "") {
	if (JSON.stringify(before) === JSON.stringify(after)) return [];
	if (!before || !after || typeof before !== "object" || typeof after !== "object") return [path];
	const keys = [.../* @__PURE__ */ new Set([...Object.keys(before), ...Object.keys(after)])];
	const at = (value, name) => value[name];
	return keys.flatMap((name) => changedPaths(at(before, name), at(after, name), path ? `${path}.${name}` : name)).slice(0, 20);
}
/** Strips the latest report preview from a ticket card when the relay already carries or does not need the summary. */
function brief(ticket) {
	const { preview: _preview, ...card } = ticketCard(ticket);
	return card;
}
/** Creates a one-off receipt notice with a unique `name` key so repeated occurrences of the same event are each delivered instead of coalescing. */
const receiptNotice = (value, summary) => [
	key("receipt", randomUUID()),
	value,
	summary
];
/** Builds a notice that a person removed a thread's subscriptions at `at`; a later removal of the same thread replaces an unsent waiting notice. */
const subscriptionNotice = (thread, at) => [
	`subscription:${thread}`,
	{
		subscription_changes: [{
			thread,
			removed: true
		}],
		...at ? { at } : {}
	},
	`Removed the subscriptions on thread ${thread}`
];
/**
* Converts an unsolicited domain event into a main-Session notice (`ticket.ended`, `trigger.requeued`, or
* `thread.unsubscribed` by a person or executor); returns `undefined` for events that require no notice.
*/
function eventNotice(event, ticket = () => void 0) {
	const { at } = event;
	if (event.type === "ticket.ended") {
		const { ticketId, by, outcome, reason = outcome } = event.data;
		const ended = ticket(ticketId);
		return receiptNotice(ended ? { ticket_ended: brief(ended) } : {
			ticket_ended: ticketId,
			by,
			outcome,
			reason,
			at
		}, `Ticket ${ticketId} ended (${reason})`);
	}
	if (event.type === "trigger.requeued") {
		const id = event.data.triggerId;
		return receiptNotice({
			trigger_requeued: id,
			read: `trigger/${id}`,
			at
		}, `Trigger ${id} queued for a fresh assessment`);
	}
	if (event.type === "thread.unsubscribed" && event.data.by === "person") return subscriptionNotice(event.data.threadKey, at);
	if (event.type === "thread.unsubscribed") {
		const { ticketId, threadKey: thread, reason } = event.data;
		return receiptNotice({
			thread_unrelated: {
				ticket_id: ticketId,
				thread,
				reason
			},
			at,
			note: "Its Executor found this thread unrelated after reading it; attach later triggers there to this ticket only when they point at it explicitly."
		}, `Ticket ${ticketId} no longer follows thread ${thread}: ${reason}`);
	}
}
/** Builds a background notice when a ticket's worker subscribes to a related thread for context only. */
const threadFollowedNotice = (ticketId, thread, reason) => receiptNotice({
	thread_followed: {
		ticket_id: ticketId,
		thread,
		reason
	},
	note: "For context only: its messages reach this ticket and grant nothing."
}, `Ticket ${ticketId} follows thread ${thread} for context: ${reason}`);
/** What a follow-up asks of the main Session: nothing but a stop the person asks for, since its ticket's worker decides it. */
const FOLLOWUP_NOTE = "Its ticket's worker has it and decides; act only if the person asks to stop the work (orchestrator_route kind stop with this trigger_id).";
/**
* Builds a steering relay for a human follow-up trigger that reached at least one live ticket (including an ended ticket
* that resumed on the follow-up), with the trigger rendered as workers read it, the replied-to message, and the open
* tickets it reached; returns `undefined` while no ticket's worker decides it (see `followupOwners`) or it reached no live ticket.
*/
function followupNotice(store, sources, triggerId) {
	const trigger = store.triggers.get(triggerId);
	const disposition = store.triggers.disposition(triggerId);
	if (!trigger || !followupOwners(trigger, store).length) return void 0;
	const tickets = disposition.fanout.flatMap((id) => {
		const ticket = store.tickets.get(id);
		const context = disposition.context?.includes(id) ? { context: true } : {};
		return ticket && liveTicket(ticket) ? [{
			ticket_id: id,
			title: ticket.title,
			state: ticketCard(ticket).state,
			...context
		}] : [];
	});
	if (!tickets.length) return void 0;
	return followupRelay(triggerMessage(trigger, {}, void 0, repliedTo({
		store,
		sources
	}, trigger)), tickets);
}
/**
* A person's message that reached tickets, as the main Session hears of it: the message as their workers read it, and the
* tickets it reached with their state. Their workers decide it; the main Session may only stop the work on it.
*/
function followupRelay(message, tickets) {
	return {
		id: `followup:${message.trigger_id}`,
		text: JSON.stringify({
			kind: "follow_up",
			...message,
			delivered_to: tickets,
			note: FOLLOWUP_NOTE
		})
	};
}
/** Formats a worker report relay for the main Session (truncating summaries over 600 characters behind `ticket/<id>/result`); `replyTo` names the human question trigger it answers. */
function resultRelay(ticket, state, text, replyTo) {
	const id = key("worker-result", ticket.id, ticket.updatedAt, text);
	const summary = text.length > 600 ? {
		summary: text.slice(0, 600),
		chars: text.length
	} : { summary: text };
	const report = {
		kind: "worker_report",
		ticket: brief(ticket),
		trigger_id: ticket.origin.triggerId,
		state,
		...replyTo ? { answer_to: replyTo } : {},
		...summary,
		read: `ticket/${ticket.id}/result`
	};
	return {
		id: `report:${id}`,
		text: JSON.stringify(report)
	};
}
/**
* Converts a worker report recorded on `ticket` into a main-Session relay: a question for a person produces a
* `worker_attention` relay, and a result, blocker, end, or answer to a question produces a `worker_report` relay, while
* routine `progress` reports without `answers` stay internal.
* @returns The steering `Relay`, or `undefined` when the report is not relayed to the main Session.
*/
function reportRelay(ticket, report) {
	const asked = report.question ? ticket.attention : void 0;
	if (asked) return {
		id: `attention:${ticket.id}:${asked.id}`,
		text: JSON.stringify({
			kind: "worker_attention",
			ticket: brief(ticket),
			state: report.state,
			read: `ticket/${ticket.id}/result`
		})
	};
	if (report.state === "progress" && !report.answers) return void 0;
	return resultRelay(ticket, report.state, report.summary, report.answers);
}
//#endregion
//#region src/app/versions.ts
/**
* Manages numbered snapshots of a versioned record in the `Store` key-value table with a pointer key tracking the active revision.
* Each save writes a new snapshot and advances the pointer atomically, keeping full history without duplicating the active record.
* Used by `Store` for settings history and by `Prompts` for versioned prompt configuration.
*/
var Versions = class {
	store;
	pointer;
	family;
	constructor(store, pointer, family) {
		this.store = store;
		this.pointer = pointer;
		this.family = family;
	}
	/** Current revision number, or `0` before the first save. */
	revision() {
		return this.store.get(this.pointer) ?? 0;
	}
	/** Current snapshot, or `undefined` before the first save. */
	current() {
		const revision = this.store.get(this.pointer);
		return revision === void 0 ? void 0 : this.get(revision);
	}
	get(revision) {
		return this.store.get(this.family(revision));
	}
	save(make) {
		return this.store.atomic(() => {
			const version = make(this.revision() + 1);
			this.store.set(this.family(version.revision), version);
			this.store.set(this.pointer, version.revision);
			return version;
		});
	}
	/** Stores a snapshot without advancing the current revision pointer (e.g., to record an initial built-in baseline). */
	keep(version) {
		this.store.set(this.family(version.revision), version);
	}
	list(limit = Infinity) {
		return this.store.keys(this.family).flatMap((name) => this.store.get(name) ?? []).sort((a, b) => b.revision - a.revision).slice(0, limit);
	}
};
//#endregion
//#region src/app/prompts.ts
/** Manages versioned role prompts, behavioral policies, and operational skills independently of access settings. */
/** Prompt sections the team writes; the built-in parts follow dsh-superagent's text until the team overrides them. */
const TEAM_SECTIONS = [
	"communication",
	"scope",
	"delivery"
];
/** Markdown headings for each team section; fixed prompt sections refer to them by these exact names. */
const TEAM_HEADINGS = {
	communication: "Communication",
	scope: "Ticket scope",
	delivery: "Delivery requirements"
};
const SKILL_NAME = /^[a-z][a-z0-9-]*$/;
/** Prefix prepended to skill names when registering them in DSH Sessions. */
const SKILL_PREFIX = "dsh-superagent-";
const SkillNameSchema = z.string().regex(SKILL_NAME).refine((name) => !Object.keys(sourceSkills).includes(name), "This name belongs to a built-in skill");
/** A team's text for a built-in part, and `base`, the key of the built-in text it was edited from. */
const OverrideSchema = z.object({
	text: z.string(),
	base: z.string().optional().describe("Key of the built-in text it was edited from; copy as read, or omit.")
}).strict();
/**
* A configuration, whose overrides may name a part a later version no longer has, which `Prompts.validate` drops when the
* saved version holds it and refuses otherwise.
*/
const PromptConfigSchema = z.object({
	communication: z.string(),
	scope: z.string(),
	delivery: z.string(),
	skills: z.record(SkillNameSchema, z.string()),
	overrides: z.record(z.string(), OverrideSchema).optional().describe("Text in place of a built-in part, by its key in prompts/defaults; a part not named follows its built-in text.")
}).strict();
const defaultPrompts = () => ({
	...teamDefaults,
	skills: {}
});
const ENVIRONMENT_HEADING = "Execution environment (from this installation's settings; it takes precedence over any repository or account named elsewhere in these instructions; an empty value means that part is not configured here). The prepare command of a ticket directory reads the same variables:";
const POLICY_HEAD = "## Policy\nPolicy version {version}; accept mode {mode}. The accept mode and the rules decide proactive candidates only: an explicit request is routed as dispatch says, in any mode and whatever the rules.";
const BOTH = ["orchestrator", "worker"];
const MAIN = ["orchestrator"];
const WORKER = ["worker"];
let parts;
/**
* The built-in parts of both roles' prompts, the two Source skills, and the templates of the generated parts, whose data the
* system fills in, by the key an override names them by. Built on first use, as the texts it reads are imported in a cycle.
*/
const builtInParts = () => parts ??= {
	"runtime/shared": {
		roles: BOTH,
		text: sharedPrompt
	},
	"runtime/orchestrator": {
		roles: MAIN,
		text: masterPrompt
	},
	"runtime/worker": {
		roles: WORKER,
		text: workerPrompt
	},
	"runtime/subscriptions": {
		roles: BOTH,
		text: `## subscriptions\n${guides.subscriptions}`
	},
	"runtime/replies": {
		roles: BOTH,
		text: `## replies\n${guides.replies}`
	},
	"runtime/dispatch": {
		roles: MAIN,
		text: `## dispatch\n${guides.dispatch}`
	},
	"runtime/work": {
		roles: WORKER,
		text: `## work\n${guides.work}`
	},
	"runtime/admission": {
		roles: MAIN,
		text: mainAdmissionPolicy
	},
	"runtime/handoff/orchestrator": {
		roles: MAIN,
		text: handoffPolicy("orchestrator")
	},
	"runtime/handoff/worker": {
		roles: WORKER,
		text: handoffPolicy("worker")
	},
	"runtime/environment": {
		roles: BOTH,
		text: `${ENVIRONMENT_HEADING}\n{variables}`,
		placeholders: ["{variables}"]
	},
	"runtime/policy": {
		roles: MAIN,
		text: `${POLICY_HEAD} The enabled rules, by name and id:\n{rules}`,
		placeholders: [
			"{version}",
			"{mode}",
			"{rules}"
		]
	},
	"runtime/policy/none": {
		roles: MAIN,
		text: `${POLICY_HEAD} No rule is enabled: a proactive candidate can only be ignored.`,
		placeholders: ["{version}", "{mode}"]
	},
	"skill/feishu": {
		roles: BOTH,
		text: `${sourceSkills.feishu}\n\n## CLI usage\n${cliNotes}`
	},
	"skill/github": {
		roles: BOTH,
		text: `${sourceSkills.github}\n\n## CLI usage\n${cliNotes}`
	}
};
/** The key of a built-in text, which an override's `base` records. */
const builtInBase = (text) => key("prompt-built-in", text);
/** The built-in part a key names, if any; a name an object's prototype has names none. */
const builtInPart = (part) => Object.hasOwn(builtInParts(), part) ? builtInParts()[part] : void 0;
/** The text of a built-in part: the team's override, else the built-in one. */
const builtIn = (config, part) => (config.overrides && Object.hasOwn(config.overrides, part) ? config.overrides[part].text : void 0) ?? builtInParts()[part].text;
/** Fill a template's placeholders in one pass, so text filled in is not read for placeholders again. */
const fill = (template, values) => template.replace(/\{(\w+)\}/g, (match, name) => Object.hasOwn(values, name) ? values[name] : match);
/** The execution environment part: its template with the variables, or, while setup waits, that it waits. */
function environmentSection(config, variables) {
	return variables ? fill(builtIn(config, "runtime/environment"), { variables: environmentLines(variables) }) : "Execution environment: dsh-superagent is waiting for setup; the management panel names what is missing.";
}
/**
* The main Session's Policy section: the Policy version and accept mode it judges proactive candidates by, and every enabled
* rule, as the settings hold them, each on one line, so a line of an instruction reads as no rule or heading of its own; the
* settings bound each instruction (`LIMITS.ruleInstruction`). `key` names the template it was filled from.
*/
function policySection(settings, config = defaultPrompts()) {
	const line = (text) => text.replace(/\s*\n\s*/g, " ");
	const rules = settings.policy.rules.filter((rule) => rule.enabled).map(({ id, name, instruction }) => `- ${line(name)} (${id}): ${line(instruction)}`);
	const part = rules.length ? "runtime/policy" : "runtime/policy/none";
	return {
		key: part,
		text: fill(builtIn(config, part), {
			version: policyVersion(settings),
			mode: settings.eval.mode,
			rules: rules.join("\n")
		})
	};
}
/**
* Assemble a role's system prompt sections in order from fixed templates, team sections, the generated execution environment
* and, last, the main Session's generated Policy section, which nothing follows, and whose change leaves the rest unchanged.
*/
function promptParts(config, role, environment, policy) {
	const fixed = (name, part = name) => ({
		name,
		kind: "fixed",
		key: part,
		text: builtIn(config, part)
	});
	const team = (name) => ({
		name,
		kind: "team",
		heading: `## ${TEAM_HEADINGS[name]}`,
		text: config[name] ? `## ${TEAM_HEADINGS[name]}\n${config[name]}` : ""
	});
	return [
		fixed("runtime/shared"),
		fixed(`runtime/${role}`),
		...TEAM_SECTIONS.map(team),
		...[
			"subscriptions",
			"replies",
			role === "orchestrator" ? "dispatch" : "work"
		].map((name) => fixed(`runtime/${name}`)),
		...role === "orchestrator" ? [fixed("runtime/admission")] : [],
		fixed("runtime/handoff", `runtime/handoff/${role}`),
		...environment ? [{
			name: "runtime/environment",
			kind: "generated",
			key: "runtime/environment",
			text: environment
		}] : [],
		...role === "orchestrator" && policy ? [{
			name: "runtime/policy",
			kind: "generated",
			...policy
		}] : []
	].filter((part) => part.text);
}
function composePrompt(config, role, environment, policy) {
	return promptParts(config, role, environment, policy).map((part) => part.text).join("\n\n");
}
function composeSkill(config, name) {
	return name === "feishu" || name === "github" ? builtIn(config, `skill/${name}`) : config.skills[name] ?? "";
}
/**
* Indicates an optimistic concurrency conflict when saving a prompt configuration against a stale base revision.
* Thrown by `Prompts.save` and translated into an HTTP 409 response by the management routes.
*/
var PromptConflict = class extends Error {};
/**
* Stores numbered prompt configurations in `Store` via `Versions` and composes role system prompts and skills with the execution environment.
* `Sessions` reads the composed prompts and skills for orchestrator and worker runs, while management routes and tools validate, preview, and save revisions through it.
*/
var Prompts = class {
	store;
	maxChars;
	environment;
	feishu;
	versions;
	constructor(store, maxChars, environment, feishu) {
		this.store = store;
		this.maxChars = maxChars;
		this.environment = environment;
		this.feishu = feishu;
		this.versions = new Versions(store, KV.prompts.revision, KV.prompts.version);
	}
	/** A role's prompt; the main Session's Policy section follows the settings as they are now, at each model request. */
	compose(config, role, variables = this.environment()) {
		return composePrompt(config, role, environmentSection(config, variables), role === "orchestrator" ? policySection(this.store.settings(), config) : void 0);
	}
	/** Returns skills to register in every Session: built-in Source skills (`feishu` only when a Feishu bot is configured) followed by team skills. */
	skills(config) {
		return [
			...this.feishu() ? ["feishu"] : [],
			"github",
			...Object.keys(config.skills)
		].map((name) => [name, composeSkill(config, name)]);
	}
	current() {
		const revision = this.versions.revision();
		return revision ? this.version(revision) : {
			revision: 0,
			previousRevision: null,
			savedAt: "",
			source: "defaults",
			config: defaultPrompts()
		};
	}
	/** Reads a revision by number; revision 0 resolves to built-in defaults before the first save persists it. */
	version(revision) {
		const version = this.versions.get(revision) ?? (revision === 0 && this.versions.revision() === 0 ? this.current() : void 0);
		if (!version) throw new UserError("unknownPromptRevision", { revision: String(revision) });
		return version;
	}
	/**
	* Parse a configuration: an override names a built-in part, holds text and keeps its template's placeholders, and records the
	* built-in text it was edited from: the saved override's unless it names one, else the current one. It goes once its text is
	* the built-in text again, and so does one of a part this version no longer has, which the saved version holds.
	*/
	validate(value) {
		const { overrides, ...config } = PromptConfigSchema.parse(value);
		const saved = this.current().config.overrides ?? {};
		const kept = Object.entries(overrides ?? {}).flatMap(([name, override]) => {
			const part = builtInPart(name);
			if (!part && Object.hasOwn(saved, name)) return [];
			if (!part) throw new UserError("unknownPromptPart", { part: name });
			if (!override.text.trim()) throw new UserError("promptPartEmpty", { part: name });
			const missing = (part.placeholders ?? []).filter((placeholder) => !override.text.includes(placeholder));
			if (missing.length) throw new UserError("promptPlaceholders", {
				part: name,
				placeholders: missing.join(", ")
			});
			const base = override.base ?? (Object.hasOwn(saved, name) ? saved[name].base : void 0) ?? builtInBase(part.text);
			return override.text === part.text ? [] : [[name, {
				text: override.text,
				base
			}]];
		});
		const result = {
			...config,
			...kept.length ? { overrides: Object.fromEntries(kept) } : {}
		};
		const limit = this.maxChars();
		if (JSON.stringify(result).length > limit) throw new UserError("promptTooLong", { limit: String(limit) });
		return result;
	}
	/**
	* The overrides of `config` whose built-in part changed since the team edited it, by the `base` they were edited from, each
	* with the built-in text of that base when this installation kept it, and those of a part this version no longer has.
	*/
	defaultChanged(config) {
		return Object.entries(config.overrides ?? {}).flatMap(([part, { base }]) => {
			const now = builtInPart(part);
			if (!now) return [{
				part,
				...base === void 0 ? {} : { base },
				removed: true
			}];
			if (base === void 0 || base === builtInBase(now.text)) return [];
			const previous = this.store.get(KV.prompts.builtIn(base));
			return [{
				part,
				base,
				...previous === void 0 ? {} : { previous }
			}];
		});
	}
	preview(value) {
		const config = this.validate(value);
		const environment = environmentSection(config, this.environment()), policy = policySection(this.store.settings(), config);
		return {
			orchestrator: composePrompt(config, "orchestrator", environment, policy),
			worker: composePrompt(config, "worker", environment),
			parts: {
				orchestrator: promptParts(config, "orchestrator", environment, policy),
				worker: promptParts(config, "worker", environment)
			},
			skills: Object.fromEntries(this.skills(config)),
			scope: "Team sections, skills, and overrides of built-in parts, which follow their built-in text until overridden. Workers additionally inherit the host prompt and repository AGENTS.md. Prompt text changes what the agents are told, not what dsh-superagent allows: tool permissions, the gate and account wrappers stay."
		};
	}
	save(value, baseRevision, source) {
		const config = this.validate(value);
		return this.store.atomic(() => {
			const previous = this.current();
			if (previous.revision !== baseRevision) throw new PromptConflict(`Prompt version changed to ${previous.revision}; compare the latest version before saving`);
			if (previous.revision === 0 && !this.versions.get(0)) this.versions.keep(previous);
			for (const [part, { base }] of Object.entries(config.overrides ?? {})) {
				const text = builtInParts()[part].text;
				if (base === builtInBase(text) && this.store.get(KV.prompts.builtIn(base)) === void 0) this.store.set(KV.prompts.builtIn(base), text);
			}
			return this.versions.save((revision) => ({
				revision,
				previousRevision: previous.revision,
				savedAt: (/* @__PURE__ */ new Date()).toISOString(),
				source,
				config
			}));
		});
	}
	history(offset = 0, limit = 20) {
		const current = this.current();
		const revisions = Array.from({ length: Math.min(limit, Math.max(0, current.revision + 1 - offset)) }, (_, i) => {
			const version = current.revision - offset - i === 0 && current.revision === 0 ? current : this.version(current.revision - offset - i);
			const { config, ...summary } = version;
			const previous = version.previousRevision === null ? void 0 : this.versions.get(version.previousRevision)?.config;
			if (version.legacy || version.previousRevision !== null && this.versions.get(version.previousRevision)?.legacy) return {
				...summary,
				changed: ["legacy"]
			};
			const entries = (value) => ({
				communication: value.communication,
				scope: value.scope,
				delivery: value.delivery,
				...Object.fromEntries(Object.entries(value.skills).map(([name, text]) => ["skill/" + name, text])),
				...Object.fromEntries(Object.entries(value.overrides ?? {}).map(([part, override]) => [part, JSON.stringify(override)]))
			});
			const before = previous ? entries(previous) : {};
			const after = entries(config);
			const changed = previous ? [.../* @__PURE__ */ new Set([...Object.keys(before), ...Object.keys(after)])].filter((name) => before[name] !== after[name]) : [];
			return {
				...summary,
				changed
			};
		});
		return {
			revisions,
			next_offset: offset + revisions.length <= current.revision ? offset + revisions.length : null
		};
	}
};
/** Save a new prompt revision and notify the main Session when the change originated outside its own tool call. */
async function savePrompts(host, config, baseRevision, origin) {
	return {
		revision: host.store.atomic(() => {
			const saved = host.prompts.save(config, baseRevision, origin);
			if (origin !== "tool") host.sessions.notify(...promptsNotice(saved.revision));
			return saved;
		}).revision,
		effect: "next-request",
		context_delivery: await host.sessions.delivery("prompts")
	};
}
//#endregion
//#region src/app/resources.ts
/** Resource descriptors exposed via orchestrator_read, marking which resources worker sessions may also read for their own ticket. */
const RESOURCES = [
	{
		name: "tickets",
		holds: "ticket cards, newest first; a card's state is person/review after a ready report, person/blocked or person/failed after those reports, person/answer with a question, person/delivery when an input could not reach the worker, working or working/queued while it works, idle once the worker ended its turn without a report, else how the ticket ended"
	},
	{
		name: "triggers",
		holds: "trigger cards with where each went, newest first"
	},
	{
		name: "threads",
		holds: "subscribed threads, newest activity first, with their labels, tickets, current assessment and polling errors"
	},
	{
		name: "thread/<key>",
		holds: "one thread: its label and link, its tickets and latest decisions, and its triggers, newest first",
		executor: true
	},
	{
		name: "decisions",
		holds: "decisions, newest first"
	},
	{
		name: "decision/<id>",
		holds: "one decision with its audit"
	},
	{
		name: "ticket/<id>",
		holds: "a ticket's card, the trigger, decision and threads it is tied to, its latest assignments with the start of each report, and its inputs, newest first",
		executor: true
	},
	{
		name: "ticket/<id>/assignment",
		holds: "its assignment text",
		executor: true
	},
	{
		name: "ticket/<id>/assignments",
		holds: "its assignments, newest first, with the start of each report",
		executor: true
	},
	{
		name: "ticket/<id>/inputs",
		holds: "its inputs, newest first",
		executor: true
	},
	{
		name: "ticket/<id>/result",
		holds: "its latest report",
		executor: true
	},
	{
		name: "ticket/<id>/report/<id>",
		holds: "the report of one of its assignments",
		executor: true
	},
	{
		name: "ticket/<id>/transcript",
		holds: "its Executor Session's messages, newest first",
		executor: true
	},
	{
		name: "ticket/<id>/message/<n>",
		holds: "one message of that transcript",
		executor: true
	},
	{
		name: "ticket/<id>/input/<id>",
		holds: "one input it was delivered",
		executor: true
	},
	{
		name: "trigger/<id>",
		holds: "a trigger's text, where it went, the message it replies to and the messages around it on its thread",
		executor: true
	},
	{
		name: "settings",
		holds: "settings by block, each with the revision a save names: the small blocks whole, the Policy and the Source instances summarized"
	},
	{
		name: "settings/<block>",
		holds: "one settings block whole, as orchestrator_settings_save takes it: policy, eval, executor, pause or source:<id>"
	},
	{
		name: "prompts",
		holds: "the prompt revision each Session reads, the skills, and the saved versions"
	},
	{
		name: "prompts/<revision>",
		holds: "one prompt version by number, or current, the one the Session works under",
		executor: true
	},
	{
		name: "prompts/defaults",
		holds: "the built-in prompt configuration, and the built-in parts by the key an override names"
	},
	{
		name: "prompt-preview/<id>",
		holds: "a composed prompt that orchestrator_prompts_save previewed"
	},
	{
		name: "models",
		holds: "model providers, the DSH default and each role's model"
	},
	{
		name: "models/<provider>",
		holds: "one provider's models"
	},
	{
		name: "feishu/<trigger-id>/…",
		holds: "a Feishu original, as the dsh-superagent-feishu skill describes",
		executor: true
	},
	{
		name: "github/…",
		holds: "a GitHub original, as the dsh-superagent-github skill describes",
		executor: true
	}
];
const resourceGrammar = (executor) => RESOURCES.filter((resource) => !executor || resource.executor).map((resource) => `${resource.name}: ${resource.holds}`).join("; ");
/** Enforces that main-Session-only resources cannot be read by worker Sessions. */
const main = ({ host, ticketId }) => {
	if (ticketId || !("settings" in host)) throw new Error("This resource belongs to the main Session");
	return host;
};
const text$1 = ({ resource, offset, limit }, body) => textPage(resource, body, offset, limit ?? 4e3);
function list({ offset, limit }, fetch) {
	const size = Math.min(limit ?? 20, 50);
	const items = fetch(offset, size + 1);
	return {
		items: items.slice(0, size),
		next_offset: items.length > size ? offset + size : null
	};
}
/** Check whether a worker session's ticket is authorized to read a trigger (via delivery, ticket origin, or followed thread). */
const readable = (host, ticket, trigger) => reached(ticket, trigger, (key) => host.store.threads.get(key)) || ticket.origin.triggerIds.includes(trigger.id) || trigger.threads.some((ref) => ticket.follows?.some((follow) => follow.thread === threadKey(ref)));
const trigger = (host, id, ticketId) => {
	const found = host.store.triggers.get(id);
	if (!found) throw new UserError("unknownTrigger");
	const ticket = ticketId ? host.store.tickets.get(ticketId) : void 0;
	if (ticketId && (!ticket || !readable(host, ticket, found))) throw new UserError("notReached");
	return found;
};
/** Fetch and cache a source resource on offset 0, serving subsequent offsets from the session cache. */
async function sourcePage(read, source, fetch) {
	const { host, resource, offset, sessionId } = read;
	const body = offset === 0 ? JSON.stringify(await fetch()) : host.pages.get(`${sessionId}:${resource}`);
	if (body === void 0) throw new Error(`Read this ${source === "feishu" ? "Feishu" : "GitHub"} resource from offset 0 first`);
	if (offset === 0) host.pages.set(`${sessionId}:${resource}`, body);
	return text$1(read, body);
}
const triggerLine = (trigger) => ({
	trigger_id: trigger.id,
	actor: trigger.actor.id,
	human: trigger.human,
	at: trigger.at,
	preview: preview$1(trigger.text),
	chars: trigger.text.length,
	read: `trigger/${trigger.id}`
});
async function transcript(host, ticketId) {
	return (await host.context.sessionController.inspect(workerSessionId(ticketId))).events;
}
const ROUTES = [
	["tickets", (read) => {
		const host = main(read), tickets = host.store.tickets.list();
		const card = (ticket) => ({
			...ticketCard(ticket),
			...host.sessions.modelRetry(runningAssignment(ticket) && workerSessionId(ticket.id))
		});
		return list(read, (offset, count) => tickets.slice(offset, offset + count).map(card));
	}],
	["triggers", (read) => {
		const { store } = main(read);
		return list(read, (offset, count) => store.read.recentTriggers(offset, count).map((item) => triggerCard(item, store.triggers.disposition(item.id))));
	}],
	["threads", (read) => {
		const { store } = main(read);
		const threads = store.read.subscribedThreads().sort((a, b) => (b.lastAt ?? b.createdAt).localeCompare(a.lastAt ?? a.createdAt));
		return list(read, (offset, count) => threads.slice(offset, offset + count).map((thread) => threadCard(thread, threadTitle(store, thread))));
	}],
	["thread/", (read) => {
		const { host, rest, ticketId } = read;
		const thread = host.store.threads.get(rest);
		const ticket = ticketId ? host.store.tickets.get(ticketId) : void 0;
		if (!thread || ticketId && !(thread.subscriptions.includes(ticketId) || ticket?.follows?.some((follow) => follow.thread === rest))) throw new Error("Unknown or inaccessible thread");
		const { store } = host;
		const { read: _read, tickets: ids, ...card } = threadCard(thread, threadTitle(store, thread));
		const page = list(read, (offset, count) => store.read.threadPage(thread.key, offset, count).map(triggerLine));
		if (ticketId) return {
			...card,
			...page
		};
		const tickets = ids.flatMap((id) => {
			const found = store.tickets.get(id);
			return found ? [ticketCard(found)] : [];
		});
		const decisions = store.decisions.byThread(thread.key).slice(-5).reverse().map(decisionCard);
		return {
			...card,
			tickets,
			decisions,
			...page
		};
	}],
	["decisions", (read) => list(read, (offset, count) => main(read).store.read.recentDecisions(offset, count).map(decisionCard))],
	["decision/", (read) => {
		const decision = main(read).store.decisions.get(read.rest);
		if (!decision) throw new Error("Unknown decision");
		return decisionDetails(decision);
	}],
	["settings", (read) => main(read).settings.view()],
	["settings/", (read) => text$1(read, JSON.stringify(main(read).settings.block(read.rest)))],
	["prompts", (read) => {
		const host = main(read), current = host.prompts.current(), status = host.sessions.status();
		const history = host.prompts.history(read.offset, Math.min(read.limit ?? 20, 50)), skills = host.prompts.skills(current.config).map(([name]) => name);
		const changes = host.prompts.defaultChanged(current.config);
		const changed = changes.filter((item) => !item.removed).map((item) => item.part);
		const removed = changes.filter((item) => item.removed).map((item) => item.part);
		return {
			revision: status.revision,
			read: `prompts/${current.revision}`,
			notification_pending: status.notificationPending,
			...changed.length ? { default_changed: changed } : {},
			...removed.length ? { removed_parts: removed } : {},
			sessions: status.sessions.map((session) => ({
				session_id: session.sessionId,
				revision: session.revision
			})),
			skills: {
				built_in: skills.filter((name) => !(name in current.config.skills)).map((name) => `dsh-superagent-${name}`),
				team: Object.keys(current.config.skills).map((name) => `dsh-superagent-${name}`)
			},
			items: history.revisions.map(({ previousRevision, savedAt, ...version }) => ({
				...version,
				previous_revision: previousRevision,
				saved_at: savedAt
			})),
			next_offset: history.next_offset
		};
	}],
	["prompts/", (read) => {
		const { host, resource, rest, sessionId, ticketId } = read;
		const prompts = host.prompts;
		const bound = host.promptVersion(sessionId);
		const parts = () => Object.fromEntries(Object.entries(builtInParts()).map(([key, part]) => [key, part.text]));
		const version = rest === "current" ? bound : rest === "defaults" && !ticketId ? {
			revision: 0,
			config: defaultPrompts(),
			parts: parts()
		} : /^\d+$/.test(rest) ? Number(rest) === 0 && prompts.current().revision === 0 ? prompts.current() : prompts.version(Number(rest)) : void 0;
		if (!version || ticketId && !host.mayRead(sessionId, version.revision)) throw new Error("Unknown or inaccessible prompt version");
		return text$1({
			...read,
			resource: rest === "current" ? `prompts/${version.revision}` : resource
		}, JSON.stringify(version));
	}],
	["prompt-preview/", (read) => {
		const body = main(read).pages.get(`${read.sessionId}:${read.resource}`);
		if (body === void 0) throw new Error("Unknown preview for this Session");
		return text$1(read, body);
	}],
	["models", async (read) => {
		const host = main(read), catalog = await host.context.sessionController.modelCatalog(), settings = host.store.settings();
		const roles = {
			orchestrator: settings.eval.model,
			worker: settings.executor.model
		};
		return {
			default: catalog.default,
			roles,
			failures: catalog.failures,
			providers: catalog.groups.map((group) => ({
				id: group.id,
				name: group.name,
				count: group.models.length,
				read: `models/${group.id}`
			}))
		};
	}],
	["models/", async (read) => {
		const models = (await main(read).context.sessionController.modelCatalog()).groups.find((group) => group.id === read.rest)?.models;
		if (!models) throw new Error("Unknown model provider");
		return list(read, (offset, count) => models.slice(offset, offset + count));
	}],
	["feishu/", async (read) => {
		const source = trigger(read.host, read.rest.split("/")[0], read.ticketId);
		const ref = feishuRef(source);
		if (!ref) throw new Error("A Feishu source trigger is required");
		const commands = read.host.commands.withSignal(read.signal);
		return sourcePage(read, "feishu", () => feishuRead(commands, ref, read.resource, read.host.feishuPageSize()));
	}],
	["github/", (read) => sourcePage(read, "github", () => readGithub(read.host.commands.withSignal(read.signal), read.resource))],
	["trigger/", async (read) => {
		const { host, rest, ticketId, offset, signal } = read;
		if (!rest || rest.includes("/")) throw new Error("Unknown context resource");
		const found = trigger(host, rest, ticketId);
		const ref = feishuRef(found);
		const ticket = ticketId ? host.store.tickets.get(ticketId) : void 0;
		const shown = (item) => item && (!ticket || readable(host, ticket, item)) ? item : void 0;
		const disposition = host.store.triggers.disposition(found.id);
		const { preview: _preview, chars: _chars, read: _read, ...card } = triggerCard(found, disposition && ticket ? {
			...disposition,
			decisionId: void 0,
			fanout: disposition.fanout.filter((id) => id === ticket.id)
		} : disposition);
		const parent = found.source === "feishu" && typeof found.meta.parentId === "string" ? found.meta.parentId : void 0;
		const repliedTo = shown(parent ? host.store.triggers.get(feishuTriggerId(parent)) : void 0);
		const neighbours = host.store.read.neighbours(threadKey(found.threads[0]), found.at, found.id);
		const around = {
			before: shown(neighbours.before),
			after: shown(neighbours.after)
		};
		return {
			...card,
			...await host.sourceLink(found, signal),
			acknowledgement: host.store.replyStatus(key("ack", found.id)) ?? "not_requested",
			...ref ? { context: feishuReferences(ref) } : {},
			...offset === 0 ? {
				...repliedTo ? { replied_to: triggerLine(repliedTo) } : {},
				around: {
					...around.before ? { before: triggerLine(around.before) } : {},
					...around.after ? { after: triggerLine(around.after) } : {}
				}
			} : {},
			...text$1(read, found.text)
		};
	}],
	["ticket/", async (read) => {
		const { host, resource, rest, ticketId, signal } = read;
		const [id, section, part, ...more] = rest.split("/");
		if (!id || more.length) throw new Error("Unknown context resource");
		if (ticketId && ticketId !== id) throw new Error("Ticket does not belong to this worker");
		const ticket = host.store.tickets.get(id);
		if (!ticket) throw new UserError("unknownTicket");
		if (section === void 0) {
			const running = runningAssignment(ticket) && workerSessionId(ticket.id);
			const retry = "sessions" in host ? host.sessions.modelRetry(running) : {};
			const bound = new Set((ticket.follows ?? []).map((follow) => follow.thread));
			const subscribed = host.store.read.subscribedThreads().filter((thread) => thread.subscriptions.includes(id));
			const marked = (key, context) => ({
				thread: key,
				...context ? { context: true } : {},
				...bound.has(key) ? { bound: true } : {}
			});
			return {
				...ticketDetails(ticket, [...subscribed.map((thread) => marked(thread.key, !!thread.context?.includes(id))), ...[...bound].filter((key) => !subscribed.some((thread) => thread.key === key)).map((key) => marked(key, false))], batchOf(host, ticket), !!ticketId),
				...retry
			};
		}
		if (section === "assignments" || section === "inputs") {
			if (part !== void 0) throw new Error("Unknown context resource");
			const size = Math.min(read.limit ?? (section === "assignments" ? 3 : 10), 50);
			const { items, next_offset } = section === "assignments" ? newestPage(ticket.assignments, read.offset, size, (item) => assignmentLine(ticket, item), resource) : newestPage(ticket.inputs, read.offset, size, (input) => inputLine(ticket, input, !!ticketId), resource);
			return {
				items,
				next_offset: next_offset ?? null
			};
		}
		let body;
		if (section === "input" && part) {
			const input = ticket.inputs.find((item) => key(item.id) === part || item.id === part);
			const trigger = input?.kind === "trigger" ? host.store.triggers.get(input.triggerId) : void 0;
			const card = trigger && input?.kind === "trigger" ? triggerMessage(trigger, await host.sourceLink(trigger, signal), input.note) : void 0;
			const message = input && inputMessage(input, card);
			if (message === void 0) throw new Error("Unknown ticket input");
			body = message;
		} else if (section === "message" && part && /^\d+$/.test(part)) {
			const event = (await transcript(host, id))[Number(part)];
			const entry = event && transcriptEntry(event);
			if (!entry) throw new Error("Unknown transcript entry");
			body = JSON.stringify(entry);
		} else if (section === "report" && part) {
			const report = ticket.assignments.find((item) => item.id === part)?.report;
			if (!report) throw new Error("Unknown assignment report");
			body = report.summary;
		} else if (part !== void 0) throw new Error("Unknown context resource");
		else if (section === "assignment") body = ticket.execution?.assignment ?? "";
		else if (section === "result") body = latestReport(ticket)?.summary ?? "";
		else if (section === "transcript") body = (await transcript(host, id)).flatMap((event, index) => {
			const entry = transcriptEntry(event);
			const said = entry?.message.content.map((block) => block.type === "text" ? block.text : `[${block.type}]`).join(" ") ?? "";
			return entry ? [{
				type: entry.type,
				preview: preview$1(said).slice(0, 80),
				chars: JSON.stringify(entry).length,
				read: `ticket/${id}/message/${index}`
			}] : [];
		}).reverse().map((event) => JSON.stringify(event)).join("\n");
		else throw new Error("Unknown context resource");
		return text$1(read, body);
	}]
];
/**
* Read a paginated resource for the main Session or a ticket's worker Session.
* Legacy prefixes (`event/`, `task/`, `observation/`) remain accepted so references in older Session history stay readable.
*/
async function readResource(host, resource, offset, limit, ticketId, signal) {
	const name = resource.replace(/^event\//, "trigger/").replace(/^task\//, "ticket/").replace(/^observation\//, "decision/");
	const route = ROUTES.find(([route]) => route.endsWith("/") ? name.startsWith(route) : name === route);
	if (!route) throw new Error("Unknown context resource");
	const sessionId = ticketId ? workerSessionId(ticketId) : host.masterId;
	const rest = route[0].endsWith("/") ? name.slice(route[0].length) : "";
	return route[1]({
		host,
		resource: name,
		rest,
		offset,
		sessionId,
		...limit ? { limit } : {},
		...ticketId ? { ticketId } : {},
		...signal ? { signal } : {}
	});
}
//#endregion
//#region src/app/tools/tool.ts
/** Shared tool primitives and schemas for the main and executor Sessions. */
const tool = (definition) => definition;
/** Human-facing acknowledgement text, constrained to `IM_WORDS` regardless of which channel it is posted to. */
const AcknowledgementSchema = z.string().trim().min(1).refine((text) => wordCount(text) <= 100, `An acknowledgement has at most 100 words (Chinese uses word segmentation); write one short sentence.`);
/**
* Builds the `orchestrator_read` tool, scoping allowed resource patterns to the main Session or to an
* Executor Session (which may read only its own ticket and messages that reached it).
*/
function readTool(description, executor, read) {
	return tool({
		name: "orchestrator_read",
		description,
		schema: z.object({
			resource: z.string().min(1).describe(`The resource, one of: ${resourceGrammar(executor)}.`),
			offset: z.number().int().min(0).default(0).describe("Copy next_offset from the previous page; it counts characters of a text and items of a list."),
			limit: z.number().int().min(1).max(8e3).optional().describe("Characters of a text, 4000 by default and 8000 at most, or items of a list, 20 by default and 50 at most.")
		}).strict(),
		execute: async (args, signal) => read(args.resource, args.offset, args.limit, signal)
	});
}
//#endregion
//#region src/app/assessment.ts
/** Schema for a short lowercase kebab-case English ticket worktree name (1–4 words, at most 32 characters). */
const WorktreeNameSchema = z.string().max(32).regex(/^[a-z]+(?:-[a-z0-9]+){0,3}$/, "Use 1–4 short English words in lowercase kebab-case, at most 32 characters").describe("Meaningful short English ticket name, e.g. fix-plan-color. Translate Chinese titles into English; no Chinese, pinyin or generic ticket names. 1–4 lowercase words in kebab-case, at most 32 characters.");
/** Schema for the main Session's proactive candidate assessment decision (`orchestrator_eval_decide`). */
const AssessmentSchema = z.object({
	decision: z.enum([
		"accept",
		"ignore",
		"unavailable"
	]),
	rule_assessments: z.array(RuleAssessmentSchema).refine((assessments) => new Set(assessments.map((assessment) => assessment.rule_id)).size === assessments.length, "Duplicate rule assessment IDs").describe("One per enabled rule."),
	direction: AdmissionDirectionSchema.describe("Required for every decision."),
	title: z.string().min(1).max(160),
	worktree_name: WorktreeNameSchema.optional(),
	scope: z.string().max(1500),
	intent_evidence: z.string().trim().min(1).max(700).nullish().describe("For acceptance: the quotes that establish the three facts."),
	acknowledgement: AcknowledgementSchema.nullish().describe("For acceptance: one sentence in the source language, posted as a reply to the trigger; omit only when a matched rule asks for silence."),
	reason: z.string().min(1).max(500)
}).strict().refine((value) => value.decision !== "accept" || !directionAllowed(value.direction) || !value.rule_assessments.some((rule) => rule.matched) || !!value.worktree_name, {
	message: "Accepted work requires a short English worktree_name",
	path: ["worktree_name"]
});
/** Character limits in the initial thread window: for the trigger itself, its two nearest neighbours, other window messages, and stub previews. */
const TRIGGER_CHARS$1 = 4e3;
const NEAR_CHARS = 1200;
const WINDOW_CHARS = 400;
const STUB_CHARS = 50;
const FINISHED = "This assessment has finished: it was decided, timed out or restarted";
const EXPLICIT = "This is an explicit request, which is routed instead of assessed: use orchestrator_route with its trigger_id and kind accept, attach, stop or ignore";
/** Message returned when assessing a Trigger whose Source provides no thread context. */
const NO_CONTEXT = "This Source gives no Thread context; assess the Trigger's own text and the batch.";
/** Schema for bounded context or repository read requests during an active evaluation (`orchestrator_eval_read`). */
const EvalReadSchema = z.object({
	trigger_id: z.string().min(1).describe("Original candidate ID returned by orchestrator_eval; every reference is scoped to this trigger."),
	resource: z.enum([
		"message",
		"root",
		"parent",
		"thread",
		"file",
		"directory",
		"image"
	]),
	path: z.string().optional().describe("Repository-relative path, only for file/directory."),
	message_id: z.string().optional().describe("Only for message: omit for the trigger, or the id of a window message or stub."),
	cursor: z.string().optional().describe("Only for thread: omit on the first page, then the next_cursor of the window or the cursor of next_read. Never a thread or message ID."),
	image_id: z.string().optional().describe("Only for image: an image id the window or a read lists."),
	offset: z.number().int().min(0).default(0).describe("Text pagination: copy next_offset; keep the other arguments unchanged. Images use 0.")
}).strict().superRefine((read, ctx) => {
	if ((read.resource === "file" || read.resource === "directory") !== (read.path !== void 0)) ctx.addIssue({
		code: "custom",
		message: "path is required only for file/directory. To read the source/root/parent, use resource=message/root/parent without a path."
	});
	if (read.message_id !== void 0 && read.resource !== "message") ctx.addIssue({
		code: "custom",
		message: "message_id is only for message; use returned image_id for images."
	});
	if (read.cursor !== void 0 && read.resource !== "thread") ctx.addIssue({
		code: "custom",
		message: "cursor is only for thread. First page: {resource:\"thread\"}."
	});
	if (read.resource === "image" !== (read.image_id !== void 0)) ctx.addIssue({
		code: "custom",
		message: "Images require image_id from a returned read reference. Read the thread or root first to discover their images."
	});
});
/**
* Implements the `Engine` `Assessor` port for proactive candidate evaluation in the main Session.
* Relays each evaluation's candidate card to the main Session through the durable `assessment` effect, serves bounded `TriggerContext` and repository reads while the evaluation runs, and converts the main Session's assessment into an `AssessmentOutcome` for `Engine.decide`.
* Depends on `SourceRegistry` (via `AssessorHost`) for source-specific thread context and on `Sessions` for deduplicated candidate delivery; the main Session's `orchestrator_eval*` tools call `context`, `read`, and `decide`.
*/
var MasterAssessor = class {
	host;
	/** Per-evaluation read caches and thread contexts, keyed by `evalId`. */
	evals = /* @__PURE__ */ new Map();
	controller = new AbortController();
	/** Registers the handler that relays each Eval's candidate card, which a link lookup may delay for seconds. */
	constructor(host) {
		this.host = host;
		host.effects.handle("assessment", async ({ triggerId }, evalId) => {
			const candidate = this.host.engine.candidate(triggerId);
			if (candidate?.evalId !== evalId) return;
			await this.host.deliver(`candidate:${evalId}`, JSON.stringify({
				kind: "candidate",
				...await this.host.candidateCard(candidate)
			}));
			this.host.engine.candidateDelivered(evalId);
		}, { limit: () => host.paused() ? 0 : 4 });
	}
	/** Enqueues an `assessment` effect to deliver `candidate`'s card to the main Session. */
	request(candidate) {
		this.host.effects.enqueue("assessment", candidate.evalId, { triggerId: candidate.triggers[0].id });
	}
	/** Whether `evalId` is still the active evaluation for `trigger`. */
	live(evalId, trigger) {
		return this.host.engine.candidate(trigger.id)?.evalId === evalId;
	}
	/** Drop an Eval's context and reads once it finishes; any running load for it discards its result. */
	release(evalId) {
		this.evals.delete(evalId);
	}
	/** Resolve the active evaluation for a trigger; historical triggers have none, and explicit requests are routed instead. */
	evalFor(triggerId) {
		const candidate = this.host.engine.candidate(triggerId);
		if (!candidate) throw new Error("No assessment is in progress for this trigger; it was already decided, timed out, or never reached assessment");
		if (candidate.strength === "explicit") throw new Error(EXPLICIT);
		return {
			candidate,
			trigger: candidate.triggers.find((item) => item.id === triggerId)
		};
	}
	/** Returns or initializes the read cache for `evalId`, seeded with the trigger's own message and image references; throws if `evalId` has finished. */
	reads(evalId, trigger) {
		let reads = this.evals.get(evalId);
		if (!reads) {
			if (!this.live(evalId, trigger)) throw new Error(FINISHED);
			const context = this.host.threadContext(trigger);
			const messages = /* @__PURE__ */ new Map([[context?.messageId ?? "", trigger.text]]);
			reads = { cache: {
				snapshots: /* @__PURE__ */ new Map(),
				images: /* @__PURE__ */ new Map(),
				messages,
				cursors: /* @__PURE__ */ new Set()
			} };
			this.evals.set(evalId, reads);
			this.imageReferences(context, trigger, trigger.text, context?.messageId ?? "", reads.cache);
		}
		return reads;
	}
	imageReferences(context, trigger, text, messageId, cache) {
		return (context?.images(text) ?? []).map((imageKey) => {
			const imageId = `${messageId}/${imageKey}`;
			cache.images.set(imageId, {
				id: messageId,
				text
			});
			return {
				message_id: messageId,
				image_key: imageKey,
				read: {
					trigger_id: trigger.id,
					resource: "image",
					image_id: imageId
				}
			};
		});
	}
	/** Loads and caches the initial bounded thread window once per evaluation (including after a host restart). */
	async seed(evalId, trigger, caller) {
		caller?.throwIfAborted();
		const reads = this.reads(evalId, trigger);
		if (reads.context || reads.error !== void 0) return;
		const thread = this.host.threadContext(trigger);
		if (!thread) {
			reads.error = NO_CONTEXT;
			return;
		}
		let loading = reads.loading;
		if (!loading) {
			const current = () => this.evals.get(evalId)?.loading === loading;
			loading = Promise.resolve().then(async () => {
				try {
					const timeout = AbortSignal.timeout(this.host.deployment.admissionContextTimeoutMs.get());
					const signal = AbortSignal.any([
						this.controller.signal,
						...caller ? [caller] : [],
						timeout
					]);
					const commands = this.host.commands.withSignal(signal);
					const context = await admissionContext(thread, commands, this.host.deployment.admissionContextMaxPages.get());
					if (!current()) return;
					reads.context = context;
					if (context.next) reads.cache.cursors.add(context.next);
					for (const message of context.messages) if (!message.deleted) {
						reads.cache.messages.set(message.id, message.text);
						this.imageReferences(thread, trigger, message.text, message.id, reads.cache);
					}
				} catch (error) {
					caller?.throwIfAborted();
					if (current()) reads.error = `Thread context unavailable: ${String(error).slice(0, 300)}. Use orchestrator_eval_read before deciding based on missing context.`;
				}
			}).finally(() => {
				if (current()) delete reads.loading;
			});
			reads.loading = loading;
		}
		await loading;
		caller?.throwIfAborted();
		if (!this.live(evalId, trigger)) throw new Error(FINISHED);
	}
	/**
	* Returns the `orchestrator_eval` payload: the trigger's text once (up to `TRIGGER_CHARS`), batch peers, related tickets
	* on the thread, the Policy version its Eval was built from, and the initial thread window (first five messages and five
	* on either side of the trigger, truncated to `WINDOW_CHARS` or `NEAR_CHARS` for its two nearest neighbours with total
	* length and image IDs, plus other loaded messages as `STUB_CHARS` previews; `orchestrator_eval_read` reads any message
	* in full by ID).
	* Assessment instructions live in the main Session's prompt (`prompts/admission.md`), not in this payload.
	*/
	async context(triggerId, signal) {
		const { candidate, trigger } = this.evalFor(triggerId);
		await this.seed(candidate.evalId, trigger, signal);
		const { context, error } = this.evals.get(candidate.evalId) ?? {};
		const source = this.host.threadContext(trigger);
		const images = (text) => source?.images(text) ?? [];
		const imageIds = (id, text) => {
			const keys = images(text);
			return keys.length ? { images: keys.map((key) => `${id}/${key}`) } : {};
		};
		const cut = (text, limit) => text.length <= limit ? { text } : {
			text: `${text.slice(0, limit)}…`,
			chars: text.length
		};
		const thread = context ? (() => {
			const shown = new Map(context.window.entries.map((entry) => [entry.message.id, entry]));
			const at = context.messages.findIndex((message) => message.id === source?.messageId);
			const messages = context.messages.map((message, index) => {
				const author = {
					id: message.id,
					from: message.from,
					...message.bot ? { bot: true } : {}
				};
				if (message.deleted) return {
					...author,
					deleted: true
				};
				if (!shown.has(message.id)) return {
					...author,
					preview: message.text.replace(/\s+/g, " ").slice(0, STUB_CHARS)
				};
				if (index === at) return {
					...author,
					at: message.at,
					trigger: true
				};
				const near = at >= 0 && Math.abs(index - at) <= 2;
				return {
					...author,
					at: message.at,
					...cut(message.text, near ? NEAR_CHARS : WINDOW_CHARS),
					...imageIds(message.id, message.text)
				};
			});
			return {
				complete: context.complete,
				loaded_messages: context.messages.length,
				source_found: context.window.source_found,
				...context.next ? { next_cursor: context.next } : {},
				messages
			};
		})() : {
			error: error ?? "Call orchestrator_eval to load initial context",
			complete: false
		};
		const settings = this.host.settings();
		const others = candidate.triggers.filter((item) => item.id !== trigger.id);
		return {
			trigger_id: trigger.id,
			strength: candidate.strength,
			mode: settings.eval.mode,
			source: {
				kind: trigger.source,
				actor: trigger.actor.id,
				thread: threadKey(trigger.threads[0]),
				...trigger.url ? { url: trigger.url } : {}
			},
			...cut(trigger.text, TRIGGER_CHARS$1),
			...imageIds(source?.messageId ?? "", trigger.text),
			...others.length ? { batch: others.map((item) => {
				const text = cut(item.text, WINDOW_CHARS);
				return {
					trigger_id: item.id,
					actor: item.actor.id,
					at: item.at,
					...text,
					..."chars" in text ? { read: `trigger/${item.id}` } : {}
				};
			}) } : {},
			...relatedTickets(candidate.tickets),
			policy_version: candidate.policyVersion,
			thread
		};
	}
	/**
	* Serves bounded paginated text or image attachments from the evaluation's thread context or repository for
	* `orchestrator_eval_read`; `agent` is the main Session, which receives images as attachments.
	*/
	async read(agent, read, signal) {
		const { candidate, trigger } = this.evalFor(read.trigger_id);
		await this.seed(candidate.evalId, trigger, signal);
		const { cache } = this.reads(candidate.evalId, trigger);
		const { snapshots, images, messages, cursors } = cache;
		const commands = this.host.commands.withSignal(AbortSignal.any([this.controller.signal, signal]));
		if (read.resource === "image") {
			if (read.offset !== 0) throw new Error("Images are not paginated; use offset 0");
			const image = images.get(read.image_id);
			if (!image) throw new Error("Unknown image reference. Read the source/root/thread for this trigger first and copy its image read arguments.");
			const source = this.host.threadContext(trigger);
			if (!source) throw new Error(NO_CONTEXT);
			const key = read.image_id.slice(read.image_id.indexOf("/") + 1);
			return source.image(agent, commands, image, key, this.host.deployment.stateDir, signal);
		}
		const cacheKey = JSON.stringify([
			read.resource,
			read.path,
			read.cursor,
			read.message_id
		]);
		if (read.offset > 0) {
			const cached = snapshots.get(cacheKey);
			if (cached === void 0) throw new Error("Read this resource at offset 0 first");
			return textPage(read.resource, cached, read.offset, 4e3);
		}
		let body;
		const source = this.host.threadContext(trigger);
		if (read.resource === "message") {
			const message = messages.get(read.message_id ?? source?.messageId ?? "");
			if (message === void 0) throw new Error("Unknown message reference. Use resource=root/parent or read the thread first; copy a returned message read call.");
			body = message;
		} else if (read.resource === "thread" || read.resource === "root" || read.resource === "parent") {
			if (!source) throw new Error(NO_CONTEXT);
			if (read.cursor !== void 0 && !cursors.has(read.cursor)) throw new Error("Unknown thread cursor. First call {resource:\"thread\"}; then copy the returned next_read exactly.");
			const result = await source.read(commands, read.resource, read.cursor);
			const references = result.messages.filter((message) => !message.deleted).flatMap((message) => {
				messages.set(message.id, message.text);
				return this.imageReferences(source, trigger, message.text, message.id, cache);
			});
			if (result.next) cursors.add(result.next);
			const next = result.next ? {
				trigger_id: trigger.id,
				resource: "thread",
				cursor: result.next
			} : null;
			body = JSON.stringify({
				images: references,
				next_read: next,
				...result.body
			});
		} else {
			if (!this.host.deployment.repository) throw new Error("No GitHub repository is configured in this installation; read thread, message, root, or parent resources instead.");
			body = await readRepositoryPath(commands, read.path, read.resource === "directory" ? "directory" : "file");
		}
		snapshots.set(cacheKey, body);
		return textPage(read.resource, body, read.offset, 4e3);
	}
	/** Converts the assessment into an outcome under current settings and passes it to `Engine.decide` for policy verification. */
	async decide(triggerId, result, signal) {
		const { candidate } = this.evalFor(triggerId);
		signal?.throwIfAborted();
		let outcome = assessmentOutcome(result, this.host.settings(), candidate.strength);
		if (outcome.kind === "accept" && outcome.acknowledgement) outcome = {
			...outcome,
			acknowledgement: checkedImText(outcome.acknowledgement)
		};
		const decision = this.host.engine.decide(triggerId, {
			...outcome,
			evalId: candidate.evalId
		});
		return {
			state: decision.kind,
			...decision.ticketId ? { ticket_id: decision.ticketId } : {},
			reason: reasonText(decision.reason)
		};
	}
	/** Aborts any in-flight thread context or repository read commands when the runtime stops. */
	stop() {
		this.controller.abort();
	}
};
//#endregion
//#region src/executor/background.ts
/** How long a stop waits for a killed job to end, collecting its end so the worker is not woken to hear of it. */
const KILL_WAIT_MS = 1e4;
/** How long a release of subagents may take; it can hold up a shutdown, so DSH's own callers bound it too. */
const DRAIN_LIMIT_MS = 1e4;
/** How long one wait that collects a job's end runs; one that ends with the job running is followed by the next. */
const COLLECT_WAIT_MS = 6e5;
const registry = (ctx) => ctx.get("jobs");
const subagentsOf = (ctx) => ctx.get("subagents");
const running = (status) => status === "running" || status === "stopping";
/** The jobs the Session owns that run, but those in `except`, such as the ones left to a person. */
const owned = (jobs, sessionId, except) => jobs.list(sessionId).filter((job) => job.owner === sessionId && running(job.status) && !except?.has(job.id));
/** `work`, or false once `signal` aborts or `ms` pass first. */
function until(work, signal, ms) {
	if (signal?.aborted) return Promise.resolve(false);
	let stop;
	const stopped = new Promise((resolve) => {
		stop = () => {
			resolve(false);
		};
	});
	signal?.addEventListener("abort", stop, { once: true });
	const timer = ms === void 0 ? void 0 : setTimeout(stop, ms);
	timer?.unref?.();
	return Promise.race([work, stopped]).finally(() => {
		signal?.removeEventListener("abort", stop);
		clearTimeout(timer);
	});
}
/** The workers whose turn a stop of their subagents cancelled, whose next idle ends that turn rather than one of their own. */
const cancelled = /* @__PURE__ */ new WeakSet();
/** The pending join of each worker's subagents, which DSH cannot cancel, so a later look joins the same one. */
const joins = /* @__PURE__ */ new WeakMap();
function childrenEnd(subagents, agent) {
	let join = joins.get(agent);
	if (!join) {
		join = subagents.waitForChildren(agent).finally(() => {
			joins.delete(agent);
		});
		joins.set(agent, join);
	}
	return join;
}
/** A job by its id and the first line of its label. */
const named = (job) => {
	const line = job.label?.split("\n")[0]?.trim();
	return line ? `${job.id} (${line})` : job.id;
};
/** The shell jobs the Session owns that still run, but those in `except`, with their names. */
const runningJobs = (ctx, sessionId, except) => {
	const jobs = registry(ctx);
	return jobs ? owned(jobs, sessionId, except).map((job) => ({
		id: job.id,
		name: named(job)
	})) : [];
};
/**
* Wait until no shell job the Session owns runs; false at once when none ran, or when `signal` aborts first. The wait is
* no waiter on any job, so each job's end still reaches the worker.
*/
function jobsEnd(ctx, sessionId, signal, except) {
	const jobs = registry(ctx);
	if (!jobs || !owned(jobs, sessionId, except).length) return Promise.resolve(false);
	return new Promise((resolve) => {
		let settled = false;
		const done = (value) => {
			if (settled) return;
			settled = true;
			unsubscribe();
			signal.removeEventListener("abort", aborted);
			resolve(value);
		};
		const aborted = () => {
			done(false);
		};
		const unsubscribe = jobs.events.subscribe({ owner: sessionId }, (event) => {
			if ((event.type === "settled" || event.type === "removed") && !owned(jobs, sessionId, except).length) done(true);
		});
		signal.addEventListener("abort", aborted, { once: true });
		if (signal.aborted) aborted();
	});
}
/**
* Wait until nothing runs for a worker that went idle: its shell jobs, but those in `except`, and its subagents. A job's or a
* subagent's end wakes the worker with its result, which ends this look: the turn it starts ends with an idle of its own,
* which looks afresh.
* @returns true once all of it ended with the worker idle; false when the worker runs again, or when `signal` aborts first,
* as when the host stops or the look's time is up.
*/
async function untilQuiet(ctx, agent, signal, except) {
	for (;;) {
		const subagents = subagentsOf(ctx);
		const children = subagents ? await until(childrenEnd(subagents, agent), signal) : false;
		const jobs = await jobsEnd(ctx, agent.id, signal, except);
		if (signal.aborted || agent.status !== "idle") return false;
		if (!children && !jobs) return true;
	}
}
/**
* Kill the shell jobs the Session owns, but those in `except`, collecting each end so the worker is not woken to hear of it.
* One failure stops none other.
*/
async function killJobs(ctx, sessionId, reason, except) {
	const jobs = registry(ctx);
	const live = jobs ? owned(jobs, sessionId, except) : [];
	const failures = [];
	const collected = live.map((job) => jobs.wait(job.id, KILL_WAIT_MS, sessionId).catch(() => void 0));
	for (const job of live) try {
		jobs.kill(job.id, sessionId, reason);
	} catch (error) {
		failures.push(error);
	}
	await Promise.all(collected);
	if (failures.length) throw new AggregateError(failures, `Killing the shell jobs of ${sessionId} failed`);
}
/**
* Collect the end of a shell job the Session owns, so it wakes no one, until `signal` aborts.
* @returns the job's name and status once it ended; undefined when `signal` aborted first.
*/
async function collectJob(ctx, sessionId, job, signal) {
	const jobs = registry(ctx);
	while (jobs && !signal.aborted) {
		const view = await jobs.wait(job.id, COLLECT_WAIT_MS, sessionId, signal).catch(() => void 0);
		if (!view) return void 0;
		if (!running(view.status)) return {
			name: job.name,
			status: view.status
		};
	}
}
/**
* Release the worker's live subagents, for a bounded time. DSH delivers each one's end to the worker before the release
* returns, which wakes it, so the worker's turn is cancelled after, keeping its inbox when `keepInbox`, and the stop ends
* with that turn. Its Session still admits subagents.
*/
async function stopSubagents(ctx, agent, keepInbox = false) {
	const subagents = subagentsOf(ctx);
	if (!subagents) return;
	const live = (await subagents.listChildren(agent.id)).map((child) => child.id).filter((id) => ctx.agents.get(id));
	if (!live.length) return;
	try {
		await until(subagents.drainChildren(agent, live), void 0, DRAIN_LIMIT_MS);
	} finally {
		if (agent.status !== "idle") cancelled.add(agent);
		agent.cancel({ kind: "user" }, { keepInbox });
		await until(agent.whenIdle(), void 0, DRAIN_LIMIT_MS);
	}
}
/**
* Stop what a worker runs in the background once its Assignment ends: kill its shell jobs and release its subagents (see
* `stopSubagents`). A Session not loaded has no subagent at work. One failure stops nothing else.
*/
async function stopBackground(ctx, sessionId, reason, keepInbox = false) {
	const failures = [];
	await killJobs(ctx, sessionId, reason).catch((error) => {
		failures.push(error);
	});
	const agent = ctx.agents.get(sessionId);
	if (agent) await stopSubagents(ctx, agent, keepInbox).catch((error) => {
		failures.push(error);
	});
	if (failures.length) throw new AggregateError(failures, `Stopping the background work of ${sessionId} failed`);
}
//#endregion
//#region src/executor/dsh.ts
const now$3 = () => (/* @__PURE__ */ new Date()).toISOString();
/** Returns the worker session ID (`worker-<ticketId>`) for a ticket. */
const workerSessionId = (ticketId) => `worker-${ticketId}`;
/** Returns the ticket ID for a worker session ID (`worker-<ticketId>`), or undefined for non-worker sessions. */
const ticketOfSession = (sessionId) => sessionId.startsWith("worker-") ? sessionId.slice(7) : void 0;
/** Maximum runtime for a workspace prepare command. */
const PREPARE_TIMEOUT_MS = 6e5;
/** Maximum transient retry attempts for a launch or worker turn, and the initial backoff before resuming a turn. */
const TRANSIENT_TRIES = 3;
const TRANSIENT_BACKOFF_MS = 15e3;
/** How long a worker's background work may run on after its turn ended before it is stopped and the worker reported waiting. */
const BACKGROUND_LIMIT_MS = 18e5;
/** How long a host stop waits for the workers' background work to stop. */
const SHUTDOWN_STOP_MS = 1e4;
/** How long a worker that goes on after a passing failure waits for a worker slot, or for processing to resume, between looks. */
const SLOT_WAIT_MS = 5e3;
/** True when an input comes from a person (a non-context human trigger or a direct text input such as a status request). */
const fromPerson = (input) => input?.kind === "trigger" ? !!input.human && !input.context : input?.kind === "text";
/**
* Internal error thrown when a ticket's workspace prepare command fails during launch.
* DshExecutor catches it to mark the ticket failed immediately rather than retrying automatically, because an existing directory counts as prepared and an automatic retry would treat whatever a failed prepare command left behind in the directory as a prepared workspace.
*/
var PrepareFailed = class extends Error {};
const PASSING = new RegExp([
	"ECONNRESET",
	"ECONNREFUSED",
	"ETIMEDOUT",
	"EAI_AGAIN",
	"ENOTFOUND",
	"EPIPE",
	"UND_ERR",
	"socket hang up",
	"fetch failed",
	"network error",
	"overloaded",
	"rate limit",
	"\\b(?:408|429|50[0-4])\\b"
].join("|"), "i");
/**
* True when an error represents a transient network or model-provider failure: an HTTP 408, 429, or 5xx status, or a
* connection that was refused, reset, timed out, or could not resolve its host.
*/
function transient(error) {
	const status = error?.status;
	if (typeof status === "number") return status === 408 || status === 429 || status >= 500;
	const text = error instanceof Error ? `${error.name} ${error.message} ${String(error.code ?? "")}` : String(error);
	return PASSING.test(text);
}
/** Appends a stable 12-character ticket ID suffix to a validated English worktree name. */
const ticketWorktreeName = (name, id) => `${WorktreeNameSchema.parse(name)}-${id.slice(0, 12)}`;
/** Looks up a ticket's origin trigger in Store. */
const sourceTrigger = (host, ticket) => host.store.triggers.get(ticket.origin.triggerId);
/**
* Returns additional system-prompt mandate instructions for a worker beyond the request: for work accepted proactively under
* rules (`strength === 'inferred'`), restricts non-exploratory rules to small internal changes and grants exploratory rules
* workspace-scoped synthesis without repository mutation or unsolicited questions; returns `''` for explicit requests.
*/
function mandateInstructions(mandate, rules) {
	if (mandate.strength !== "inferred") return "";
	const matched = mandate.basis?.rules ?? [];
	return !!rules && matched.length > 0 && matched.some((id) => rules.some((rule) => rule.id === id && rule.exploratory)) ? "This ticket has exploratory proactive authorization within the matched rule scope. Synthesize grounded research, option trade-offs, or workspace deliverables without mutating existing user repositories or asking unsolicited clarification; if investigation finds no substantive value beyond the conversation, stop and report dropped." : "This ticket has limited proactive authorization. Independently verify that it is a small change internal to one module within the accepted rule scope. If it requires public-interface or behavior changes, new interaction, product decisions or clarification, stop and report dropped; do not expand scope.";
}
/** Builds a newly accepted ticket's Execution metadata: its worktree name, workspace directory, and assignment text. */
function ticketExecution(ticket, outcome, settings, stateDir) {
	const name = ticketWorktreeName(outcome.name ?? "", ticket.id);
	ticket.origin.triggerId;
	const note = outcome.note ? `\nRouting note (not the source request): ${outcome.note}` : "";
	const ruleIds = ticket.mandate.basis.rules;
	const rules = settings.policy.rules.filter((rule) => ruleIds?.includes(rule.id)).map((rule) => `\n- ${rule.name} (${rule.id}): ${rule.instruction}`).join("");
	const precedence = rules ? `\nMatched rules; their procedure and communication instructions take precedence over the default acknowledgement and messaging policy for this ticket:${rules}` : "";
	const assignment = ticket.mandate.strength === "inferred" && ruleIds ? `Proactively accepted under ${ruleIds.join(", ")}. Scope: ${outcome.scope}.${precedence}${note}` : note.trim();
	return {
		name,
		directory: join(executionRoot(settings, stateDir), name),
		assignment
	};
}
/** Character limits for inline assignment and trigger text in worker messages; longer text is read via its resource. */
const ASSIGNMENT_CHARS = 1500;
const TRIGGER_CHARS = 600;
/** Returns `text` up to `limit` characters, or a truncated preview with total character count and the resource path to read the full text. */
const capped = (text, limit, read) => text.length <= limit ? { text } : {
	text: `${text.slice(0, limit)}…`,
	chars: text.length,
	read
};
/**
* Formats a Trigger for worker delivery: author, thread, timestamp, text up to `TRIGGER_CHARS`, source message link,
* optional routing note, and a preview of the replied-to message when the worker has not yet seen it.
*/
function triggerMessage(trigger, link, note, repliesTo) {
	return {
		trigger_id: trigger.id,
		from: trigger.actor.id,
		thread: threadKey(trigger.threads[0]),
		at: trigger.at,
		...capped(trigger.text, TRIGGER_CHARS, `trigger/${trigger.id}`),
		...link,
		...note ? { routing_note: note } : {},
		...repliesTo ? { replies_to: {
			trigger_id: repliesTo.id,
			preview: repliesTo.text.replace(/\s+/g, " ").slice(0, 160)
		} } : {}
	};
}
/** Formats a peer trigger from the ticket's acceptance batch with author, timestamp, 160-character preview, and read resource path. */
const batchLine = (trigger) => ({
	trigger_id: trigger.id,
	from: trigger.actor.id,
	at: trigger.at,
	preview: trigger.text.replace(/\s+/g, " ").slice(0, 160),
	read: `trigger/${trigger.id}`
});
/** Returns the other triggers in a ticket's origin batch (excluding the primary `origin.triggerId`), oldest first. */
const batchOf = (host, ticket) => ticket.origin.triggerIds.filter((id) => id !== ticket.origin.triggerId).flatMap((id) => host.store.triggers.get(id) ?? []);
const RESUMED = "This ticket ended earlier and the message that follows, on its thread, resumed it under the same mandate. If it asks for more within the original scope, inspect the worktree, git history and PR state and continue; if it asks for work beyond that scope or for another ticket, hand it back with orchestrator_trigger_handback and report dropped; if it needs nothing, such as thanks, report dropped without a message. Report ready when the follow-up is done. Do not repeat completed work.";
const RETRIED = "A person retried this ticket. Continue the assignment from the current worktree, git history and PR state.";
/** Formats a policy-change input for the worker; inputs recorded before `effect` existed fall back to a general notice. */
function policyMessage(effect) {
	if (!effect) return "Policy change: the access or admission rules changed. Check that the remaining work stays within the assignment.";
	return [
		"Policy change:",
		...(effect.rules ?? []).map((rule) => rule.change === "disabled" ? `Rule ${rule.name} (${rule.id}), which this ticket was accepted under, no longer applies: finish only a change within it, or report dropped.` : `Rule ${rule.name} (${rule.id}), which this ticket was accepted under, changed. Keep the remaining work within it as it reads now: ${rule.instruction}`),
		...effect.proactive === false ? ["Work inferred from a rule is no longer accepted, as the accept mode is no longer auto: finish only what is in progress within the assignment, or report dropped, and take on nothing new."] : [],
		...effect.requesterAllowed === false ? [`The sender this ticket is for, ${effect.requester ? `${effect.requester.id} on ${effect.requester.source}` : "who asked for it"}, may no longer start work here: finish the assignment within its scope, and take no new requests from them on it.`] : []
	].join("\n");
}
/** Resource path under which a worker session reads the full text of a ticket input. */
const inputResource = (ticketId, inputId) => `ticket/${ticketId}/input/${key(inputId)}`;
/**
* Formats a ticket input for worker delivery: a `trigger` rendered via `trigger` (or by its ID and read path when absent),
* a `policy-changed` notice, a `resumed` notice, an orchestrator `note`, or a `text` input as written.
* Returns `undefined` for legacy `reopen` inputs, which are historical only because the schema 11 migration converted pending reopen inputs into text inputs.
*/
function inputMessage(input, trigger) {
	if (input.kind === "trigger") return JSON.stringify({
		...trigger ?? {
			trigger_id: input.triggerId,
			read: `trigger/${input.triggerId}`
		},
		...input.context ? { context: true } : {}
	});
	if (input.kind === "policy-changed") return policyMessage(input.effect);
	if (input.kind === "resumed") return RESUMED;
	if (input.kind === "note") return `Note from the orchestrator, for context only: ${input.text}`;
	return input.kind === "text" ? input.text : void 0;
}
/**
* Tracks active and starting worker sessions against the configured concurrency limit: a ticket holds a slot while its
* worker's turn runs, while its shell jobs or subagents run after that turn ended, and while a launch or wake starts that worker.
* DshExecutor reserves slots synchronously before awaiting launch or wake work so two starts cannot take the last slot,
* and allows one extra slot beyond the limit for human follow-ups (`by === 'person'`) so they never wait behind new launches.
*/
var WorkerSlots = class {
	running;
	max;
	/** Tickets currently holding a startup slot, mapped to whether the start is a launch, a wake, or a wake for a person's message. */
	starting = /* @__PURE__ */ new Map();
	/**
	* @param running - Returns the ticket IDs whose worker holds a slot (see `DshExecutor.running`).
	* @param max - Returns the configured maximum number of concurrent worker slots.
	*/
	constructor(running, max) {
		this.running = running;
		this.max = max;
	}
	/** Number of slots currently in use across running workers and starting reservations. */
	used() {
		return (/* @__PURE__ */ new Set([...this.running(), ...this.starting.keys()])).size;
	}
	/** How many launches may run concurrently: the slots not held by a running worker or a wake reservation. */
	launches() {
		const wakes = [...this.starting].flatMap(([ticketId, by]) => by !== "launch" ? [ticketId] : []);
		return this.max() - (/* @__PURE__ */ new Set([...this.running(), ...wakes])).size;
	}
	/**
	* Reserves a startup slot for `ticketId`; idempotent if `ticketId` already holds a starting slot.
	* A wake for a person's message (`by === 'person'`) may use one extra slot beyond `max()`.
	* Call `free(ticketId)` once the worker turn is running or the launch/wake attempt ends.
	* @throws Later when no slot is free.
	*/
	reserve(ticketId, by) {
		if (this.starting.has(ticketId)) return;
		if (this.used() >= this.max() + (by === "person" ? 1 : 0)) throw new Later("No worker slot is free");
		this.starting.set(ticketId, by);
	}
	/** Releases `ticketId`'s starting slot once its worker session is running or the launch/wake attempt has ended. */
	free(ticketId) {
		this.starting.delete(ticketId);
	}
};
/**
* Executes ticket assignments in persistent per-ticket DSH worker sessions and isolated workspace directories.
* Queues launches and input deliveries through Effects, manages concurrency with WorkerSlots, listens for `agent/status`,
* `agent/inbox/claimed`, `session/event` and `agent/error` events on the Cordis context, and reports status transitions back to Engine.
* Runtime, Engine, worker tools, and management routes use this class to prepare, launch, deliver to, stop, and resume ticket assignments.
*/
var DshExecutor = class {
	host;
	disposers = [];
	slots;
	/** Transient failure counts tried so far: keyed by `assignment.id` for worker turns and `launch:<assignment.id>` for launches. */
	transient = /* @__PURE__ */ new Map();
	/** Assignment IDs currently waiting on a transient-failure backoff timer before resuming their worker turn. */
	resuming = /* @__PURE__ */ new Set();
	/**
	* The looks at background work of workers that went idle, by ticket, which hold their slots; a look ends when its worker
	* runs again or its Assignment ends.
	*/
	settling = /* @__PURE__ */ new Map();
	/** The stops of tickets' background work that run, by ticket, which a launch or a delivery of the ticket waits for. */
	stopping = /* @__PURE__ */ new Map();
	/** The jobs workers left to a person when they handed off, by ticket, and the collecting of their ends. */
	left = /* @__PURE__ */ new Map();
	/** When a person's message typed into a worker's Session last started a turn, by ticket. */
	personal = /* @__PURE__ */ new Map();
	/** The timers of workers that go on after a passing failure, which dispose clears. */
	timers = /* @__PURE__ */ new Set();
	/** Registers the `launch` and `delivery` effect handlers; both are held (concurrency limit 0) while processing is paused. */
	constructor(host) {
		this.host = host;
		this.slots = new WorkerSlots(() => host.store.tickets.open().filter((ticket) => this.running(ticket)).map((ticket) => ticket.id), () => host.store.settings().executor.maxWorkers);
		host.effects.handle("launch", (payload) => this.launchQueued(payload), {
			limit: () => host.paused() ? 0 : this.slots.launches(),
			retry: [5e3, 3e5]
		});
		host.effects.handle("delivery", (payload) => this.deliverQueued(payload.ticketId), {
			limit: () => host.paused() ? 0 : 4,
			quiet: true
		});
	}
	/** Populates a newly accepted ticket's `execution` attributes (worktree name, workspace directory, and assignment text). */
	prepare(ticket, outcome) {
		return {
			...ticket,
			execution: ticketExecution(ticket, outcome, this.host.store.settings(), this.host.machine.stateDir)
		};
	}
	/**
	* Runs the configured `executor.prepare` command for a new ticket workspace in its parent directory with the ticket's
	* execution environment variables, then verifies the directory as the worker sees it.
	* A failed prepare command throws `PrepareFailed`, which is not retried automatically; an empty directory it left is removed, a non-empty one kept.
	* @throws PrepareFailed with the command's output when the prepare command fails.
	*/
	async prepareDirectory(ticket) {
		const directory = ticket.execution?.directory ?? "";
		await mkdir(dirname(directory), { recursive: true });
		const command = this.host.store.settings().executor.prepare.trim();
		const env = Object.fromEntries(this.host.environment(ticket).map((variable) => [variable.key, variable.value]));
		const signal = AbortSignal.any([this.host.lifetime, AbortSignal.timeout(PREPARE_TIMEOUT_MS)]);
		if (command) await runAsWorker(this.host.context.subprocess, [
			"sh",
			"-c",
			command
		], dirname(directory), signal, env).catch(async (error) => {
			await rmdir(directory).catch(() => {});
			throw new PrepareFailed(`The prepare command failed: ${error instanceof Error ? error.message : String(error)}`);
		});
		await mkdir(directory, { recursive: true });
		await verifyDirectory(directory, this.host.context.subprocess, this.host.lifetime);
	}
	/** Enqueues a `launch` effect for an accepted or resumed assignment; launches start in queue order as worker slots free up. */
	start(ticket, assignment) {
		this.host.effects.enqueue("launch", assignment.id, {
			ticketId: ticket.id,
			assignmentId: assignment.id
		});
	}
	/** Enqueues a `delivery` effect to steer pending inputs into `ticket`'s running worker session. */
	deliver(ticket, _assignment) {
		this.host.effects.enqueue("delivery", ticket.id, { ticketId: ticket.id });
	}
	/** Launches a queued assignment unless its ticket ended or a newer assignment replaced it meanwhile. */
	async launchQueued({ ticketId, assignmentId }) {
		const ticket = this.host.store.tickets.get(ticketId);
		const assignment = ticket && latestAssignment(ticket);
		if (!ticket || !liveTicket(ticket) || assignment?.id !== assignmentId || assignment.state !== "pending") return;
		this.slots.reserve(ticketId, "launch");
		try {
			await this.launch(ticket, assignment);
			this.transient.delete(`launch:${assignmentId}`);
		} catch (error) {
			if (this.host.closing() || error instanceof Later) throw error;
			if (!(error instanceof PrepareFailed) && this.retries(`launch:${assignmentId}`, error)) throw error;
			this.launchFailed(ticketId, assignmentId, error);
		} finally {
			this.slots.free(ticketId);
		}
	}
	/**
	* Delivers queued inputs to a running assignment one by one, re-reading ticket state before each delivery so delivery
	* stops immediately if the ticket ended or another assignment took over.
	*/
	async deliverQueued(ticketId) {
		await this.stopped(ticketId);
		const first = this.host.store.tickets.get(ticketId);
		const target = first && liveTicket(first) ? runningAssignment(first) : void 0;
		if (!first || !target || !first.undelivered.length) return;
		let woken = false;
		try {
			for (;;) {
				const ticket = this.host.store.tickets.get(ticketId);
				const assignment = ticket && liveTicket(ticket) ? runningAssignment(ticket) : void 0;
				const inputId = ticket?.undelivered[0];
				if (!ticket || !assignment || inputId === void 0) return;
				const sessionId = workerSessionId(ticketId);
				if (!woken && !this.running(ticket)) {
					const person = ticket.undelivered.some((id) => fromPerson(ticket.inputs.find((item) => item.id === id)));
					this.slots.reserve(ticketId, person ? "person" : "wake");
					woken = true;
				}
				const input = ticket.inputs.find((item) => item.id === inputId);
				try {
					if (!this.host.context.agents.get(sessionId)) await this.host.sessions.ensure(sessionId, ticket.execution?.directory ?? "", ticket.title, "worker");
					if (input) await this.deliverInput(ticket, assignment, input);
				} catch (error) {
					if (this.host.closing() || error instanceof Later) throw error;
					const current = this.host.store.tickets.get(ticketId);
					if (!current || !liveTicket(current) || runningAssignment(current)?.id !== assignment.id) return;
					this.host.engine.deliveryFailed(ticketId, assignment.id, String(error));
					throw error;
				}
				this.host.engine.inputsDelivered(ticketId, assignment.id, [inputId]);
			}
		} finally {
			if (woken) this.slots.free(ticketId);
		}
	}
	async deliverInput(ticket, assignment, input) {
		const live = () => {
			const current = this.host.store.tickets.get(ticket.id);
			if (!current || !liveTicket(current) || runningAssignment(current)?.id !== assignment.id) throw new Error("The ticket ended or another Assignment took it over");
			if (this.stopping.has(ticket.id)) throw new Later("The worker's background work is stopping");
		};
		live();
		const message = inputMessage(input, input.kind === "trigger" ? await this.triggerCard(ticket, input.triggerId, input.note) : void 0);
		if (message === void 0) return;
		const text = message.length > ASSIGNMENT_CHARS ? JSON.stringify(capped(message, ASSIGNMENT_CHARS, inputResource(ticket.id, input.id))) : message;
		await this.host.sessions.prompt(workerSessionId(ticket.id), input.id, text, "steer", live);
	}
	/** Formats a trigger on `ticket` for the worker, including a preview of the replied-to message when the worker has not yet seen it. */
	async triggerCard(ticket, triggerId, note) {
		const trigger = this.host.store.triggers.get(triggerId);
		if (!trigger) return void 0;
		const parent = this.host.repliedTo(trigger);
		const seen = parent && (parent.id === ticket.origin.triggerId || ticket.inputs.some((item) => item.kind === "trigger" && item.triggerId === parent.id));
		return triggerMessage(trigger, await this.host.sourceLink(trigger), note, seen ? void 0 : parent);
	}
	/**
	* After the ending transaction commits (so a rollback leaves the worker working, and a launch the same transaction queued
	* starts after it): ends the look at its background work, cancels its turn unless its last word was a `ready` or `dropped`
	* report with no Input delivered since, and stops its shell jobs and subagents, including jobs it left to a person.
	*/
	stop(ticket, assignment, reason) {
		this.transient.delete(assignment.id);
		this.transient.delete(`launch:${assignment.id}`);
		const report = assignment.report;
		const busy = !!assignment.deliveredAt && !!report && assignment.deliveredAt >= report.at;
		const ownTurn = (report?.state === "ready" || report?.state === "dropped") && !busy;
		const sessionId = workerSessionId(ticket.id);
		this.host.store.afterCommit(() => {
			this.settling.get(ticket.id)?.abort();
			if (!ownTurn) this.host.context.agents.get(sessionId)?.cancel({ kind: "user" }, { keepInbox: false });
			this.stopWork(ticket.id, reason);
			this.left.get(ticket.id)?.collect.abort();
			this.left.delete(ticket.id);
			this.personal.delete(ticket.id);
		});
	}
	/** Stop what a ticket's worker runs in the background (see `stopBackground`). */
	stopWork(ticketId, reason, keepInbox = false) {
		this.track(ticketId, stopBackground(this.host.context, workerSessionId(ticketId), reason, keepInbox));
	}
	/** A stop of a ticket's background work, which a launch or a delivery of the ticket waits for while it runs. */
	track(ticketId, stop) {
		const entry = Promise.all([this.stopping.get(ticketId), stop.catch(() => {})]).then(() => {}).finally(() => {
			if (this.stopping.get(ticketId) === entry) this.stopping.delete(ticketId);
		});
		this.stopping.set(ticketId, entry);
		this.background(stop);
	}
	/** Wait for a stop of the ticket's background work that runs, unless the host stops first. */
	async stopped(ticketId) {
		const stopping = this.stopping.get(ticketId);
		if (stopping) await until(stopping, this.host.lifetime);
	}
	/**
	* On a host stop, for a bounded time: stop each loaded worker's background work, keeping its inbox; then end the collecting
	* of the jobs left to a person, which were killed, and cancel a worker turn that started meanwhile, keeping its inbox.
	*/
	async shutdown() {
		const agents = this.host.store.tickets.list().map((ticket) => this.host.context.agents.get(workerSessionId(ticket.id))).filter((agent) => agent !== void 0);
		const stop = async () => {
			await Promise.allSettled(agents.map((agent) => stopBackground(this.host.context, agent.id, "dsh-superagent stopped", true)));
			for (const { collect } of this.left.values()) collect.abort();
			const running = agents.filter((agent) => agent.status !== "idle");
			for (const agent of running) agent.cancel({ kind: "user" }, { keepInbox: true });
			await Promise.allSettled(running.map((agent) => agent.whenIdle()));
		};
		await until(stop(), void 0, SHUTDOWN_STOP_MS);
	}
	/** Number of open tickets whose worker holds a worker slot: its turn runs, or its shell jobs or subagents still run after its turn ended. */
	activeCount() {
		return this.host.store.tickets.open().filter((ticket) => this.running(ticket)).length;
	}
	/** Whether a ticket's worker holds a worker slot: its turn runs, or its shell jobs or subagents do after its turn ended. */
	running(ticket) {
		if (!runningAssignment(ticket)) return false;
		return this.host.context.agents.get(workerSessionId(ticket.id))?.status === "running" || this.settling.has(ticket.id);
	}
	/** Marks a ticket failed after its launch fails; the ticket waits until new human input or an explicit retry arrives. */
	launchFailed(ticketId, assignmentId, error) {
		const ticket = this.host.store.tickets.get(ticketId);
		if (!ticket || !liveTicket(ticket) || latestAssignment(ticket)?.id !== assignmentId) return;
		this.failed(ticketId, String(error));
	}
	/** Records a `failed` report on the ticket and relays the failure to the main Session in one transaction. */
	failed(ticketId, summary) {
		this.host.store.atomic(() => {
			const updated = this.host.engine.report(ticketId, {
				state: "failed",
				summary
			});
			this.relay(resultRelay(updated, "failed", summary));
		});
	}
	relay({ id, text }) {
		this.host.sessions.relay(id, text);
	}
	async launch(ticket, assignment) {
		const current = () => {
			if (this.host.closing()) throw new Error("dsh-superagent is stopping");
			if (this.host.paused()) throw new Later("Processing is paused");
			const stored = this.host.store.tickets.get(ticket.id);
			return !!stored && liveTicket(stored) && latestAssignment(stored)?.id === assignment.id;
		};
		const source = sourceTrigger(this.host, ticket);
		const workspace = ticket.execution?.directory ?? "";
		if (!current()) return;
		if (!await stat(workspace).then(() => true, () => false)) {
			await this.prepareDirectory(ticket);
			if (!current()) return;
		}
		if (!current()) return;
		const sessionId = workerSessionId(ticket.id);
		const agent = await this.host.sessions.ensure(sessionId, workspace, ticket.title, "worker");
		if (!current()) return;
		await this.stopped(ticket.id);
		if (!current()) return;
		for (const id of this.host.store.tickets.get(ticket.id)?.undelivered ?? []) agent.inbox.remove(this.host.sessions.promptedId(id));
		const first = `assignment:${ticket.id}`;
		const later = ticket.assignments.length > 1;
		const told = later && await this.host.sessions.holds(sessionId, first);
		if (!current()) return;
		const retried = ticket.assignments.at(-2)?.endedReason === "retried" ? { note: RETRIED } : {};
		const assignmentText = ticket.execution?.assignment ?? "";
		const { text: brief, chars, read } = capped(assignmentText, ASSIGNMENT_CHARS, `ticket/${ticket.id}/assignment`);
		const card = told || !source ? void 0 : await this.triggerCard(ticket, source.id);
		if (!current()) return;
		const batch = told ? [] : batchOf(this.host, ticket).map(batchLine);
		const text = told ? JSON.stringify({
			ticket_id: ticket.id,
			assignment: ticket.assignments.length,
			...retried
		}) : JSON.stringify({
			ticket_id: ticket.id,
			title: ticket.title,
			...brief ? { assignment: brief } : {},
			...read ? {
				assignment_chars: chars,
				assignment_read: read
			} : {},
			...card ? { trigger: card } : {},
			...batch.length ? { batch } : {},
			...retried
		});
		const requestId = later ? `assignment:${ticket.id}:${assignment.id}` : first;
		await this.host.sessions.prompt(sessionId, requestId, text, "queue", () => {
			if (!current()) throw new Error("Launch authorization changed before worker delivery");
		}, () => {
			this.host.engine.assignmentStarted(ticket.id, assignment.id);
		});
		this.host.engine.assignmentStarted(ticket.id, assignment.id);
	}
	/** Returns the stored ticket for `agent` when it is a worker session, or undefined otherwise. */
	ticketOf(agent) {
		const ticketId = ticketOfSession(agent.id);
		return ticketId === void 0 ? void 0 : this.host.store.tickets.get(ticketId);
	}
	/** Subscribes to host `agent/status`, `agent/inbox/claimed`, `session/event` and `agent/error` events for worker sessions. Call once at startup. */
	install() {
		const ctx = this.host.context;
		this.disposers.push(ctx.on("agent/status", ({ agent, status }) => {
			if (status === "running") {
				this.settling.get(ticketOfSession(agent.id) ?? "")?.abort();
				return;
			}
			if (status !== "idle" || cancelled.delete(agent) || this.host.closing()) return;
			const ticket = this.ticketOf(agent);
			const assignment = ticket && runningAssignment(ticket);
			if (ticket && assignment && liveTicket(ticket)) this.background(this.workerIdle(ticket, assignment, agent));
		}));
		this.disposers.push(ctx.on("agent/inbox/claimed", ({ agent, message }) => {
			const ticketId = ticketOfSession(agent.id);
			if (ticketId !== void 0 && message.source.kind === "user") this.personal.set(ticketId, now$3());
		}));
		this.disposers.push(ctx.on("session/event", (session, event) => {
			const ticketId = ticketOfSession(session.id);
			if (event.type !== "user/message" || ticketId === void 0 || event.data.source.kind !== "dsh-superagent" || this.host.closing()) return;
			const message = event.data;
			this.background(Promise.resolve().then(() => {
				const read = this.host.store.tickets.get(ticketId)?.inputs.filter((input) => input.kind === "trigger" && !input.readAt && this.host.sessions.promptedId(input.id) === message.id).map((input) => input.id) ?? [];
				if (read.length) this.host.engine.inputsRead(ticketId, read);
			}));
		}));
		this.disposers.push(ctx.on("agent/error", ({ agent, error }) => {
			const ticket = this.ticketOf(agent);
			const assignment = ticket && runningAssignment(ticket);
			if (!ticket || !assignment || !liveTicket(ticket) || this.host.closing()) return;
			if (this.retries(assignment.id, error)) {
				this.resumeAfter(ticket.id, assignment.id, error);
				return;
			}
			this.background(Promise.resolve().then(() => {
				this.failed(ticket.id, String(error));
			}));
		}));
	}
	/** Unsubscribes from host agent events and clears any pending transient-retry timers. */
	dispose() {
		for (const dispose of this.disposers.splice(0)) dispose();
		for (const timer of this.timers) clearTimeout(timer);
		this.timers.clear();
	}
	/**
	* Reconciles running and pending assignments across open tickets after a host restart: notifies Engine of interrupted
	* running assignments and re-queues pending launches (which earlier versions may have kept outside the effect queue),
	* while failed launches (`waitsForPerson`) wait for a person's message or a retry.
	*/
	resume() {
		for (const ticket of this.host.store.tickets.open().sort((a, b) => a.createdAt.localeCompare(b.createdAt))) {
			const running = runningAssignment(ticket), latest = latestAssignment(ticket);
			if (running) {
				this.host.context.agents.get(workerSessionId(ticket.id))?.cancel({ kind: "user" }, { keepInbox: true });
				this.stopWork(ticket.id, "dsh-superagent restarted", true);
				this.host.engine.assignmentInterrupted(ticket.id, running.id);
			} else if (latest?.state === "pending" && !waitsForPerson(ticket)) this.start(ticket, latest);
		}
	}
	/** Runs background worker event handling and updates the `worker` health entry on failure or recovery. */
	background(work) {
		const { health } = this.host;
		return work.then(() => {
			if (health.get()?.state === "error") health.set({
				state: "ready",
				detail: "Worker events are handled",
				at: now$3()
			});
		}, (error) => {
			health.set({
				state: "error",
				detail: String(error),
				at: now$3()
			});
		});
	}
	/**
	* Checks whether `error` is a transient failure with retry attempts remaining under `key`, mutating `this.transient`:
	* increments the attempt counter and returns `true` when retrying, or deletes `key` from `this.transient` and returns `false` when non-transient or out of tries.
	*/
	retries(key, error) {
		const tries = this.transient.get(key) ?? 0;
		if (!transient(error) || tries >= TRANSIENT_TRIES) {
			this.transient.delete(key);
			return false;
		}
		this.transient.set(key, tries + 1);
		return true;
	}
	/** Schedules a worker turn retry with exponential backoff after a transient provider or network error. */
	resumeAfter(ticketId, assignmentId, error) {
		const tries = this.transient.get(assignmentId);
		const text = `Your last turn failed for a passing reason (${String(error).slice(0, 200)}). Continue the assignment where it stopped.`;
		this.resuming.add(assignmentId);
		const go = () => {
			if (this.host.closing()) return;
			const ticket = this.host.store.tickets.get(ticketId);
			if (!ticket || !liveTicket(ticket) || runningAssignment(ticket)?.id !== assignmentId) {
				this.resuming.delete(assignmentId);
				return;
			}
			if (this.host.paused()) {
				this.after(SLOT_WAIT_MS, go);
				return;
			}
			const sessionId = workerSessionId(ticketId);
			const waking = !this.running(ticket);
			try {
				if (waking) this.slots.reserve(ticketId, "wake");
			} catch (failure) {
				if (!(failure instanceof Later)) throw failure;
				this.after(SLOT_WAIT_MS, go);
				return;
			}
			const sent = this.host.sessions.prompt(sessionId, `retry:${assignmentId}:${tries}`, text, "queue");
			this.background(sent.finally(() => {
				if (waking) this.slots.free(ticketId);
				this.resuming.delete(assignmentId);
			}).catch((failure) => {
				this.failed(ticketId, String(failure));
			}));
		};
		this.after(TRANSIENT_BACKOFF_MS * 2 ** (tries - 1), go);
	}
	/** Schedules `then` to run after `ms` milliseconds unless `dispose()` is called first. */
	after(ms, then) {
		const timer = setTimeout(() => {
			this.timers.delete(timer);
			then();
		}, ms);
		timer.unref?.();
		this.timers.add(timer);
	}
	/**
	* A worker that handed off to a person frees its slot: its subagents stop, and its shell jobs, such as a server for the
	* person, are left to the person until the Assignment ends. They hold no slot and run past any limit; their ends are
	* collected, so none wakes the worker outside a slot, and the worker reads of each at its next turn.
	*/
	handOff(ticketId, agent) {
		this.track(ticketId, stopSubagents(this.host.context, agent, true));
		const left = this.left.get(ticketId) ?? {
			jobs: /* @__PURE__ */ new Set(),
			collect: new AbortController()
		};
		this.left.set(ticketId, left);
		for (const job of runningJobs(this.host.context, agent.id, left.jobs)) {
			left.jobs.add(job.id);
			this.background(collectJob(this.host.context, agent.id, job, left.collect.signal).then(async (ended) => {
				if (!ended) return;
				const note = `Your background job ${ended.name} ended: ${ended.status}.`;
				await this.host.sessions.prompt(agent.id, `ended:${job.id}`, note, { inject: "Background job ended" });
			}));
		}
	}
	async workerIdle(ticket, idle, agent) {
		await agent.whenIdle();
		if (this.resuming.has(idle.id) || agent.status !== "idle") return;
		this.transient.delete(idle.id);
		const live = () => {
			const stored = this.host.store.tickets.get(ticket.id);
			return stored && liveTicket(stored) && runningAssignment(stored)?.id === idle.id ? stored : void 0;
		};
		const handedOff = (stored) => {
			const assignment = runningAssignment(stored), report = assignment?.report;
			const since = !!assignment?.deliveredAt && !!report && assignment.deliveredAt >= report.at;
			return (report?.state === "ready" || !!stored.attention) && !since || waitsForPerson(stored);
		};
		const before = live();
		if (!before || this.host.closing()) return;
		const report = runningAssignment(before)?.report, person = this.personal.get(ticket.id);
		if (handedOff(before) && !(report && person && person > report.at)) {
			this.host.engine.turnEnded(ticket.id, idle.id);
			this.handOff(ticket.id, agent);
			return;
		}
		this.settling.get(ticket.id)?.abort();
		const look = new AbortController(), limit = new AbortController();
		this.settling.set(ticket.id, look);
		const timer = setTimeout(() => {
			limit.abort();
		}, BACKGROUND_LIMIT_MS);
		timer.unref?.();
		let quiet;
		const left = this.left.get(ticket.id)?.jobs;
		try {
			quiet = await untilQuiet(this.host.context, agent, AbortSignal.any([
				this.host.lifetime,
				look.signal,
				limit.signal
			]), left);
		} finally {
			clearTimeout(timer);
			if (this.settling.get(ticket.id) === look) this.settling.delete(ticket.id);
		}
		const current = live();
		if (this.host.closing() || look.signal.aborted || !quiet && !limit.signal.aborted || !current || this.resuming.has(idle.id)) return;
		if (quiet) this.host.engine.turnEnded(ticket.id, idle.id);
		let stopped = "";
		if (!quiet) {
			const sessionId = workerSessionId(ticket.id), minutes = BACKGROUND_LIMIT_MS / 6e4;
			const jobs = runningJobs(this.host.context, sessionId, left).map((job) => job.name);
			if (jobs.length) {
				this.background(killJobs(this.host.context, sessionId, "The job ran past its limit", left));
				const note = `Your background jobs ran ${minutes} minutes after your turn ended and were killed: ${jobs.join(", ")}.`;
				this.background(this.host.sessions.prompt(sessionId, `killed:${jobs.join(",")}`, note, { inject: "Background jobs killed" }));
			}
			stopped = jobs.length ? `Background jobs ran ${minutes} minutes after the worker's turn ended and were killed: ${jobs.join(", ")}.` : `Subagents still ran ${minutes} minutes after the worker's turn ended.`;
		}
		if (handedOff(current)) return;
		const last = agent.session.snapshotEvents().filter((event) => event.type === "assistant/message").at(-1);
		const said = [last?.type === "assistant/message" ? last.data.message.content.filter((block) => block.type === "text").map((block) => block.text).join("\n").trim() : "", stopped].filter(Boolean).join("\n\n");
		this.host.store.atomic(() => {
			const before = latestReport(current)?.summary ?? "";
			const updated = this.host.engine.report(ticket.id, {
				state: "waiting",
				summary: said || before
			});
			if (said) this.relay(resultRelay(updated, "waiting", said));
			else if (!before.trim()) this.relay(resultRelay(updated, "waiting", "Worker ended without a status report. Use orchestrator_ticket_request_status to request one."));
		});
	}
};
/** Returns an error message explaining why `version` cannot be opened: older schemas need a new state directory. */
const tooOld = (version) => `Orchestrator database schema ${version} predates schema 10, which this version cannot migrate; start with a new state directory`;
const isObject = (value) => !!value && typeof value === "object" && !Array.isArray(value);
const text = (value) => typeof value === "string" && value ? value : void 0;
/** Runs one migration step, prefixing any thrown error with the name of the record that failed. */
function step(record, work) {
	try {
		return work();
	} catch (error) {
		throw new Error(`${record}: ${error instanceof Error ? error.message : String(error)}`, { cause: error });
	}
}
/** Rewrite all schema 10 records into their schema 11 shapes in place. */
function migrateTo11(store) {
	step("the settings", () => {
		migrateSettingsRecords(store);
	});
	step("the prompt versions", () => {
		migratePrompts(store);
	});
	const answers = /* @__PURE__ */ new Map();
	for (const name of store.keys("answer-ready:")) {
		const [, ticketId, triggerId] = name.split(":");
		if (store.get(name) === true && ticketId && triggerId) answers.set(ticketId, [...answers.get(ticketId) ?? [], triggerId]);
	}
	const human = (triggerId) => store.triggers.get(triggerId)?.human === true;
	const closed = (number) => pullEnd(store.get(`github-ended:${number}`));
	for (const row of store.db.prepare("SELECT id, value FROM ticket").all()) step(`ticket ${String(row.id)}`, () => {
		store.tickets.save(ticketOf(JSON.parse(String(row.value)), answers, human, closed));
	});
	for (const row of store.db.prepare("SELECT id, value FROM decision WHERE json_type(value, '$.mandate') = 'object'").all()) step(`decision ${String(row.id)}`, () => {
		const decision = JSON.parse(String(row.value));
		store.decisions.save({
			...decision,
			mandate: {
				...decision.mandate,
				basis: basisOf(decision.mandate.basis)
			}
		});
	});
	for (const thread of store.threads.list()) {
		const evaluating = thread.evaluating;
		if (evaluating) step(`thread ${thread.key}`, () => {
			store.threads.save({
				...thread,
				evaluating: {
					...evaluating,
					basis: basisOf(evaluating.basis)
				}
			});
		});
	}
	step("the Threads' activity times", () => {
		backfillThreadTimes(store);
	});
	for (const name of store.keys("task/")) {
		const renamed = `ticket/${name.slice(5)}`;
		if (store.get(renamed) === void 0) store.set(renamed, store.get(name));
		store.delete(name);
	}
	for (const name of DEAD_KEYS.flatMap((prefix) => prefix.endsWith(":") ? store.keys(prefix) : [prefix])) store.delete(name);
	store.db.exec(`DELETE FROM kv WHERE key LIKE 'feishu-read:%' OR key LIKE 'github-read:%' OR key LIKE 'feishu-source-link:%'
    OR key LIKE '%:prompt-preview/%'`);
	queueEarlierWork(store);
	store.db.exec(`UPDATE outbox SET value = json_set(value, '$.dropped.reason', CASE value ->> '$.dropped.reason'
    WHEN 'The conversation can no longer receive messages' THEN 'channelGone'
    WHEN 'The Source no longer listens to this conversation' THEN 'channelIgnored'
    ELSE value ->> '$.dropped.reason' END) WHERE value -> '$.dropped' IS NOT NULL`);
	step("the outbox", () => {
		outboxReceipts(store);
	});
	step("the current settings", () => {
		settingsAsVersions(store);
	});
	store.db.exec("DELETE FROM kv WHERE key LIKE 'prompt-version-read:%'");
	step("the Sources' records", () => {
		migrateSourceRecords(store);
	});
	step("the Inputs' bodies", () => {
		store.db.exec("DELETE FROM kv WHERE key LIKE 'ticket/%/input/%'");
	});
	step("the pull request ends", () => {
		dropPullEnds(store);
	});
	step("the dismissed problems", () => {
		moveDismissals(store);
	});
	for (const row of store.db.prepare("SELECT id, value FROM ticket").all()) step(`ticket ${String(row.id)}`, () => {
		store.tickets.save(withoutCopies(JSON.parse(String(row.value))));
	});
	step("the reasons", () => {
		reasonsAsCodes(store);
	});
	step("the Triggers' times", () => {
		triggerTimes(store);
	});
}
/**
* Normalize trigger and thread timestamps to fixed-width millisecond ISO strings so lexicographical text order matches
* chronological order (GitHub wrote whole seconds like `…:00Z`, which sorted after `…:00.001Z`).
*/
function triggerTimes(store) {
	for (const row of store.db.prepare("SELECT id, at FROM trigger").all()) {
		const at = isoTime(String(row.at));
		if (at !== row.at) store.db.prepare("UPDATE trigger SET at = ?, value = json_set(value, '$.at', ?) WHERE id = ?").run(at, at, String(row.id));
	}
	store.db.exec(`UPDATE trigger_thread SET at = (SELECT at FROM trigger WHERE trigger.id = trigger_thread.id)
    WHERE at <> (SELECT at FROM trigger WHERE trigger.id = trigger_thread.id)`);
	for (const thread of store.threads.list()) {
		const createdAt = isoTime(thread.createdAt), lastAt = thread.lastAt === void 0 ? void 0 : isoTime(thread.lastAt);
		if (createdAt === thread.createdAt && lastAt === thread.lastAt) continue;
		store.threads.save({
			...thread,
			createdAt,
			...lastAt === void 0 ? {} : { lastAt }
		});
	}
}
/**
* Obsolete KV keys and prefixes (ending in `:`) from removed `github-issue` eligibility checks, earlier migrations,
* and pre-schema-11 maintenance and subscription tracking.
*/
const DEAD_KEYS = [
	"github-object-state:",
	"github-issue-eligibility:",
	"github-auto-merge:",
	"source-labels-at:",
	"legacy-migrated-at",
	"thread-times-backfilled",
	"settings-before-9",
	"answer-ready:",
	"prompt-sections",
	"prompt-settings-text",
	"prompt-vocabulary",
	"subscriptions",
	"subscriptions-initialized",
	"subscription-seen:",
	"subscription-initialized:",
	"subscription-since:",
	"observation-since:",
	"task-threads:",
	"maintenance-recovery:",
	"maintenance-progress-report-recovery:",
	"maintenance-thread-followup:",
	"master-recovery:",
	"github-issue-candidates"
];
/**
* Move legacy main-session queues into the unified effect queue in order (relays to steer, then notices for removed
* subscriptions, saved prompts, and saved settings), then delete the legacy keys.
*/
function queueEarlierWork(store) {
	const queue = effectQueue(store);
	const { relays, unsubscribed, prompts, settings } = KV.queues;
	for (const { id, text } of store.get(relays) ?? []) queue("relay", id, { text });
	const prompt = store.get(prompts), saved = store.get(settings);
	const notices = [
		...(store.get(unsubscribed) ?? []).map((thread) => subscriptionNotice(thread)),
		...prompt == null ? [] : [promptsNotice(prompt)],
		...saved == null ? [] : [settingsNotice()]
	];
	for (const [name, value, summary] of notices) queue("notice", name, {
		value,
		summary
	});
	for (const name of [
		relays,
		unsubscribed,
		prompts,
		settings
	]) store.delete(name);
}
/**
* Insert effects directly into the database during migration before `Effects` exists, preserving prior failure counts;
* unlike `Effects.enqueue` (which upserts payload, increments generation, and resets attempts), `INSERT OR IGNORE` leaves an already-queued row for that `kind` and `key` untouched.
*/
function effectQueue(store) {
	let seq = Number(store.db.prepare("SELECT IFNULL(MAX(seq), 0) AS seq FROM effect").get()?.seq ?? 0);
	return (kind, key, payload, failed = {
		attempts: 0,
		error: ""
	}) => store.db.prepare("INSERT OR IGNORE INTO effect (kind, key, value, seq, attempts, error, due, since) VALUES (?, ?, ?, ?, ?, ?, ?, ?)").run(kind, key, JSON.stringify(payload), ++seq, failed.attempts, failed.error, Date.now(), (/* @__PURE__ */ new Date()).toISOString());
}
/**
* Convert outbox rows into status receipts (`pending`, `sent`, or `dropped`) and enqueue pending messages as `reply`
* effects in row order, moving their prior `attempts` and `error` onto the effect.
*/
function outboxReceipts(store) {
	if (!store.db.prepare("SELECT name FROM pragma_table_xinfo('outbox')").all().map((row) => String(row.name)).includes("sent")) return;
	const queue = effectQueue(store);
	for (const row of store.db.prepare("SELECT id, value, sent FROM outbox ORDER BY rowid").all()) {
		const { attempts, error, nextAttemptAt: _next, ...message } = JSON.parse(String(row.value));
		const status = message.dropped ? "dropped" : row.sent ? "sent" : "pending";
		store.db.prepare("UPDATE outbox SET value = ? WHERE id = ?").run(JSON.stringify({
			...message,
			status
		}), String(row.id));
		if (status === "pending") queue("reply", String(row.id), {}, {
			attempts: Number(attempts ?? 0) || 0,
			error: typeof error === "string" ? error : ""
		});
	}
	store.db.exec("DROP INDEX IF EXISTS outbox_waiting; ALTER TABLE outbox DROP COLUMN sent");
}
/**
* Ensure the latest settings revision snapshot holds the current settings (saving a new revision if missing or if earlier
* migration steps stripped a removed Source), then delete the standalone `settings` key.
*/
function settingsAsVersions(store) {
	const current = store.get("settings");
	if (current === void 0) return;
	const versions = new Versions(store, KV.settings.revision, KV.settings.version);
	const newest = Math.max(versions.revision(), ...versions.list().map((version) => version.revision));
	if (newest) store.set(KV.settings.revision, newest);
	if (JSON.stringify(versions.current()?.settings) !== JSON.stringify(current)) {
		const settings = SettingsSchema.parse(current);
		versions.save((revision) => ({
			revision,
			savedAt: (/* @__PURE__ */ new Date()).toISOString(),
			source: "internal",
			policyVersion: policyVersion(settings),
			policyChanged: false,
			notified: [],
			settings
		}));
	}
	store.delete("settings");
}
/** Settings save origin names recorded by versions before schema 11, mapped to current `SettingsOrigin` values. */
const ORIGINS = {
	web: "panel",
	"orchestrator-tool": "tool",
	"policy-sync": "sync",
	"member-sync": "sync"
};
/** Source kinds removed from dsh-superagent; the unified `github` Source now ingests Issues via notifications. */
const REMOVED_SOURCES = ["github-issue"];
/**
* Upgrade current and historical settings records to the schema 11 structure: strip removed source kinds from active
* settings while keeping them in historical revisions and mapping historical origin names.
*/
function migrateSettingsRecords(store) {
	const stored = store.get("settings");
	if (stored !== void 0) {
		const settings = SettingsSchema.parse(migrateSettings(stored));
		store.set("settings", {
			...settings,
			sources: Object.fromEntries(Object.entries(settings.sources).filter(([id]) => !REMOVED_SOURCES.includes(id)))
		});
	}
	for (const name of store.keys("settings-version:")) {
		const version = store.get(name);
		const settings = SettingsSchema.safeParse(migrateSettings(version.settings));
		store.set(name, {
			...version,
			source: ORIGINS[version.source] ?? version.source,
			...settings.success ? { settings: settings.data } : {}
		});
	}
}
/**
* Convert legacy flat settings (chat lists in Policy, top-level pause flag) or pre-schema-11 domain settings into current domain blocks:
* strips fields replaced by rule instructions and prompts (Executor reviewers and branch prefix, rule `visual` flag, `autoMergeLineLimit`, Source `authority`, GitHub `mergeCli`), extracts `paused` to the top level, and splits cross-source `members` into per-source `policy.sources` entries.
*/
function migrateSettings(value) {
	if (!isObject(value)) return value;
	if (!("members" in value || "allowedChats" in value || "admission" in value)) return withoutRemovedFields(value);
	const old = value;
	const chats = /* @__PURE__ */ new Map();
	for (const chatId of old.allowedChats ?? []) chats.set(chatId, "mentions");
	if (old.admission?.mode !== "off") for (const chatId of old.admission?.chats ?? []) chats.set(chatId, "all");
	return withoutRemovedFields({
		sources: {
			feishu: {
				enabled: true,
				config: {
					chats: [...chats].map(([chatId, listen]) => ({
						chatId,
						listen
					})),
					directMessages: old.allowDirectMessages ?? true
				}
			},
			github: {
				enabled: true,
				config: { pollSeconds: old.pollSeconds ?? 60 }
			}
		},
		policy: {
			...old.members ? { members: old.members } : {},
			...old.admission?.rules ? { rules: old.admission.rules } : {}
		},
		eval: {
			...old.admission?.mode ? { mode: old.admission.mode } : {},
			...old.admission?.timeoutSeconds ? { timeoutSeconds: old.admission.timeoutSeconds } : {},
			model: old.models?.orchestrator ?? null
		},
		executor: {
			model: old.models?.worker ?? null,
			...old.maxWorkers ? { maxWorkers: old.maxWorkers } : {},
			paused: old.paused ?? false
		}
	});
}
function withoutRemovedFields(value) {
	const { executor, policy, sources, ...rest } = value;
	const { reviewer: _reviewer, visualReviewer: _visualReviewer, branchPrefix: _branchPrefix, paused, ...kept } = executor ?? {};
	const { members, memberChat, autoMergeLineLimit: _limit, rules: storedRules, ...policyRest } = policy ?? {};
	const rules = Array.isArray(storedRules) ? storedRules.map((rule) => {
		if (!isObject(rule)) return rule;
		const { visual: _visual, ...fields } = rule;
		return fields;
	}) : storedRules;
	const people = Array.isArray(members) ? members : void 0;
	const parts = people ? {
		feishu: {
			allowed: people.filter((member) => member.feishuId).map((member) => ({
				id: member.feishuId,
				...member.name ? { name: member.name } : {}
			})),
			...memberChat ? { syncChat: memberChat } : {}
		},
		github: { allowed: people.filter((member) => member.github).map((member) => ({ id: member.github })) }
	} : void 0;
	const withoutMerge = (id, config) => {
		if (id !== "github" || !isObject(config)) return config;
		const { mergeCli: _mergeCli, ...fields } = config;
		return fields;
	};
	const instances = sources ? Object.fromEntries(Object.entries(sources).map(([id, instance]) => {
		const { authority: _authority, ...fields } = instance;
		return [id, "config" in fields ? {
			...fields,
			config: withoutMerge(id, fields.config)
		} : fields];
	})) : void 0;
	if (typeof kept.prepare === "string") kept.prepare = kept.prepare.replace(/\bDSH_(?:TAG|GO|FREELANCER)_/g, "DSH_SUPERAGENT_");
	return {
		...rest,
		...typeof paused === "boolean" ? { paused } : {},
		...executor ? { executor: kept } : {},
		...instances ? { sources: instances } : {},
		...policy ? { policy: {
			...policyRest,
			...rules ? { rules } : {},
			...parts ? { sources: parts } : {}
		} } : {}
	};
}
/** Prompt configuration shape saved before team sections existed, when all sections (including fixed ones) were editable. */
const LegacyPromptConfigSchema = z.object({
	shared: z.string(),
	orchestrator: z.string(),
	worker: z.string(),
	guides: z.record(z.string(), z.string())
});
/** Guide names from legacy prompt configurations that are now fixed built-in prompt sections or skills. */
const LEGACY_FIXED = /* @__PURE__ */ new Set([
	"cli",
	"subscriptions",
	"replies",
	"reviews",
	"dispatch",
	"work",
	"feishu",
	"github"
]);
/** Tool names used in saved prompts before the domain vocabulary rename, paired with what replaces them now. */
const RENAMED_TOOLS = [
	["orchestrator_subscription_remove", "orchestrator_thread_unsubscribe"],
	["orchestrator_subscriptions", "orchestrator_threads"],
	["orchestrator_create_task", "orchestrator_route (kind accept)"],
	["orchestrator_send_task", "orchestrator_route (kind attach)"],
	["orchestrator_reopen_task", "orchestrator_route (kind attach)"],
	["orchestrator_ticket_reopen", "orchestrator_route (kind attach)"],
	["orchestrator_stop_task", "orchestrator_route (kind stop)"],
	["orchestrator_ignore_event", "orchestrator_route (kind ignore)"],
	["orchestrator_request_status", "orchestrator_ticket_request_status"],
	["orchestrator_inspect_task", "orchestrator_ticket_inspect"],
	["orchestrator_observations", "orchestrator_decisions"],
	["orchestrator_event_replay", "orchestrator_trigger_requeue"],
	["orchestrator_tasks", "orchestrator_tickets"],
	["orchestrator_assess", "orchestrator_eval"],
	["admission_read", "orchestrator_eval_read"],
	["admission_decide", "orchestrator_eval_decide"]
];
/** Read-only tools replaced by `orchestrator_read <resource>`, mapped to their resource paths. */
const READ_TOOLS = {
	orchestrator_tickets: "tickets",
	orchestrator_threads: "threads",
	orchestrator_decisions: "decisions",
	orchestrator_settings_read: "settings",
	orchestrator_prompts_read: "prompts",
	orchestrator_models: "models",
	orchestrator_ticket_inspect: "ticket/<id>"
};
/**
* Rewrites skill and variable prefixes from the project's earlier names (`dsh-tag`, `dsh-go`, `dsh-freelancer`), replaces retired
* read tools with `orchestrator_read`, and the four routing tools with `orchestrator_route` and their kind.
*/
const currentNames = (value) => value.replace(/\bdsh-(?:tag|go|freelancer)-/g, "dsh-superagent-").replace(/\bDSH_(?:TAG|GO|FREELANCER)_/g, "DSH_SUPERAGENT_").replace(/\borchestrator_(?:tickets|threads|decisions|settings_read|prompts_read|models|ticket_inspect)\b/g, (name) => `orchestrator_read ${READ_TOOLS[name]}`).replace(/\borchestrator_(?:ticket_(accept|attach|stop)|trigger_(ignore))\b/g, (_name, ticket, trigger) => `orchestrator_route (kind ${ticket ?? trigger ?? ""})`);
/** Rewrites a legacy skill body to current tool, argument, resource, section, skill, and variable names. */
function legacyText(value) {
	let result = value;
	for (const [from, to] of RENAMED_TOOLS) result = result.replace(new RegExp(`\\b${from}\\b`, "g"), to);
	return currentNames(result.replaceAll("reply_to_event_id", "reply_to_trigger_id").replace(/\bevent_id\b/g, "trigger_id").replace(/\btask_id\b/g, "ticket_id").replaceAll("related_tasks", "related_tickets").replace(/(?<![\w/-])event\//g, "trigger/").replace(/(?<![\w/-])task\//g, "ticket/").replaceAll("<event-id>", "<trigger-id>").replace(/\bguide\/([a-z][a-z0-9-]*)\b/g, (_match, name) => LEGACY_FIXED.has(name) ? `the ${name} section` : `skill dsh-superagent-${name}`));
}
/**
* Upgrade a stored prompt configuration to current sections, tool names, and skill references; legacy configurations take
* built-in team sections, keep custom guides as skills, and carry any auto-merge line threshold into `delivery`.
*/
function normalize(config) {
	const legacy = LegacyPromptConfigSchema.safeParse(config);
	const limit = legacy.success ? /fewer than (\d+) lines \(additions plus deletions\)/.exec(legacy.data.guides.work ?? "")?.[1] : void 0;
	const current = legacy.success ? {
		...teamDefaults,
		delivery: limit ? teamDefaults.delivery.replace(autoMergeThreshold(200), autoMergeThreshold(Number(limit))) : teamDefaults.delivery,
		skills: Object.fromEntries(Object.entries(legacy.data.guides).filter(([name]) => !LEGACY_FIXED.has(name)).map(([name, body]) => [name, legacyText(body)]))
	} : PromptConfigSchema.parse(config);
	return {
		communication: currentNames(current.communication),
		scope: currentNames(current.scope),
		delivery: currentNames(current.delivery),
		skills: Object.fromEntries(Object.entries(current.skills).map(([name, body]) => [name, currentNames(body)]))
	};
}
/**
* Normalize stored prompt revisions to current sections and names (recording original configs under `legacy` when saved
* before team sections existed or unparseable) and synthesize a new revision for removed settings fields (auto-merge
* threshold and cross-source member identities) unless an earlier migration already created it.
*/
function migratePrompts(store) {
	const versions = store.keys("prompt-version:").map((name) => store.get(name)).sort((a, b) => a.revision - b.revision);
	let readable = {
		...teamDefaults,
		skills: {}
	};
	for (const version of versions) {
		const legacy = LegacyPromptConfigSchema.safeParse(version.config).success;
		let config;
		try {
			config = normalize(version.config);
		} catch {
			config = readable;
		}
		const kept = legacy || config === readable ? { legacy: version.legacy ?? { config: version.config } } : {};
		store.set(`prompt-version:${version.revision}`, {
			...version,
			config,
			...kept
		});
		readable = config;
	}
	if (store.get("prompt-settings-text") === 1) return;
	const before = store.get("settings-before-9");
	const policy = isObject(before) ? before.policy : void 0;
	const limit = typeof policy?.autoMergeLineLimit === "number" ? policy.autoMergeLineLimit : 200;
	const mapped = (Array.isArray(policy?.members) ? policy.members : []).filter((person) => person.feishuId && person.github);
	const revision = store.get("prompt-revision");
	const current = revision === void 0 ? void 0 : store.get(`prompt-version:${revision}`);
	const config = current?.config ?? {
		...teamDefaults,
		skills: {}
	};
	const delivery = config.delivery.includes(autoMergeThreshold(200)) ? config.delivery.replace(autoMergeThreshold(200), autoMergeThreshold(limit)) : limit === 200 ? config.delivery : `${config.delivery}\nEnable auto-merge only on a PR that changes fewer than ${limit} lines (additions plus deletions).`;
	const identities = mapped.length && !config.skills.identities ? { identities: ["The same colleague may use a different account on each Source. When you mention, assign or request a review from someone you met on another Source, use their account on this one:", ...mapped.map((person) => `- ${person.name ?? person.feishuId} (Feishu ${person.feishuId}) is @${person.github} on GitHub`)].join("\n") } : {};
	const next = {
		...config,
		delivery,
		skills: {
			...config.skills,
			...identities
		}
	};
	if (JSON.stringify(next) === JSON.stringify(config)) return;
	const previous = current?.revision ?? 0;
	if (!current) store.set("prompt-version:0", {
		revision: 0,
		previousRevision: null,
		savedAt: "",
		source: "defaults",
		config
	});
	store.set(`prompt-version:${previous + 1}`, {
		revision: previous + 1,
		previousRevision: previous,
		savedAt: (/* @__PURE__ */ new Date()).toISOString(),
		source: "settings-migration",
		config: next
	});
	store.set("prompt-revision", previous + 1);
}
const CELLS = [
	"listedUnaddressed",
	"unlistedAddressed",
	"unlistedUnaddressed"
];
/**
* Upgrade a legacy mandate basis object to the current tagged union shape.
* Current bases recorded `source` and `scope`; older ones recorded a Feishu chat directly (`chatId`) or schema 6's `legacyAuthority`.
* A basis with neither an admission table cell nor `followup` came from a listed sender (`addressed` when it recorded `addressed`, `sender`, and `source`, else `listed`), which holds while the sender remains listed.
*/
function basisOf(stored) {
	const old = isObject(stored) ? stored : {};
	if (typeof old.via === "string") return old;
	const chat = text(old.chatId) ? {
		source: "feishu",
		scope: {
			chatId: old.chatId,
			direct: old.direct === true
		}
	} : {};
	const received = text(old.source) ? {
		source: old.source,
		...isObject(old.scope) ? { scope: old.scope } : {},
		...text(old.row) ? { row: old.row } : {}
	} : chat;
	const sender = text(old.sender) ?? text(old.member);
	const common = {
		...received,
		...sender ? { sender } : {},
		...Array.isArray(old.rules) ? { rules: old.rules } : {}
	};
	const addressed = old.addressed === "mention" || old.addressed === "direct" ? old.addressed : old.direct === true ? "direct" : old.mention === true ? "mention" : void 0;
	const mode = text(old.mode);
	const authority = text(old.legacyAuthority) ? { authority: old.legacyAuthority } : {};
	if (old.followup === true) return {
		via: "followup",
		...common,
		...authority
	};
	if (CELLS.includes(String(old.admission))) return {
		via: "admission",
		...common,
		cell: old.admission,
		...addressed ? { addressed } : {},
		...old.observation === true ? { observation: { mode: mode ?? "auto" } } : {}
	};
	if (addressed && sender && text(old.source)) return {
		via: "addressed",
		...common,
		addressed
	};
	return {
		via: "listed",
		...common,
		...addressed ? { addressed } : {},
		...old.observation === true ? { observation: mode ? { mode } : {} } : {},
		...authority
	};
}
/**
* Upgrade a schema 10 ticket record to schema 11: extracts `origin`, `execution`, `delivery`, and followed PR threads
* (`follows`) from `meta` and GitHub opener channels, merges reported `answers`, marks human trigger inputs (`human: true`),
* and converts pending `reopen` inputs into `text` inputs for the worker.
*/
function ticketOf(old, answers = /* @__PURE__ */ new Map(), human = () => false, closed = () => void 0) {
	const { meta: storedMeta, ...rest } = old;
	const ticket = rest;
	const meta = storedMeta ?? {};
	const triggerId = text(meta.sourceTriggerId) ?? "";
	const triggerIds = Array.isArray(meta.triggerIds) ? meta.triggerIds : triggerId ? [triggerId] : [];
	const directory = text(meta.workspace);
	const execution = directory ? {
		name: text(meta.name) ?? basename(directory),
		directory,
		assignment: text(meta.assignment) ?? text(meta.legacyPrompt) ?? ""
	} : void 0;
	const inputs = ticket.inputs.map((input) => input.kind === "trigger" ? {
		...input,
		...human(input.triggerId) ? { human: true } : {}
	} : input.kind !== "reopen" || !ticket.undelivered.includes(input.id) ? input : {
		id: input.id,
		kind: "text",
		at: input.at,
		text: JSON.stringify({
			resumed: true,
			decision_id: input.decisionId,
			read: `ticket/${ticket.id}/assignment`,
			note: "This ticket ended earlier and a follow-up resumed it under the same mandate. Inspect the worktree, git history and PR state before continuing; do not repeat completed external operations."
		})
	});
	const reported = [.../* @__PURE__ */ new Set([...ticket.answers ?? [], ...answers.get(ticket.id) ?? []])];
	const ended = ticket.ended && {
		...ticket.ended,
		outcome: ticket.ended.outcome ?? outcomeOf(ticket.ended)
	};
	const mandate = {
		...ticket.mandate,
		basis: basisOf(ticket.mandate.basis)
	};
	const delivery = ticket.delivery ?? (text(meta.deliveryError) ? {
		error: meta.deliveryError,
		at: ticket.updatedAt
	} : void 0);
	const kept = execution ?? ticket.execution;
	const follows = ticket.follows ?? followsOf(meta, ticket.channels, closed);
	return {
		...ticket,
		inputs,
		...ended ? { ended } : {},
		mandate,
		origin: ticket.origin ?? {
			triggerId,
			triggerIds
		},
		...ended?.by === "human" ? { undelivered: [] } : {},
		...kept ? { execution: kept } : {},
		...delivery ? { delivery } : {},
		channels: ticket.channels.filter((channel) => !opener(channel)),
		...follows.length ? { follows } : {},
		...reported.length ? { answers: reported } : {}
	};
}
/** Schema 10 recorded a PR opened by the ticket as a GitHub Channel without a comment URL (`address.url`). */
const opener = (channel) => channel.source === "github" && !channel.address.url && !!Number(channel.address.number);
/**
* Reconstruct followed PR threads from legacy ticket metadata (`meta.prNumber` last, after PRs opened via GitHub opener
* channels), marking opened PRs `own: true` and attaching recorded close outcomes.
*/
function followsOf(meta, channels, closed) {
	const opened = channels.filter(opener).map((channel) => Number(channel.address.number));
	const bound = typeof meta.prNumber === "number" ? [meta.prNumber] : [];
	return [.../* @__PURE__ */ new Set([...opened.filter((number) => !bound.includes(number)), ...bound])].map((number) => {
		const end = closed(number);
		return {
			thread: `github:${number}`,
			own: opened.includes(number),
			...end ? { closed: end } : {}
		};
	});
}
/** Parse a schema 10 `github-ended:<number>` record into a followed PR's `closed` state when valid. */
function pullEnd(stored) {
	if (!isObject(stored) || typeof stored.at !== "string" || stored.reason !== "merged" && stored.reason !== "closed") return void 0;
	return {
		at: stored.at,
		outcome: stored.reason
	};
}
/**
* Strip redundant fields stored twice on legacy tickets: removes `state` (derived from `ended`), moves top-level `summary`
* onto the latest Assignment as a `progress` report when no Assignment has a report, and removes `execution.session` and
* per-Assignment `ticketId` and `ref` (derived from `ticket.id`).
*/
function withoutCopies(old) {
	const { state, summary, ...ticket } = old;
	const assignments = ticket.assignments.map((item) => {
		const { ticketId: _ticket, ref: _ref, ...rest } = item;
		return rest;
	});
	const latest = assignments.at(-1);
	if (latest && typeof summary === "string" && summary && !assignments.some((item) => item.report)) latest.report = {
		state: "progress",
		summary,
		at: ticket.updatedAt
	};
	const { session: _session, ...execution } = ticket.execution ?? {};
	const closed = {
		at: ticket.updatedAt,
		by: "executor",
		reason: "closed",
		outcome: "closed"
	};
	const ended = state === "open" ? void 0 : ticket.ended ?? (state === "ended" ? closed : void 0);
	const { ended: _ended, ...rest } = ticket;
	const { reason, ...end } = ended ?? {};
	const once = ended && {
		...end,
		...reason && reason !== ended.outcome ? { reason } : {}
	};
	for (const item of assignments) if (ended && item.endedReason === reason && item.endedAt === ended.at) delete item.endedReason;
	return {
		...rest,
		...once ? { ended: once } : {},
		assignments,
		...ticket.execution ? { execution } : {}
	};
}
/** Fixed English reason sentences written by versions before schema 11, mapped to their current reason codes. */
const SENTENCES = {
	"Assessment timed out": "timeout",
	"Assessment interrupted or timed out": "timeout",
	"Assessment interrupted, timed out or ended without a decision": "timeout",
	"Policy changed during assessment": "policyChanged",
	"Access or rule version changed": "policyChanged",
	"No admissible trigger": "noAdmissible",
	"Explicit member request routed by the orchestrator": "explicitRouted",
	"Explicit request from an allowed sender routed by the orchestrator": "explicitRouted",
	"Imported from the pre-domain-model task record": "legacyImport",
	"host restarted": "hostRestarted",
	"Human asked to stop": "humanStop",
	"Forwarded to the existing topic worker": "forwarded",
	"Sender is not an authorized human member": "senderNotMember",
	"Retried by a person": "retried",
	"Stop target is unknown or already ended": "stopUnknown",
	"Stop requires an explicit instruction from an authorized member": "stopNotExplicit",
	"Implementation intent or target direction is not established, or a product/design decision is still required": "directionUnsettled",
	"No enabled admission rule matched": "noRuleMatched"
};
/** Parse a legacy reason string into a `Reason` when it matches a fixed sentence in `SENTENCES`, a parameterized sentence (`routed`, `startedTicket`, `observed`), or a snake_case gate/source code. */
function knownReason(text) {
	if (SENTENCES[text]) return { code: SENTENCES[text] };
	const routed = /^Routed to ticket (\S+)$/.exec(text) ?? /^Already accepted as ticket (\S+)$/.exec(text);
	if (routed) return {
		code: text.startsWith("Routed") ? "routed" : "startedTicket",
		values: { ticket: routed[1] }
	};
	const observed = /^Observe mode: would accept \((.*)\)$/s.exec(text);
	if (observed) return {
		code: "observed",
		values: { text: observed[1] }
	};
	return /^[a-z]+(?:_[a-z]+)+$/.test(text) ? { code: text } : void 0;
}
/**
* Parse a stored Decision reason into structured `Reason` codes: splits `<triggerId>: <reason>` batches joined by `; `
* into per-Trigger reasons, maps known sentences/codes via `knownReason`, and wraps any other free-form assessor or human
* text with `said`.
*/
function reasonsOf(stored) {
	if (Array.isArray(stored)) return stored;
	const text = typeof stored === "string" ? stored : "";
	const parts = text.split("; ").map((part) => /^([^:\s]+): (.+)$/s.exec(part));
	if (parts.every((match) => match && knownReason(match[2]))) return parts.map((match) => ({
		...knownReason(match[2]),
		triggerId: match[1]
	}));
	return [knownReason(text) ?? said(text)];
}
/** Convert stored decision, disposition, and assignment end reasons from free-form strings to reason codes. */
function reasonsAsCodes(store) {
	for (const row of store.db.prepare("SELECT value FROM decision").all()) {
		const decision = JSON.parse(String(row.value));
		store.decisions.save({
			...decision,
			reason: reasonsOf(decision.reason)
		});
	}
	for (const row of store.db.prepare("SELECT id, value FROM disposition WHERE json_type(value, '$.filtered') = 'text'").all()) {
		const disposition = JSON.parse(String(row.value));
		store.triggers.saveDisposition(String(row.id), {
			...disposition,
			filtered: { code: SENTENCES[disposition.filtered] ?? disposition.filtered }
		});
	}
	for (const ticket of store.tickets.list()) {
		const ended = (reason) => reason && SENTENCES[reason] === "retried" ? "retried" : reason && SENTENCES[reason] === "hostRestarted" ? "hostRestarted" : reason;
		if (!ticket.assignments.some((item) => item.endedReason !== ended(item.endedReason))) continue;
		const assignments = ticket.assignments.map((item) => item.endedReason ? {
			...item,
			endedReason: ended(item.endedReason)
		} : item);
		store.tickets.save({
			...ticket,
			assignments
		});
	}
}
/** Move `problem-dismissed:<decisionId>` KV flags onto their corresponding `Decision.dismissed` fields and delete the KV keys. */
function moveDismissals(store) {
	for (const name of store.keys("problem-dismissed:")) {
		const decision = store.decisions.get(name.slice(18));
		if (decision && store.get(name) === true) store.decisions.save({
			...decision,
			dismissed: true
		});
		store.delete(name);
	}
}
/** Delete `github-ended:<number>` KV records after their close outcomes have been copied onto `Ticket.follows`. */
function dropPullEnds(store) {
	for (const name of store.keys("github-ended:")) store.delete(name);
}
/** Infer a ticket's `ended.outcome` when predating recorded outcomes (`stopped` for human stops, else matching `reason` or defaulting to `closed`). */
function outcomeOf(ended) {
	if (ended.by === "human") return "stopped";
	return [
		"completed",
		"merged",
		"closed",
		"dropped"
	].find((outcome) => outcome === ended.reason) ?? "closed";
}
/** Backfill thread creation and activity timestamps from their earliest and latest triggers. */
function backfillThreadTimes(store) {
	if (store.get("thread-times-backfilled")) return;
	for (const thread of store.threads.list()) {
		const first = store.read.firstTrigger(thread.key), last = store.read.threadTriggers(thread.key, 1)[0];
		if (!first || !last) continue;
		const times = {
			createdAt: first.at < thread.createdAt ? first.at : thread.createdAt,
			lastAt: !thread.lastAt || last.at > thread.lastAt ? last.at : thread.lastAt
		};
		store.threads.save({
			...thread,
			...times
		});
	}
}
/** Upgrade stored source state (Feishu topics, direct-chat flags, thread links, GitHub cursors, and pending assessments) to schema 11. */
function migrateSourceRecords(store) {
	feishuTopics(store);
	feishuDirectAddresses(store);
	feishuThreadLinks(store);
	issueSourceRecords(store);
	githubCursors(store);
	assessmentTriggers(store);
}
/** Convert legacy Feishu topic ID arrays into maps keyed by topic ID with the chat's last recovery timestamp. */
function feishuTopics(store) {
	for (const name of store.keys(KV.feishu.topics)) {
		const topics = store.get(name);
		if (!Array.isArray(topics)) continue;
		const seen = store.get(KV.feishu.history(name.slice(KV.feishu.topics.prefix.length))) ?? (/* @__PURE__ */ new Date()).toISOString();
		store.set(name, Object.fromEntries(topics.map((id) => [String(id), seen])));
	}
}
/**
* Backfill `direct: 'true'` onto Feishu channel addresses from `KV.feishu.chats`, because Feishu `oc_` chat IDs do not
* distinguish direct messages from group chats on their own.
*/
function feishuDirectAddresses(store) {
	const chats = store.get(KV.feishu.chats) ?? {};
	const direct = (channel) => isObject(channel) && channel.source === "feishu" && isObject(channel.address) && chats[String(channel.address.chatId)] === true && channel.address.direct === void 0;
	const marked = (channel) => direct(channel) ? {
		...channel,
		address: {
			...channel.address,
			direct: "true"
		}
	} : channel;
	for (const table of ["trigger", "outbox"]) for (const row of store.db.prepare(`SELECT id, value FROM ${table} WHERE value ->> '$.channel.source' = 'feishu'`).all()) {
		const value = JSON.parse(String(row.value));
		if (!direct(value.channel)) continue;
		const rewritten = JSON.stringify({
			...value,
			channel: marked(value.channel)
		});
		store.db.prepare(`UPDATE ${table} SET value = ? WHERE id = ?`).run(rewritten, row.id);
	}
	for (const row of store.db.prepare("SELECT id, value FROM ticket").all()) {
		const ticket = JSON.parse(String(row.value));
		if (ticket.channels.some(direct)) store.tickets.save({
			...ticket,
			channels: ticket.channels.map(marked)
		});
	}
}
/** Backfill chat URLs onto Feishu threads created before threads stored their own URL, inferring the brand from existing trigger URLs. */
function feishuThreadLinks(store) {
	const lark = store.db.prepare(`SELECT 1 FROM trigger WHERE value ->> '$.source' = 'feishu'
    AND value ->> '$.url' LIKE '%larksuite.com%' LIMIT 1`).get();
	for (const thread of store.threads.list()) {
		if (thread.ref.source !== "feishu" || typeof thread.meta.url === "string" || store.read.firstTrigger(thread.key)?.url) continue;
		const chatId = thread.ref.id.split(":")[0];
		if (chatId) store.threads.save({
			...thread,
			meta: {
				...thread.meta,
				url: feishuChatLink(lark ? "lark" : "feishu", chatId)
			}
		});
	}
}
/**
* Reassign triggers from the removed `github-issue` source to `github`, schedule a retry from the earliest waiting message
* within `POLL_HORIZON_MS` on each issue that had pending messages, and delete the obsolete `github-issue` KV keys.
*/
function issueSourceRecords(store) {
	store.db.exec(`UPDATE trigger SET value = json_set(value, '$.source', 'github') WHERE value ->> '$.source' = 'github-issue'`);
	const pending = store.get("github-issue-pending") ?? {};
	const retries = { ...store.get(KV.github.retries) };
	for (const { number, at } of Object.values(pending)) {
		if (!(Date.now() - Date.parse(at) < 12096e5)) continue;
		const retry = retries[number];
		retries[number] = {
			...retry,
			since: retry && retry.since < at ? retry.since : at,
			pr: retry?.pr ?? false
		};
	}
	if (Object.keys(retries).length) store.set(KV.github.retries, retries);
	const kept = [
		"github-issue-pending",
		"github-issues-since",
		"github-issues-started-at",
		...store.keys("github-issue-eligibility:")
	];
	for (const name of kept) store.delete(name);
}
/** Consolidate per-issue/PR notification and thread subscription cursors into a single cursor holding the later timestamp. */
function githubCursors(store) {
	for (const name of [...store.keys("github-thread:"), ...store.keys("thread-since:github:")]) {
		const at = store.get(name);
		const cursor = KV.github.cursor(Number(name.slice(name.lastIndexOf(":") + 1)));
		const current = store.get(cursor);
		if (at && !(current && current >= at)) store.set(cursor, at);
		store.delete(name);
	}
}
/** Attach trigger IDs to pending assessment effects and re-enqueue undelivered active evaluations so their timeout deadlines start. */
function assessmentTriggers(store) {
	const triggers = new Map(store.threads.active().flatMap((thread) => thread.evaluating ? [[thread.evaluating.id, thread.evaluating.triggerIds[0]]] : []));
	for (const row of store.db.prepare("SELECT key FROM effect WHERE kind = 'assessment' AND value ->> '$.triggerId' IS NULL").all()) {
		const triggerId = triggers.get(String(row.key));
		const named = JSON.stringify({ triggerId });
		if (triggerId) store.db.prepare("UPDATE effect SET value = ? WHERE kind = 'assessment' AND key = ?").run(named, row.key);
		else store.db.prepare("DELETE FROM effect WHERE kind = 'assessment' AND key = ?").run(row.key);
	}
	let seq = Number(store.db.prepare("SELECT COALESCE(MAX(seq), 0) AS seq FROM effect").get()?.seq ?? 0);
	for (const thread of store.threads.active()) {
		const evaluation = thread.evaluating;
		if (!evaluation || evaluation.delivered || !evaluation.triggerIds[0]) continue;
		store.db.prepare(`INSERT INTO effect (kind, key, value, seq, due, since) VALUES ('assessment', ?, ?, ?, ?, ?) ON CONFLICT(kind, key) DO NOTHING`).run(evaluation.id, JSON.stringify({ triggerId: evaluation.triggerIds[0] }), ++seq, Date.now(), (/* @__PURE__ */ new Date()).toISOString());
	}
}
//#endregion
//#region src/app/store-read.ts
function storeReads(db) {
	const values = (sql, ...parameters) => db.prepare(sql).all(...parameters).map((row) => JSON.parse(String(row.value)));
	return {
		/** Newest first by arrival (`rowid`) order rather than trigger timestamp. */
		recentTriggers: (offset = 0, limit = 50) => db.prepare("SELECT value FROM trigger ORDER BY rowid DESC LIMIT ? OFFSET ?").all(limit, offset).map((row) => JSON.parse(String(row.value))),
		/** Per-source trigger counts since `since`, plus the latest arrival timestamp across all time. */
		triggerStats: (since) => {
			const result = {};
			for (const row of db.prepare("SELECT json_extract(t.value, '$.source') AS source, MAX(t.at) AS last, SUM(t.at >= ?) AS received, SUM(t.at >= ? AND json_extract(d.value, '$.filtered') IS NOT NULL) AS filtered FROM trigger t LEFT JOIN disposition d ON d.id = t.id GROUP BY source").all(since, since)) result[String(row.source)] = {
				received: Number(row.received ?? 0),
				filtered: Number(row.filtered ?? 0),
				lastAt: String(row.last ?? "")
			};
			return result;
		},
		/**
		* Counts triggers arriving at or after `since` that passed source filtering and reached a decision,
		* and how many accept/reopen decisions those same arrivals produced.
		*/
		flow: (since) => {
			const judged = db.prepare(`SELECT COUNT(DISTINCT t.id) AS n FROM decision d, json_each(json_extract(d.value, '$.triggerIds')) j JOIN trigger t ON t.id = j.value WHERE t.at >= ? AND NOT EXISTS (SELECT 1 FROM disposition s WHERE s.id = t.id AND json_extract(s.value, '\$.filtered') IS NOT NULL)`).get(since);
			const accepted = db.prepare(`SELECT COUNT(DISTINCT d.id) AS n FROM decision d, json_each(json_extract(d.value, '$.triggerIds')) j JOIN trigger t ON t.id = j.value WHERE json_extract(d.value, '$.kind') IN ('accept', 'reopen') AND t.at >= ?`).get(since);
			return {
				judged: Number(judged?.n ?? 0),
				accepted: Number(accepted?.n ?? 0)
			};
		},
		triggers: (options, offset = 0, limit = 50) => {
			const where = [...options.source ? ["json_extract(t.value, '$.source') = ?"] : [], ...options.filtered ? ["json_extract(d.value, '$.filtered') IS NOT NULL"] : []];
			const rows = db.prepare(`SELECT t.value FROM trigger t LEFT JOIN disposition d ON d.id = t.id ${where.length ? `WHERE ${where.join(" AND ")}` : ""} ORDER BY t.at DESC LIMIT ? OFFSET ?`).all(...options.source ? [options.source] : [], limit + 1, offset);
			return {
				items: rows.slice(0, limit).map((row) => JSON.parse(String(row.value))),
				more: rows.length > limit
			};
		},
		/** Latest `limit` triggers on a thread returned oldest-first, optionally bounded before (or through) `before`. */
		threadTriggers: (threadKeyValue, limit = 50, before, through = false) => {
			return values(`SELECT t.value FROM trigger_thread x JOIN trigger t ON t.id = x.id WHERE x.thread = ? ${before ? `AND (x.at, x.id) ${through ? "<=" : "<"} (?, ?)` : ""}
      ORDER BY x.at DESC, x.id DESC LIMIT ?`, threadKeyValue, ...before ? [before.at, before.id] : [], limit).reverse();
		},
		threadPage: (threadKeyValue, offset, limit) => values(`SELECT t.value FROM trigger_thread x
    JOIN trigger t ON t.id = x.id WHERE x.thread = ? ORDER BY x.at DESC, t.rowid DESC LIMIT ? OFFSET ?`, threadKeyValue, limit, offset),
		/** Nearest non-CI triggers on a thread immediately before and after `(at, id)`. */
		neighbours: (threadKeyValue, at, id) => {
			const nearest = (side) => values(`SELECT t.value FROM trigger_thread x JOIN trigger t ON t.id = x.id
      WHERE x.thread = ? AND (x.at, x.id) ${side} (?, ?) AND json_extract(t.value, '$.meta.ci') IS NULL
      ORDER BY x.at ${side === "<" ? "DESC" : "ASC"}, x.id ${side === "<" ? "DESC" : "ASC"} LIMIT 1`, threadKeyValue, at, id)[0];
			const before = nearest("<"), after = nearest(">");
			return {
				...before ? { before } : {},
				...after ? { after } : {}
			};
		},
		/** Oldest trigger on a thread, used to title the thread in listings. */
		firstTrigger: (threadKeyValue, humanOnly = false) => {
			const row = db.prepare(`SELECT t.value FROM trigger_thread x JOIN trigger t ON t.id = x.id WHERE x.thread = ? ${humanOnly ? "AND x.human = 1" : ""} ORDER BY x.at ASC, t.rowid ASC LIMIT 1`).get(threadKeyValue);
			return row ? JSON.parse(String(row.value)) : void 0;
		},
		search: (query, limit = 20) => {
			const pattern = `%${query.replace(/[\\%_]/g, (match) => `\\${match}`)}%`;
			return db.prepare("SELECT value FROM trigger WHERE id = ? OR json_extract(value, '$.url') LIKE ? ESCAPE '\\' OR json_extract(value, '$.meta.messageId') = ? OR json_extract(value, '$.text') LIKE ? ESCAPE '\\' ORDER BY at DESC LIMIT ?").all(query, `${query.replace(/[\\%_]/g, (match) => `\\${match}`)}%`, query, pattern, limit).map((row) => JSON.parse(String(row.value)));
		},
		recentDecisions: (offset = 0, limit = 50) => db.prepare("SELECT value FROM decision ORDER BY rowid DESC LIMIT ? OFFSET ?").all(limit, offset).map((row) => JSON.parse(String(row.value))),
		/** Decisions matching `kinds` whose triggers arrived at or after `since`, aligned with `flow` window counts. */
		decisions: (options, offset, limit) => {
			const where = [...options.kinds.length ? [`json_extract(d.value, '$.kind') IN (${options.kinds.map(() => "?").join(",")})`] : [], ...options.since ? ["EXISTS (SELECT 1 FROM json_each(json_extract(d.value, '$.triggerIds')) j JOIN trigger t ON t.id = j.value WHERE t.at >= ?)"] : []];
			const rows = db.prepare(`SELECT d.value FROM decision d ${where.length ? `WHERE ${where.join(" AND ")}` : ""} ORDER BY d.rowid DESC LIMIT ? OFFSET ?`).all(...options.kinds, ...options.since ? [options.since] : [], limit + 1, offset);
			return {
				items: rows.slice(0, limit).map((row) => JSON.parse(String(row.value))),
				more: rows.length > limit
			};
		},
		/** Newest decisions of the given kinds, for surfaces that must surface rare outcomes among many ignores. */
		decisionsOfKinds: (kinds, limit = 30) => db.prepare(`SELECT value FROM decision WHERE json_extract(value, '$.kind') IN (${kinds.map(() => "?").join(",")}) ORDER BY rowid DESC LIMIT ?`).all(...kinds, limit).map((row) => JSON.parse(String(row.value))),
		/** Messages whose `reply` effect failed, with consecutive failure count and last error, oldest first. */
		failingReplies: () => db.prepare(`SELECT o.value, e.attempts, e.error FROM effect e
    JOIN outbox o ON o.id = e.key WHERE e.kind = 'reply' AND e.attempts > 0 ORDER BY e.seq`).all().map((row) => ({
			...JSON.parse(String(row.value)),
			attempts: Number(row.attempts),
			error: String(row.error)
		})),
		droppedReplies: (limit = 20) => values("SELECT value FROM outbox WHERE dropped IS NOT NULL ORDER BY dropped DESC LIMIT ?", limit),
		droppedSince: (since) => Number(db.prepare("SELECT COUNT(*) AS n FROM outbox WHERE dropped >= ?").get(since)?.n ?? 0),
		subscribedThreads: (source) => source ? values("SELECT value FROM thread WHERE subscribed = ? ORDER BY rowid", source) : values("SELECT value FROM thread INDEXED BY thread_subscribed WHERE subscribed IS NOT NULL ORDER BY rowid")
	};
}
//#endregion
//#region src/app/store.ts
/** SQLite persistence for domain aggregates, key-value state, settings history, and the channel outbox. */
/**
* Generated columns and partial indexes defining active working sets so passes scan only active rows.
* Older databases missing a column get it added on open and populated by SQLite from stored JSON rows.
*/
const SETS = {
	ticket: {
		open: "INTEGER AS (CASE WHEN value -> '$.ended' IS NULL THEN 1 END)",
		active: `INTEGER AS (CASE WHEN json_array_length(value, '$.undelivered') > 0
      OR value ->> '$.assignments[#-1].state' IN ('pending', 'running') THEN 1 END)`
	},
	thread: {
		active: "INTEGER AS (CASE WHEN json_array_length(value, '$.pending') > 0 OR value -> '$.evaluating' IS NOT NULL THEN 1 END)",
		subscribed: "TEXT AS (CASE WHEN json_array_length(value, '$.subscriptions') > 0 THEN value ->> '$.ref.source' END)"
	},
	outbox: {
		dropped: "TEXT AS (value ->> '$.dropped.at')",
		pending: `TEXT AS (CASE WHEN value ->> '$.status' = 'pending'
    AND value ->> '$.ticketId' IS NOT NULL THEN (value ->> '$.ticketId') || ' ' || (value ->> '$.channel.thread') END)`
	}
};
/**
* SQLite backing store implementing domain `Repositories`, view read queries, versioned settings, outbox receipts, and key-value state.
* The Runtime opens it after locking the state directory and automatically migrates supported older schemas on startup.
* The Engine mutates domain aggregates inside `atomic` transactions while Sources, views, and the Outbox read state or update their own records.
*/
var Store = class {
	report;
	db;
	/**
	* Opens or creates the SQLite database at `path`, migrating schema 10 to schema 11 in a single transaction.
	* @param report - Receives errors thrown by `afterCommit` callbacks without failing the committed transaction.
	* @throws When the database schema is older than `OLDEST_SCHEMA` (10), newer than `SCHEMA_VERSION` (11), or when migration fails; in every case the database file is left unchanged and the SQLite handle is closed so a later attempt in the same process can open it.
	*/
	constructor(path, report = () => {}) {
		this.report = report;
		mkdirSync(dirname(path), {
			recursive: true,
			mode: 448
		});
		this.db = new DatabaseSync(path);
		this.read = storeReads(this.db);
		try {
			chmodSync(path, 384);
			this.db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
			const version = this.get(KV.store.schema);
			if (version !== void 0 && version > 11) throw new Error(`Unsupported orchestrator database version ${version}`);
			if (version !== void 0 && version < 10) throw new Error(tooOld(version));
			const migrating = version !== void 0 && version < 11;
			try {
				this.atomic(() => {
					this.db.exec(`
            CREATE TABLE IF NOT EXISTS trigger (id TEXT PRIMARY KEY, value TEXT NOT NULL, at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS disposition (id TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS thread (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS ticket (id TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS decision (id TEXT PRIMARY KEY, thread TEXT NOT NULL, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS outbox (id TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS trigger_thread (thread TEXT NOT NULL, id TEXT NOT NULL, at TEXT NOT NULL, human INTEGER NOT NULL,
              PRIMARY KEY (thread, id));
            CREATE TABLE IF NOT EXISTS effect (kind TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, seq INTEGER NOT NULL,
              generation INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0, error TEXT NOT NULL DEFAULT '', due INTEGER NOT NULL,
              since TEXT NOT NULL, PRIMARY KEY (kind, key));
            CREATE INDEX IF NOT EXISTS trigger_at ON trigger(at);
            CREATE INDEX IF NOT EXISTS trigger_thread_at ON trigger_thread(thread, at);
            CREATE INDEX IF NOT EXISTS decision_thread ON decision(thread);
            CREATE INDEX IF NOT EXISTS effect_due ON effect(kind, due, seq);
          `);
					this.addColumns();
					if (migrating) migrateTo11(this);
					if (version !== 11) this.set(KV.store.schema, 11);
				});
			} catch (error) {
				if (!migrating) throw error;
				const reason = error instanceof Error ? error.message : String(error);
				throw new Error(`The orchestrator database is unchanged at schema ${version}: its migration to schema 11 failed: ${reason}`, { cause: error });
			}
		} catch (error) {
			this.db.close();
			throw error;
		}
	}
	/** Reconciles generated working-set columns and indexes when opening databases created by earlier versions. */
	addColumns() {
		const columns = (table) => new Set(this.db.prepare("SELECT name FROM pragma_table_xinfo(?)").all(table).map((row) => String(row.name)));
		for (const [table, definitions] of Object.entries(SETS)) {
			const sql = String(this.db.prepare("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?").get(table)?.sql ?? "");
			const generated = this.db.prepare("SELECT name FROM pragma_table_xinfo(?) WHERE hidden IN (2, 3)").all(table).map((row) => String(row.name));
			for (const name of generated) {
				if (definitions[name] && sql.includes(`${name} ${definitions[name]}`)) continue;
				this.db.exec(`DROP INDEX IF EXISTS ${table}_${name}; ALTER TABLE ${table} DROP COLUMN ${name}`);
			}
			const existing = columns(table);
			for (const [name, definition] of Object.entries(definitions)) {
				if (!existing.has(name)) this.db.exec(`ALTER TABLE ${table} ADD COLUMN ${name} ${definition}`);
				this.db.exec(`CREATE INDEX IF NOT EXISTS ${table}_${name} ON ${table}(${name}) WHERE ${name} IS NOT NULL`);
			}
		}
		if (!columns("effect").has("generation")) this.db.exec("ALTER TABLE effect ADD COLUMN generation INTEGER NOT NULL DEFAULT 0");
	}
	/** Closes the underlying SQLite database connection. */
	close() {
		this.db.close();
	}
	/** Parses JSON `value` columns returned by `sql`. */
	values(sql, ...parameters) {
		return this.db.prepare(sql).all(...parameters).map((row) => JSON.parse(String(row.value)));
	}
	/** Re-indexes which threads a Trigger belongs to, replacing any rows from an earlier save of the same Trigger. */
	indexThreads(trigger) {
		this.db.prepare("DELETE FROM trigger_thread WHERE id=?").run(trigger.id);
		const insert = this.db.prepare("INSERT OR IGNORE INTO trigger_thread VALUES (?,?,?,?)");
		for (const ref of trigger.threads) insert.run(threadKey(ref), trigger.id, trigger.at, trigger.human ? 1 : 0);
	}
	depth = 0;
	/** Callbacks queued to run once the outermost transaction commits, indexed by savepoint level; rolling back a level discards its callbacks. */
	committed = [];
	/**
	* Executes `operation` in a savepoint transaction (nested inside the current transaction if any); a failure rolls back its changes.
	* Post-commit callbacks run only after the outermost transaction commits, and callback errors are reported without failing the committed transaction.
	*/
	atomic(operation) {
		const level = this.depth++;
		const name = `orchestrator_atomic_${level}`;
		this.committed[level] = [];
		this.db.exec(`SAVEPOINT ${name}`);
		let value;
		try {
			value = operation();
			this.db.exec(`RELEASE ${name}`);
		} catch (error) {
			this.db.exec(`ROLLBACK TO ${name}`);
			this.db.exec(`RELEASE ${name}`);
			throw error;
		} finally {
			this.depth--;
		}
		const actions = this.committed.splice(level)[0];
		if (level) this.committed[level - 1].push(...actions);
		else for (const action of actions) try {
			action();
		} catch (error) {
			this.report(error);
		}
		return value;
	}
	/**
	* Schedules `action` to run once the outermost transaction commits, or immediately if outside a transaction;
	* callbacks queued inside a transaction that rolls back are discarded and never run.
	* Use `afterCommit` for immediate in-memory follow-ups to a committed write (such as refreshing health or cancelling an in-memory turn) that cannot wait for the effect queue and need not survive a restart; use `Effects` for durable side effects that must survive a crash.
	*/
	afterCommit(action) {
		if (this.depth) this.committed[this.depth - 1].push(action);
		else action();
	}
	/** Reads a typed KV record by its key in `KV`. */
	get(name) {
		const row = this.db.prepare("SELECT value FROM kv WHERE key=?").get(name);
		return row === void 0 ? void 0 : JSON.parse(String(row.value));
	}
	/** Writes a typed KV record under `name`. */
	set(name, value) {
		this.db.prepare("INSERT INTO kv VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value").run(name, JSON.stringify(value));
	}
	/** Deletes the KV record at `name`. */
	delete(name) {
		this.db.prepare("DELETE FROM kv WHERE key=?").run(name);
	}
	keys(family) {
		const pattern = `${(typeof family === "string" ? family : family.prefix).replace(/[\\%_]/g, (match) => `\\${match}`)}%`;
		return this.db.prepare("SELECT key FROM kv WHERE key LIKE ? ESCAPE '\\'").all(pattern).map((row) => String(row.key));
	}
	/** Versioned settings snapshots; the current settings are the snapshot of the latest revision. */
	settingsVersions = new Versions(this, KV.settings.revision, KV.settings.version);
	/** Current validated settings. */
	settings() {
		return SettingsSchema.parse(this.settingsVersions.current()?.settings ?? {});
	}
	/** Revision of one settings block; each configuration page saves against its own block for optimistic concurrency. */
	blockRevision(block) {
		return this.get(KV.settings.block(block)) ?? 0;
	}
	/** Saves settings as the next revision (making it current) and increments `record.block`'s revision counter when present. */
	saveSettings(value, record = {
		source: "internal",
		policyVersion: "",
		policyChanged: false,
		notified: []
	}) {
		const settings = SettingsSchema.parse(value);
		return this.atomic(() => {
			this.settingsVersions.save((revision) => ({
				...record,
				revision,
				savedAt: (/* @__PURE__ */ new Date()).toISOString(),
				settings
			}));
			if (record.block) this.set(KV.settings.block(record.block), this.blockRevision(record.block) + 1);
			return settings;
		});
	}
	/** Saved settings revisions, newest first; revisions predating settings history are absent. */
	settingsHistory(limit = 20) {
		return this.settingsVersions.list(limit);
	}
	triggers = {
		get: (id) => {
			const row = this.db.prepare("SELECT value FROM trigger WHERE id=?").get(id);
			return row ? JSON.parse(String(row.value)) : void 0;
		},
		save: (trigger) => this.atomic(() => {
			this.db.prepare("INSERT INTO trigger VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value, at=excluded.at").run(trigger.id, JSON.stringify(trigger), trigger.at);
			this.indexThreads(trigger);
		}),
		disposition: (id) => {
			const row = this.db.prepare("SELECT value FROM disposition WHERE id=?").get(id);
			return row ? JSON.parse(String(row.value)) : void 0;
		},
		saveDisposition: (id, value) => {
			this.db.prepare("INSERT INTO disposition VALUES (?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value").run(id, JSON.stringify(value));
		}
	};
	threads = {
		get: (keyValue) => {
			const row = this.db.prepare("SELECT value FROM thread WHERE key=?").get(keyValue);
			return row ? JSON.parse(String(row.value)) : void 0;
		},
		save: (thread) => {
			this.db.prepare("INSERT INTO thread VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value").run(thread.key, JSON.stringify(thread));
		},
		list: () => this.db.prepare("SELECT value FROM thread ORDER BY rowid").all().map((row) => JSON.parse(String(row.value))),
		active: () => this.values("SELECT value FROM thread WHERE active = 1 ORDER BY rowid"),
		/** Updates human-facing thread metadata (`label`, `url`, and `facts`, where `null` removes a fact by ID); no-op if the thread does not exist. */
		describe: (keyValue, patch) => {
			const thread = this.threads.get(keyValue);
			if (!thread) return;
			const facts = { ...thread.meta.facts };
			for (const [id, fact] of Object.entries(patch.facts ?? {})) if (fact) facts[id] = fact;
			else delete facts[id];
			const meta = {
				...thread.meta,
				...patch.label === void 0 ? {} : { label: patch.label },
				...patch.url === void 0 ? {} : { url: patch.url },
				facts
			};
			if (JSON.stringify(meta) !== JSON.stringify(thread.meta)) this.threads.save({
				...thread,
				meta
			});
		},
		/** Atomically sets or removes (`undefined`) source-specific metadata keys on a thread after re-reading it; no-op if the thread does not exist. */
		patchMeta: (keyValue, patch) => this.atomic(() => {
			const thread = this.threads.get(keyValue);
			if (!thread) return;
			const meta = { ...thread.meta };
			for (const [name, value] of Object.entries(patch)) if (value === void 0) delete meta[name];
			else meta[name] = value;
			if (JSON.stringify(meta) !== JSON.stringify(thread.meta)) this.threads.save({
				...thread,
				meta
			});
		})
	};
	tickets = {
		get: (id) => {
			const row = this.db.prepare("SELECT value FROM ticket WHERE id=?").get(id);
			return row ? JSON.parse(String(row.value)) : void 0;
		},
		save: (ticket) => {
			this.db.prepare("INSERT INTO ticket VALUES (?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value").run(ticket.id, JSON.stringify(ticket));
		},
		/** Newest first. */
		list: () => this.values("SELECT value FROM ticket ORDER BY rowid DESC"),
		/** Newest first. */
		open: () => this.values("SELECT value FROM ticket WHERE open = 1 ORDER BY rowid DESC"),
		/** Newest first. */
		active: () => this.values("SELECT value FROM ticket WHERE active = 1 ORDER BY rowid DESC")
	};
	decisions = {
		get: (id) => {
			const row = this.db.prepare("SELECT value FROM decision WHERE id=?").get(id);
			return row ? JSON.parse(String(row.value)) : void 0;
		},
		save: (decision) => {
			this.db.prepare("INSERT INTO decision VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value, thread=excluded.thread").run(decision.id, decision.threadKey, JSON.stringify(decision));
		},
		byThread: (threadKeyValue) => this.db.prepare("SELECT value FROM decision WHERE thread=? ORDER BY rowid").all(threadKeyValue).map((row) => JSON.parse(String(row.value)))
	};
	/** Read-only queries for management views, orchestrator tools, and source polling (see `storeReads`). */
	read;
	/** Delivery status of a queued message; receipts are retained permanently so message IDs are idempotent. */
	replyStatus(id) {
		return this.receipts.get(id)?.status;
	}
	/** Outbox message receipts for channel delivery; only `Outbox` writes to `receipts`. */
	receipts = {
		get: (id) => this.values("SELECT value FROM outbox WHERE id = ?", id)[0],
		/** Pending message receipts, oldest first. */
		waiting: () => this.values("SELECT value FROM outbox WHERE value ->> '$.status' = 'pending' ORDER BY rowid"),
		/** True if an earlier message for the same ticket and conversation is still pending with fewer than `failures` consecutive failed `reply` effect attempts. */
		behind: (id, failures) => !!this.db.prepare(`SELECT 1 FROM outbox earlier
      JOIN outbox message ON message.id = ? LEFT JOIN effect ON effect.kind = 'reply' AND effect.key = earlier.id
      WHERE earlier.pending = message.pending AND earlier.rowid < message.rowid AND IFNULL(effect.attempts, 0) < ? LIMIT 1`).get(id, failures),
		/**
		* Records a new pending message receipt; an already-recorded message ID keeps its original receipt.
		* @returns Whether the message ID was newly recorded.
		*/
		add: (message) => {
			const receipt = {
				...message,
				status: "pending"
			};
			return Number(this.db.prepare("INSERT OR IGNORE INTO outbox (id, value) VALUES (?, ?)").run(message.id, JSON.stringify(receipt)).changes) > 0;
		},
		/**
		* Marks a pending receipt as sent or dropped (with drop reason and timestamp), recreating the receipt if the message
		* was withdrawn while being sent so its ID cannot be queued again.
		*/
		settle: (message, outcome) => {
			const settled = outcome === "sent" ? { status: "sent" } : {
				status: "dropped",
				dropped: {
					at: (/* @__PURE__ */ new Date()).toISOString(),
					reason: outcome
				}
			};
			const { id, channel, text, kind, ticketId } = message;
			const updated = this.db.prepare("UPDATE outbox SET value = json_patch(value, ?) WHERE id = ? AND value ->> '$.status' = 'pending'").run(JSON.stringify(settled), id);
			if (!Number(updated.changes)) this.db.prepare("INSERT OR IGNORE INTO outbox (id, value) VALUES (?, ?)").run(id, JSON.stringify({
				id,
				channel,
				text,
				kind,
				...ticketId ? { ticketId } : {},
				...settled
			}));
		},
		/**
		* Withdraws a pending message that has not yet been sent.
		* @returns Whether a pending message with `id` was waiting and removed.
		*/
		withdraw: (id) => Number(this.db.prepare("DELETE FROM outbox WHERE id = ? AND value ->> '$.status' = 'pending'").run(id).changes) > 0
	};
};
//#endregion
//#region src/app/views/sources.ts
/** Source status view: health, 24-hour trigger counts, and recently filtered or dropped messages per Source instance. */
/** Resolves health entries for a Source instance, treating stale `sourceOff` entries on an enabled Source as `starting`. */
function sourceHealth(sources, instance, health) {
	const kind = sources.kind(instance.kind);
	const starting = {
		state: "starting",
		detail: ""
	};
	const parts = (kind?.health ?? []).map((name) => {
		const entry = health[name];
		return {
			name,
			...!entry || instance.enabled && entry.code === "sourceOff" ? starting : entry
		};
	});
	return {
		id: instance.id,
		title: kind?.title ?? {
			zh: instance.id,
			en: instance.id
		},
		health: parts
	};
}
const problemOf = (id, setup) => [setup.problem, setup.feishuProblem].find((problem) => problem?.place === id);
function sourceState(instance, parts, setup) {
	if (!instance.installed) return "missing";
	if (!instance.enabled) return "off";
	if (problemOf(instance.id, setup) || parts.some((part) => part.state === "error")) return "error";
	if (setup.problem) return "setup";
	if (parts.some((part) => part.state === "starting")) return "starting";
	return parts.some((part) => part.state === "paused") ? "paused" : "ready";
}
function sourcesStatus(host, health, setup) {
	const { store, sources } = host;
	const view = snapshot(host);
	const since = dayAgo();
	const stats = store.read.triggerStats(since);
	const filtered = (source) => store.read.triggers({
		source,
		filtered: true
	}, 0, 5).items.filter((trigger) => trigger.at >= since).map((trigger) => ({
		id: trigger.id,
		at: trigger.at,
		actor: view.actor(trigger.actor, trigger.human),
		preview: preview(trigger.text, 120),
		reason: store.triggers.disposition(trigger.id)?.filtered
	}));
	const dropped = droppedReplies(host);
	return sources.instances().map((instance) => {
		const { health: parts, ...named } = sourceHealth(sources, instance, health);
		const problem = problemOf(instance.id, setup);
		return {
			...named,
			installed: instance.installed,
			enabled: instance.enabled,
			state: sourceState(instance, parts, setup),
			health: parts,
			...problem ? { problem } : {},
			stats: stats[instance.id] ?? {
				received: 0,
				filtered: 0,
				lastAt: ""
			},
			filtered: filtered(instance.id),
			dropped: dropped.filter((item) => item.channel.source === instance.id)
		};
	});
}
/** Replies dropped in the last 24 hours, enriched with their associated ticket and thread. */
function droppedReplies({ store, links }) {
	return store.read.droppedReplies(store.read.droppedSince(dayAgo())).map((item) => {
		const ticket = item.ticketId ? store.tickets.get(item.ticketId) : void 0;
		const { triggerId } = links(item.channel);
		const home = triggerId ? store.triggers.get(triggerId)?.threads[0] : void 0;
		const thread = home ? threadKey(home) : store.threads.get(item.channel.thread) ? item.channel.thread : void 0;
		return {
			id: item.id,
			kind: item.kind,
			channel: item.channel,
			preview: preview(item.text),
			dropped: item.dropped,
			...ticket ? { ticket: {
				id: ticket.id,
				title: ticket.title
			} } : {},
			...thread ? { thread } : {}
		};
	});
}
//#endregion
//#region src/app/views/tickets.ts
/** Ticket list, ticket detail, mandate basis formatting, and executor load views. */
/**
* Extracts displayable mandate admission facts in reading order (omitting the receiving scope, which is stored
* only for re-validation), marking pre-scope records that only have `authority` as `legacy`.
*/
function basisFacts(basis, rule) {
	const facts = [];
	if (basis.sender) facts.push({
		name: "sender",
		value: basis.sender
	});
	if (basis.via === "bot") facts.push({ name: "bot" });
	if (basis.via !== "followup" && basis.addressed) facts.push({
		name: "addressed",
		value: basis.addressed
	});
	if (basis.via === "followup" && !basis.authority) facts.push({ name: "followup" });
	if (basis.via === "admission") facts.push({
		name: "admission",
		value: basis.cell
	});
	const observation = basis.via === "admission" || basis.via === "listed" || basis.via === "bot" ? basis.observation : void 0;
	if (observation && basis.via !== "bot") facts.push({ name: "observation" });
	if (observation?.mode) facts.push({
		name: "mode",
		value: observation.mode
	});
	if (basis.rules?.length) facts.push({
		name: "rules",
		value: basis.rules.map(rule)
	});
	const authority = basis.via === "followup" || basis.via === "listed" ? basis.authority : void 0;
	if (authority) facts.push({
		name: "legacyAuthority",
		value: authority
	});
	return {
		facts,
		legacy: authority !== void 0
	};
}
function ticketList(host, stage, offset, limit) {
	const view = snapshot(host);
	const { store } = view;
	const shown = (ticket) => stage === "open" ? liveTicket(ticket) : ticketStage(ticket).stage === stage;
	const tickets = (stage === "ended" ? store.tickets.list() : store.tickets.open()).filter(shown).sort(newestFirst);
	const result = page(tickets, offset, limit);
	return {
		...result,
		items: result.items.map((ticket) => ticketRow(view, ticket))
	};
}
function ticketRow(view, ticket) {
	const line = ticketLine(view, ticket);
	const channel = ticket.channels[0];
	const reply = line.stage === "person" && channel ? channelLink(view, channel) : void 0;
	return {
		...line,
		...reply ? { reply } : {}
	};
}
function executorLoad(store, running) {
	const queued = (ticket) => {
		const stage = ticketStage(ticket);
		return stage.stage === "working" && stage.action === "queued";
	};
	return {
		running,
		queued: store.tickets.open().filter(queued).length
	};
}
function ticketDetail(host, id) {
	const { store } = host;
	const ticket = store.tickets.get(id);
	if (!ticket) return void 0;
	const view = snapshot(host);
	const { stage } = ticketStage(ticket);
	const decision = store.decisions.get(ticket.decisionId);
	const input = (value) => {
		const trigger = value.kind === "trigger" ? store.triggers.get(value.triggerId) : void 0;
		const handback = trigger && store.triggers.disposition(trigger.id)?.handbacks?.find((item) => item.ticketId === id);
		const shown = trigger && {
			id: trigger.id,
			actor: view.actor(trigger.actor, trigger.human),
			human: trigger.human,
			preview: preview(trigger.text),
			thread: threadKey(trigger.threads[0]),
			...handback ? { handback: {
				reason: handback.reason,
				at: handback.at
			} } : {}
		};
		const text = (value.kind === "text" || value.kind === "note") && value.text ? { text: markdown(value.text) } : {};
		return {
			...value,
			...text,
			delivered: !ticket.undelivered.includes(value.id),
			...shown ? { trigger: shown } : {}
		};
	};
	const human = ticket.mandate.basis.via !== "bot";
	return {
		...ticketLine(view, ticket),
		mandate: {
			...ticket.mandate,
			actor: view.actor(ticket.mandate.actor, human)
		},
		basis: basisFacts(ticket.mandate.basis, view.rule),
		paused: store.settings().paused,
		channels: ticket.channels.map((channel) => channelLink(view, channel)),
		decision: decision ? decisionView(view, decision) : void 0,
		assignments: ticket.assignments.map((assignment) => ({
			...assignment,
			...assignment.startedAt ? { ref: workerSessionId(ticket.id) } : {},
			...assignment.state === "running" && assignment.report && assignment.report.state !== "progress" && stage !== "working" ? { turnEndedAt: assignment.report.at } : {}
		})),
		inputs: ticket.inputs.slice().reverse().map(input),
		threads: view.threadsOf(id).map((thread) => ({
			...threadSummary(view, thread),
			...thread.context?.includes(id) ? { context: true } : {}
		}))
	};
}
//#endregion
//#region src/app/views/overview.ts
/** Overview view: active system problems, tickets awaiting human action, executor load, and 24-hour trigger flow. */
/** Threads whose latest decision since `since` is an undismissed `unavailable` eval and that are neither evaluating nor queued. */
function unjudged(store, since) {
	const seen = /* @__PURE__ */ new Set();
	const queue = {
		store,
		owners: ownersOf(store)
	};
	return store.read.decisionsOfKinds(["unavailable"], 200).filter((decision) => decision.at >= since).flatMap((decision) => {
		if (seen.has(decision.threadKey)) return [];
		seen.add(decision.threadKey);
		const thread = store.threads.get(decision.threadKey);
		if (!thread || thread.evaluating || awaitingEval(queue, thread).length || decision.dismissed) return [];
		if (store.decisions.byThread(thread.key).at(-1)?.id !== decision.id) return [];
		return [{
			thread,
			decision
		}];
	});
}
/** Reports error health when any thread has an undismissed `unavailable` eval from the last hour without a newer decision or active eval. */
function evalsHealth(store, now = Date.now()) {
	const open = unjudged(store, (/* @__PURE__ */ new Date(now - 36e5)).toISOString());
	if (!open.length) return {
		state: "ready",
		detail: "No unavailable Eval in the last hour"
	};
	const latest = open[0].decision;
	return {
		state: "error",
		at: latest.at,
		detail: `${open.length} Eval(s) unavailable in the last hour without a later judgement; the latest on ${latest.threadKey}: ${reasonText(latest.reason)}`
	};
}
/**
* Builds the operator overview: active system problems, tickets awaiting human action, executor load, and 24-hour trigger flow.
* @param setup - Setup problem to surface first (where setup stopped, or a Source paused by setup).
*/
function overview(host, health, policyVersionValue, load, setup) {
	const { store, sources } = host;
	const view = snapshot(host);
	const settings = store.settings();
	const now = (/* @__PURE__ */ new Date()).toISOString(), since = dayAgo();
	const evaluating = store.threads.active().filter((thread) => thread.evaluating);
	const instances = sources.instances();
	const running = instances.filter((instance) => instance.enabled && instance.installed).map((instance) => sourceHealth(sources, instance, health));
	const sourceParts = new Set(instances.flatMap((instance) => sources.kind(instance.kind)?.health ?? []));
	const problems = [
		...setup ? [{
			kind: "setup",
			...setup
		}] : [],
		...running.length ? [] : [{ kind: "no-source" }],
		...anyoneAllowed(settings) ? [] : [{ kind: "no-allowed" }],
		...running.flatMap((source) => source.health.filter((item) => item.state === "error").map((item) => ({
			kind: "source-error",
			source: {
				id: source.id,
				title: source.title,
				health: item
			}
		}))),
		...settings.paused ? [{ kind: "executor-paused" }] : [],
		...Object.entries(health).filter(([name, item]) => item.state === "error" && !sourceParts.has(name) && !name.startsWith("sync:") && name !== "evals").map(([name, item]) => ({
			kind: "runtime-error",
			name,
			detail: item.detail
		})),
		...evaluating.filter((thread) => thread.evaluating.deadline < now).map((thread) => ({
			kind: "eval-overdue",
			thread: threadSummary(view, thread)
		})),
		...unjudged(store, since).map(({ thread, decision }) => ({
			kind: "eval-unavailable",
			decisionId: decision.id,
			thread: threadSummary(view, thread),
			reason: decision.reason,
			triggerId: decision.triggerIds[0] ?? ""
		})),
		...store.read.failingReplies().map((item) => ({
			kind: "outgoing",
			outgoing: {
				id: item.id,
				channel: item.channel,
				text: preview(item.text),
				attempts: item.attempts,
				error: item.error
			}
		}))
	];
	const open = store.tickets.open().sort(newestFirst);
	const stats = Object.values(store.read.triggerStats(since));
	const received = stats.reduce((sum, item) => sum + item.received, 0), filtered = stats.reduce((sum, item) => sum + item.filtered, 0);
	const judgement = store.read.flow(since);
	return {
		problems,
		person: open.filter((ticket) => ticketStage(ticket).stage === "person").map((ticket) => ticketRow(view, ticket)),
		executor: {
			...load,
			maxWorkers: settings.executor.maxWorkers,
			idle: open.filter((ticket) => ticketStage(ticket).stage === "idle").length
		},
		flow: {
			received,
			filtered,
			triggers: received - filtered,
			judged: judgement.judged,
			accepted: judgement.accepted,
			evaluating: evaluating.length,
			dropped: store.read.droppedSince(since)
		},
		policyVersion: policyVersionValue
	};
}
//#endregion
//#region src/app/cache.ts
/**
* In-memory LRU cache bounded by total UTF-16 code units, always retaining the most recently inserted entry.
* Runtime uses separate instances to cache paginated resource snapshots for `orchestrator_read` and resolved Feishu message links for search and cards.
*/
var TextCache = class {
	limit;
	texts = /* @__PURE__ */ new Map();
	size = 0;
	constructor(limit) {
		this.limit = limit;
	}
	get(key) {
		const text = this.texts.get(key);
		if (text !== void 0) {
			this.texts.delete(key);
			this.texts.set(key, text);
		}
		return text;
	}
	set(key, text) {
		this.size -= this.texts.get(key)?.length ?? 0;
		this.texts.delete(key);
		this.texts.set(key, text);
		this.size += text.length;
		for (const [oldest, value] of this.texts) {
			if (this.size <= this.limit || oldest === key) break;
			this.texts.delete(oldest);
			this.size -= value.length;
		}
	}
	/** Entries ordered from least to most recently used. */
	entries() {
		return this.texts.entries();
	}
};
//#endregion
//#region src/app/api.ts
const TICKET_FILTERS = [
	"open",
	"person",
	"working",
	"idle",
	"ended"
];
const THREAD_FILTERS = [
	"subscribed",
	"evaluating",
	"recent",
	"all"
];
//#endregion
//#region src/app/role-models.ts
/** Resolve a configured route through the live provider; catalog membership is not a restriction. */
async function resolveRoleModel(ctx, model) {
	const value = await ctx.llm.resolveCallConfig({
		provider: model.provider,
		model: model.model,
		...model.reasoningEffort ? { reasoningEffort: ReasoningEffortId(model.reasoningEffort) } : {}
	});
	return {
		provider: value.provider,
		model: value.model,
		...value.reasoningEffort ? { reasoningEffort: value.reasoningEffort } : {}
	};
}
/** Seed a role's configured model onto a brand-new session before its first request, leaving later manual or durable selections intact. */
async function initializeRoleModel(ctx, agent, model) {
	if (!model) return;
	if (agent.session.requestHeader() || agent.session.snapshotEvents().some((event) => event.type === "model/selection")) return;
	const selected = await resolveRoleModel(ctx, model);
	agent.session.append("model/selection", selected);
	let initial = true;
	let assembled;
	agent.ctx.effect(() => {
		const disposers = [
			agent.ctx.on("system-prompt/assemble", async (_assembly, _context, next) => {
				const selection = initial ? selected : void 0;
				const result = await next();
				assembled = selection;
				return selection ? {
					...result,
					variables: {
						...result.variables,
						provider: selection.provider,
						model: selection.model
					}
				} : result;
			}, { prepend: true }),
			agent.ctx.on("agent/request", async (_payload, next) => {
				const result = await next();
				if (!assembled) return result;
				const { reasoningEffort: _inherited, ...rest } = result;
				return {
					...rest,
					...assembled
				};
			}, { prepend: true }),
			ctx.on("session/event", (session, event) => {
				if (session === agent.session && (event.type === "request/header" || event.type === "model/selection")) initial = false;
			})
		];
		return () => disposers.forEach((dispose) => dispose());
	});
	await ctx.sessionPersistence.flush();
}
//#endregion
//#region src/app/setup.ts
const setupFields = (settings) => JSON.stringify([settings.sources.github?.enabled !== false, ...Object.entries(SETUP_FIELDS).map(([id, keys]) => keys.map((key) => settings.sources[id]?.config[key] ?? ""))]);
const setupChanged = (before, after) => setupFields(before) !== setupFields(after);
/**
* Resolves the target repository, GitHub account, and optional Feishu bot by probing CLIs, then writes and applies the isolated git and shim environment used by worker processes.
* `Runtime` runs it at startup to gate orchestration readiness, while `Settings` uses it to validate account changes, update blocked command shims, and schedule restarts.
*/
var Setup = class {
	host;
	resolved;
	problem;
	feishuProblem;
	/** PATH with the worker shim directory removed so the host's own CLI calls invoke the real binaries. */
	path;
	/** Environment variables pointing agent subprocesses at the isolated git config and command shims. */
	variables;
	restoreEnvironment;
	constructor(host) {
		this.host = host;
		this.path = withoutDirectory(process.env.PATH ?? "", workerBin(host.machine.stateDir));
		this.variables = agentVariables(host.machine.stateDir);
	}
	/** Host command environment with agent git variables applied and the worker shim directory excluded from PATH. */
	get commandEnvironment() {
		return {
			...this.variables,
			PATH: this.path
		};
	}
	get deployment() {
		if (!this.resolved) throw new Error(`dsh-superagent is waiting for setup: ${this.problem?.detail ?? "setup has not run"}`);
		return this.resolved;
	}
	configured() {
		return this.resolved !== void 0;
	}
	/** Resolve deployment accounts and apply the worker environment, recording `SetupError` failures in `problem`/`feishuProblem` and rethrowing unexpected errors. */
	async run(settings) {
		try {
			this.resolved = await this.resolve(settings);
			return true;
		} catch (error) {
			if (!(error instanceof SetupError)) throw error;
			this.problem = error.problem;
			return false;
		}
	}
	/** Trigger a restart to re-run setup, refusing if setup and Feishu are already healthy so running assignments are not interrupted. */
	check() {
		if (this.configured() && !this.feishuProblem) throw new UserError("setupComplete");
		this.restart();
	}
	/** Defer the restart to the next macrotask so the current HTTP or tool caller receives its response first. */
	restart() {
		setTimeout(this.host.restart, 0);
	}
	/** Verify account CLIs for a modified source block before saving, ignoring setup errors belonging to other blocks. */
	async checkAccounts(block, settings) {
		if (block !== "source:feishu" && block !== "source:github") return;
		if (block === "source:github" && settings.sources.github?.enabled === false) return;
		const { machine } = this.host;
		await (block === "source:feishu" ? resolveFeishuBot(machine, settings.sources.feishu?.config, this.probe()) : resolveDeployment(machine, settings.sources.github?.config, this.probe())).catch((error) => {
			if (!(error instanceof SetupError) || error.place === block.slice(7)) throw error;
		});
	}
	async blockCommands(blocked) {
		if (this.resolved) await writeEnvironment(this.resolved, blocked);
	}
	restore() {
		this.restoreEnvironment?.();
		this.restoreEnvironment = void 0;
	}
	/** Probes CLIs the way worker shells run them, using `stateDir` as `cwd` since it exists even before the repository clone is valid. */
	probe() {
		const { context, machine, lifetime } = this.host;
		return workerProbe(context.subprocess, machine.stateDir, machine.stateDir, lifetime);
	}
	async resolve(settings) {
		const { context, machine, lifetime } = this.host;
		const probe = this.probe();
		const deployment = settings.sources.github?.enabled === false ? {
			...machine,
			repository: "",
			github: {
				cli: "",
				login: "local-agent",
				noreply: "local-agent@localhost"
			}
		} : await resolveDeployment(machine, settings.sources.github?.config, probe);
		const feishu = await resolveFeishuBot(machine, settings.sources.feishu?.config, probe).catch((error) => {
			if (!(error instanceof SetupError)) throw error;
			this.feishuProblem = error.problem;
			context.logger.warn("dsh-superagent leaves Feishu out: %s", error.message);
		});
		const resolved = {
			...deployment,
			...feishu ? { feishu } : {}
		};
		const machineProblem = (error) => {
			if (error instanceof SetupError) throw error;
			throw new SetupError("environmentFailed", { output: error instanceof Error ? error.message : String(error) });
		};
		await writeEnvironment(resolved, settings.executor.blockedCommands).catch(machineProblem);
		this.restoreEnvironment = applyEnvironment(this.variables, machine.stateDir, this.path);
		await verifyEnvironment(resolved, context.subprocess, lifetime).catch((error) => {
			this.restore();
			machineProblem(error);
		});
		return resolved;
	}
};
//#endregion
//#region src/app/settings.ts
/**
* Indicates an optimistic concurrency conflict when saving or syncing a settings block against a stale revision.
* Thrown by `Settings.save` and `Settings.sync` and translated into an HTTP 409 response by the management routes.
*/
var SettingsConflict = class extends Error {};
const now$2 = () => (/* @__PURE__ */ new Date()).toISOString();
/** Executor settings that control shell execution paths, prepare commands, and command shims. */
const environment = ({ executor }) => JSON.stringify([
	executor.directory,
	executor.prepare,
	executor.blockedCommands
]);
const BLOCKS = {
	policy: {
		parse: (value, sources) => {
			const policy = PolicyConfigSchema.parse(value);
			return {
				...policy,
				sources: sources.validatePolicy(policy.sources)
			};
		},
		merge: (settings, value) => ({
			...settings,
			policy: value
		})
	},
	eval: {
		parse: (value) => EvalConfigSchema.parse(value),
		merge: (settings, value) => ({
			...settings,
			eval: value
		})
	},
	executor: {
		parse: (value) => ExecutorConfigSchema.parse(value),
		merge: (settings, value) => ({
			...settings,
			executor: value
		}),
		guard: (current, candidate, origin) => {
			if (origin !== "panel" && environment(current) !== environment(candidate)) throw new UserError("panelOnlyEnvironment");
		}
	},
	source: {
		parse: (value, sources, id) => sources.validate(id, z.object({
			enabled: z.boolean(),
			config: z.unknown()
		}).parse(value)),
		merge: (settings, value, id) => ({
			...settings,
			sources: {
				...settings.sources,
				[id]: value
			}
		}),
		guard: (current, candidate, origin) => {
			if (origin !== "panel" && setupChanged(current, candidate)) throw new UserError("panelOnlyAccounts");
		}
	}
};
/**
* Validates and persists block-scoped settings in `Store`, enforces origin guards, and manages source policy synchronization and label refreshes.
* `Runtime`, management HTTP routes, and main-Session tools read and save settings through it.
* Notifies `Engine` when the policy version changes, notifies the main Session via `Sessions`, and triggers `Setup` restarts or `Passes` runs when saved settings take effect.
* Tracks per-source synchronization status in `HealthBoard` and retries failed syncs with exponential backoff.
*/
var Settings = class {
	host;
	/** Per-source `sync:<id>` health entries, claimed lazily on each source's first policy sync. */
	syncs = /* @__PURE__ */ new Map();
	/** Pending exponential-backoff retry timer and last wait duration (ms) per source after a failed sync. */
	retries = /* @__PURE__ */ new Map();
	constructor(host) {
		this.host = host;
		host.lifetime.addEventListener("abort", () => {
			for (const { timer } of this.retries.values()) clearTimeout(timer);
		}, { once: true });
	}
	/** Schedule exponential backoff retries (1 minute up to 1 hour) after a failed source sync, or clear pending retries on success. */
	retrySync(id, failed) {
		const previous = this.retries.get(id);
		if (previous) clearTimeout(previous.timer);
		this.retries.delete(id);
		if (!failed || this.host.lifetime.aborted) return;
		const wait = previous ? Math.min(previous.wait * 2, 36e5) : 6e4;
		const timer = setTimeout(() => {
			this.sync(id).catch(() => {});
		}, wait);
		timer.unref?.();
		this.retries.set(id, {
			timer,
			wait
		});
	}
	syncHealth(id) {
		let entry = this.syncs.get(id);
		if (!entry) this.syncs.set(id, entry = this.host.health.claim(`sync:${id}`));
		return entry;
	}
	/** Returns the current validated settings from `Store`. */
	current() {
		return this.host.store.settings();
	}
	/**
	* Returns an overview of all settings blocks with their current block revisions: full values for `pause`, `eval`, and
	* `executor`; rule summaries and allowed-sender counts for `policy`; and instance status switches for `sources` (with `read: 'settings/<block>'` paths for full block reads).
	*/
	view() {
		const { store, sources } = this.host;
		const settings = store.settings(), revision = (block) => store.blockRevision(block);
		const { rules, sources: parts } = settings.policy;
		return {
			revision: store.get(KV.settings.revision) ?? 0,
			pause: {
				revision: revision("pause"),
				value: { paused: settings.paused }
			},
			eval: {
				revision: revision("eval"),
				value: settings.eval
			},
			executor: {
				revision: revision("executor"),
				value: settings.executor
			},
			policy: {
				revision: revision("policy"),
				rules: rules.map((rule) => ({
					id: rule.id,
					name: rule.name,
					enabled: rule.enabled
				})),
				allowed: Object.fromEntries(Object.entries(parts).map(([id, part]) => [id, part.allowed.length])),
				read: "settings/policy"
			},
			sources: sources.instances(settings).map(({ id, kind, enabled, installed }) => ({
				id,
				kind,
				enabled,
				installed,
				revision: revision(`source:${id}`),
				read: `settings/source:${id}`
			}))
		};
	}
	/**
	* Returns one settings block as accepted by `save` (`policy`, `eval`, `executor`, `pause` holding `{ paused }`, or
	* `source:<id>` holding `{ enabled, config }`) along with its current block revision.
	* @throws UserError (`unknownBlock`) when no such settings block exists.
	*/
	block(block) {
		const { store, sources } = this.host;
		const settings = store.settings(), id = block.startsWith("source:") ? block.slice(7) : void 0;
		const instance = id === void 0 ? void 0 : sources.instances(settings).find((item) => item.id === id);
		const value = block === "pause" ? { paused: settings.paused } : block === "policy" || block === "eval" || block === "executor" ? settings[block] : instance ? {
			enabled: instance.enabled,
			config: instance.config
		} : void 0;
		if (value === void 0) throw new UserError("unknownBlock", { block });
		return {
			block,
			revision: store.blockRevision(block),
			value
		};
	}
	/**
	* Validates and saves one settings block against its `revision`; a no-op save records no new revision, a changed policy
	* version notifies affected open tickets, and changing a setup-read field (`SETUP_FIELDS`, such as an account CLI) or any
	* change saved while waiting for setup (`!this.host.setup.configured()`) restarts `dsh-superagent` so setup runs again.
	* @param origin - Caller origin; restricts execution-environment and account-CLI changes to `'panel'` (a guardrail against prompt-injected tool calls, not an OS security boundary, since agents run shell commands; `origin` has no default so no caller receives panel privileges implicitly).
	* @returns Save outcome with the block's current `revision`, whether `policy_changed`, whether `restarting`, and `context_delivery` status (`'injected'` or `'pending'`).
	* @throws SettingsConflict when `block`'s revision changed before or during validation checks.
	* @throws UserError | z.ZodError when `block` is unknown, the source is not installed, `value` is invalid (such as an `executor` block carrying `paused`, which only `pause` sets), a non-panel `origin` changes panel-only fields, or a role-model or account check fails.
	*/
	async save(block, value, revision, origin) {
		const { store, sources, engine, sessions } = this.host;
		const stale = () => revision !== store.blockRevision(block);
		if (stale()) throw new SettingsConflict("Settings changed. Reload before saving.");
		const id = block.startsWith("source:") ? block.slice(7) : block;
		const kind = block.startsWith("source:") ? "source" : block;
		if (!(kind in BLOCKS)) throw new UserError("unknownBlock", { block });
		const rules = BLOCKS[kind];
		if (kind === "source" && !sources.kind(id)) throw new UserError("sourceNotInstalled", { source: id });
		const parsed = rules.parse(value, sources, id);
		const current = store.settings();
		const candidate = rules.merge(current, parsed, id);
		const model = block === "eval" ? candidate.eval.model : block === "executor" ? candidate.executor.model : null;
		const previous = block === "eval" ? current.eval.model : block === "executor" ? current.executor.model : null;
		if (model && JSON.stringify(model) !== JSON.stringify(previous)) try {
			await resolveRoleModel(this.host.context, model);
		} catch (error) {
			throw new UserError("modelUnavailable", {
				block,
				error: error instanceof Error ? error.message : String(error)
			});
		}
		rules.guard?.(current, candidate, origin);
		if (setupChanged(current, candidate)) await this.host.setup.checkAccounts(block, candidate);
		if (stale()) throw new SettingsConflict("Settings changed during the checks. Reload before saving.");
		const old = store.settings();
		const settings = rules.merge(old, parsed, id);
		if (JSON.stringify(SettingsSchema.parse(settings)) === JSON.stringify(old)) {
			const delivery = await sessions.delivery(`settings:${block}`);
			return {
				saved: true,
				revision: store.blockRevision(block),
				policy_changed: false,
				restarting: false,
				context_delivery: delivery
			};
		}
		const restarting = setupChanged(old, settings) || !this.host.setup.configured();
		const before = policyVersion(old), after = policyVersion(settings);
		const scope = (version) => ({ scope: (input) => this.host.sources.scope(input, version) });
		const effects = before === after ? /* @__PURE__ */ new Map() : policyEffects(store.tickets.open(), old, SettingsSchema.parse(settings), scope);
		const notified = [...effects.keys()];
		store.atomic(() => {
			store.saveSettings(SettingsSchema.parse(settings), {
				source: origin,
				block,
				policyVersion: after,
				policyChanged: before !== after,
				notified
			});
			if (origin !== "tool") sessions.notify(...settingsNotice(block, changedPaths(old, settings)));
			if (before !== after) engine.policyChanged(before, after, effects);
		});
		const blocked = settings.executor.blockedCommands;
		if (blocked.join(" ") !== old.executor.blockedCommands.join(" ")) await this.host.setup.blockCommands(blocked);
		const delivery = restarting ? "pending" : await sessions.delivery(`settings:${block}`);
		if (restarting) this.host.setup.restart();
		else this.host.requestPass();
		return {
			saved: true,
			revision: store.blockRevision(block),
			policy_changed: before !== after,
			restarting,
			context_delivery: delivery
		};
	}
	/**
	* Pauses or resumes processing (new evaluations, worker dispatch, and channel delivery, while Sources continue recording
	* Triggers); saved in its own `'pause'` block so concurrent `executor` edits remain valid across it.
	* @returns Whether processing is now paused (`{ paused }`).
	*/
	async pause(paused, origin) {
		const { store, sessions } = this.host;
		const old = store.settings();
		if (old.paused === paused) return { paused };
		store.atomic(() => {
			const record = {
				source: origin,
				block: "pause",
				policyVersion: policyVersion(old),
				policyChanged: false,
				notified: []
			};
			store.saveSettings({
				...old,
				paused
			}, record);
			if (origin !== "tool") sessions.notify(...settingsNotice("pause", ["paused"]));
		});
		await sessions.delivery("settings:pause");
		this.host.requestPass();
		return { paused };
	}
	/** Returns the IDs of installed, enabled Sources whose policy section can synchronize now (empty while setup is not configured). */
	syncable() {
		const { sources } = this.host;
		if (!this.host.setup.configured()) return [];
		return sources.instances().filter((instance) => instance.installed && instance.enabled).flatMap((instance) => {
			const sync = sources.kind(instance.id)?.policy?.sync;
			const part = sources.policyPart(instance.id);
			return sync && part && sync.ready(part) ? [instance.id] : [];
		});
	}
	/**
	* Synchronizes source `id`'s policy section from its external source of truth, saves it as a `'policy'` revision when
	* changed, and records the outcome in the `sync:<id>` health entry (scheduling exponential-backoff retries via `retrySync` on failure).
	* @returns The synchronized policy section for `id`.
	* @throws UserError (`nothingToSync`) when `id` cannot sync now, `SettingsConflict` if the `'policy'` block changed during synchronization, or the underlying sync error on failure.
	*/
	async sync(id) {
		const { store, sources } = this.host;
		if (!this.syncable().includes(id)) throw new UserError("nothingToSync", { source: id });
		const health = this.syncHealth(id);
		try {
			const revision = store.blockRevision("policy");
			const part = await sources.kind(id).policy.sync.run(this.host.sourceHost, sources.policyPart(id), this.host.lifetime);
			if (revision !== store.blockRevision("policy")) throw new SettingsConflict("Policy changed during synchronization. Retry with the current settings.");
			const policy = store.settings().policy;
			if (JSON.stringify(part) !== JSON.stringify(policy.sources[id])) await this.save("policy", {
				...policy,
				sources: {
					...policy.sources,
					[id]: part
				}
			}, revision, "sync");
			health.set({
				state: "ready",
				detail: `${part.allowed.length} allowed`,
				at: now$2()
			});
			this.retrySync(id, false);
			return part;
		} catch (error) {
			health.set({
				state: "error",
				detail: String(error),
				at: now$2()
			});
			this.retrySync(id, true);
			throw error;
		}
	}
	/**
	* Rereads a Source's display names (such as Feishu chat names) immediately.
	* @returns Sorted display names (`{ added }`) that were not present in the stored label map before this read.
	* @throws UserError (`noLabels`) when the Source has no label refresh; rethrows a failed read, keeping the stored list.
	*/
	async refreshLabels(id) {
		const { store, sources } = this.host;
		const instance = sources.instance(id);
		const kind = instance && sources.kind(instance.kind);
		if (!kind?.refreshLabels) throw new UserError("noLabels");
		const before = store.get(KV.sources.labels(id)) ?? {};
		const after = await kind.refreshLabels(this.host.sourceHost);
		return { added: Object.entries(after).filter(([key]) => !(key in before)).map(([, name]) => name).sort((a, b) => a.localeCompare(b)) };
	}
};
//#endregion
//#region src/app/settings-history.ts
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
function fieldChanges(id, fields, a, b, part) {
	const changes = [];
	const at = {
		source: id,
		...part ? { part } : {}
	};
	for (const field of fields) {
		const from = a[field.key], to = b[field.key];
		if (same(from, to)) continue;
		if (field.type === "rows") {
			const rowKey = field.columns[0].key;
			const rows = (value) => new Map((Array.isArray(value) ? value : []).map((row) => [String(row[rowKey]), row]));
			const label = (row, item) => String(field.columns[1] && row?.[field.columns[1].key] || item);
			const old = rows(from), next = rows(to);
			const added = [...next.keys()].filter((item) => !old.has(item)).map((item) => label(next.get(item), item)), removed = [...old.keys()].filter((item) => !next.has(item)).map((item) => label(old.get(item), item));
			const changed = [...next.keys()].filter((item) => old.has(item) && !same(old.get(item), next.get(item))).map((item) => label(next.get(item), item));
			if (added.length) changes.push({
				code: "sourceRowsAdded",
				...at,
				field: field.key,
				items: added
			});
			if (removed.length) changes.push({
				code: "sourceRowsRemoved",
				...at,
				field: field.key,
				items: removed
			});
			if (changed.length) changes.push({
				code: "sourceRowsChanged",
				...at,
				field: field.key,
				items: changed
			});
		} else changes.push({
			code: "sourceField",
			...at,
			field: field.key,
			from,
			to
		});
	}
	return changes;
}
function sourceChanges(id, before, after, sources) {
	const kind = sources.kind(id);
	const changes = [];
	if ((before?.enabled ?? true) !== (after?.enabled ?? true)) changes.push({
		code: after?.enabled === false ? "sourceDisabled" : "sourceEnabled",
		source: id
	});
	const fill = (value) => kind ? kind.schema.parse(value?.config ?? {}) : value?.config ?? {};
	return [...changes, ...fieldChanges(id, kind?.fields ?? [], fill(before), fill(after))];
}
function settingsChanges(before, after, sources) {
	const changes = [];
	for (const rule of after.policy.rules) {
		const old = before.policy.rules.find((item) => item.id === rule.id);
		if (!old) {
			changes.push({
				code: "ruleAdded",
				name: rule.name
			});
			continue;
		}
		if (old.name !== rule.name) changes.push({
			code: "ruleRenamed",
			from: old.name,
			to: rule.name
		});
		if (old.instruction !== rule.instruction) changes.push({
			code: "ruleInstruction",
			name: rule.name
		});
		if (old.enabled !== rule.enabled) changes.push({
			code: rule.enabled ? "ruleEnabled" : "ruleDisabled",
			name: rule.name
		});
	}
	for (const rule of before.policy.rules) if (!after.policy.rules.some((item) => item.id === rule.id)) changes.push({
		code: "ruleRemoved",
		name: rule.name
	});
	for (const id of /* @__PURE__ */ new Set([...Object.keys(before.policy.sources), ...Object.keys(after.policy.sources)])) {
		const policy = sources.kind(id)?.policy;
		const fill = (value) => {
			const { admission: _admission, ...rest } = value ?? {};
			return policy ? policy.schema.parse(rest) : rest;
		};
		changes.push(...fieldChanges(id, policy?.fields ?? [], fill(before.policy.sources[id]), fill(after.policy.sources[id]), true));
		if (JSON.stringify(before.policy.sources[id]?.admission ?? {}) !== JSON.stringify(after.policy.sources[id]?.admission ?? {})) changes.push({
			code: "sourceAdmission",
			source: id,
			part: true
		});
	}
	if (before.eval.mode !== after.eval.mode) changes.push({
		code: "mode",
		from: before.eval.mode,
		to: after.eval.mode
	});
	if (before.eval.timeoutSeconds !== after.eval.timeoutSeconds) changes.push({
		code: "timeout",
		from: before.eval.timeoutSeconds,
		to: after.eval.timeoutSeconds
	});
	if (!same(before.eval.model, after.eval.model)) changes.push({ code: "evalModel" });
	if (!same(before.executor.model, after.executor.model)) changes.push({ code: "executorModel" });
	if (before.executor.maxWorkers !== after.executor.maxWorkers) changes.push({
		code: "maxWorkers",
		from: before.executor.maxWorkers,
		to: after.executor.maxWorkers
	});
	if (before.paused !== after.paused) changes.push({ code: after.paused ? "paused" : "resumed" });
	if (before.executor.directory !== after.executor.directory) changes.push({
		code: "executionDirectory",
		from: before.executor.directory,
		to: after.executor.directory
	});
	if (before.executor.prepare !== after.executor.prepare) changes.push({ code: "prepareCommand" });
	if (!same(before.executor.blockedCommands, after.executor.blockedCommands)) changes.push({
		code: "blockedCommands",
		from: before.executor.blockedCommands.join(" "),
		to: after.executor.blockedCommands.join(" ")
	});
	for (const id of /* @__PURE__ */ new Set([...Object.keys(before.sources), ...Object.keys(after.sources)])) changes.push(...sourceChanges(id, before.sources[id], after.sources[id], sources));
	return changes;
}
/** Compute changes between two revisions, returning null if a historical revision fails current source schema validation. */
function changesOf(before, after, sources) {
	try {
		return settingsChanges(before, after, sources);
	} catch {
		return null;
	}
}
/** Return recent settings revisions newest-first with their computed diffs and notified tickets. */
function policyHistory(store, sources, policyVersionValue) {
	const versions = store.settingsHistory(30);
	return {
		current: store.get(KV.settings.revision) ?? 0,
		policyVersion: policyVersionValue,
		items: versions.map((version, index) => {
			const previous = versions[index + 1];
			return {
				revision: version.revision,
				savedAt: version.savedAt,
				source: version.source,
				block: version.block,
				policyVersion: version.policyVersion,
				policyChanged: version.policyChanged,
				notified: version.notified.map((id) => ({
					id,
					title: store.tickets.get(id)?.title ?? id
				})),
				changes: previous && previous.revision === version.revision - 1 ? changesOf(previous.settings, version.settings, sources) : null
			};
		})
	};
}
//#endregion
//#region src/app/views/settings.ts
/** Settings view combining versioned configuration blocks, per-source forms and policy metadata, and execution environment details. */
function policyOf(sources, id, health) {
	const policy = sources.kind(id)?.policy;
	if (!policy) return {};
	const part = sources.policyPart(id);
	const config = sources.instance(id)?.config ?? {};
	const sync = policy.sync && {
		label: policy.sync.label,
		ready: policy.sync.ready(part),
		health: health[`sync:${id}`]
	};
	return { policy: {
		fields: policy.fields,
		explicit: policy.explicit,
		...policy.rows ? { rows: policy.rows(config) } : {},
		...sync ? { sync } : {}
	} };
}
/**
* Builds the settings view by block (`{ value, revision }`), per-Source configuration and restart-sensitive fields,
* and execution environment details (`stateDir` provides the default ticket working directory root).
*/
function settingsView(store, sources, health, setup, stateDir) {
	const settings = store.settings();
	const block = (name, value) => ({
		value,
		revision: store.blockRevision(name)
	});
	return {
		policyVersion: policyVersion(settings),
		blocks: {
			policy: block("policy", settings.policy),
			eval: block("eval", settings.eval),
			executor: block("executor", settings.executor)
		},
		sources: sources.instances(settings).map((instance) => {
			const kind = sources.kind(instance.kind);
			const problem = problemOf(instance.id, setup);
			const { id, title } = sourceHealth(sources, instance, health);
			return {
				id,
				kind: instance.kind,
				title,
				description: kind?.description ?? {
					zh: "",
					en: ""
				},
				installed: instance.installed,
				value: {
					enabled: instance.enabled,
					config: instance.config
				},
				revision: store.blockRevision(`source:${instance.id}`),
				restarts: SETUP_FIELDS[instance.id] ?? [],
				fields: kind?.fields ?? [],
				facts: kind?.facts?.(setup.deployment) ?? {},
				labels: store.get(KV.sources.labels(instance.id)) ?? {},
				...problem ? { problem } : {},
				...policyOf(sources, instance.id, health)
			};
		}),
		environment: {
			root: executionRoot(settings, stateDir),
			variables: declaredVariables(sources, settings)
		}
	};
}
//#endregion
//#region src/app/views/threads.ts
/** Thread list, timeline detail, cross-entity search, and decision list views. */
function threadList(host, filter, offset, limit) {
	const { store } = host;
	const view = snapshot(host);
	const since = dayAgo();
	const open = new Set(store.tickets.open().map((ticket) => ticket.id));
	const live = (thread) => thread.subscriptions.some((id) => open.has(id));
	const lastAt = (thread) => thread.lastAt ?? thread.createdAt;
	const kept = (thread) => filter === "recent" ? lastAt(thread) >= since : filter === "all" || (filter === "subscribed" ? live(thread) : !!thread.evaluating || awaitingEval(view, thread).length > 0);
	const threads = (filter === "subscribed" ? store.read.subscribedThreads() : filter === "evaluating" ? store.threads.active() : store.threads.list()).filter(kept).sort((a, b) => lastAt(b).localeCompare(lastAt(a)));
	const result = page(threads, offset, limit);
	return {
		...result,
		items: result.items.map((thread) => threadSummary(view, thread))
	};
}
/**
* Thread timeline with triggers ordered oldest-first, inline decisions, and subscribed tickets.
* `before` pages backward; `around` anchors the page on a specific trigger.
*/
function threadDetail(host, key, before, limit, around) {
	const { store } = host;
	const thread = store.threads.get(key);
	if (!thread) return void 0;
	const view = snapshot(host);
	const target = around ? store.triggers.get(around) : void 0;
	const [at = "", id = ""] = before?.split("|") ?? [];
	const triggers = target ? store.read.threadTriggers(key, limit + 1, target, true) : store.read.threadTriggers(key, limit + 1, before ? {
		at,
		id
	} : void 0);
	const decisions = store.decisions.byThread(key);
	const more = triggers.length > limit;
	const shown = more ? triggers.slice(1) : triggers;
	const first = store.read.firstTrigger(key);
	const url = attribute(thread.meta.url) ?? first?.url ?? (first?.channel ? channelLink(view, first.channel).url : void 0);
	return {
		...threadSummary(view, thread),
		url,
		context: thread.context ?? [],
		correlated: thread.correlated.map((other) => {
			const value = store.threads.get(other);
			return {
				key: other,
				title: value ? threadTitle(store, value) : other
			};
		}),
		tickets: thread.subscriptions.flatMap((id) => {
			const ticket = store.tickets.get(id);
			return ticket ? [ticketLine(view, ticket)] : [];
		}),
		decisions: decisions.slice().reverse().map((decision) => decisionView(view, decision)),
		timeline: shown.map((trigger) => triggerView(view, trigger, decisions)),
		earlier: more ? `${shown[0].at}|${shown[0].id}` : null
	};
}
/**
* Searches triggers, threads, and tickets by text, ID, source-extracted references (e.g., `#N`, URLs), or cached Feishu AppLinks.
* @param links - Feishu message AppLinks cached since startup, keyed by chat and message ID.
*/
function search(host, query, links) {
	const { store, sources } = host;
	const value = query.trim();
	if (!value) return {
		tickets: [],
		items: [],
		threads: []
	};
	const view = snapshot(host);
	const named = sources.find(value);
	const terms = /* @__PURE__ */ new Set([value, ...named.terms]);
	for (const [name, url] of links.entries()) if (url === value) terms.add(name.split(":").at(-1));
	const found = /* @__PURE__ */ new Map();
	for (const term of terms) for (const trigger of store.read.search(term)) found.set(trigger.id, trigger);
	const threads = named.threads.flatMap((key) => {
		const thread = store.threads.get(key);
		return thread ? [threadSummary(view, thread)] : [];
	});
	const lower = value.toLowerCase();
	const reaches = (ticket) => [...(ticket.follows ?? []).map((follow) => follow.thread), ...view.threadsOf(ticket.id).map((thread) => thread.key)];
	const matches = (ticket) => reaches(ticket).some((key) => named.threads.includes(key)) || ticket.title.toLowerCase().includes(lower);
	const tickets = store.tickets.list().filter(matches).sort(newestFirst).slice(0, 10).map(ticketSummary);
	const shownThreads = new Set(threads.map((thread) => thread.key));
	const item = (trigger) => {
		const home = store.threads.get(threadKey(trigger.threads[0]));
		const { text: _text, ...row } = triggerView(view, trigger);
		const filtered = home ? {} : { filtered: store.triggers.disposition(trigger.id)?.filtered ?? "" };
		return {
			...row,
			threadTitle: home ? threadTitle(store, home) : void 0,
			...filtered
		};
	};
	return {
		tickets,
		items: [...found.values()].filter((trigger) => trigger.human || !shownThreads.has(threadKey(trigger.threads[0]))).sort((a, b) => b.at.localeCompare(a.at)).slice(0, 20).map(item),
		threads
	};
}
function decisionList(host, kinds, offset, limit, since = "") {
	const { items, more } = host.store.read.decisions({
		kinds,
		since
	}, offset, limit);
	const view = snapshot(host);
	return {
		items: items.map((decision) => decisionView(view, decision)),
		next_offset: more ? offset + limit : null
	};
}
//#endregion
//#region src/app/http.ts
/**
* Represents a client-facing 400 or 404 error raised during management route parsing or lookup.
* Route handlers throw it when request bodies are malformed or target records are missing, and registerHttp serializes its status and message in the HTTP response.
*/
var RouteError = class extends Error {
	status;
	constructor(status, message) {
		super(message);
		this.status = status;
	}
};
async function readBody(req, maxBytes = 131072) {
	let size = 0;
	const chunks = [];
	for await (const chunk of req) {
		const bytes = Buffer.from(chunk);
		size += bytes.length;
		if (size > maxBytes) throw new RouteError(400, `Request exceeds ${maxBytes} bytes`);
		chunks.push(bytes);
	}
	try {
		return JSON.parse(Buffer.concat(chunks).toString("utf8"));
	} catch {
		throw new RouteError(400, "The request body is not JSON");
	}
}
function json(res, status, value) {
	res.writeHead(status, {
		"content-type": "application/json; charset=utf-8",
		"cache-control": "no-store",
		"x-content-type-options": "nosniff"
	});
	res.end(JSON.stringify(value));
}
function sameOrigin(req, port) {
	const host = req.headers.host;
	if (host !== `127.0.0.1:${port}` && host !== `localhost:${port}`) return false;
	return req.headers["x-orchestrator-request"] === "1" && (req.headers.origin === void 0 || req.headers.origin === `http://${host}`);
}
/** Maps errors to HTTP status codes and structured payloads that the panel localizes in the interface language. */
function failure(error) {
	if (error instanceof z.ZodError) {
		const issues = error.issues.map((issue) => ({
			path: issue.path.join("."),
			message: issue.message
		}));
		return [400, {
			error: `Invalid settings: ${issues.map((issue) => issue.path).join(", ")}`,
			issues
		}];
	}
	if (error instanceof SetupError) return [400, {
		error: error.message,
		setup: error.problem
	}];
	if (error instanceof RouteError) return [error.status, { error: error.message }];
	if (error instanceof UserError) return [error.missing ? 404 : 400, {
		error: error.message,
		code: error.code,
		values: error.values
	}];
	if (error instanceof SettingsConflict || error instanceof PromptConflict) return [409, { error: error.message }];
	return [500, { error: error instanceof Error ? error.message : String(error) }];
}
function machineView({ stateDir, promptMaxChars, admissionContextMaxPages, admissionContextTimeoutMs }) {
	return {
		stateDir,
		promptMaxChars: promptMaxChars.get(),
		admissionContextMaxPages: admissionContextMaxPages.get(),
		admissionContextTimeoutMs: admissionContextTimeoutMs.get()
	};
}
function setupView(runtime) {
	const resolved = runtime.configured() ? runtime.deployment : void 0;
	return {
		machine: machineView(runtime.machine),
		problem: runtime.setupProblem ?? null,
		feishuProblem: runtime.feishuProblem ?? null,
		accounts: resolved ? {
			repository: resolved.repository,
			agent: resolved.github.login,
			feishu: resolved.feishu ? {
				appId: resolved.feishu.appId,
				brand: resolved.feishu.brand,
				botId: resolved.feishu.botId,
				name: resolved.feishu.name
			} : null
		} : null
	};
}
/** Build the `/orchestrator/api/state` response consumed by the management panel and `scripts/dsh-superagent status` (`docs/006-deployment.md`). */
function stateView(runtime) {
	const settings = runtime.store.settings();
	return {
		setup: setupView(runtime),
		load: {
			...executorLoad(runtime.store, runtime.executor.activeCount()),
			maxWorkers: settings.executor.maxWorkers
		},
		masterId: runtime.masterId,
		paused: settings.paused,
		health: runtime.health
	};
}
const views = (runtime) => ({
	store: runtime.store,
	sources: runtime.sources,
	links: runtime.links()
});
const setupState = (runtime) => ({
	deployment: runtime.configured() ? runtime.deployment : void 0,
	problem: runtime.setupProblem,
	feishuProblem: runtime.feishuProblem
});
/** Builds a ticket's detail view; `environment` is empty while waiting for setup because it requires the resolved deployment. */
function ticketPage(runtime, id) {
	const detail = ticketDetail(views(runtime), id), ticket = runtime.store.tickets.get(id);
	if (!detail || !ticket) throw new RouteError(404, "Ticket not found");
	return {
		...detail,
		environment: runtime.configured() ? runtime.ticketEnvironment(ticket) : []
	};
}
function promptsView(runtime, revision, offset) {
	const current = runtime.prompts.current();
	const shown = revision === void 0 || revision === current.revision ? current : runtime.prompts.version(revision);
	const parts = Object.entries(builtInParts()).map(([key, part]) => ({
		key,
		...part,
		base: builtInBase(part.text)
	}));
	return {
		masterId: runtime.masterId,
		current: shown,
		defaults: defaultPrompts(),
		sections: TEAM_SECTIONS,
		skillName: SKILL_NAME.source,
		builtin: Object.keys(sourceSkills),
		skillPrefix: SKILL_PREFIX,
		parts,
		defaultChanged: runtime.prompts.defaultChanged(shown.config),
		...runtime.sessions.status(),
		...runtime.prompts.history(offset)
	};
}
const offset = z.coerce.number().int().nonnegative().catch(0);
const limit = (fallback, max) => z.coerce.number().int().positive().catch(fallback).transform((value) => Math.min(max, value));
const TicketsQuery = z.object({
	state: z.enum(TICKET_FILTERS).catch("open"),
	offset,
	limit: limit(20, 1e3)
});
const ThreadsQuery = z.object({
	filter: z.enum(THREAD_FILTERS).catch("subscribed"),
	offset,
	limit: limit(20, 1e3)
});
const ThreadQuery = z.object({
	limit: limit(50, 100),
	before: z.string().optional(),
	around: z.string().optional()
});
const DecisionsQuery = z.object({
	kind: z.string().default(""),
	window: z.literal("24h").optional().catch(void 0),
	offset,
	limit: limit(30, 200)
});
const count = z.coerce.number().int().nonnegative();
const PromptsQuery = z.object({
	revision: count.optional(),
	offset: count.default(0)
});
const SourceBlock = z.templateLiteral(["source:", z.string().regex(/^[a-z][a-z0-9-]*$/)]);
const SettingsBlockSchema = z.union([z.enum([
	"policy",
	"eval",
	"executor"
]), SourceBlock]);
const SaveRequest = z.object({
	value: z.unknown(),
	revision: z.number().int().nonnegative()
});
function routes(runtime) {
	const { store } = runtime;
	const ticket = (id) => {
		if (!store.tickets.get(id)) throw new RouteError(404, "Ticket not found");
		return id;
	};
	const promptBody = (input) => input.body(4 * runtime.machine.promptMaxChars.get() + 4096);
	return {
		"GET state": () => stateView(runtime),
		"GET overview": () => overview(views(runtime), runtime.health, policyVersion(store.settings()), executorLoad(store, runtime.executor.activeCount()), runtime.setupProblem ?? runtime.feishuProblem),
		"GET search": ({ query }) => search(views(runtime), query.q ?? "", runtime.sourceLinks),
		"GET sources": () => sourcesStatus(views(runtime), runtime.health, setupState(runtime)),
		"GET settings": () => settingsView(store, runtime.sources, runtime.health, setupState(runtime), runtime.machine.stateDir),
		"POST sources/:id/labels": ({ params }) => runtime.settings.refreshLabels(params.id),
		"GET threads": ({ query }) => {
			const { filter, offset, limit } = ThreadsQuery.parse(query);
			return threadList(views(runtime), filter, offset, limit);
		},
		"GET threads/:key": ({ params, query }) => {
			const { limit, before, around } = ThreadQuery.parse(query);
			const detail = threadDetail(views(runtime), params.key, before, limit, around);
			if (!detail) throw new RouteError(404, "Thread not found");
			return detail;
		},
		"POST threads/:key/unsubscribe": async ({ params }) => {
			return {
				removed: runtime.engine.unsubscribe(params.key),
				thread: params.key,
				context_delivery: await runtime.sessions.delivery(`subscription:${params.key}`)
			};
		},
		"POST triggers/:id/requeue": ({ params }) => {
			const queued = runtime.engine.reevaluate(params.id);
			runtime.requestPass();
			return { queued };
		},
		"GET decisions": ({ query }) => {
			const { kind, window, offset, limit } = DecisionsQuery.parse(query);
			const since = window ? (/* @__PURE__ */ new Date(Date.now() - 864e5)).toISOString() : "";
			return decisionList(views(runtime), kind.split(",").filter(Boolean), offset, limit, since);
		},
		"POST decisions/:id/dismiss": ({ params }) => {
			runtime.engine.dismiss(params.id);
			return { dismissed: true };
		},
		"GET tickets": ({ query }) => {
			const { state, offset, limit } = TicketsQuery.parse(query);
			return ticketList(views(runtime), state, offset, limit);
		},
		"GET tickets/:id": ({ params }) => ticketPage(runtime, params.id),
		"POST tickets/:id/retry": ({ params }) => {
			const id = ticket(params.id);
			runtime.engine.retryTicket(id);
			return { retried: true };
		},
		"POST tickets/:id/stop": ({ params }) => {
			const id = ticket(params.id);
			runtime.engine.stopTicket(id);
			return { stopped: true };
		},
		"POST executor/pause": async ({ body }) => runtime.settings.pause(z.object({ paused: z.boolean() }).parse(await body()).paused, "panel"),
		"PUT settings/:block": async ({ params, body }) => {
			const block = SettingsBlockSchema.parse(params.block);
			if (!(!block.startsWith("source:") || runtime.sources.instances().some((instance) => `source:${instance.id}` === block))) throw new RouteError(404, "Source not found");
			const request = SaveRequest.parse(await body());
			return runtime.settings.save(block, request.value, request.revision, "panel");
		},
		"GET policy/history": () => policyHistory(store, runtime.sources, policyVersion(store.settings())),
		"POST policy-sync/:id": async ({ params }) => ({ policy: await runtime.settings.sync(params.id) }),
		"POST setup/check": () => {
			runtime.checkSetup();
			return { restarting: true };
		},
		"GET models": () => runtime.models(),
		"GET prompts": ({ query }) => {
			const { revision, offset } = PromptsQuery.parse(query);
			return promptsView(runtime, revision, offset);
		},
		"PUT prompts": async (input) => {
			const request = z.object({
				config: z.unknown(),
				baseRevision: z.number().int().nonnegative()
			}).parse(await promptBody(input));
			return savePrompts(runtime, request.config, request.baseRevision, "panel");
		},
		"POST prompts/preview": async (input) => runtime.prompts.preview(await promptBody(input))
	};
}
function decoded(segment) {
	try {
		return decodeURIComponent(segment);
	} catch {
		throw new RouteError(400, "A path segment has a malformed escape");
	}
}
function match(table, method, segments) {
	for (const [route, run] of Object.entries(table)) {
		const [verb, path] = route.split(" ");
		const pattern = path.split("/");
		const fits = pattern.length === segments.length && pattern.every((part, index) => part.startsWith(":") || part === segments[index]);
		if (verb !== method || !fits) continue;
		const params = {};
		pattern.forEach((part, index) => {
			if (part.startsWith(":")) params[part.slice(1)] = decoded(segments[index]);
		});
		return {
			run,
			params
		};
	}
}
function registerHttp(ctx, runtime) {
	if (ctx.webServer.host !== "127.0.0.1") throw new Error("Orchestrator management requires a loopback Web server");
	const table = routes(runtime);
	const disposers = [ctx.webServer.register({
		kind: "prefix",
		path: "/orchestrator",
		handler: async (req, res) => {
			const url = new URL(req.url ?? "/", "http://localhost");
			if (!url.pathname.startsWith("/orchestrator/api/")) {
				res.writeHead(404);
				res.end();
				return;
			}
			if (!sameOrigin(req, ctx.webServer.port)) {
				json(res, 403, { error: "Same-origin management request required" });
				return;
			}
			try {
				await runtime.ready;
				const route = match(table, req.method ?? "GET", url.pathname.slice(18).split("/"));
				if (!route) throw new RouteError(404, "Unknown operation");
				const query = Object.fromEntries(url.searchParams);
				json(res, 200, await route.run({
					params: route.params,
					query,
					body: (maxBytes) => readBody(req, maxBytes)
				}));
			} catch (error) {
				json(res, ...failure(error));
			}
		}
	})];
	return () => {
		for (const dispose of disposers) dispose();
	};
}
//#endregion
//#region src/app/outbox.ts
/**
* Persists outbound channel messages as receipts and delivers them sequentially through `Effects` and `SourceRegistry`.
* Implements the core `Outbox` port for `Engine` and source contexts, ensuring per-conversation ordering for each ticket until an earlier message fails repeatedly.
* Messages wait while processing is paused or their source is unavailable, and settle as dropped when the target conversation is ignored or gone.
*/
var Outbox = class {
	host;
	constructor(host) {
		this.host = host;
		host.effects.handle("reply", (_payload, id) => this.deliver(id), {
			limit: () => host.paused() ? 0 : 1,
			retry: [5e3, 3e5]
		});
	}
	/** Record a message receipt and enqueue its delivery effect atomically; duplicate message IDs are ignored. */
	send(message) {
		if (message.kind === "reply" && message.channel.source === "feishu") checkedImText(message.text);
		const { store, effects } = this.host;
		store.atomic(() => {
			if (store.receipts.add(message)) effects.enqueue("reply", message.id, {});
		});
	}
	status(id) {
		return this.host.store.receipts.get(id)?.status;
	}
	withdraw(id) {
		const { store, effects } = this.host;
		store.atomic(() => {
			if (store.receipts.withdraw(id)) effects.cancel("reply", id);
		});
	}
	sent() {
		return this.host.effects.idle("reply");
	}
	async deliver(id) {
		const { store, sources, commands } = this.host;
		const receipt = store.receipts.get(id);
		if (receipt?.status !== "pending") return;
		if (!sources.instance(receipt.channel.source)?.enabled) throw new Later("The Source is off or not installed");
		if (store.receipts.behind(id, 3)) throw new Later("An earlier message of this ticket to this conversation waits");
		if (!sources.channelAllowed(receipt.channel)) {
			store.receipts.settle(receipt, "channelIgnored");
			return;
		}
		const result = await sources.send(receipt, commands);
		if (result === "waiting") throw new Later("The Source is not installed");
		store.receipts.settle(receipt, result === "gone" ? "channelGone" : "sent");
	}
};
//#endregion
//#region src/app/passes.ts
const now$1 = () => (/* @__PURE__ */ new Date()).toISOString();
/**
* Schedules and serializes orchestration passes that kick due `Effects` and advance `Engine` evaluations.
* `Runtime` manages its lifecycle, while sources, tools, `Settings`, and HTTP routes trigger immediate passes when new work arrives or state changes.
* Updates the runtime `HealthEntry` when a pass fails and clears the error once a subsequent pass succeeds.
*/
var Passes = class {
	host;
	timer;
	stopped = false;
	pumping;
	pumpAgain;
	constructor(host) {
		this.host = host;
	}
	start() {
		if (!this.stopped) this.timer = setInterval(() => {
			this.request();
		}, 2e3);
	}
	stop() {
		this.stopped = true;
		clearInterval(this.timer);
		return Promise.allSettled([this.pumping, this.pumpAgain]);
	}
	receive(trigger) {
		if (this.host.closing()) throw new Error("Orchestrator is stopping");
		const result = this.host.engine.receive(trigger);
		if (result === "stored") this.request();
		return result;
	}
	request() {
		const { health } = this.host;
		this.pump().then(() => {
			if (health.get()?.state !== "error" || this.host.lifetime.aborted) return;
			health.set({
				state: "ready",
				detail: "Orchestrator is ready",
				at: now$1()
			});
		}, (error) => {
			health.set({
				state: "error",
				detail: `A pass failed: ${String(error)}`,
				at: now$1()
			});
		});
	}
	/** Wait until no pass or effect that can start now is running. */
	async idle() {
		for (;;) {
			await Promise.allSettled([this.pumping, this.pumpAgain]);
			await this.host.effects.idle();
			if (!this.pumping && !this.pumpAgain) return;
		}
	}
	/** Run one pass, coalescing concurrent callers into a single follow-up pass. */
	async pump() {
		if (!this.host.configured() || this.host.closing()) return;
		if (!this.pumping) return this.pumping = this.pumpOnce().finally(() => {
			this.pumping = void 0;
		});
		const next = () => {
			this.pumpAgain = void 0;
			return this.pump();
		};
		return this.pumpAgain ??= this.pumping.then(next, next);
	}
	async pumpOnce() {
		this.host.effects.kick();
		if (this.host.closing()) return;
		this.host.engine.evaluateDue();
	}
};
//#endregion
//#region \0@oxc-project+runtime@0.148.0/helpers/esm/usingCtx.js
function _usingCtx() {
	var r = "function" == typeof SuppressedError ? SuppressedError : function(r, e) {
		var n = Error();
		return n.name = "SuppressedError", n.error = r, n.suppressed = e, n;
	}, e = {}, n = [];
	function using(r, e) {
		if (null != e) {
			if (Object(e) !== e) throw new TypeError("using declarations can only be used with objects, functions, null, or undefined.");
			if (r) var o = e[Symbol.asyncDispose || Symbol["for"]("Symbol.asyncDispose")];
			if (void 0 === o && (o = e[Symbol.dispose || Symbol["for"]("Symbol.dispose")], r)) var t = o;
			if ("function" != typeof o) throw new TypeError("Object is not disposable.");
			t && (o = function o() {
				try {
					t.call(e);
				} catch (r) {
					return Promise.reject(r);
				}
			}), n.push({
				v: e,
				d: o,
				a: r
			});
		} else r && n.push({
			d: e,
			a: r
		});
		return e;
	}
	return {
		e,
		u: using.bind(null, !1),
		a: using.bind(null, !0),
		d: function d() {
			var o, t = this.e, s = 0;
			function next() {
				for (; o = n.pop();) try {
					if (!o.a && 1 === s) return s = 0, n.push(o), Promise.resolve().then(next);
					if (o.d) {
						var r = o.d.call(o.v);
						if (o.a) return s |= 2, Promise.resolve(r).then(next, err);
					} else s |= 1;
				} catch (r) {
					return err(r);
				}
				if (1 === s) return t !== e ? Promise.reject(t) : Promise.resolve();
				if (t !== e) throw t;
			}
			function err(n) {
				return t = t !== e ? new r(n, t) : n, next();
			}
			return next();
		}
	};
}
//#endregion
//#region src/app/delivery.ts
/** The id of the message delivered under `requestId`, the same on every retry. */
const messageId = (requestId) => MessageId(`dsh-superagent:${requestId}`);
/** Extracts the idempotency key from current or legacy plugin message sources. */
function deliveryId(message) {
	const source = message.source;
	if (source.kind === "dsh-superagent" || source.kind === "plugin" && source.plugin === "dsh-superagent") return message.id;
	if (source.kind === "user" && "rpcId" in source && typeof source.rpcId === "string") return messageId(source.rpcId);
}
/**
* Delivers messages to DSH agents at most once per request ID across active and restored Sessions.
* Tracks delivered message IDs from live Session events, persisted history, and pending inboxes so retries from `Sessions` do not duplicate messages,
* and marks delivered messages with `dsh-superagent`'s own source (`dsh-superagent`) rather than user RPCs so they are never mistaken for messages written by a person.
*/
var AgentDelivery = class {
	ctx;
	seen = /* @__PURE__ */ new WeakMap();
	constructor(ctx) {
		this.ctx = ctx;
		ctx.on("session/event", (session, event) => {
			if (event.type !== "user/message") return;
			const id = deliveryId(event.data);
			if (id) this.seen.get(session)?.ids.add(id);
		});
	}
	async history(agent) {
		let seen = this.seen.get(agent.session);
		if (!seen) {
			seen = { ids: /* @__PURE__ */ new Set() };
			this.seen.set(agent.session, seen);
		}
		const state = seen;
		state.loaded ??= (async () => {
			try {
				var _usingCtx$1 = _usingCtx();
				await this.ctx.sessionPersistence.flush();
				const handle = _usingCtx$1.a(await this.ctx.sessionPersistence.open(agent.id, "read"));
				for (let offset = 0;;) {
					const { events } = await handle.read(offset, 512);
					if (!events.length) break;
					for (const event of events) {
						if (event.type !== "user/message") continue;
						const id = deliveryId(event.data);
						if (id) state.ids.add(id);
					}
					offset += events.length;
				}
			} catch (_) {
				_usingCtx$1.e = _;
			} finally {
				await _usingCtx$1.d();
			}
		})().catch((error) => {
			state.loaded = void 0;
			throw error;
		});
		await state.loaded;
		return state;
	}
	async holds(agent, requestId) {
		const id = messageId(requestId);
		return (await this.history(agent)).ids.has(id) || [...agent.inbox.nextTurn, ...agent.inbox.nextStep].some((message) => deliveryId(message) === id);
	}
	/** Delivers once to the selected inbox, or injects into history without waking the agent, and flushes Session persistence before acknowledging the producer. */
	async send(agent, requestId, text, mode, signal, authorize, accepted) {
		signal.throwIfAborted();
		const seen = await this.history(agent);
		signal.throwIfAborted();
		if (this.ctx.agents.get(agent.id) !== agent) throw new Error("Delivery target was disposed");
		authorize?.();
		const id = messageId(requestId);
		const pending = [...agent.inbox.nextTurn, ...agent.inbox.nextStep].some((message) => deliveryId(message) === id);
		if (!seen.ids.has(id) && !pending) {
			const source = typeof mode === "object" ? {
				kind: "dsh-superagent",
				form: "notice",
				summary: mode.inject
			} : {
				kind: "dsh-superagent",
				form: "relay"
			};
			const message = freezeMessage({
				id,
				role: "user",
				content: [{
					type: "text",
					text
				}],
				source
			});
			if (typeof mode === "object") {
				agent.inject(message);
				seen.ids.add(id);
			} else if (mode === "steer") agent.steer(message);
			else agent.followup(message);
		}
		accepted?.();
		await this.ctx.sessionPersistence.flush();
	}
};
//#endregion
//#region src/app/retry-health.ts
const record = (value) => value !== null && typeof value === "object" && !Array.isArray(value) ? value : void 0;
const ordinal = (value) => typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
/** Identify model budget exhaustion from structured failure metadata without inspecting assistant message content. */
function budgetFailure(value) {
	const failure = record(value);
	if (!failure) return false;
	if ([
		401,
		403,
		429
	].includes(Number(failure.status)) || typeof failure.code === "string" && /AUTH|RATE_LIMIT|CONTEXT|TOKEN_LIMIT/i.test(failure.code)) return false;
	if (failure.type === "budget_exceeded" || failure.code === "budget_exceeded") return true;
	if (typeof failure.message !== "string") return false;
	const message = failure.message.slice(0, 8192);
	try {
		const body = record(JSON.parse(message.slice(message.indexOf("{"))));
		const error = record(body?.error) ?? body;
		if (error?.type === "budget_exceeded" || error?.code === "budget_exceeded") return true;
	} catch {}
	return /\bBudget has been exceeded(?:!|[.:]|$)/i.test(message);
}
/**
* Tracks which managed sessions are currently blocked on model budget retries by observing session lifecycle and retry events.
* `Sessions` feeds session events into it and mirrors the aggregated retry state into the `models` health entry, while `resources` and views attach per-session retry status to ticket cards.
*/
var RetryHealth = class {
	sessions = /* @__PURE__ */ new Map();
	/** Replay an ordered native event snapshot; the caller must clear idle or disposed agents afterwards. */
	restore(sessionId, events) {
		this.sessions.delete(sessionId);
		for (const event of events) this.observe(sessionId, event);
	}
	/** Clear active retry status while preserving the sequence watermark against out-of-order events. */
	clear(sessionId) {
		const state = this.sessions.get(sessionId);
		if (state) {
			state.active = void 0;
			state.settled = true;
		}
	}
	get(sessionId) {
		const status = this.sessions.get(sessionId)?.active?.status;
		return status ? { ...status } : void 0;
	}
	list() {
		return [...this.sessions.values()].flatMap((state) => state.active ? [{ ...state.active.status }] : []);
	}
	observe(sessionId, event) {
		if (!ordinal(event.seq) || !Number.isFinite(event.time) || event.time < 0 || event.time > 864e13) return;
		let state = this.sessions.get(sessionId);
		if (!state) {
			state = {
				seq: -1,
				turn: -1,
				step: -1,
				ended: false,
				settled: false
			};
			this.sessions.set(sessionId, state);
		}
		if (event.seq <= state.seq) return;
		state.seq = event.seq;
		const data = record(event.data);
		if (!data) return;
		if (event.type === "turn/start" || event.type === "turn/end") {
			if (!ordinal(data.turn) || data.turn < state.turn) return;
			if (data.turn > state.turn) Object.assign(state, {
				turn: data.turn,
				step: -1,
				ended: false,
				settled: false,
				active: void 0
			});
			if (event.type === "turn/end") {
				state.active = void 0;
				state.ended = true;
			}
			return;
		}
		if (event.type === "llm/retry-started") return;
		if (![
			"step/start",
			"llm/retry",
			"assistant/message"
		].includes(event.type)) return;
		if (!ordinal(data.turn) || !ordinal(data.step)) return;
		if (data.turn < state.turn || data.turn === state.turn && (state.ended || data.step < state.step)) return;
		if (event.type === "assistant/message") {
			const source = record(record(data.message)?.source);
			if (state.active && data.turn === state.turn && data.step === state.step && data.interrupted !== true && source?.kind === "model" && source.provider === state.active.provider) {
				state.active = void 0;
				state.settled = true;
			}
			return;
		}
		if (data.turn > state.turn || data.step > state.step) Object.assign(state, {
			turn: data.turn,
			step: data.step,
			ended: false,
			settled: false,
			active: void 0
		});
		if (event.type === "step/start" || state.settled) return;
		if (typeof data.retryId !== "string" || !data.retryId || typeof data.provider !== "string" || typeof data.retry !== "number" || !Number.isInteger(data.retry) || data.retry < 1) return;
		if (!budgetFailure(data.failure)) {
			state.active = void 0;
			return;
		}
		const attempts = Math.min(data.retry, Number.MAX_SAFE_INTEGER);
		const previous = state.active?.id === data.retryId && state.active.provider === data.provider ? state.active.status : void 0;
		if (previous && attempts <= previous.attempts) return;
		const at = new Date(event.time).toISOString();
		state.active = {
			id: data.retryId,
			provider: data.provider,
			status: {
				sessionId,
				provider: /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$/.test(data.provider) ? data.provider : "unknown",
				attempts,
				since: previous?.since ?? at,
				lastAt: at
			}
		};
	}
};
//#endregion
//#region src/app/sessions.ts
/** The agent presets Executor Sessions and the main Session are created with, which the bundle's patch defines. */
const WORKER_PRESET = "dsh-superagent-worker";
const ROUTER_PRESET = "dsh-superagent-router";
/**
* The DSH tools an Executor Session works with: files, search, the shell and its jobs, the web, skills, its todo list and
* subagents. It gets no other tool the profile has, whenever it was registered: none that asks or shows a person something,
* changes the profile, schedules work or starts goals outside the worker slots, the pause and a person's hold, starts or
* messages other Sessions, or edits documents.
*/
const WORK_TOOLS = [
	"read",
	"write",
	"edit",
	"read_image",
	"glob",
	"grep",
	"bash",
	"pwsh",
	"job_output",
	"job_list",
	"job_kill",
	"web_search",
	"web_fetch",
	"skill",
	"todo_write",
	"subagent",
	"list_subagent_models",
	"send_message",
	"list_agents",
	"interrupt_agent"
];
/** What the main Session is told when it would wait: what it waits for comes to it, and a waiting step holds back the next. */
const NO_WAIT = "Reports, follow_up notices, new candidates and a background job's end with its output arrive by themselves as messages; end the turn instead of waiting for them.";
/** What a main Session under `standard` is told when its command would wait the shell's default. */
const DEFAULT_WAIT = "This shell waits up to 60 seconds by default: pass timeoutMs of at most 30000, or run_in_background, as a waiting step holds back new candidates.";
/** `sleep` at a command position: the start, after ; & | ( { ! ` or a newline, or after a keyword or a command that runs it. */
const SLEEP = /(?:^|[;&|({!`\n]|\b(?:do|then|else|elif|if|while|until|time|exec|nohup|command|env)\s)\s*(?:\S*\/)?sleep\b/;
/**
* The main Session's guard: it refuses a bash command that runs sleep or asks to hold the step longer than 30 seconds, and a
* job wait longer than 5 seconds. Under `standard`, as a main Session created before the router preset runs, the shell holds
* a command 60 seconds and a job wait lasts 30 seconds by default, so a command needs a timeout or the background, and a
* job wait its timeout; the router preset ends both after 5 seconds.
*/
function noWait({ name, arguments: input }, routed) {
	const args = input ?? {};
	if (name === "bash") {
		if (typeof args.command === "string" && SLEEP.test(args.command) || typeof args.timeoutMs === "number" && args.timeoutMs > 3e4) return NO_WAIT;
		if (args.timeoutMs === void 0 && args.run_in_background !== true && !routed()) return DEFAULT_WAIT;
	}
	if (name === "job_output" && args.wait === true && (typeof args.timeout_ms === "number" ? args.timeout_ms > 5e3 : !routed())) return NO_WAIT;
}
/**
* Creates and decorates orchestrator and worker DSH `Agent` sessions with role models, system prompt sections from `Prompts`, runtime skills, and restricted tool sets.
* `Runtime`, `DshExecutor`, `MasterAssessor`, `Settings`, and management routes/tools use it to ensure sessions, deliver deduplicated messages via `AgentDelivery`, and process ordered `relay` and `notice` effects.
* Feeds session events into `RetryHealth` to report model budget waits on the `models` `HealthEntry`, and durably records which prompt revisions each session has worked under in `Store` (`KV.sessions.prompts`) to authorize prompt version reads.
*/
var Sessions = class {
	host;
	agentDelivery;
	/** Decorated agents mapped to their registered disposers and skill scope until the agent is disposed or `Sessions.dispose()` runs. */
	bindings = /* @__PURE__ */ new Map();
	retryHealth = new RetryHealth();
	ctx;
	/** Registers ordered `relay` and `notice` effect handlers that deliver to the main Session. */
	constructor(host) {
		this.host = host;
		this.ctx = host.context;
		this.agentDelivery = new AgentDelivery(host.context);
		host.effects.handle("relay", ({ text }, requestId) => this.prompt(host.masterId, requestId, text, "steer"), { ordered: true });
		host.effects.handle("notice", ({ value, summary }, name) => this.inject(name, value, summary), { ordered: true });
	}
	/** Subscribes to host agent and session events so newly created sessions are decorated and model-budget retries are reflected in health. Call once at startup. */
	install() {
		const ctx = this.ctx;
		ctx.on("agent/disposed", ({ agent }) => {
			this.release(agent);
			this.retryHealth.clear(agent.id);
			this.updateModelHealth();
		});
		ctx.on("session/event", (session, event) => {
			const agent = ctx.agents.get(session.id);
			const binding = agent && agent.session === session ? this.bindings.get(agent) : void 0;
			if (!agent || !binding || binding.subagent) return;
			this.retryHealth.observe(agent.id, event);
			this.updateModelHealth();
		});
		ctx.on("agent/created", async ({ agent }) => {
			await this.decorate(agent);
		});
		ctx.inject(["agentPresets"], (child) => {
			child.on("agent-preset/selected", (sessionId, preset) => {
				const ticketId = ticketOfSession(sessionId), agent = ctx.agents.get(sessionId);
				const ours = sessionId === this.host.masterId ? ROUTER_PRESET : ticketId && this.host.store.tickets.get(ticketId) ? WORKER_PRESET : void 0;
				if (!ours || preset === ours || !agent) return;
				child.get("agentPresets").select(agent, ours).catch(() => {});
			});
		});
		ctx.on("agent/status", ({ agent, status }) => {
			if (status === "idle" && !this.host.closing()) {
				this.retryHealth.clear(agent.id);
				this.updateModelHealth();
			}
		});
	}
	/** Resolves or creates session `id` in workspace `cwd`, initializes its role model, decorates it with prompts/skills/tools, sets `danger-full-access` permissions, and renames it to `title`. */
	async ensure(id, cwd, title, role) {
		const ctx = this.ctx;
		let result = await ctx.sessionController.resolveAgent(id);
		if ("error" in result && result.error.code === "session/not-found") {
			const workspace = await ctx.workspaceRegistry.create(cwd);
			await ctx.sessionController.create({
				sessionId: id,
				workspaceId: workspace.id,
				agentPreset: role === "worker" ? WORKER_PRESET : ROUTER_PRESET
			});
			result = await ctx.sessionController.resolveAgent(id);
		}
		if ("error" in result) throw result.error;
		const settings = this.host.store.settings();
		await initializeRoleModel(ctx, result.agent, role === "orchestrator" ? settings.eval.model : settings.executor.model);
		await this.decorate(result.agent);
		ctx.permissionPresets.set(result.agent.session, "danger-full-access");
		await ctx.sessionController.rename({
			sessionId: id,
			title
		});
		return result.agent;
	}
	/** Returns whether `sessionId` already holds the message delivered under `requestId`, or `false` if the session does not exist. */
	async holds(sessionId, requestId) {
		const result = await this.ctx.sessionController.resolveAgent(sessionId);
		return !("error" in result) && await this.agentDelivery.holds(result.agent, key(requestId));
	}
	/** Deliver a message once per request id: to the next turn, the current one, or `inject`ed with its label without waking the agent. */
	async prompt(sessionId, requestId, text, mode, authorize, accepted) {
		const result = await this.ctx.sessionController.resolveAgent(sessionId);
		if ("error" in result) throw result.error;
		await this.agentDelivery.send(result.agent, key(requestId), text, mode, this.host.lifetime, authorize, accepted);
	}
	/** The id of the message `prompt` delivers under `requestId`, which DSH's inbox events name it by. */
	promptedId(requestId) {
		return messageId(key(requestId));
	}
	/** Enqueues a steering relay to the main Session; relays are durable and retried by `Effects` until delivered, at most once per `requestId`. */
	relay(requestId, text) {
		this.host.effects.enqueue("relay", requestId, { text });
	}
	/** Enqueues a durable background notice for injection into the main Session; a new notice with the same `name` replaces a still-waiting notice of that `name`. */
	notify(name, value, summary) {
		this.host.effects.enqueue("notice", name, {
			value,
			summary
		});
	}
	/** Waits for currently runnable `notice` effects to settle and returns `'injected'` if notice `name` has reached the main Session or `'pending'` if it is still queued. */
	async delivery(name) {
		await this.host.effects.idle("notice");
		return this.host.effects.pending("notice", name) ? "pending" : "injected";
	}
	/** Injects a notice into the main Session without waking it; no-op if the main Session does not exist yet. */
	async inject(name, value, summary) {
		const resolved = await this.ctx.sessionController.resolveAgent(this.host.masterId);
		if ("error" in resolved) return;
		const text = JSON.stringify(value);
		await this.agentDelivery.send(resolved.agent, `notice:${name}:${key(text)}`, text, { inject: summary }, this.host.lifetime);
	}
	/** Returns the current prompt revision, the active prompt revision of each loaded Session, and whether the main Session still has a pending `'prompts'` notice. */
	status() {
		const { store, prompts, effects } = this.host;
		const sessions = store.keys(KV.sessions.prompts).flatMap((name) => {
			const sessionId = name.slice(KV.sessions.prompts.prefix.length), revision = store.get(name)?.at(-1);
			return this.ctx.agents.get(sessionId) && revision !== void 0 ? [{
				sessionId,
				revision
			}] : [];
		});
		return {
			revision: prompts.current().revision,
			sessions,
			notificationPending: effects.pending("notice", "prompts")
		};
	}
	/** Returns the prompt version a Session runs under (the one bound on its latest model request, or the current version). */
	promptVersion(sessionId) {
		const revision = this.host.store.get(KV.sessions.prompts(sessionId))?.at(-1);
		return revision === void 0 ? this.host.prompts.current() : this.host.prompts.version(revision);
	}
	/** Whether a Session is authorized to read `revision` (its active revision or any revision it previously ran under). */
	mayRead(sessionId, revision) {
		return revision === this.promptVersion(sessionId).revision || (this.host.store.get(KV.sessions.prompts(sessionId)) ?? []).includes(revision);
	}
	/** Returns a tool registrar for `agent` that renders tool output as JSON text and attaches `output.image` as an image when present. */
	registerTool(agent, binding) {
		return (name, description, schema, execute) => {
			binding.disposers.push(agent.ctx.tools.register({
				name,
				description,
				parameters: z.toJSONSchema(schema),
				output: {
					schema: {
						type: "object",
						additionalProperties: true
					},
					render: (_args, value) => {
						const text = {
							type: "text",
							text: JSON.stringify(value)
						};
						const image = value && typeof value === "object" && "image" in value ? value.image : void 0;
						return image ? [text, {
							type: "image",
							attachment: image
						}] : [text];
					}
				},
				execute: (args, execution) => execute(schema.parse(args), execution.signal)
			}));
		};
	}
	/** Returns `sessionId`'s active model-budget retry state (`{ model_retry }`) for status listings, or `{}` when not waiting on one. */
	modelRetry(sessionId) {
		const retry = sessionId ? this.retryHealth.get(sessionId) : void 0;
		return retry ? { model_retry: retry } : {};
	}
	updateModelHealth() {
		const retries = this.retryHealth.list();
		this.host.health.set(retries.length ? {
			state: "error",
			detail: retries.slice(0, 5).map((item) => `${item.sessionId}: ${item.provider} is over its model budget; retried ${item.attempts} times, waiting since ${item.since}; the model and retry policy are unchanged`).join("; ") + (retries.length > 5 ? `; ${retries.length - 5} more Sessions` : ""),
			at: retries.at(-1).lastAt
		} : {
			state: "ready",
			detail: "No managed Session is waiting on a model budget retry"
		});
	}
	ticketOf(agent) {
		const ticketId = ticketOfSession(agent.id);
		return ticketId === void 0 ? void 0 : this.host.store.tickets.get(ticketId);
	}
	async decorate(agent) {
		if (this.bindings.has(agent)) return;
		const host = this.host;
		const master = agent.id === host.masterId;
		const ticket = master ? void 0 : this.ticketOf(agent);
		if (!master && !ticket) {
			this.limitSubagent(agent);
			return;
		}
		const binding = { disposers: [] };
		this.bindings.set(agent, binding);
		this.retryHealth.restore(agent.id, agent.session.snapshotEvents());
		if (agent.status === "idle") this.retryHealth.clear(agent.id);
		this.updateModelHealth();
		binding.disposers.push(agent.ctx.systemPrompt.section({
			name: "dsh-superagent-policy",
			order: 9999,
			interpolate: false,
			text: (context) => {
				const version = this.promptFor(agent, context.signal !== void 0);
				const current = ticket && host.store.tickets.get(ticket.id);
				const composed = host.prompts.compose(version.config, master ? "orchestrator" : "worker", current ? host.environment(current) : void 0);
				return `[dsh-superagent prompt revision ${version.revision}]\n${composed}\n${current ? mandateInstructions(current.mandate, host.store.settings().policy.rules) : ""}`;
			},
			...master ? { complete: true } : {}
		}));
		const skillScope = agent.ctx.inject(["skills"], (scope) => {
			binding.scope = scope;
			binding.skills = void 0;
			this.bindSkills(binding, host.prompts.current());
		});
		binding.disposers.push(() => {
			skillScope.dispose().catch((error) => {
				this.ctx.logger.warn("dsh-superagent could not release a skill scope: %s", String(error));
			});
		});
		await skillScope;
		if (this.bindings.get(agent) !== binding) return;
		const register = this.registerTool(agent, binding);
		for (const tool of host.tools(agent, ticket)) register(tool.name, tool.description, tool.schema, tool.execute);
		if (master) binding.disposers.push(agent.ctx.tools.restrict({ allow: [
			"skill",
			"bash",
			"read",
			"read_image",
			"job_output",
			"job_list",
			"job_kill"
		] }), agent.ctx.tools.guard((execution) => noWait(execution, () => this.routed(agent))));
		else binding.disposers.push(...this.workOnly(agent, ticket.id));
	}
	/**
	* Whether a Session runs the router preset: as DSH's preset registry last selected it, read through the session projection
	* on a DSH whose registry has no `presetForSession`, else as it was created; `standard`, the safer caps, when unreadable.
	*/
	routed(agent) {
		try {
			const presets = this.ctx.get("agentPresets");
			const projections = this.ctx.get("sessionProjections");
			return ((typeof presets?.presetForSession === "function" ? presets.presetForSession(agent.session) : projections?.stateOf?.(agent.session, "agentPreset")) ?? agent.session.header.agentPreset) === ROUTER_PRESET;
		} catch {
			return false;
		}
	}
	/**
	* An Executor Session's tools: only the profile's work tools, which DSH requires to be known, and none once its ticket
	* ended. A failed or blocked worker keeps its tools, so a person may continue it in its Session; only automated input waits
	* (see the executor). Read inherited tools through the parent scope, which includes the preset's tools. The global view
	* misses preset tools; the agent's own view also includes local tools such as subagent, which restrict refuses to name.
	*/
	workOnly(agent, ticketId) {
		const store = this.host.store;
		const parent = scopeParentOf(agent);
		const allow = WORK_TOOLS.filter((name) => agent.ctx.tools.get(name, parent));
		return [agent.ctx.tools.restrict({ allow }), agent.ctx.tools.guard(() => {
			const current = store.tickets.get(ticketId);
			return !current || !liveTicket(current) ? "Ticket ended; new work needs a new authorized ticket" : void 0;
		})];
	}
	/**
	* A subagent of an Executor Session, or of one of its subagents, which runs under DSH's `standard` preset with the worker's
	* permissions, gets the same work tools as the worker, and none once the worker's ticket ended. Any other agent is left as
	* it is.
	*/
	limitSubagent(agent) {
		let parent = agent.session.header.parentSession;
		for (let depth = 0; parent !== void 0 && ticketOfSession(parent) === void 0 && depth < 8; depth++) parent = this.ctx.agents.get(parent)?.session.header.parentSession;
		const ticketId = parent === void 0 ? void 0 : ticketOfSession(parent);
		if (ticketId === void 0 || !this.host.store.tickets.get(ticketId)) return;
		this.bindings.set(agent, {
			disposers: this.workOnly(agent, ticketId),
			subagent: true
		});
	}
	/** Register the skills of a prompt version in the agent's skill scope, in place of an earlier version's. */
	bindSkills(binding, version) {
		const { scope, skills: previous } = binding;
		if (!scope || previous?.revision === version.revision) return;
		previous?.dispose();
		const disposers = [];
		for (const [name, content] of this.host.prompts.skills(version.config)) {
			const bundled = name === "feishu" || name === "github" ? bundledSkills[name] : void 0;
			const body = version.config.skills[name] ?? "";
			const description = bundled?.description ?? (body.replace(/\s+/g, " ").slice(0, 120) || "Custom dsh-superagent operational skill.");
			disposers.push(scope.skills.register({
				name: `${SKILL_PREFIX}${name}`,
				description,
				content,
				source: "runtime",
				...bundled ? { resourceBase: {
					kind: "directory",
					path: dirname(bundled.path)
				} } : {}
			}));
		}
		binding.skills = {
			revision: version.revision,
			dispose: () => {
				disposers.forEach((dispose) => dispose());
			}
		};
	}
	/** Return the current prompt version, updating the agent's skills and recording the revision in Store when bound to a model request. */
	promptFor(agent, bind) {
		const version = this.host.prompts.current();
		if (!bind) return version;
		const binding = this.bindings.get(agent);
		if (binding) this.bindSkills(binding, version);
		const { store } = this.host;
		const revisions = store.get(KV.sessions.prompts(agent.id)) ?? [];
		const bound = [...revisions.filter((revision) => revision !== version.revision), version.revision];
		if (revisions.at(-1) !== version.revision) store.set(KV.sessions.prompts(agent.id), bound);
		return version;
	}
	/** Releases registrations for `agent` in reverse order (LIFO); disposing its skill scope releases its skills as well. */
	release(agent) {
		const binding = this.bindings.get(agent);
		if (!binding) return;
		this.bindings.delete(agent);
		binding.skills?.dispose();
		for (const dispose of binding.disposers.splice(0).reverse()) try {
			dispose();
		} catch (error) {
			this.ctx.logger.warn("dsh-superagent could not release what it registered for a Session: %s", String(error));
		}
	}
	/** Releases prompt sections, skills, and tools registered by `Sessions` across all decorated agents. */
	dispose() {
		for (const agent of [...this.bindings.keys()]) this.release(agent);
	}
};
//#endregion
//#region src/app/source-context.ts
/**
* Builds the context for one Source kind. Health reports are restricted to entries declared by the kind and
* bound to the active registration, becoming no-ops once unregistered.
*/
function sourceContextOf(deps, kind) {
	const { store } = deps;
	const health = deps.sources.healthEntries(kind.health);
	return {
		get deployment() {
			return deps.deployment;
		},
		commands: deps.commands,
		ready: deps.ready,
		configured: () => deps.configured(),
		get problem() {
			return [deps.feishuProblem, deps.setupProblem].find((problem) => problem?.place === kind.kind);
		},
		config: (id) => {
			const instance = deps.sources.instance(id);
			return instance?.enabled ? instance.config : void 0;
		},
		receive: (trigger) => deps.receive(trigger),
		atomic: (work) => store.atomic(work),
		state: {
			get: (name) => store.get(name),
			set: (name, value) => {
				if (value === void 0) store.delete(name);
				else store.set(name, value);
			},
			keys: (prefix) => store.keys(prefix)
		},
		threads: {
			get: (key) => store.threads.get(key),
			subscribed: (source) => store.read.subscribedThreads(source),
			describe: (key, description) => store.threads.describe(key, description),
			patch: (key, meta) => {
				store.threads.patchMeta(key, meta);
			}
		},
		tickets: {
			get: (id) => store.tickets.get(id),
			open: () => store.tickets.open(),
			bindThread: (id, thread, own) => {
				deps.engine.bindThread(id, thread, own);
			},
			threadClosed: (thread, outcome, at) => {
				deps.engine.threadClosed(thread, outcome, at);
			}
		},
		triggers: {
			get: (id) => store.triggers.get(id),
			latest: (thread) => store.read.threadTriggers(thread, 1)[0]
		},
		notify: (message) => {
			deps.outbox.send(message);
		},
		report: (entry, value) => {
			if (!kind.health.includes(entry)) throw new Error(`The ${kind.kind} Source has no health entry ${entry}`);
			health.get(entry)?.set(value);
		}
	};
}
//#endregion
//#region src/app/tools/main.ts
const RoutingNoteSchema = z.string().trim().refine((text) => wordCount(text) <= 30, `Routing note must not exceed 30 words (Chinese uses word segmentation). Shorten it; do not split it across deliveries.`).describe(`Optional routing background or explicit human constraint, at most 30 words. Never add implementation instructions or replace the original source.`);
/** Schedules an Engine pass to execute the recorded routing decision and formats the tool response. */
function routed(host, result) {
	host.requestPass();
	const ticket = result.ticketId ? host.store.tickets.get(result.ticketId) : void 0;
	return {
		...result.decision ? { decision: result.decision } : {},
		reason: result.reason,
		...ticket ? { ticket: ticketCard(ticket) } : {}
	};
}
const fromDecision = (decision) => ({
	decision: decision.kind,
	reason: reasonText(decision.reason),
	ticketId: decision.ticketId
});
/**
* One routing decision of `orchestrator_route`. The schema holds only its shape: each kind's fields are checked as its item
* runs (`FIELDS`), so an item that lacks one, or whose value breaks a limit, is refused alone.
*/
const RouteItemSchema = z.object({
	kind: z.enum([
		"accept",
		"attach",
		"ignore",
		"stop"
	]),
	trigger_id: z.string().describe("The candidate card's trigger_id; deciding it decides its batch."),
	ticket_id: z.string().nullish().describe("attach and stop: the ticket."),
	title: z.string().nullish().describe("accept: a short label of at most 200 characters describing the original request; no added requirements or implementation advice."),
	worktree_name: z.string().nullish().describe(`accept: ${WorktreeNameSchema.description ?? ""}`),
	acknowledgement: z.string().nullish().describe(`accept: one brief sentence of at most 100 words naming the concrete change and intended result in the source language. It is posted as a reply to the original source on acceptance, so do not quote the source; quote an earlier proposal briefly only when the trigger merely confirms it and the sentence does not already state it. No generic I will handle it.`),
	note: z.string().nullish().describe(`accept and attach: ${RoutingNoteSchema.description ?? ""}`),
	reason: z.string().nullish().describe("ignore and stop: why, at most 500 characters; an ignore needs it.")
}).strict();
/** Each field's check, the kinds whose items read it and those that need it; an item of another kind leaves it unread. */
const FIELDS = {
	ticket_id: {
		check: z.string(),
		reads: ["attach", "stop"],
		needs: ["attach", "stop"]
	},
	title: {
		check: z.string().max(200),
		reads: ["accept"],
		needs: ["accept"]
	},
	worktree_name: {
		check: WorktreeNameSchema,
		reads: ["accept"],
		needs: ["accept"]
	},
	acknowledgement: {
		check: AcknowledgementSchema,
		reads: ["accept"],
		needs: ["accept"]
	},
	note: {
		check: RoutingNoteSchema,
		reads: ["accept", "attach"],
		needs: []
	},
	reason: {
		check: z.string().max(500),
		reads: ["ignore", "stop"],
		needs: ["ignore"]
	}
};
/** Why an item cannot run: a field its kind needs is missing, or one it reads breaks its limit. */
function invalid(item) {
	for (const [field, { check, reads, needs }] of Object.entries(FIELDS)) {
		const value = item[field];
		if (!reads.includes(item.kind)) continue;
		if (value === void 0 || value === null || value.trim() === "") {
			if (needs.includes(item.kind)) return `${item.kind} needs ${field}`;
			continue;
		}
		const checked = check.safeParse(value);
		if (!checked.success) return `${field}: ${checked.error.issues[0]?.message ?? "invalid"}`;
	}
}
/**
* Carry out one routing decision as its Engine command, in a transaction of its own. `decided` holds the Triggers that this
* call's earlier items decided, with their batches.
*/
function route(host, item, decided) {
	const note = item.note ? { note: item.note } : {};
	const earlier = decided.get(item.trigger_id);
	if (earlier && item.kind === "ignore") return { refused: `Decided in this call with ${earlier}, whose Decision took its batch` };
	switch (item.kind) {
		case "accept": {
			const before = host.store.triggers.disposition(item.trigger_id)?.decisionId;
			const decision = host.engine.decide(item.trigger_id, {
				kind: "accept",
				title: item.title,
				scope: item.title,
				reason: { code: "explicitRouted" },
				acknowledgement: item.acknowledgement,
				name: item.worktree_name,
				...note
			});
			if (decision.kind !== "accept" || !decision.ticketId) return { refused: `Ticket was not created: ${reasonText(decision.reason)}` };
			if (decision.id === before) return {
				decision: "accept",
				reason: `Already accepted as ${decision.ticketId}; title and acknowledgement unchanged`,
				ticketId: decision.ticketId
			};
			return {
				...fromDecision(decision),
				triggerIds: decision.triggerIds
			};
		}
		case "attach": return {
			reason: "Attached: the ticket follows the trigger's thread and receives the trigger",
			ticketId: host.quietly(() => host.engine.attach(item.ticket_id, item.trigger_id, item.note ?? void 0)).id
		};
		case "stop": {
			const decision = host.engine.decide(item.trigger_id, {
				kind: "stop",
				ticketId: item.ticket_id,
				reason: item.reason || { code: "humanStop" }
			});
			return {
				...fromDecision(decision),
				triggerIds: decision.triggerIds
			};
		}
		case "ignore": {
			const decision = host.engine.decide(item.trigger_id, {
				kind: "ignore",
				reason: item.reason
			});
			return {
				...fromDecision(decision),
				triggerIds: decision.triggerIds
			};
		}
	}
}
/**
* `orchestrator_route`: routing decisions for several triggers in one call, in order. Each runs as its own Engine command; one
* that is refused, or fails, is answered so, and the others still run.
*/
function routeTool(host) {
	return tool({
		name: "orchestrator_route",
		description: "Route candidates, one item each by the card's trigger_id, in one call: accept an explicit request as a new ticket, attach a trigger to an existing ticket, stop a ticket on a person's stop message, or ignore a candidate that needs no ticket or stop, as dispatch says. Items run in order and each is answered on its own; a refused item leaves the others. An inferred candidate may be ignored here; accepting one goes through orchestrator_eval_decide.",
		schema: z.object({ decisions: z.array(RouteItemSchema).min(1).max(20) }).strict(),
		execute: async ({ decisions }) => {
			const decided = /* @__PURE__ */ new Map();
			const results = decisions.map((item) => {
				const head = {
					trigger_id: item.trigger_id,
					kind: item.kind
				};
				const problem = invalid(item);
				if (problem) return {
					...head,
					refused: problem
				};
				try {
					const result = route(host, item, decided);
					if ("refused" in result) return {
						...head,
						...result
					};
					for (const id of result.triggerIds ?? []) if (!decided.has(id)) decided.set(id, item.trigger_id);
					const ticket = result.ticketId ? host.store.tickets.get(result.ticketId) : void 0;
					return {
						...head,
						...result.decision ? { decision: result.decision } : {},
						reason: result.reason,
						...ticket ? { ticket: ticketCard(ticket) } : {}
					};
				} catch (error) {
					if (error instanceof UserError) return {
						...head,
						refused: error.message
					};
					host.context.logger.warn("dsh-superagent could not route trigger %s: %s", item.trigger_id, String(error));
					return {
						...head,
						refused: `Not recorded: ${error instanceof Error ? error.message : String(error)}; retry this item`
					};
				}
			});
			host.requestPass();
			return { results };
		}
	});
}
/** Builds the main Session's tools; `agent` scopes prompt preview resources to that Session. */
function mainTools(host, agent) {
	const resources = {
		...host.resources,
		sessions: host.sessions,
		settings: host.settings
	};
	return [
		readTool("Read one page of a resource the resource parameter lists, such as the ticket list or a ticket. Follow next_offset, and next_resource where a page names one.", false, (resource, offset, limit, signal) => readResource(resources, resource, offset, limit, void 0, signal)),
		routeTool(host),
		tool({
			name: "orchestrator_ticket_retry",
			description: "Start a new assignment on an explicit human request to retry a ticket whose worker reported failed or blocked, or whose input was not delivered; the stalled one ends.",
			schema: z.object({ ticket_id: z.string() }).strict(),
			execute: async (args) => routed(host, {
				reason: "Started a new assignment",
				ticketId: host.engine.retryTicket(args.ticket_id).id
			})
		}),
		tool({
			name: "orchestrator_ticket_request_status",
			description: "Ask the worker of an idle ticket, one whose turn ended without a report, for a status report; for other tickets it sends nothing and returns the card.",
			schema: z.object({ ticket_id: z.string() }).strict(),
			execute: async (args) => {
				return routed(host, {
					reason: host.engine.requestStatus(args.ticket_id) ? "Asked the worker for a status report" : "The worker is not waiting; nothing was sent",
					ticketId: args.ticket_id
				});
			}
		}),
		tool({
			name: "orchestrator_ticket_note",
			description: "Tell a ticket's worker a fact from other work, such as what another ticket found; it grants no authority.",
			schema: z.object({
				ticket_id: z.string(),
				text: z.string().trim().min(1).refine((text) => wordCount(text) <= 100, `At most 100 words`)
			}).strict(),
			execute: async (args) => {
				host.engine.note(args.ticket_id, args.text);
				return routed(host, {
					reason: "Noted for the worker",
					ticketId: args.ticket_id
				});
			}
		}),
		tool({
			name: "orchestrator_trigger_requeue",
			description: "Queue a trigger for a fresh assessment, such as after its Source's access changed; a follow-up that reached a ticket comes back only from its worker.",
			schema: z.object({ trigger_id: z.string() }).strict(),
			execute: async (args) => {
				const trigger = host.store.triggers.get(args.trigger_id);
				const owners = trigger ? followupOwners(trigger, host.store) : [];
				if (owners.length) throw new UserError("workerDecides", { tickets: owners.join(", ") });
				const queued = host.quietly(() => host.engine.reevaluate(args.trigger_id));
				host.requestPass();
				return { queued };
			}
		}),
		tool({
			name: "orchestrator_eval",
			description: "Load a proactive candidate's window and its thread's tickets; repeated calls reuse them.",
			schema: z.object({ trigger_id: z.string() }).strict(),
			execute: async (args, signal) => host.assessor.context(args.trigger_id, signal)
		}),
		tool({
			name: "orchestrator_eval_read",
			description: "Read more of a candidate's context, always with its trigger_id: a message or stub whole by message_id, an image by image_id, the root, the parent, a thread page by cursor, or a file or directory by path.",
			schema: EvalReadSchema,
			execute: async (read, signal) => host.assessor.read(agent, read, signal)
		}),
		tool({
			name: "orchestrator_eval_decide",
			description: "Record the decision of an assessment, as admission describes it, after orchestrator_eval with the same trigger_id.",
			schema: z.object({
				trigger_id: z.string().min(1),
				...AssessmentSchema.shape
			}).strict(),
			execute: async ({ trigger_id, ...result }, signal) => {
				const decided = await host.assessor.decide(trigger_id, AssessmentSchema.parse(result), signal);
				return routed(host, {
					decision: decided.state,
					reason: decided.reason,
					ticketId: decided.ticket_id
				});
			}
		}),
		tool({
			name: "orchestrator_reply",
			description: `Send an answer to a human question, a ready result, or attention requiring human action, as the replies section says; the gate refuses anything else, such as progress. purpose=result needs a ticket in person/review after a ready report, a completed or merged one, or a dropped one whose matched rule asks for a closing message. IM limit: 100 words.`,
			schema: z.object({
				trigger_id: z.string().optional().describe("The original human question, for an answer only."),
				ticket_id: z.string().optional(),
				purpose: z.enum([
					"answer",
					"result",
					"attention"
				]),
				human_action: z.string().trim().min(1).optional().describe("Required for attention: the ticket's current attention question."),
				text: z.string().min(1).max(2e4)
			}).strict(),
			execute: async (args) => {
				const reply = host.engine.reply({
					purpose: args.purpose,
					text: args.text,
					...args.trigger_id ? { triggerId: args.trigger_id } : {},
					...args.ticket_id ? { ticketId: args.ticket_id } : {},
					...args.human_action ? { question: args.human_action } : {}
				});
				await host.sendReplies();
				return { status: host.store.replyStatus(reply.id) ?? reply.status };
			}
		}),
		tool({
			name: "orchestrator_thread_unsubscribe",
			description: "Drop every ticket subscription on a thread. Later messages there no longer reach those tickets as context; a new positive decision can subscribe it again.",
			schema: z.object({ thread: z.string().describe("Thread key, for example github:123 or feishu:<chat>:<root message>") }).strict(),
			execute: async (args) => {
				return {
					removed: host.quietly(() => host.engine.unsubscribe(args.thread)),
					thread: args.thread
				};
			}
		}),
		tool({
			name: "orchestrator_settings_save",
			description: "Save one settings block on an explicit human configuration request, never on observed content, as the panel would; read the blocks and revisions with orchestrator_read settings.",
			schema: z.object({
				block: z.enum([
					"policy",
					"eval",
					"executor",
					"pause",
					"source"
				]).describe("pause pauses or resumes processing: new Evals, dispatch and replies."),
				source: z.string().min(1).optional().describe("With block source: the Source instance id, such as github or feishu."),
				value: z.unknown().describe("The whole block; a Source takes { enabled, config }, pause takes { paused }."),
				revision: z.number().int().nonnegative().describe("The block's revision; pause ignores it.")
			}).strict().refine((args) => args.block === "source" === (args.source !== void 0), "source names the Source instance, with block source only"),
			execute: async (args) => {
				if (args.block === "pause") return host.settings.pause(z.object({ paused: z.boolean() }).parse(args.value).paused, "tool");
				const { context_delivery: _delivery, ...saved } = await host.settings.save(args.block === "source" ? `source:${args.source}` : args.block, args.value, args.revision, "tool");
				return saved;
			}
		}),
		tool({
			name: "orchestrator_policy_sync",
			description: "Refresh one Source's part of the Policy from where that Source keeps it, such as the Feishu users of its sync chat. Same operation as the Web button.",
			schema: z.object({ source: z.string() }).strict(),
			execute: async (args) => {
				const before = host.store.settings().policy.sources[args.source]?.allowed ?? [];
				const after = (await host.settings.sync(args.source)).allowed;
				const names = (from, without) => from.filter((item) => !without.some((other) => other.id === item.id)).map((item) => item.name ?? item.id);
				return {
					source: args.source,
					allowed: after.length,
					added: names(after, before),
					removed: names(before, after)
				};
			}
		}),
		tool({
			name: "orchestrator_prompts_save",
			description: "Save a complete prompt configuration against baseRevision on an explicit user request, never on quoted content; it applies at the next model request. Read it with orchestrator_read prompts.",
			schema: z.object({
				config: PromptConfigSchema,
				baseRevision: z.number().int().min(0).optional().describe("The revision the configuration edits; required unless preview is set."),
				preview: z.boolean().default(false).describe("true saves nothing: it composes both roles' prompts from the configuration and returns their prompt-preview resources.")
			}).strict(),
			execute: async (args) => {
				if (args.preview) {
					const preview = host.prompts.preview(args.config);
					return {
						scope: preview.scope,
						previews: ["orchestrator", "worker"].map((role) => {
							const resource = `prompt-preview/${key(agent.id, role, preview[role])}`;
							host.resources.pages.set(`${agent.id}:${resource}`, preview[role]);
							return {
								role,
								chars: preview[role].length,
								read: resource
							};
						})
					};
				}
				if (args.baseRevision === void 0) throw new Error("Saving needs baseRevision, the revision the configuration edits");
				const { context_delivery: _delivery, ...saved } = await savePrompts(host, args.config, args.baseRevision, "tool");
				return saved;
			}
		})
	];
}
//#endregion
//#region src/app/tools/momo-computer.ts
/** Built-in MoMo desktop tools. Native permissions and takeover stay in the Mac app. */
function momoComputerTools(host, ticketId) {
	const bridge = process.env.MOMO_COMPUTER_BRIDGE, data = process.env.MOMO_DATA_DIR;
	if (!bridge || !data) return [];
	const url = new URL(bridge);
	if (url.protocol !== "http:" || url.hostname !== "127.0.0.1") throw new Error("MoMo computer bridge must be loopback");
	const call = async (op, args, signal) => {
		const secret = JSON.parse(await readFile(join(data, "superagent/state/momo-bridge.json"), "utf8"));
		signal.throwIfAborted();
		const current = host.store.tickets.get(ticketId);
		const assignment = current && runningAssignment(current);
		if (!current || !liveTicket(current) || current.attention || !assignment) throw new Error("Ticket is not running");
		const response = await fetch(new URL("/momo/internal/superagent/computer", url), {
			method: "POST",
			signal: AbortSignal.any([signal, AbortSignal.timeout(2e4)]),
			headers: {
				"content-type": "application/json",
				"x-momo-bridge": secret.secret
			},
			body: JSON.stringify({
				ticket_id: ticketId,
				assignment_id: assignment.id,
				op,
				args
			})
		});
		const result = await response.json();
		if (!response.ok) throw new Error(result.error ?? `Computer bridge returned ${response.status}`);
		return result;
	};
	return [{
		name: "computer_snapshot",
		description: "Read the Mac accessibility tree with bundled agent-desktop. Empty app uses the frontmost window. Use full @snapshot:eN refs with computer_action; complete=false means a partial tree. Re-read after actions or stale refs. User takeover blocks access.",
		schema: z.object({
			app: z.string().max(512).default(""),
			depth: z.number().int().min(1).max(20).default(10)
		}).strict(),
		execute: (args, signal) => call("accessibility-snapshot", args, signal)
	}, {
		name: "computer_action",
		description: "Act on a full ref from computer_snapshot using agent-desktop. set_value replaces text; type_text inserts. Headless semantic actions by default; headed=true explicitly allows physical input. Re-read stale/ambiguous refs. Never blindly repeat uncertain delivery; observe and verify the result.",
		schema: z.object({
			ref: z.string().regex(/^@[A-Za-z0-9_-]+:e[0-9]+$/),
			action: z.enum([
				"click",
				"double_click",
				"right_click",
				"set_value",
				"focus",
				"expand",
				"collapse",
				"select",
				"toggle",
				"check",
				"uncheck",
				"scroll",
				"scroll_to",
				"press_key",
				"type_text",
				"clear",
				"hover"
			]),
			text: z.string().max(8e3).default(""),
			key: z.string().max(80).default(""),
			modifiers: z.array(z.enum([
				"meta",
				"ctrl",
				"alt",
				"shift"
			])).max(4).default([]),
			direction: z.enum([
				"up",
				"down",
				"left",
				"right"
			]).default("down"),
			amount: z.number().int().min(1).max(100).default(3),
			headed: z.boolean().default(false)
		}).strict(),
		execute: (args, signal) => call("accessibility-action", args, signal)
	}];
}
//#endregion
//#region src/app/tools/executor.ts
/** Executor Session tools for reading ticket context, acknowledging requests, managing threads, handing back out-of-scope triggers, and reporting status. */
function executorTools(host, ticket) {
	const ticketId = ticket.id;
	return [
		...momoComputerTools(host, ticketId),
		readTool("Read one page of a resource of this ticket that the resource parameter lists. Follow next_offset, and next_resource where a page names one.", true, (resource, offset, limit, signal) => readResource(host.resources, resource, offset, limit, ticketId, signal)),
		tool({
			name: "orchestrator_ack",
			description: "Acknowledge one original human request before substantial work, as the replies section says; it posts as a reply to that message.",
			schema: z.object({
				trigger_id: z.string(),
				text: AcknowledgementSchema.describe(`At most 100 words; Markdown is supported.`)
			}).strict(),
			execute: async (args) => {
				const reply = host.engine.reply({
					purpose: "acknowledgement",
					ticketId,
					triggerId: args.trigger_id,
					text: args.text
				});
				if (reply.status !== "sent") await host.sendReplies();
				return {
					trigger_id: args.trigger_id,
					acknowledgement: host.store.replyStatus(reply.id),
					reused: reply.reused
				};
			}
		}),
		tool({
			name: "orchestrator_thread_unrelated",
			description: "Stop following an attached thread that is not about this ticket, as the work section says; its own threads cannot be dropped.",
			schema: z.object({
				thread: z.string().min(1).describe("The thread key, which trigger/<id> of one of its messages shows as thread, such as feishu:<chat>:<root> or github:<number>."),
				reason: z.string().trim().min(1).max(300).describe("One sentence on why the thread is not about this ticket.")
			}).strict(),
			execute: async (args) => {
				host.engine.markUnrelated(ticketId, args.thread, args.reason);
				return {
					removed: true,
					thread: args.thread
				};
			}
		}),
		tool({
			name: "orchestrator_thread_follow",
			description: "Follow a related thread, such as an Issue or another PR, for context only.",
			schema: z.object({
				thread: z.string().describe("Thread key, such as github:<number>."),
				reason: z.string().trim().min(1).max(300).describe("How it relates, in one sentence.")
			}).strict(),
			execute: async (args) => host.store.atomic(() => {
				const at = args.thread.indexOf(":");
				if (at < 1 || at === args.thread.length - 1) throw new Error("A thread key is <source>:<id>, such as github:<number>");
				const followed = host.engine.followForContext(ticketId, {
					source: args.thread.slice(0, at),
					id: args.thread.slice(at + 1)
				});
				if (followed) host.sessions.notify(...threadFollowedNotice(ticketId, args.thread, args.reason));
				return {
					followed,
					thread: args.thread
				};
			})
		}),
		tool({
			name: "orchestrator_trigger_handback",
			description: "Hand back a message that asks for work beyond this ticket or for another one, for a fresh assessment; once per message. queued is false while another ticket still decides it, and for a message that was never this ticket's to decide, such as a bot's, which is assessed without it.",
			schema: z.object({
				trigger_id: z.string().min(1),
				reason: z.string().trim().min(1).max(300).describe("One sentence on what it asks for beyond this ticket.")
			}).strict(),
			execute: async (args) => ({
				trigger_id: args.trigger_id,
				queued: host.engine.handback(ticketId, args.trigger_id, args.reason)
			})
		}),
		tool({
			name: "orchestrator_report",
			description: "Report progress, ready, blocked, failed or dropped, as the work and handoff sections say.",
			schema: z.object({
				state: z.enum([
					"progress",
					"ready",
					"blocked",
					"failed",
					"dropped"
				]),
				summary: z.string().min(1),
				human_action: z.string().trim().min(1).max(1e3).nullish().describe("One concrete question for a person, also with state=progress; omit to keep the pending one, null to clear it."),
				question_for_trigger_id: z.string().optional().describe("With human_action: the human message that raised the question, which is asked where that person wrote."),
				pr_number: z.number().int().positive().nullish().describe(`The ticket's PR: its source PR, or one by ${host.github.deployment.github.login} from a branch named after this ticket (DSH_SUPERAGENT_NAME).`),
				reply_to_trigger_id: z.string().optional().describe("The explicit human question this report answers; never for ordinary progress.")
			}).strict(),
			execute: async (args, signal) => {
				const current = host.store.tickets.get(ticketId);
				if (!current || !liveTicket(current)) throw new Error("Ticket ended (PR was closed or work finished); do not resume it");
				const pull = args.pr_number != null ? await readPull(host.github, args.pr_number, signal) : void 0;
				return host.store.atomic(() => {
					const refused = pull && claimPull(host.github, ticketId, pull);
					if (refused) throw new Error(refused);
					const report = {
						state: args.state,
						summary: args.summary,
						...args.human_action !== void 0 ? { question: args.human_action } : {},
						...args.question_for_trigger_id ? { askedBy: args.question_for_trigger_id } : {},
						...args.reply_to_trigger_id ? { answers: args.reply_to_trigger_id } : {}
					};
					const updated = host.engine.report(ticketId, report);
					const relay = reportRelay(updated, report);
					if (relay) host.sessions.relay(relay.id, relay.text);
					return {
						reported: true,
						notification: relay ? "orchestrator" : "internal_only",
						...updated.attention ? { attention: updated.attention } : {}
					};
				});
			}
		})
	];
}
//#endregion
//#region src/app/runtime.ts
/** Application composition root and lifecycle manager for dsh-superagent. */
const now = () => (/* @__PURE__ */ new Date()).toISOString();
/**
* Composition root of dsh-superagent that connects `Store`, `Setup`, `Engine`, `SourceRegistry`, `Effects`, `Outbox`, `Passes`, `Sessions`, `Settings`, `Prompts`, `DshExecutor`, and `MasterAssessor`.
* Exposes the `SourceHost` service on the Cordis context for source plugins and coordinates startup, setup checks, HTTP route registration, and graceful shutdown.
* Locks the state directory before opening SQLite so concurrent processes cannot corrupt or double-migrate state.
*/
var Runtime = class extends Service {
	machine;
	store;
	setup;
	prompts;
	effects;
	sources;
	commands;
	sessions;
	settings;
	executor;
	assessor;
	outbox;
	engine;
	passes;
	ready;
	board = new HealthBoard();
	runtimeHealth = this.board.claim("runtime", {
		state: "starting",
		detail: ""
	});
	masterId;
	sourceLinks = new TextCache(2e5);
	stopped = new AbortController();
	disposers = [];
	releaseLock;
	closingFlag = false;
	stopping;
	sourceDeps;
	toolHost;
	/** Non-zero while a main-Session tool is executing an Engine command, suppressing self-triggered domain event notices. */
	quiet = 0;
	constructor(ctx, machine, restart) {
		super(ctx, "orchestrator");
		this.machine = machine;
		const runtime = this;
		mkdirSync(machine.stateDir, {
			recursive: true,
			mode: 448
		});
		const compromised = (error) => {
			this.runtimeHealth.set({
				state: "error",
				detail: error.message
			});
			this.stopped.abort();
		};
		const release = lockSync(machine.stateDir, {
			stale: 3e4,
			onCompromised: compromised
		});
		this.releaseLock = async () => {
			release();
		};
		let opened;
		try {
			const report = (error) => {
				ctx.logger.warn("dsh-superagent: %s", String(error));
			};
			const store = opened = this.store = new Store(join(machine.stateDir, "orchestrator.sqlite"), report);
			const setup = this.setup = new Setup({
				context: ctx,
				machine,
				lifetime: this.lifetime,
				restart
			});
			const deployed = () => setup.configured() ? environmentOf({
				deployment: setup.deployment,
				sources: this.sources,
				settings: store.settings()
			}) : void 0;
			const feishu = () => setup.configured() && !!setup.deployment.feishu;
			const prompts = this.prompts = new Prompts(store, () => machine.promptMaxChars.get(), deployed, feishu);
			const masterId = this.masterId = store.get(KV.runtime.masterId) ?? `orchestrator-${key(machine.stateDir)}`;
			store.set(KV.runtime.masterId, masterId);
			const commands = this.commands = new Commands(() => setup.deployment, setup.commandEnvironment, this.lifetime);
			const board = this.board;
			const effects = this.effects = new Effects(store, board);
			const sources = this.sources = new SourceRegistry(() => store.settings(), board, (kind) => {
				if (kind.policy?.sync) this.ready?.then(() => this.settings.syncable().includes(kind.kind) ? this.settings.sync(kind.kind) : void 0).catch(() => {});
				return () => {};
			});
			const links = {
				store,
				links: this.sourceLinks,
				commands,
				sources,
				lifetime: this.lifetime
			};
			const link = (trigger, signal) => sourceLink(links, trigger, signal);
			const environment = (ticket) => this.ticketEnvironment(ticket);
			const resources = {
				store,
				pages: new TextCache(4e6),
				prompts,
				commands,
				masterId,
				context: ctx,
				promptVersion: (id) => this.sessions.promptVersion(id),
				mayRead: (id, revision) => this.sessions.mayRead(id, revision),
				feishuPageSize: () => feishuSettings(sources).readPageSize,
				sourceLink: link
			};
			const sessions = this.sessions = new Sessions({
				context: ctx,
				store,
				prompts,
				effects,
				health: board.claim("models"),
				masterId,
				lifetime: this.lifetime,
				closing: () => this.closing(),
				environment,
				tools: (agent, ticket) => ticket ? executorTools(this.toolHost, ticket) : mainTools(this.toolHost, agent)
			});
			const policyChanged = (from, to, effects) => {
				this.engine.policyChanged(from, to, effects);
			};
			this.settings = new Settings({
				store,
				sources,
				engine: { policyChanged },
				health: board,
				context: ctx,
				lifetime: this.lifetime,
				sessions,
				sourceHost: this,
				setup,
				requestPass: () => {
					this.passes.request();
				}
			});
			this.executor = new DshExecutor({
				context: ctx,
				get engine() {
					return runtime.engine;
				},
				store,
				effects,
				health: board.claim("worker"),
				machine,
				lifetime: this.lifetime,
				sessions,
				closing: () => this.closing(),
				paused: () => this.paused(),
				environment,
				sourceLink: link,
				repliedTo: (trigger) => repliedTo({
					store,
					sources
				}, trigger)
			});
			this.assessor = new MasterAssessor({
				get engine() {
					return runtime.engine;
				},
				commands,
				get deployment() {
					return setup.deployment;
				},
				effects,
				settings: () => store.settings(),
				paused: () => this.paused(),
				threadContext: (trigger) => sources.threadContext(trigger),
				deliver: (id, text) => sessions.prompt(masterId, id, text, "steer"),
				candidateCard: (candidate) => candidateCard(links, candidate)
			});
			const outbox = this.outbox = new Outbox({
				store,
				effects,
				sources,
				commands,
				paused: () => this.paused()
			});
			const { assessor, executor } = this;
			const policy = () => settingsPolicy(store.settings(), sources);
			const engine = this.engine = new Engine({
				repo: store,
				scope: sources,
				policy,
				assessor,
				executor,
				outbox,
				prepareTicket: (ticket, outcome) => executor.prepare(ticket, outcome),
				emit: (event) => {
					const notice = this.quiet ? void 0 : eventNotice(event, (id) => store.tickets.get(id));
					if (notice) sessions.notify(...notice);
					const followup = !this.quiet && (event.type === "trigger.received" || event.type === "ticket.resumed" || event.type === "trigger.followup") ? followupNotice(store, sources, event.data.triggerId) : void 0;
					if (followup) sessions.relay(followup.id, followup.text);
					const ended = event.type === "ticket.ended" ? store.tickets.get(event.data.ticketId) : void 0;
					if (ended && setup.configured() && setup.deployment.repository) {
						const request = store.triggers.get(ended.origin.triggerId)?.text ?? "";
						for (const message of pullEndNotices(ended, request, setup.deployment.repository)) outbox.send(message);
					}
				}
			});
			const evals = board.claim("evals", {
				state: "ready",
				detail: "No unavailable Eval in the last hour"
			});
			const evaluateDue = () => {
				engine.evaluateDue();
				evals.set(evalsHealth(store));
			};
			const passes = this.passes = new Passes({
				engine: {
					receive: (trigger) => engine.receive(trigger),
					evaluateDue
				},
				effects,
				health: this.runtimeHealth,
				lifetime: this.lifetime,
				configured: () => setup.configured(),
				closing: () => this.closing()
			});
			this.sourceDeps = {
				store,
				engine,
				outbox,
				commands,
				sources,
				get ready() {
					return runtime.ready;
				},
				get deployment() {
					return setup.deployment;
				},
				configured: () => setup.configured(),
				get setupProblem() {
					return setup.problem;
				},
				get feishuProblem() {
					return setup.feishuProblem;
				},
				receive: (trigger) => passes.receive(trigger)
			};
			this.toolHost = {
				context: ctx,
				engine,
				store,
				prompts,
				sessions,
				settings: this.settings,
				assessor,
				resources,
				get github() {
					return runtime.context({
						kind: "github",
						health: ["github"]
					});
				},
				requestPass: () => {
					passes.request();
				},
				sendReplies: () => outbox.sent(),
				quietly: (run) => {
					this.quiet++;
					try {
						return run();
					} finally {
						this.quiet--;
					}
				}
			};
			this.ready = this.initialize();
		} catch (error) {
			try {
				opened?.close();
			} finally {
				release();
			}
			throw error;
		}
	}
	get health() {
		return this.board.all;
	}
	/** Aborted when dsh-superagent stops or loses its state directory lock, cancelling running reads and subprocesses. */
	get lifetime() {
		return this.stopped.signal;
	}
	context(kind) {
		return sourceContextOf(this.sourceDeps, kind);
	}
	/** Resolved deployment; throws while waiting for setup (`!configured()`). */
	get deployment() {
		return this.setup.deployment;
	}
	configured() {
		return this.setup.configured();
	}
	get setupProblem() {
		return this.setup.problem;
	}
	/** Why the Feishu bot is unavailable even though the Feishu Source configures a CLI. */
	get feishuProblem() {
		return this.setup.feishuProblem;
	}
	links() {
		const resolved = this.setup.configured() ? this.setup.deployment : void 0;
		const links = resolved ? {
			repository: resolved.repository,
			...resolved.feishu ? { feishu: resolved.feishu } : {}
		} : {};
		return (channel) => this.sources.link(channel, links);
	}
	ticketEnvironment(ticket) {
		const trigger = sourceTrigger(this, ticket);
		const { setup: { deployment }, sources } = this;
		return ticketEnvironment({
			deployment,
			sources,
			settings: this.store.settings(),
			ticket,
			...trigger ? { trigger } : {}
		});
	}
	checkSetup() {
		this.setup.check();
	}
	receive(trigger) {
		return this.passes.receive(trigger);
	}
	idle() {
		return this.passes.idle();
	}
	pump() {
		return this.passes.pump();
	}
	sendReplies() {
		return this.outbox.sent();
	}
	closing() {
		return this.closingFlag;
	}
	/** Hold evaluation, dispatch, and outbound delivery while paused or awaiting setup; sources still record incoming triggers. */
	paused() {
		return !this.setup.configured() || this.store.settings().paused;
	}
	async initialize() {
		this.disposers.push(registerHttp(this.ctx, this.httpHost()));
		if (!await this.setup.run(this.store.settings())) {
			this.runtimeHealth.set({
				...health("paused", "setupPending"),
				at: now()
			});
			return;
		}
		this.sessions.install();
		this.executor.install();
		await this.sessions.ensure(this.masterId, this.machine.stateDir, "dsh-superagent orchestrator", "orchestrator");
		for (const id of this.settings.syncable()) await this.settings.sync(id).catch(() => {});
		if (this.closing()) return;
		this.executor.resume();
		this.passes.start();
		this.effects.start();
		this.runtimeHealth.set({
			state: "ready",
			detail: "Orchestrator is ready",
			at: now()
		});
	}
	httpHost() {
		const runtime = this;
		const { store, sources, prompts, sessions, settings, engine, executor, health, machine, masterId, ready, sourceLinks, setup, passes } = this;
		return {
			store,
			sources,
			prompts,
			sessions,
			settings,
			engine,
			executor,
			health,
			machine,
			masterId,
			ready,
			sourceLinks,
			get deployment() {
				return setup.deployment;
			},
			get setupProblem() {
				return setup.problem;
			},
			get feishuProblem() {
				return setup.feishuProblem;
			},
			configured: () => setup.configured(),
			links: () => runtime.links(),
			ticketEnvironment: (ticket) => runtime.ticketEnvironment(ticket),
			checkSetup: () => {
				setup.check();
			},
			requestPass: () => {
				passes.request();
			},
			models: () => this.ctx.sessionController.modelCatalog()
		};
	}
	/** Idempotent stop; concurrent or repeated calls share the same shutdown promise. */
	stop() {
		return this.stopping ??= this.shutdown();
	}
	async shutdown() {
		this.closingFlag = true;
		const passes = this.passes.stop();
		this.stopped.abort();
		try {
			this.assessor.stop();
			const agents = [this.masterId, ...this.store.tickets.list().map((ticket) => workerSessionId(ticket.id))].map((id) => this.ctx.agents.get(id)).filter((agent) => agent !== void 0);
			for (const agent of agents) agent.cancel({ kind: "user" }, { keepInbox: true });
			await Promise.allSettled([
				passes,
				this.effects.drain(),
				...agents.map((agent) => agent.whenIdle())
			]);
			await this.executor.shutdown();
			this.executor.dispose();
			this.sessions.dispose();
			for (const dispose of this.disposers.reverse()) dispose();
			await this.ctx.sessionPersistence.flush();
		} finally {
			this.setup.restore();
			try {
				this.store.close();
			} finally {
				const unreleased = (error) => {
					this.ctx.logger.warn("dsh-superagent could not release its state directory lock: %s", String(error));
				};
				await this.releaseLock?.().catch(unreleased);
			}
		}
	}
};
//#endregion
//#region src/index.ts
const name = "dsh-superagent";
const inject = [
	"agents",
	"sessionController",
	"sessionPersistence",
	"workspaceRegistry",
	"permissionPresets",
	"tools",
	"systemPrompt",
	"skills",
	"webServer",
	"llm",
	"subprocess"
];
async function apply(ctx, config) {
	const machine = machineOf(config);
	ctx.inject(["settings"], (child) => {
		child.effect(() => child.settings.configure({ auto: false }, ctx.fiber));
	});
	const restart = () => {
		ctx.fiber.restart().then(() => {
			ctx.get("settings")?.describe();
		}).catch((error) => {
			ctx.logger.error("dsh-superagent restart failed: %s", String(error));
		});
	};
	const runtime = new Runtime(ctx, machine, restart);
	ctx.effect(() => async () => {
		await runtime.stop();
	});
	await runtime.ready;
	ctx.logger.info(runtime.configured() ? "dsh-superagent ready; the Superagent sidebar entry opens the management panel" : `dsh-superagent is waiting for setup: ${runtime.setupProblem?.detail ?? ""}`);
}
//#endregion
export { Config, Engine, MemoryRepositories, REASONS, USER_ERRORS, UserError, apply, canRetry, followupOwners, inject, isoTime, key, latestAssignment, latestReport, liveTicket, name, reached, readUntil, reasonText, runningAssignment, said, settled, threadKey, ticketOutcome, ticketStage, waitsForPerson };
