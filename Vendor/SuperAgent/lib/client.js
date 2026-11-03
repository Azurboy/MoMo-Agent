window.__ModuleLoader__.load({
	id: "dsh-superagent",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
		let react = require("react");
		let react_dom = require("react-dom");
		let react_jsx_runtime = require("react/jsx-runtime");
		//#region src/navigation.ts
		/**
		* Thrown by `openKnownSession` when the host Session catalog is not ready or does not list the target Session.
		* The management panel catches it to display a localized error message.
		*/
		var SessionNavigationError = class extends Error {
			code;
			constructor(code) {
				super(code);
				this.code = code;
			}
		};
		/** Select `id` in the workspace once the catalog lists it, unless aborted first. */
		async function openKnownSession(sessions, id, open, signal) {
			if (signal.aborted) return false;
			if (sessions.list.getSnapshot().phase !== "ready" || !sessions.list.getSnapshot().byId[id]) await sessions.refresh();
			if (signal.aborted) return false;
			const list = sessions.list.getSnapshot();
			if (list.phase !== "ready") throw new SessionNavigationError("not-ready");
			if (!list.byId[id]) throw new SessionNavigationError("not-listed");
			open(id);
			return true;
		}
		//#endregion
		//#region src/client/controls.tsx
		/**
		* Context-free UI primitives styled with `--dsw-alias-*` tokens.
		* Mirrors DSH ui-primitives markup and keyboard behavior without coupling to its internal package API.
		*/
		const cx = (...names) => names.filter(Boolean).join(" ");
		const ICON_PATHS = {
			"chevron-left": "M15 5l-7 7 7 7",
			"chevron-right": "M9 5l7 7-7 7",
			"chevron-down": "M5 9l7 7 7-7",
			"chevron-up": "M5 15l7-7 7 7",
			search: "M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM20 20l-4-4",
			question: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .9-1 1.6v.6M12 17h.01",
			plus: "M12 5v14M5 12h14",
			trash: "M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3",
			refresh: "M20 12a8 8 0 1 1-2.3-5.6M20 4v5h-5",
			clock: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 7v5l3 2",
			history: "M3.5 12a8.5 8.5 0 1 0 2.5-6M3.5 4v4h4M12 8v4l3 2",
			shield: "M12 3l7 3v6c0 4.2-2.9 7.6-7 9-4.1-1.4-7-4.8-7-9V6z",
			decision: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM8.5 12.5l2.5 2.5 4.5-5",
			message: "M5 5h14a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1H10l-5 4V6a1 1 0 0 1 1-1z",
			inbox: "M4 13l2.5-8h11l2.5 8M4 13v6h16v-6M4 13h5l1 2h4l1-2h5",
			hash: "M10 4L8 20M16 4l-2 16M5 9h15M4 15h15",
			filter: "M4 5h16l-6 7.5V18l-4 2v-7.5z",
			user: "M12 4a4 4 0 1 0 0 8 4 4 0 0 0 0-8zM4 20c1.5-3.5 4.5-5 8-5s6.5 1.5 8 5",
			close: "M6 6l12 12M18 6L6 18",
			settings: "M4 7h10M18 7h2M4 17h4M12 17h8M16 5v4M10 15v4",
			external: "M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5",
			session: "M4 5h16v14H4zM8 10l3 2-3 2M13 15h3",
			stop: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM9.5 9.5h5v5h-5z",
			pause: "M9 6v12M15 6v12",
			play: "M8 5l11 7-11 7z",
			unsubscribe: "M6 16v-5a6 6 0 0 1 10-4.5M18 11v5l2 2H8M10 20h4M4 4l16 16",
			dismiss: "M4 4l16 16M9.9 5.2A9 9 0 0 1 21 12a12 12 0 0 1-2.4 3.2M6.3 6.4A12 12 0 0 0 3 12c2 4 5.5 6 9 6 1.4 0 2.7-.3 3.9-.9",
			pull: "M7 4a2 2 0 1 0 0 4 2 2 0 0 0 0-4zM7 8v8M7 16a2 2 0 1 0 0 4 2 2 0 0 0 0-4zM17 16a2 2 0 1 0 0 4 2 2 0 0 0 0-4zM17 16V9a2 2 0 0 0-2-2h-4M13 5l-2 2 2 2",
			copy: "M9 9h10v11H9zM5 15V4h10",
			review: "M9 4h6v3H9zM7 5H5v15h14V5h-2M9 13l2 2 4-4",
			ask: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .9-1 1.6v.6M12 17h.01",
			alert: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 7.5v5.5M12 16.5h.01",
			running: "M12 3a9 9 0 1 0 9 9",
			blocked: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM5.6 5.6l12.8 12.8",
			queue: "M4 6h16M4 12h16M4 18h10"
		};
		function Icon({ name, size = 16 }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("svg", {
				width: size,
				height: size,
				viewBox: "0 0 24 24",
				fill: "none",
				stroke: "currentColor",
				strokeWidth: 1.8,
				strokeLinecap: "round",
				strokeLinejoin: "round",
				"aria-hidden": "true",
				children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("path", { d: ICON_PATHS[name] })
			});
		}
		function Button({ variant = "ghost", size = "md", icon, className, children, type = "button", ...rest }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("button", {
				type,
				className: cx("dt-btn", `dt-btn-${variant}`, `dt-btn-${size}`, className),
				...rest,
				children: [icon !== void 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
					className: "dt-btn-icon",
					children: icon
				}), children]
			});
		}
		function Tag({ tone = "outline", title, children }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
				className: "dt-tag",
				"data-tone": tone,
				title,
				children
			});
		}
		function Pill({ active, onClick, children }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
				type: "button",
				className: cx("dt-pill", active && "dt-pill-active"),
				"aria-pressed": active,
				onClick,
				children
			});
		}
		function walk(event, values, value, onChange) {
			const index = values.indexOf(value);
			const next = {
				ArrowRight: index + 1,
				ArrowLeft: index - 1,
				Home: 0,
				End: values.length - 1
			}[event.key];
			if (next === void 0) return;
			event.preventDefault();
			const target = values[(next + values.length) % values.length];
			if (target !== value) onChange(target);
			const list = event.currentTarget;
			requestAnimationFrame(() => list.querySelector("[role=\"tab\"][aria-selected=\"true\"]")?.focus());
		}
		/** Page-level tab bar that re-emits `onChange` when clicking the active tab so callers can reset to the tab root. */
		function SegmentedTabs({ items, value, onChange, label, className }) {
			const list = (0, react.useRef)(null);
			const [more, setMore] = (0, react.useState)();
			const measure = (0, react.useCallback)(() => {
				const element = list.current;
				if (!element) return;
				const start = element.scrollLeft > 1, end = element.scrollLeft + element.clientWidth < element.scrollWidth - 1;
				setMore(start && end ? "both" : start ? "start" : end ? "end" : void 0);
			}, []);
			(0, react.useEffect)(() => {
				measure();
				if (!list.current || typeof ResizeObserver === "undefined") return;
				const observer = new ResizeObserver(measure);
				observer.observe(list.current);
				for (const tab of list.current.children) observer.observe(tab);
				return () => {
					observer.disconnect();
				};
			}, [measure, items.length]);
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
				ref: list,
				role: "tablist",
				"aria-label": label,
				className: cx("dt-tabs", className),
				"data-more": more,
				onScroll: measure,
				style: { gridTemplateColumns: `repeat(${items.length}, minmax(0, 1fr))` },
				onKeyDown: (event) => walk(event, items.map((item) => item.value), value, onChange),
				children: items.map((item) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
					type: "button",
					role: "tab",
					id: item.id,
					"aria-controls": item.panelId,
					"aria-selected": item.value === value,
					tabIndex: item.value === value ? 0 : -1,
					className: "dt-tab",
					onClick: () => onChange(item.value),
					children: item.label
				}, item.value))
			});
		}
		function SegmentedControl({ options, value, onChange, label, disabled, className }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
				role: "tablist",
				"aria-label": label,
				className: cx("dt-segmented", className),
				style: { gridTemplateColumns: `repeat(${options.length}, minmax(0, 1fr))` },
				onKeyDown: (event) => {
					if (!disabled) walk(event, options.map((option) => option.value), value, onChange);
				},
				children: options.map((option) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
					type: "button",
					role: "tab",
					"aria-selected": option.value === value,
					tabIndex: option.value === value ? 0 : -1,
					title: option.title,
					disabled,
					className: "dt-segment",
					onClick: () => {
						if (option.value !== value) onChange(option.value);
					},
					children: option.label
				}, option.value))
			});
		}
		function Input({ icon, className, ...rest }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("span", {
				className: cx("dt-input", className),
				children: [icon !== void 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
					className: "dt-input-icon",
					children: icon
				}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("input", { ...rest })]
			});
		}
		function Switch({ checked, onChange, label, className }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
				type: "button",
				role: "switch",
				"aria-checked": checked,
				"aria-label": label,
				className: cx("dt-switch", className),
				onClick: () => onChange(!checked),
				children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { className: "dt-switch-thumb" })
			});
		}
		function StateDot({ state, className }) {
			if (state === "ongoing") return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("svg", {
				className: cx("dt-spinner", className),
				"data-state": "ongoing",
				width: 14,
				height: 14,
				viewBox: "0 0 24 24",
				"aria-hidden": "true",
				children: /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("g", { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("circle", {
					cx: "12",
					cy: "12",
					r: "9.5"
				}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("circle", {
					cx: "12",
					cy: "12",
					r: "9.5"
				})] })
			});
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
				className: cx("dt-state-dot", className),
				"data-state": state,
				"aria-hidden": "true"
			});
		}
		function Dot({ state, label }) {
			const dot = /* @__PURE__ */ (0, react_jsx_runtime.jsx)(StateDot, {
				className: "dt-dot",
				state
			});
			return label ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
				className: "dt-dot-wrap",
				title: label,
				role: "img",
				"aria-label": label,
				children: dot
			}) : dot;
		}
		function DisclosureRow({ icon, title, open, onToggle, collapsedContent, children }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-disclosure",
				"data-open": open || void 0,
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-disclosure-row",
					role: "button",
					tabIndex: 0,
					"aria-expanded": open,
					"data-disclosure-row": true,
					onClick: onToggle,
					onKeyDown: (event) => {
						if (event.key === "Enter" || event.key === " ") {
							event.preventDefault();
							onToggle();
						}
					},
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("span", {
							className: "dt-disclosure-lead",
							children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
								className: "dt-disclosure-icon",
								children: icon
							}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
								className: "dt-disclosure-chevron",
								children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: open ? "chevron-up" : "chevron-down" })
							})]
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
							className: "dt-disclosure-title",
							children: title
						}),
						!open && collapsedContent
					]
				}), open && children]
			});
		}
		const FOCUSABLE = "a[href], button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex]:not([tabindex=\"-1\"])";
		function trapTab(event, dialog) {
			const items = [...dialog.querySelectorAll("*")].filter((element) => element.matches(FOCUSABLE));
			const first = items[0], last = items.at(-1), active = document.activeElement;
			const target = event.shiftKey ? last : first;
			if (!target || !dialog.contains(active) || active === dialog || active === (event.shiftKey ? first : last)) {
				event.preventDefault();
				target?.focus();
			}
		}
		/** Accessible modal dialog with focus trapping, Escape/backdrop dismissal, and focus restoration. */
		function Modal({ open, onClose, title, closeLabel, description, footer, className, children }) {
			const dialog = (0, react.useRef)(null);
			const close = (0, react.useRef)(onClose);
			close.current = onClose;
			(0, react.useEffect)(() => {
				if (!open) return;
				const opener = document.activeElement instanceof HTMLElement ? document.activeElement : void 0;
				dialog.current?.focus();
				const onKeyDown = (event) => {
					if (event.key === "Escape") close.current();
					else if (event.key === "Tab" && dialog.current) trapTab(event, dialog.current);
				};
				document.addEventListener("keydown", onKeyDown);
				return () => {
					document.removeEventListener("keydown", onKeyDown);
					opener?.focus();
				};
			}, [open]);
			if (!open) return null;
			return (0, react_dom.createPortal)(/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-modal-root",
				role: "presentation",
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
					className: "dt-modal-mask",
					"aria-hidden": "true",
					onClick: onClose
				}), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					ref: dialog,
					className: cx("dt-modal", className),
					role: "dialog",
					"aria-modal": "true",
					"aria-label": title,
					tabIndex: -1,
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
							className: "dt-modal-header",
							children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("h2", { children: title }), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
								type: "button",
								className: "dt-modal-close",
								"aria-label": closeLabel,
								onClick: onClose,
								children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, {
									name: "close",
									size: 14
								})
							})]
						}),
						description && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
							className: "dt-modal-description",
							children: description
						}),
						children !== void 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
							className: "dt-modal-body",
							children
						}),
						footer !== void 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
							className: "dt-modal-footer",
							children: footer
						})
					]
				})]
			}), document.body);
		}
		/** Portaled tooltip trigger supporting hover, keyboard focus, and touch toggle. */
		function InfoTip({ text, icon = "question", warn }) {
			const anchor = (0, react.useRef)(null);
			const bubble = (0, react.useRef)(null);
			const [open, setOpen] = (0, react.useState)(false);
			(0, react.useLayoutEffect)(() => {
				const target = anchor.current, element = bubble.current;
				if (!open || !target || !element) return;
				const margin = 12, gap = 8;
				const a = target.getBoundingClientRect(), b = element.getBoundingClientRect();
				const above = a.top - gap - b.height >= margin;
				element.style.left = `${Math.max(margin, Math.min(a.left + a.width / 2 - b.width / 2, window.innerWidth - margin - b.width))}px`;
				element.style.top = `${above ? a.top - gap - b.height : a.bottom + gap}px`;
				element.style.visibility = "visible";
			}, [open]);
			(0, react.useEffect)(() => {
				if (!open) return;
				const close = () => setOpen(false);
				window.addEventListener("scroll", close, true);
				window.addEventListener("resize", close);
				return () => {
					window.removeEventListener("scroll", close, true);
					window.removeEventListener("resize", close);
				};
			}, [open]);
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
				ref: anchor,
				type: "button",
				className: warn ? "dt-info dt-info-warn" : "dt-info",
				"aria-label": text,
				onMouseEnter: () => setOpen(true),
				onMouseLeave: () => setOpen(false),
				onBlur: () => setOpen(false),
				onFocus: (event) => {
					if (event.currentTarget.matches(":focus-visible")) setOpen(true);
				},
				onKeyDown: (event) => {
					if (event.key === "Escape") setOpen(false);
				},
				onPointerUp: (event) => {
					if (event.pointerType === "touch") setOpen(!open);
				},
				onClick: (event) => {
					if (event.detail > 0 && event.nativeEvent.pointerType !== "touch") setOpen(false);
				},
				children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, {
					name: icon,
					size: 14
				})
			}), open && (0, react_dom.createPortal)(/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
				ref: bubble,
				role: "tooltip",
				className: "dt-tooltip",
				style: { visibility: "hidden" },
				children: text
			}), document.body)] });
		}
		//#endregion
		//#region src/admission.ts
		const ADMISSION_OPTIONS = {
			listedUnaddressed: ["inferred", "ignore"],
			unlistedAddressed: [
				"explicit",
				"inferred",
				"ignore"
			],
			unlistedUnaddressed: ["inferred", "ignore"]
		};
		/** Default admission rules (matching pre-table behavior): unaddressed messages from listed senders are inferred candidates; unlisted senders are ignored. */
		const ADMISSION_DEFAULTS = {
			listedUnaddressed: "inferred",
			unlistedAddressed: "ignore",
			unlistedUnaddressed: "ignore"
		};
		//#endregion
		//#region src/limits.ts
		/** Validation bounds shared between host schemas and management panel forms. */
		const LIMITS = {
			ruleName: 100,
			ruleInstruction: 2e3,
			evalTimeoutSeconds: {
				min: 30,
				max: 600
			},
			maxWorkers: {
				min: 1,
				max: 16
			},
			prepareCommand: 4e3,
			promptMaxChars: {
				min: 1e3,
				max: 1e6
			},
			admissionContextMaxPages: {
				min: 1,
				max: 100
			},
			admissionContextTimeoutMs: {
				min: 1,
				max: 9e4
			}
		};
		//#endregion
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
		//#endregion
		//#region src/client/api.ts
		/** Same-origin client and polling hook for the orchestrator management API. */
		/**
		* Represents a failed management API request with a localized message and structured diagnostic details.
		* Thrown by API callers and inspected by UI views and draft state to distinguish validation issues, missing records,
		* and unreachable hosts (`details.unreachable` is set when `dsh-superagent` did not answer at all, such as during a restart,
		* in which case a 404 does not mean a record is missing).
		*/
		var ApiError = class extends Error {
			status;
			details;
			constructor(message, status, details = {}) {
				super(message);
				this.status = status;
				this.details = details;
			}
			get issues() {
				return this.details.issues ?? [];
			}
			/** True when the host confirmed the record does not exist, rather than being unreachable. */
			get missing() {
				return this.status === 404 && !this.details.unreachable;
			}
		};
		const isUserError = (code) => typeof code === "string" && Object.hasOwn(USER_ERRORS, code);
		/** Calls one management endpoint; the `x-orchestrator-request` header marks the request as originating from this page. */
		async function api(messages, path, method, body) {
			let response;
			const json = body === void 0 ? {} : {
				headers: { "content-type": "application/json" },
				body: JSON.stringify(body)
			};
			try {
				response = await fetch(`/orchestrator/api/${path}`, {
					method,
					...json,
					headers: {
						"x-orchestrator-request": "1",
						...json.headers
					}
				});
			} catch {
				throw new ApiError(messages.offline, 0, { unreachable: true });
			}
			const text = await response.text();
			let value;
			try {
				value = text ? JSON.parse(text) : {};
			} catch {
				value = void 0;
			}
			if (!response.ok) {
				const failure = value ?? {};
				const issues = Array.isArray(failure.issues) ? failure.issues : [];
				const user = isUserError(failure.code) ? {
					code: failure.code,
					values: failure.values ?? {}
				} : void 0;
				const { status } = response;
				throw new ApiError(failure.setup ? messages.setup(failure.setup) : user ? messages.user(user) : typeof failure.error === "string" ? failure.error : !text && status === 404 ? messages.notRunning : status >= 500 ? messages.serverError(status) : messages.requestFailed(status), status, {
					issues,
					...failure.setup ? { setup: failure.setup } : {},
					...user ? { user } : {},
					...text ? {} : { unreachable: true }
				});
			}
			return value;
		}
		const HIDDEN_FACTOR = 6;
		const same$1 = (a, b) => a === b || JSON.stringify(a) === JSON.stringify(b);
		/**
		* Poll an endpoint while mounted, backing off when the document is hidden.
		* Preserves the last successful value across dependency changes and errors, skips state updates when the response is unchanged,
		* and drops stale responses when `deps` or `intervalMs` changes start a new subscription.
		*/
		function usePoll(load, deps, intervalMs = 5e3) {
			const [state, setState] = (0, react.useState)({});
			const loader = (0, react.useRef)(load);
			loader.current = load;
			const refresh = (0, react.useRef)(async () => {});
			(0, react.useEffect)(() => {
				let active = true;
				let timer;
				let queue = Promise.resolve();
				const once = async () => {
					clearTimeout(timer);
					try {
						const value = await loader.current();
						if (active) setState((previous) => same$1(previous.data, value) ? previous.error ? { data: previous.data } : previous : { data: value });
					} catch (failure) {
						if (active) setState((previous) => ({
							...previous,
							error: failure instanceof Error ? failure : new Error(String(failure))
						}));
					} finally {
						if (active) timer = setTimeout(run, document.hidden ? intervalMs * HIDDEN_FACTOR : intervalMs);
					}
				};
				const run = () => queue = queue.then(once);
				const shown = () => {
					if (!document.hidden) run();
				};
				refresh.current = run;
				run();
				document.addEventListener("visibilitychange", shown);
				return () => {
					active = false;
					clearTimeout(timer);
					document.removeEventListener("visibilitychange", shown);
				};
			}, [...deps, intervalMs]);
			const reload = (0, react.useCallback)(() => refresh.current(), []);
			return {
				data: state.data,
				error: state.error,
				reload
			};
		}
		const DECISION_FILTERS = [
			"work",
			"stop",
			"ignore",
			"unavailable",
			"all"
		];
		const DECISION_KINDS = {
			work: "accept,reopen",
			stop: "stop",
			ignore: "ignore",
			unavailable: "unavailable",
			all: ""
		};
		/** Build a typed route caller that resolves localized error messages on each request. */
		function caller(messages) {
			return (route, ...[request]) => {
				const [method, pattern] = route.split(" ");
				const values = request ?? {};
				const path = pattern.replace(/:(\w+)/g, (_match, name) => encodeURIComponent(String(values[name])));
				const query = Object.entries(values.query ?? {}).filter(([, value]) => value !== void 0 && value !== "").map(([name, value]) => `${name}=${encodeURIComponent(String(value))}`).join("&");
				return api(messages(), query ? `${path}?${query}` : path, method, values.body);
			};
		}
		//#endregion
		//#region src/client/client.css?raw
		var client_default = "/* Panel layout and local UI controls styled with DSH `--dsw-alias-*` design tokens; one rule per line. */\n.dt-page { box-sizing: border-box; height: 100%; overflow: auto; scrollbar-gutter: stable; scroll-padding: 48px 0 72px; container-type: inline-size; padding: 28px clamp(24px, 4vw, 48px) 0; color: var(--dsw-alias-label-primary); }\n/* Deployment page rendered inside DSH Plugin Manager, which owns scrolling and padding. */\n.dt-embedded { container-type: inline-size; color: var(--dsw-alias-label-primary); }\n/* Disable sticky positioning inside DSH Plugin Manager, where the host container owns scrolling and bottom padding. */\n.dt-embedded .dt-savebar { position: static; }\n.dt-page > .dt-column { max-width: 960px; margin: 0 auto; padding-bottom: 48px; display: flex; flex-direction: column; gap: 24px; }\n.dt-head { position: relative; z-index: 3; display: flex; align-items: flex-start; justify-content: space-between; gap: 8px 16px; flex-wrap: wrap; }\n.dt-search { position: relative; width: 240px; max-width: 100%; }\n.dt-search-results { position: absolute; top: calc(100% + 6px); right: 0; width: min(560px, 90cqw); max-height: 60vh; overflow: auto; padding: 8px 16px; border: 0.5px solid var(--dsw-alias-border-l3); border-radius: 12px; background: var(--dsw-alias-bg-layer-2); box-shadow: var(--dsw-elevation-prominent); z-index: 5; display: flex; flex-direction: column; gap: 8px; }\n.dt-mark { background: color-mix(in srgb, var(--dsw-alias-state-warn-primary) 25%, transparent); color: inherit; border-radius: 2px; }\n[data-platform='darwin'] .dt-page .dt-head { padding-top: var(--dsh-frame-top-clearance, 0px); }\n.dt-title { margin: 0; font-size: 15px; line-height: 22px; font-weight: 600; color: var(--dsw-alias-label-secondary); }\n.dt-toolbar { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }\n.dt-page .dt-tabs { overflow-x: auto; display: flex; gap: 20px; max-width: none; padding: 0; border-radius: 0; background: none; border-bottom: 0.5px solid var(--dsw-alias-border-l3); }\n.dt-segmented { width: 100%; max-width: 420px; box-sizing: border-box; display: inline-grid; gap: 2px; padding: 3px; border-radius: 9px; background: var(--dsw-alias-interactive-bg-hover); }\n.dt-form.dt-block { padding: 16px; border: 0.5px solid var(--dsw-alias-border-l3); border-radius: 16px; gap: 16px; }\n.dt-block-title { display: flex; align-items: center; gap: 4px; margin: 0; font-size: 16px; line-height: 24px; font-weight: 500; }\n.dt-section { display: flex; flex-direction: column; gap: 8px; min-width: 0; }\n.dt-section-title { margin: 0; display: flex; flex-wrap: wrap; align-items: baseline; gap: 8px; font-size: 13px; line-height: 20px; font-weight: 600; color: var(--dsw-alias-label-secondary); }\n.dt-section-name { white-space: nowrap; }\n.dt-count { font-size: 14px; color: var(--dsw-alias-label-caption); font-variant-numeric: tabular-nums; font-weight: 400; }\n.dt-hint { margin: 0; font-size: 13px; line-height: 20px; color: var(--dsw-alias-label-tertiary); }\n.dt-error { margin: 0; font-size: 13px; line-height: 20px; color: var(--dsw-alias-state-error-primary); }\n.dt-banner { margin: 0; padding: 8px 12px; border-radius: 10px; font-size: 13px; line-height: 20px; background: color-mix(in srgb, var(--dsw-alias-state-warn-primary) 10%, transparent); overflow-wrap: anywhere; }\n.dt-banner.dt-danger { background: color-mix(in srgb, var(--dsw-alias-state-error-primary) 10%, transparent); }\n.dt-list { list-style: none; margin: 0 -8px; padding: 0; display: flex; flex-direction: column; gap: 2px; }\n.dt-row { position: relative; min-width: 0; border-radius: 12px; padding: 10px 8px; display: flex; flex-wrap: wrap; gap: 4px 12px; align-items: flex-start; }\n.dt-row.dt-link:hover { background: var(--dsw-alias-interactive-bg-hover); }\n.dt-row-main { flex: 1 1 200px; min-width: 0; display: flex; flex-direction: column; gap: 4px; }\n.dt-disclosure-body .dt-row-main { flex-basis: 0; }\n.dt-row-title { display: flex; align-items: center; gap: 8px; min-width: 0; font-size: 14px; line-height: 20px; font-weight: 500; }\n.dt-open { max-width: 100%; padding: 0; border: 0; background: transparent; color: inherit; font: inherit; font-size: 14px; line-height: 20px; font-weight: 500; text-align: left; cursor: pointer; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }\n.dt-open::after { content: ''; position: absolute; inset: 0; border-radius: 12px; }\n.dt-open:focus-visible { outline: none; }\n.dt-open-wrap { white-space: normal; }\n.dt-open:focus-visible::after { outline: 2px solid var(--dsw-alias-brand-primary); outline-offset: 2px; }\n.dt-row-meta { display: flex; align-items: center; flex-wrap: wrap; gap: 4px 10px; font-size: 12px; line-height: 18px; color: var(--dsw-alias-label-caption); overflow-wrap: anywhere; }\n.dt-row-quote { font-size: 13px; line-height: 20px; color: var(--dsw-alias-label-secondary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }\n.dt-clamp { display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }\n/* Transparent block borders preserve vertical spacing when line clamping clips padding. */\n.dt-banner:is(.dt-clamp, .dt-clamp-8) { padding-block: 0; border-block: 8px solid transparent; }\n.dt-banner-label { font-weight: 500; }\n.dt-banner .dt-md { display: inline; }\n.dt-banner .dt-md > p:first-child { display: inline; }\n.dt-row-buttons { position: relative; z-index: 1; gap: 8px; margin-top: 4px; }\n.dt-row-actions { position: relative; z-index: 1; display: flex; align-items: center; gap: 4px; flex: none; margin-left: auto; font-size: 13px; line-height: 20px; }\n.dt-dot { flex: none; margin-top: 5px; }\n.dt-inline-link { position: relative; z-index: 1; color: var(--dsw-alias-link); text-decoration: none; }\n.dt-inline-link:hover { text-decoration: underline; }\n.dt-textlink { padding: 0; border: 0; background: none; font: inherit; color: var(--dsw-alias-link); cursor: pointer; text-align: left; }\n.dt-textlink:hover { text-decoration: underline; }\n.dt-actions { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; font-size: 13px; line-height: 20px; }\n.dt-kv { display: grid; grid-template-columns: max-content 1fr; gap: 6px 16px; margin: 0; font-size: 13px; line-height: 20px; }\n.dt-kv dt { color: var(--dsw-alias-label-tertiary); }\n.dt-kv dd { margin: 0; min-width: 0; overflow-wrap: anywhere; }\n.dt-timeline { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; }\n.dt-event { padding: 12px 0; border-bottom: 0.5px solid var(--dsw-alias-border-l2); display: flex; flex-direction: column; gap: 6px; min-width: 0; }\n.dt-event:last-child { border-bottom: 0; }\n.dt-event.dt-highlight { background: var(--dsw-alias-interactive-bg-hover); border-radius: 8px; padding-inline: 8px; margin-inline: -8px; }\n.dt-event-text { margin: 0; font-size: 13px; line-height: 20px; white-space: pre-wrap; overflow-wrap: anywhere; }\n.dt-event-actor { font-weight: 500; color: var(--dsw-alias-label-secondary); }\n.dt-event-quiet .dt-event-text { color: var(--dsw-alias-label-tertiary); }\n.dt-flow { margin: 0; font-size: 13px; line-height: 20px; color: var(--dsw-alias-label-secondary); }\n.dt-clamp-8 { display: -webkit-box; -webkit-line-clamp: 8; -webkit-box-orient: vertical; overflow: hidden; }\n.dt-more { align-self: flex-start; font-size: 12px; }\n.dt-reveal { opacity: 0; }\n.dt-event:hover .dt-reveal, .dt-reveal:focus-visible { opacity: 1; }\n@media (hover: none) {\n  .dt-reveal { opacity: 1; }\n}\n.dt-event-foot { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; font-size: 12px; line-height: 18px; color: var(--dsw-alias-label-tertiary); }\n.dt-filters { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }\n.dt-filters .dt-search { margin-left: auto; }\n.dt-form { display: flex; flex-direction: column; gap: 24px; }\n.dt-fieldset { display: flex; flex-direction: column; gap: inherit; min-width: 0; margin: 0; padding: 0; border: 0; }\n.dt-field { display: flex; flex-direction: column; gap: 6px; font-size: 13px; line-height: 20px; min-width: 0; }\n.dt-field small { color: var(--dsw-alias-label-caption); font-size: 12px; }\n.dt-textarea { box-sizing: border-box; width: 100%; min-width: 0; border: 0.5px solid var(--dsw-alias-border-l3); border-radius: 10px; padding: 8px 12px; font: inherit; font-size: 13px; line-height: 20px; color: var(--dsw-alias-label-primary); background: var(--dsw-alias-bg-layer-1, transparent); resize: vertical; }\n.dt-select { box-sizing: border-box; width: 100%; min-width: 0; height: 32px; border: 0.5px solid var(--dsw-alias-border-l4); border-radius: 8px; padding: 0 28px 0 8px; text-overflow: ellipsis; font: inherit; font-size: 14px; line-height: 22px; color: var(--dsw-alias-label-primary); background: var(--dsw-alias-bg-layer-1, transparent); }\n.dt-textarea:focus-visible, .dt-select:focus-visible { outline: 2px solid var(--dsw-alias-brand-primary); outline-offset: 1px; }\n.dt-mono { font-family: var(--ds-font-family-code, Menlo, monospace); font-size: 12px; overflow-wrap: anywhere; }\n.dt-detail { margin-top: 2px; color: var(--dsw-alias-label-secondary); }\n.dt-savebar .dt-error { white-space: pre-line; }\n.dt-switch-row { display: flex; align-items: center; justify-content: space-between; gap: 16px; min-height: 36px; font-size: 13px; }\n.dt-subhead-actions { display: inline-flex; align-items: center; gap: 4px; }\n.dt-btn-busy .dt-btn-icon svg { animation: dt-spin 1s linear infinite; }\n.dt-subhead { display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap; font-size: 13px; line-height: 20px; color: var(--dsw-alias-label-secondary); }\n.dt-rules, .dt-changes { list-style: none; margin: 0; padding: 0; }\n.dt-field-head { display: inline-flex; align-items: center; gap: 4px; color: var(--dsw-alias-label-secondary); }\n.dt-info { display: inline-flex; align-items: center; justify-content: center; width: 16px; height: 16px; padding: 0; border: 0; background: none; color: var(--dsw-alias-label-caption); cursor: help; }\n.dt-info:hover, .dt-info:focus-visible { color: var(--dsw-alias-label-secondary); }\n.dt-info:focus-visible { outline: 2px solid var(--dsw-alias-brand-primary); outline-offset: 2px; border-radius: 50%; }\n.dt-tooltip { position: fixed; z-index: 1100; width: max-content; max-width: min(320px, calc(100vw - 24px)); padding: 3px 7px; border-radius: 8px; background: var(--dsw-alias-tooltip-bg); color: var(--dsw-static-neutral-bluish-00); font-size: 13px; line-height: 20px; overflow-wrap: break-word; pointer-events: none; animation: dt-tooltip-in 150ms ease-in-out; }\n@keyframes dt-tooltip-in { from { opacity: 0; } }\n.dt-rules { border-top: 0.5px solid var(--dsw-alias-border-l2); }\n.dt-rule { display: flex; align-items: flex-start; gap: 12px; padding: 6px 0; border-bottom: 0.5px solid var(--dsw-alias-border-l2); }\n.dt-rule > :first-child { flex: 1; min-width: 0; }\n.dt-rule-preview { flex: 1; min-width: 0; margin-left: 8px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 12px; color: var(--dsw-alias-label-caption); }\n.dt-rule-switch { margin-top: 2px; flex: none; }\n.dt-rule-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: var(--dsw-alias-label-caption); }\n.dt-rule-dot[data-enabled] { background: var(--dsw-alias-brand-primary); }\n.dt-rule-body { display: flex; flex-direction: column; gap: 12px; padding: 8px 0 8px 28px; }\n.dt-model { display: flex; flex-direction: column; gap: 6px; }\n.dt-grid3 { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }\n.dt-changes { display: flex; flex-direction: column; gap: 2px; font-size: 13px; line-height: 20px; }\n.dt-changes li::before { content: '· '; color: var(--dsw-alias-label-caption); }\n.dt-main { display: flex; flex-direction: column; gap: 24px; min-width: 0; }\n.dt-modal.dt-glossary-modal { width: min(680px, 100%); }\n.dt-nav-item { display: flex; align-items: center; justify-content: space-between; gap: 8px; width: 100%; min-height: 32px; padding: 6px 10px; border: 0; border-radius: 8px; background: transparent; color: var(--dsw-alias-label-secondary); font: inherit; font-size: 13px; line-height: 20px; text-align: left; cursor: pointer; }\n.dt-nav-item:hover { background: var(--dsw-alias-interactive-bg-hover); }\n.dt-nav-item[aria-current='true'] { background: var(--dsw-alias-interactive-bg-hover); color: var(--dsw-alias-label-primary); font-weight: 500; }\n.dt-nav-item:focus-visible { outline: 2px solid var(--dsw-alias-brand-primary); outline-offset: -2px; }\n.dt-changed-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--dsw-alias-brand-primary); flex: none; }\n.dt-add-skill { display: flex; flex-direction: column; gap: 6px; margin-top: 8px; padding-top: 8px; border-top: 0.5px solid var(--dsw-alias-border-l2); }\n.dt-prompt-main { display: flex; flex-direction: column; gap: 12px; min-width: 0; }\n.dt-editor { min-height: 360px; }\n.dt-inline-select { width: auto; }\n.dt-preview-part { display: flex; flex-direction: column; gap: 6px; padding: 2px 0 2px 12px; border-left: 2px solid var(--dsw-alias-border-l3); }\n.dt-preview-head { font-size: 13px; line-height: 20px; display: flex; align-items: baseline; gap: 8px; }\ndiv.dt-preview-head { color: var(--dsw-alias-label-secondary); }\n.dt-card { display: flex; flex-direction: column; gap: 12px; padding: 16px; border: 0.5px solid var(--dsw-alias-border-l3); border-radius: 16px; min-width: 0; }\n.dt-card-head { display: flex; align-items: center; gap: 12px; min-height: 28px; }\n.dt-card-head .dt-row-main { flex: 1 1 0; min-width: 64px; }\n.dt-card-title { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }\n.dt-row-label { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 13px; font-weight: 500; }\n.dt-rows { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }\n.dt-rows-item { display: grid; grid-template-columns: repeat(var(--dt-columns), minmax(0, 1fr)) auto; gap: 8px; align-items: center; }\n.dt-filter-gap { flex: 1; }\n.dt-page-head { display: flex; flex-direction: column; align-items: flex-start; gap: 4px; }\n.dt-page-head > .dt-btn { margin-left: -10px; }\n.dt-page-title { display: flex; align-items: center; gap: 8px 16px; flex-wrap: wrap; width: 100%; }\n.dt-page-title h2 { margin: 0; flex: 1 1 auto; min-width: 0; font-size: 20px; line-height: 28px; font-weight: 500; overflow-wrap: anywhere; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }\n.dt-status-line { margin-top: -16px; }\n.dt-plain-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 4px; font-size: 13px; line-height: 20px; }\n.dt-details { display: flex; flex-direction: column; gap: 2px; border-top: 0.5px solid var(--dsw-alias-border-l2); padding-top: 8px; }\n.dt-danger-zone { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; padding-top: 16px; border-top: 0.5px solid var(--dsw-alias-border-l2); }\n.dt-danger-zone .dt-btn { color: var(--dsw-alias-state-error-primary); }\n.dt-md { display: flex; flex-direction: column; gap: 6px; font-size: 13px; line-height: 20px; overflow-wrap: anywhere; }\n.dt-md p, .dt-md ul, .dt-md ol { margin: 0; }\n.dt-md ul, .dt-md ol { padding-left: 20px; display: flex; flex-direction: column; gap: 2px; }\n.dt-md-heading { font-weight: 500; }\n.dt-code { font-family: var(--ds-font-family-code, Menlo, monospace); font-size: 12px; padding: 0 4px; border-radius: 4px; background: var(--dsw-alias-bg-module-platform); }\n.dt-dot-wrap { display: inline-flex; flex: none; }\n.dt-search-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; }\n.dt-ellipsis { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 280px; }\n.dt-legend-title { margin: 16px 0 6px; font-size: 13px; color: var(--dsw-alias-label-tertiary); }\n.dt-legend { list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: 6px 16px; font-size: 13px; }\n.dt-legend li { display: flex; align-items: center; gap: 6px; }\n.dt-legend .dt-dot { margin-top: 0; }\n.dt-savebar { position: sticky; bottom: 0; z-index: 2; display: flex; align-items: center; justify-content: flex-end; gap: 8px; flex-wrap: wrap; padding: 12px 0; background: var(--dsw-alias-bg-base, var(--dsw-alias-bg-layer-1)); border-top: 0.5px solid var(--dsw-alias-border-l2); }\n.dt-savebar .dt-hint { margin-right: auto; }\n.dt-card > .dt-savebar, .dt-block > .dt-savebar { margin: 0 -16px -16px; padding: 12px 16px; border-radius: 0 0 16px 16px; }\n.dt-glossary { width: 100%; border-collapse: collapse; font-size: 13px; line-height: 20px; }\n.dt-glossary th, .dt-glossary td { text-align: left; padding: 6px 8px; border-bottom: 0.5px solid var(--dsw-alias-border-l2); vertical-align: top; }\n.dt-glossary th { color: var(--dsw-alias-label-tertiary); font-weight: 400; }\n.dt-glossary th.dt-glossary-group { color: var(--dsw-alias-label-secondary); font-weight: 600; padding-top: 14px; }\n.dt-glossary th:nth-child(-n+2), .dt-glossary td:nth-child(-n+2) { white-space: nowrap; }\n.dt-values { display: grid; grid-template-columns: max-content 1fr; gap: 6px 16px; margin: 16px 0 0; font-size: 13px; }\n.dt-values dt { color: var(--dsw-alias-label-tertiary); }\n.dt-values dd { margin: 0; }\n.dt-pre { margin: 0; padding: 12px; border-radius: 10px; background: var(--dsw-alias-bg-module-platform); font-family: var(--ds-font-family-code, Menlo, monospace); font-size: 12px; line-height: 18px; white-space: pre-wrap; overflow-wrap: anywhere; max-height: 480px; overflow: auto; }\n.dt-pre ins { background: color-mix(in srgb, var(--dsw-alias-state-success-primary, green) 18%, transparent); text-decoration: none; }\n.dt-pre del { background: color-mix(in srgb, var(--dsw-alias-state-error-primary) 18%, transparent); text-decoration: none; }\n.dt-prompt { display: grid; grid-template-columns: 200px minmax(0, 1fr); gap: 20px; align-items: start; }\n.dt-prompt-nav { display: flex; flex-direction: column; gap: 2px; }\n.dt-prompt-nav button { justify-content: flex-start; }\n.dt-disclosure-body { padding: 8px 0 8px 28px; display: flex; flex-direction: column; gap: 8px; }\n@container (max-width: 640px) {\n  .dt-tab { padding: 0 8px; font-size: 13px; }\n  .dt-segment { padding: 0 10px; }\n  .dt-head { align-items: center; }\n  .dt-search-results { right: auto; left: 0; width: 100%; }\n  .dt-page-title h2 { font-size: 17px; line-height: 24px; }\n  .dt-status-line { margin-top: -12px; }\n  .dt-page .dt-tabs { display: flex; flex-wrap: nowrap; scrollbar-width: thin; }\n  .dt-page .dt-tab { flex: none; }\n  .dt-page .dt-tabs[data-more='end'] { mask-image: linear-gradient(to right, #000 calc(100% - 40px), transparent); }\n  .dt-page .dt-tabs[data-more='start'] { mask-image: linear-gradient(to right, transparent, #000 40px); }\n  .dt-page .dt-tabs[data-more='both'] { mask-image: linear-gradient(to right, transparent, #000 40px, #000 calc(100% - 40px), transparent); }\n  .dt-kv { grid-template-columns: 1fr; gap: 2px; }\n  .dt-grid3, .dt-prompt { grid-template-columns: 1fr; }\n  .dt-search { width: 100%; }\n  .dt-filters .dt-search { margin-left: 0; }\n}\n/* Local UI primitive styles (see controls.tsx). */\n.dt-btn { display: inline-flex; align-items: center; justify-content: center; gap: 4px; border: none; border-radius: 18px; cursor: pointer; font: inherit; font-size: 14px; line-height: 22px; color: var(--dsw-alias-label-primary); background: transparent; padding: 0 14px; white-space: nowrap; }\n.dt-btn:disabled { cursor: not-allowed; opacity: 0.4; }\n.dt-btn:focus-visible { outline: 2px solid var(--dsw-alias-brand-primary); outline-offset: 2px; }\n.dt-btn-md { height: 36px; }\n.dt-btn-sm { height: 28px; font-size: 12px; line-height: 18px; padding: 0 10px; border-radius: 14px; }\n.dt-btn-primary { background: var(--dsw-alias-button-primary-fill); color: var(--dsw-alias-label-primary-foreground); }\n.dt-btn-primary:hover:not(:disabled) { background: var(--dsw-alias-button-primary-hover); }\n.dt-btn-ghost:hover:not(:disabled), .dt-btn-outline:hover:not(:disabled) { background: var(--dsw-alias-interactive-bg-hover); }\n.dt-btn-ghost:active:not(:disabled) { background: var(--dsw-alias-interactive-bg-active); }\n.dt-btn-outline { border: 0.5px solid var(--dsw-alias-border-l3); }\n.dt-btn-icon { display: inline-flex; width: 16px; height: 16px; align-items: center; justify-content: center; }\n.dt-tag { display: inline-flex; align-items: center; border-radius: 999px; padding: 1px 8px; font-size: 11px; line-height: 17px; font-weight: 500; white-space: nowrap; }\n.dt-tag[data-tone='outline'] { border: 0.5px solid var(--dsw-alias-border-l4); color: var(--dsw-alias-label-tertiary); }\n.dt-tag[data-tone='neutral'] { background: var(--dsw-alias-bg-module-platform); color: var(--dsw-alias-label-secondary); }\n.dt-tag[data-tone='quiet'] { color: var(--dsw-alias-label-tertiary); }\n.dt-tag[data-tone='success'] { background: color-mix(in srgb, var(--dsw-alias-state-success-primary) 10%, transparent); color: var(--dsw-alias-state-success-primary); }\n.dt-tag[data-tone='info'] { background: color-mix(in srgb, var(--dsw-alias-state-business-primary) 10%, transparent); color: var(--dsw-alias-state-business-primary); }\n.dt-tag[data-tone='warning'] { background: color-mix(in srgb, var(--dsw-alias-state-warn-primary) 12%, transparent); color: var(--dsw-alias-state-warn-primary); }\n.dt-tag[data-tone='danger'] { background: color-mix(in srgb, var(--dsw-alias-state-error-primary) 10%, transparent); color: var(--dsw-alias-state-error-primary); }\n.dt-pill { display: inline-flex; align-items: center; gap: 4px; height: 24px; padding: 0 8px; border: none; border-radius: 12px; font: inherit; font-size: 12px; line-height: 18px; color: var(--dsw-alias-label-secondary); background: var(--dsw-alias-bg-layer-2); cursor: pointer; }\n.dt-pill:hover { background: var(--dsw-alias-interactive-bg-hover); }\n.dt-pill-active, .dt-pill-active:hover { color: var(--dsw-alias-label-primary); background: var(--dsw-alias-button-ghost-active-fill); box-shadow: inset 0 0 0 1px var(--dsw-alias-button-ghost-active-border); }\n.dt-tabs { display: grid; padding: 4px; border-radius: 12px; background: var(--dsw-alias-bg-module-platform); }\n.dt-tab { box-sizing: border-box; height: 34px; padding: 0 12px; border: 0.5px solid transparent; border-radius: 8px; background: transparent; color: var(--dsw-alias-label-secondary); font: inherit; font-size: 14px; line-height: 20px; white-space: nowrap; cursor: pointer; transition: color 180ms ease, background 180ms ease; }\n.dt-tab:hover { color: var(--dsw-alias-label-primary); }\n.dt-tab[aria-selected='true'] { color: var(--dsw-alias-label-primary); font-weight: 600; background: var(--dsw-alias-bg-layer-3); border-color: var(--dsw-alias-border-l3); }\n.dt-tab:focus-visible { outline: none; text-decoration: underline; text-underline-offset: 4px; }\n.dt-segment { height: 28px; padding: 0 16px; border: 0; border-radius: 7px; background: transparent; color: var(--dsw-alias-label-secondary); font: inherit; font-size: 13px; line-height: 20px; font-weight: 500; white-space: nowrap; cursor: pointer; transition: color 120ms ease, background 160ms ease; }\n.dt-segment:hover:not(:disabled), .dt-segment[aria-selected='true'] { color: var(--dsw-alias-label-primary); }\n.dt-segment[aria-selected='true'] { background: var(--dsw-alias-bg-layer-1); box-shadow: var(--dsw-elevation-soft); }\n.dt-segment:disabled { cursor: default; opacity: 0.4; }\n.dt-segment:focus-visible { outline: 2px solid var(--dsw-alias-brand-primary); outline-offset: -2px; }\n.dt-input { box-sizing: border-box; display: inline-flex; align-items: center; gap: 6px; height: 32px; min-width: 0; padding: 0 8px; border: 0.5px solid var(--dsw-alias-border-l4); border-radius: 8px; background: var(--dsw-alias-bg-layer-1); }\n.dt-input:focus-within { border-color: var(--dsw-alias-brand-primary); }\n.dt-input-icon { display: inline-flex; width: 16px; height: 16px; align-items: center; justify-content: center; color: var(--dsw-alias-label-tertiary); }\n.dt-input input { flex: 1; min-width: 0; border: none; outline: none; background: transparent; font: inherit; font-size: 14px; line-height: 22px; color: var(--dsw-alias-label-primary); }\n.dt-input input::placeholder { color: var(--dsw-alias-label-dimmed); }\n.dt-input input::-webkit-search-cancel-button { -webkit-appearance: none; appearance: none; }\n.dt-field .dt-input, .dt-search .dt-input, .dt-add-skill .dt-input { display: flex; width: 100%; }\n.dt-switch { box-sizing: border-box; flex: 0 0 auto; width: 36px; height: 20px; padding: 2px; border: 0; border-radius: 10px; background: var(--dsw-alias-border-l3); cursor: pointer; }\n.dt-switch[aria-checked='true'] { background: var(--dsw-alias-brand-primary); }\n.dt-switch:focus-visible { outline: 2px solid var(--dsw-alias-brand-primary); outline-offset: 2px; }\n.dt-switch-thumb { display: block; width: 16px; height: 16px; border-radius: 50%; background: var(--dsw-alias-label-primary-foreground); transition: transform 120ms ease; }\n.dt-switch[aria-checked='true'] .dt-switch-thumb { transform: translateX(16px); }\n.dt-state-dot { position: relative; display: inline-block; flex: none; width: 10px; height: 10px; color: var(--dsw-alias-state-idle-primary); }\n.dt-state-dot::after { content: ''; position: absolute; inset: 20%; border-radius: 50%; background: currentColor; }\n.dt-state-dot[data-state='done'] { color: var(--dsw-alias-state-success-primary); }\n.dt-state-dot[data-state='warning'] { color: var(--dsw-alias-state-warn-primary); }\n.dt-state-dot[data-state='error'] { color: var(--dsw-alias-state-error-primary); }\n.dt-spinner { flex: none; color: var(--dsw-alias-label-tertiary); }\n.dt-spinner g { transform-origin: center; animation: dt-spin 1.5s linear infinite; }\n.dt-spinner circle { fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; }\n.dt-spinner circle:first-child { opacity: 0.25; }\n.dt-spinner circle:last-child { stroke-dasharray: 18 150; }\n@keyframes dt-spin { to { transform: rotate(360deg); } }\n.dt-disclosure-row { display: flex; align-items: center; gap: 4px; min-height: 28px; min-width: 0; border-radius: 8px; cursor: pointer; font-size: 13px; line-height: 20px; color: var(--dsw-alias-label-secondary); }\n.dt-disclosure-row:hover { color: var(--dsw-alias-label-primary); }\n.dt-disclosure-row:focus-visible { outline: 2px solid var(--dsw-alias-brand-primary); outline-offset: 2px; }\n.dt-disclosure-lead { position: relative; display: inline-flex; flex: none; width: 24px; height: 24px; align-items: center; justify-content: center; }\n.dt-disclosure-icon { display: inline-flex; align-items: center; justify-content: center; }\n.dt-disclosure-chevron { position: absolute; inset: 0; display: none; align-items: center; justify-content: center; }\n.dt-disclosure-row:hover .dt-disclosure-icon, .dt-disclosure[data-open] .dt-disclosure-icon { visibility: hidden; }\n.dt-disclosure-row:hover .dt-disclosure-chevron, .dt-disclosure[data-open] .dt-disclosure-chevron { display: inline-flex; }\n.dt-disclosure-title { flex: 0 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }\n.dt-modal-root { position: fixed; inset: 0; z-index: 1000; display: flex; align-items: center; justify-content: center; padding: max(24px, var(--dsh-frame-top-clearance, 24px)) 24px; }\n.dt-modal-mask { position: absolute; inset: 0; background: var(--dsw-alias-bg-mask-1); backdrop-filter: var(--dsw-mask-blur); }\n.dt-modal { position: relative; z-index: 1; display: flex; flex-direction: column; gap: 20px; width: min(380px, 100%); max-height: 100%; padding: 0 0 24px; overflow: hidden; border-radius: 24px; background: var(--dsw-alias-bg-layer-2); box-shadow: var(--dsw-elevation-prominent); color: var(--dsw-alias-label-primary); outline: none; }\n.dt-modal-header { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 22px 14px 0 24px; }\n.dt-modal-header h2 { margin: 0; font-size: 16px; line-height: 24px; font-weight: 500; }\n.dt-modal-close { display: inline-flex; align-items: center; justify-content: center; width: 28px; height: 28px; border: none; border-radius: 8px; background: transparent; cursor: pointer; color: var(--dsw-alias-label-secondary); }\n.dt-modal-close:hover { background: var(--dsw-alias-interactive-bg-hover); }\n.dt-modal-description { margin: -8px 0 0; padding: 0 24px; font-size: 14px; line-height: 22px; }\n.dt-modal-body { min-width: 0; min-height: 0; overflow: auto; padding: 0 24px; }\n.dt-modal-footer { display: flex; align-items: center; justify-content: flex-end; gap: 8px; padding: 0 24px; }\n.dt-toast { position: fixed; top: 40px; left: 50%; z-index: 1100; pointer-events: none; width: max-content; max-width: min(640px, calc(100vw - 48px)); padding: 12px 16px; border-radius: 14px; background: var(--dsw-alias-toast-bg); color: var(--dsw-static-neutral-bluish-00); font-size: 14px; line-height: 22px; box-shadow: var(--dsw-shadow-lv3); transform: translateX(-50%); animation: dt-toast-in 160ms ease-out, dt-toast-fade 1000ms ease var(--dt-toast-hold, 3000ms) forwards; }\n@keyframes dt-toast-in { from { opacity: 0; transform: translate(-50%, -6px); } to { opacity: 1; transform: translate(-50%, 0); } }\n@keyframes dt-toast-fade { to { opacity: 0; visibility: hidden; } }\n@media (prefers-reduced-motion: reduce) {\n  .dt-tab, .dt-segment, .dt-switch-thumb, .dt-spinner g, .dt-btn-busy .dt-btn-icon svg, .dt-tooltip { transition: none; animation: none; }\n  .dt-toast { animation: dt-toast-fade 1000ms ease var(--dt-toast-hold, 3000ms) forwards; }\n}\n.dt-page .dt-tab { height: 34px; padding: 0 2px; border: 0; border-radius: 0; color: var(--dsw-alias-label-tertiary); font-size: 14px; }\n.dt-page .dt-tab[aria-selected='true'] { background: none; color: var(--dsw-alias-label-primary); font-weight: 500; box-shadow: inset 0 -1.5px 0 var(--dsw-alias-label-primary); }\n.dt-status-head { display: flex; align-items: center; gap: 8px; }\n.dt-status-title { margin: 0; flex: 1; display: flex; align-items: center; gap: 4px; font-size: 15px; line-height: 22px; font-weight: 600; }\n.dt-status-text { margin-left: auto; flex: none; font-size: 12px; font-weight: 400; color: var(--dsw-alias-label-secondary); }\n.dt-status-line .dt-status-text { margin-left: 0; }\n.dt-status-text[data-state='warning'] { color: var(--dsw-alias-state-warn-primary); }\n.dt-status-text[data-state='error'] { color: var(--dsw-alias-state-error-primary); }\n.dt-row-name { min-width: 0; overflow: hidden; text-overflow: ellipsis; }\n.dt-lv { white-space: nowrap; }\n.dt-lv-label { color: var(--dsw-alias-label-caption); }\n.dt-lv-value { color: var(--dsw-alias-label-secondary); font-variant-numeric: tabular-nums; }\n.dt-chip { display: inline-flex; flex-wrap: wrap; max-width: 100%; border: 0.5px solid var(--dsw-alias-border-l3); border-radius: 6px; overflow: hidden; font-size: 11px; line-height: 18px; color: var(--dsw-alias-label-secondary); }\n.dt-chip-source { padding: 0 6px; color: var(--dsw-alias-label-tertiary); background: var(--dsw-alias-bg-module-platform); }\n.dt-chip-fact { padding: 0 6px; border-left: 0.5px solid var(--dsw-alias-border-l3); white-space: nowrap; }\n.dt-chip-label { margin-right: 4px; color: var(--dsw-alias-label-caption); }\n.dt-chip-link { position: relative; z-index: 1; text-decoration: none; cursor: pointer; transition: border-color 120ms ease; }\n.dt-chip-link:hover { border-color: var(--dsw-alias-brand-primary); }\n.dt-chip-link:focus-visible { outline: 2px solid var(--dsw-alias-brand-primary); outline-offset: 1px; }\n.dt-chip-open { display: inline-flex; align-items: center; padding: 0 5px; border-left: 0.5px solid var(--dsw-alias-border-l3); color: var(--dsw-alias-brand-primary); }\n.dt-chip-problem, .dt-chip-problem .dt-chip-label { color: var(--dsw-alias-state-error-primary); }\n.dt-cards { gap: 8px; }\n.dt-att .dt-inline-link { font-size: 13px; font-weight: 500; }\n.dt-list > .dt-att { margin: 2px 8px; }\n.dt-att { padding: 10px 12px 10px 16px; border: 0; border-radius: 0; border-bottom: 0.5px solid var(--dsw-alias-border-l3); }\n.dt-att::before { content: ''; position: absolute; left: 6px; top: 10px; bottom: 10px; width: 2px; border-radius: 1px; background: var(--dsw-alias-state-warn-primary); opacity: 0.7; }\n.dt-att-error::before { background: var(--dsw-alias-state-error-primary); }\n.dt-att-what { font-size: 12px; line-height: 18px; font-weight: 500; color: var(--dsw-alias-state-warn-primary); }\n.dt-att-error .dt-att-what, .dt-att-error .dt-att-what .dt-open { color: var(--dsw-alias-state-error-primary); }\n.dt-stats { display: flex; flex-wrap: wrap; gap: 6px 20px; }\n.dt-stat { display: inline-flex; align-items: baseline; gap: 6px; font-size: 12px; color: var(--dsw-alias-label-caption); }\n.dt-stat-value { font-size: 14px; font-weight: 500; color: var(--dsw-alias-label-primary); font-variant-numeric: tabular-nums; }\n.dt-more-link { font-size: 12px; font-weight: 400; }\n.dt-settings { display: grid; grid-template-columns: 140px minmax(0, 1fr); gap: 24px; align-items: start; }\n.dt-settings-nav { position: sticky; top: 0; display: flex; flex-direction: column; gap: 2px; }\n.dt-settings-link { padding: 6px 10px; border: 0; border-radius: 8px; background: none; color: var(--dsw-alias-label-secondary); font: inherit; font-size: 14px; text-align: left; cursor: pointer; }\n.dt-settings-link:hover { color: var(--dsw-alias-label-primary); }\n.dt-settings-link[aria-current='page'] { background: var(--dsw-alias-bg-module-platform); color: var(--dsw-alias-label-primary); font-weight: 500; }\n.dt-settings-link[data-stage] + .dt-settings-link:not([data-stage]) { margin-top: 10px; }\n.dt-settings-body { display: flex; flex-direction: column; gap: 16px; min-width: 0; }\n.dt-settings-title { margin: 0; font-size: 15px; line-height: 22px; font-weight: 600; }\n.dt-subtabs { display: flex; gap: 16px; border-bottom: 0.5px solid var(--dsw-alias-border-l3); }\n.dt-subtab { padding: 0 0 6px; border: 0; background: none; color: var(--dsw-alias-label-tertiary); font: inherit; font-size: 13px; cursor: pointer; }\n.dt-subtab[aria-selected='true'] { color: var(--dsw-alias-label-primary); font-weight: 500; box-shadow: inset 0 -1.5px 0 var(--dsw-alias-label-primary); }\n.dt-part { display: flex; flex-direction: column; gap: 12px; }\n.dt-rows-summary { text-align: left; color: var(--dsw-alias-label-secondary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 100%; }\n.dt-table { width: 100%; border-collapse: collapse; font-size: 12px; line-height: 18px; }\n.dt-table th { text-align: left; font-weight: 400; color: var(--dsw-alias-label-caption); padding: 2px 8px 2px 0; }\n.dt-table td { padding: 4px 8px 4px 0; border-top: 0.5px solid var(--dsw-alias-border-l3); vertical-align: top; color: var(--dsw-alias-label-secondary); overflow-wrap: anywhere; }\n@container (max-width: 640px) {\n  .dt-settings { grid-template-columns: 1fr; gap: 12px; }\n  .dt-settings-nav { position: static; flex-direction: row; flex-wrap: wrap; }\n  .dt-settings-link[data-stage] + .dt-settings-link:not([data-stage]) { margin-top: 0; }\n  .dt-page .dt-tabs { gap: 14px; }\n}\n.dt-list > .dt-ticket { display: grid; grid-template-columns: 112px minmax(0, 1fr); column-gap: 12px; align-items: start; margin: 0; padding: 12px 8px 12px 18px; border-radius: 0; border-bottom: 0.5px solid var(--dsw-alias-border-l3); }\n.dt-list > .dt-ticket[data-state]::before { content: ''; position: absolute; left: 6px; top: 12px; bottom: 12px; width: 2px; border-radius: 1px; background: var(--dsw-alias-state-warn-primary); opacity: 0.7; }\n.dt-list > .dt-ticket[data-state='error']::before { background: var(--dsw-alias-state-error-primary); }\n.dt-ticket-stage { align-self: stretch; padding-top: 1px; border-right: 0.5px solid var(--dsw-alias-border-l3); }\n.dt-ticket-body { display: flex; flex-direction: column; gap: 4px; min-width: 0; }\n.dt-ticket-body .dt-row-title .dt-open { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }\n.dt-ticket-meta { flex-wrap: nowrap; overflow: hidden; white-space: nowrap; }\n.dt-ticket-meta .dt-chip { flex: none; }\n.dt-ticket-note { min-width: 0; overflow: hidden; text-overflow: ellipsis; color: var(--dsw-alias-label-primary); }\n.dt-ticket-note-error { color: var(--dsw-alias-state-error-primary); }\n.dt-ticket-actions { position: relative; z-index: 1; display: flex; flex-wrap: wrap; gap: 8px; min-height: 30px; margin-top: 2px; }\n/* Pass pointer events through action containers to the row link, keeping only child controls interactive. */\n.dt-ticket-actions, .dt-row-buttons, .dt-row-actions { pointer-events: none; }\n.dt-ticket-actions > *, .dt-row-buttons > *, .dt-row-actions > * { pointer-events: auto; }\n.dt-line { min-height: 20px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }\n.dt-row-meta.dt-line { flex-wrap: nowrap; }\n.dt-line-text { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }\n.dt-error-text { color: var(--dsw-alias-state-error-primary); }\n.dt-stage { display: inline-flex; align-items: flex-start; gap: 5px; font-size: 12px; line-height: 18px; font-weight: 500; color: var(--dsw-alias-label-secondary); }\n.dt-stage svg { flex: none; margin-top: 2px; }\n.dt-stage[data-state='warning'] { color: var(--dsw-alias-state-warn-primary); }\n.dt-stage[data-state='error'] { color: var(--dsw-alias-state-error-primary); }\n.dt-stage[data-state='ongoing'] { color: var(--dsw-alias-state-business-primary); }\n.dt-icon-link { display: inline-flex; align-items: center; gap: 4px; }\na.dt-btn, a.dt-btn:hover { text-decoration: none; }\n.dt-section-icon { display: inline-flex; align-self: center; color: var(--dsw-alias-label-tertiary); }\n.dt-trigger-link { display: flex; flex-direction: column; gap: 2px; width: 100%; margin: -4px 0 -4px -8px; padding: 4px 8px; border: 0; border-radius: 8px; background: none; font: inherit; color: inherit; text-align: left; cursor: pointer; }\n.dt-trigger-link:hover { background: var(--dsw-alias-interactive-bg-hover); }\n.dt-trigger-link:focus-visible { outline: 2px solid var(--dsw-alias-brand-primary); outline-offset: 1px; }\n.dt-trigger-text { display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }\n.dt-kv-stack { display: flex; flex-direction: column; gap: 2px; min-width: 0; }\n.dt-banner-actions { margin-top: 6px; }\n@container (max-width: 640px) {\n  .dt-list > .dt-ticket { grid-template-columns: 1fr; row-gap: 4px; }\n  .dt-ticket-stage { border-right: 0; }\n}\n.dt-nav-group { margin: 10px 10px 2px; font-size: 12px; font-weight: 600; color: var(--dsw-alias-label-secondary); }\n.dt-nav-group:first-child { margin-top: 0; }\n.dt-prompt-nav .dt-nav-item { flex-direction: column; align-items: flex-start; gap: 2px; text-align: left; }\n.dt-nav-item > span { display: inline-flex; align-items: center; gap: 6px; }\n.dt-nav-item small { font-size: 12px; line-height: 18px; font-weight: 400; color: var(--dsw-alias-label-caption); }\n.dt-preview-part[data-editable] { border-left-color: var(--dsw-alias-brand-primary); }\n.dt-preview-head b { font-weight: 500; }\n.dt-preview-head > span { font-size: 12px; color: var(--dsw-alias-label-caption); }\n.dt-changed-tag { margin-left: 6px; padding: 0 5px; border: 0.5px solid var(--dsw-alias-border-l3); border-radius: 4px; font-size: 11px; line-height: 16px; font-weight: 400; color: var(--dsw-alias-label-secondary); }\n.dt-updated-tag { border-color: var(--dsw-alias-state-warn-primary); color: var(--dsw-alias-state-warn-primary); }\n.dt-default-updated { display: flex; flex-direction: column; gap: 6px; padding: 2px 0 2px 12px; border-left: 2px solid var(--dsw-alias-state-warn-primary); }\n.dt-diff-fold { color: var(--dsw-alias-label-caption); font-style: italic; }\n.dt-compare { margin-left: auto; }\n.dt-admission th { white-space: nowrap; }\n.dt-admission thead tr:first-child th:not(:first-child) { color: var(--dsw-alias-label-secondary); font-weight: 500; }\n.dt-admission td { vertical-align: middle; }\n.dt-admission-scope { color: var(--dsw-alias-label-primary); font-size: 13px; }\n.dt-admission-scope small { display: block; font-size: 11px; color: var(--dsw-alias-label-caption); }\n.dt-admission-na { color: var(--dsw-alias-label-caption); }\n.dt-admission-cell { display: flex; align-items: center; gap: 4px; }\n.dt-admission-cell .dt-select { flex: 1; min-width: 0; }\n.dt-admission-slot { display: inline-flex; flex: none; width: 16px; }\n.dt-info-warn { color: var(--dsw-alias-state-warn-primary); }\n.dt-field-segmented { max-width: 240px; }\n";
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
		/** Formats reasons in English (prefixed by `triggerId` when present) for agent consumption. */
		function reasonText(reasons) {
			return [reasons ?? []].flat().map((reason) => {
				const text = (REASONS[reason.code] ?? reason.code).replace(/\{(\w+)\}/g, (match, name) => reason.values?.[name] ?? match);
				return reason.triggerId ? `${reason.triggerId}: ${text}` : text;
			}).join("; ");
		}
		//#endregion
		//#region src/client/text.ts
		const errorText = (failure) => failure instanceof Error ? failure.message : String(failure);
		const localized = (t, text) => typeof text === "string" ? text : text ? text[t("lang") === "en" ? "en" : "zh"] : "";
		const actorName = (t, actor) => actor?.name ? localized(t, actor.name) : t("automatedNotice");
		function valueLabel(t, group, key) {
			if (!key) return "";
			const name = `${group}.${key}`;
			const text = t(name);
			return text === name ? key : text;
		}
		/** Format one or more structured or raw reasons in the active UI language, truncating multi-line host errors to their first line. */
		function reasonLabel(t, reason) {
			if (typeof reason === "string") return reason ? label(t, { code: reason }) : "";
			return [reason ?? []].flat().map((item) => label(t, item)).filter(Boolean).join("；");
		}
		function label(t, reason) {
			const key = `reason.${reason.code}`;
			const text = reason.code === "said" ? reason.values?.text ?? "" : t(key, reason.values);
			if (reason.code !== "said" && text !== key) return text;
			const written = reason.code === "said" ? text : reasonText({
				...reason,
				triggerId: void 0
			});
			if (/^\w*Error\b/.test(written)) {
				const first = written.split("\n")[0];
				return first.length > 140 ? `${first.slice(0, 140)}…` : first;
			}
			return written;
		}
		const setupText = (t, problem) => t(`setup.${problem.code}`, problem.values);
		const healthText = (t, health) => health.code ? t(`healthCode.${health.code}`, health.values) : health.detail;
		/** Replaces Feishu and GitHub content placeholders (images, cards, media, forwards, unresolved mentions) with localized labels. */
		function readableMarkers(t, text) {
			return text.replace(/!\[[^\]]*\]\([^)]*\)|\[Image: [^\]]*\]|\[image\]/g, t("imageMarker")).replace(/\[Chat card: [^\]]*\]/g, t("cardMarker")).replace(/\[Media: [^\]]*\]/g, t("mediaMarker")).replace(/\[Merged forward\]/g, t("forwardMarker")).replace(/@_user_\d+/g, t("unknownMention"));
		}
		const timeLocale = (lang) => lang === "en" ? "en" : "zh-CN";
		function when(value, lang) {
			if (!value) return "";
			const date = new Date(value);
			if (Number.isNaN(date.getTime())) return value;
			const seconds = Math.round((date.getTime() - Date.now()) / 1e3);
			if (Math.abs(seconds) < 86400) {
				const relative = new Intl.RelativeTimeFormat(timeLocale(lang), { numeric: "auto" });
				if (Math.abs(seconds) < 60) return relative.format(0, "second");
				if (Math.abs(seconds) < 3600) return relative.format(Math.round(seconds / 60), "minute");
				return relative.format(Math.round(seconds / 3600), "hour");
			}
			const year = date.getFullYear() === (/* @__PURE__ */ new Date()).getFullYear() ? {} : { year: "numeric" };
			return date.toLocaleString(timeLocale(lang), {
				...year,
				month: "short",
				day: "numeric",
				hour: "2-digit",
				minute: "2-digit"
			});
		}
		function fullTime(value, lang) {
			const date = new Date(value ?? "");
			return Number.isNaN(date.getTime()) ? "" : date.toLocaleString(timeLocale(lang));
		}
		//#endregion
		//#region src/client/provider.tsx
		/** Shared panel React contexts, state polling, restart detection, and action runner hook. */
		const Panel = (0, react.createContext)(void 0);
		const PanelState = (0, react.createContext)(void 0);
		function usePanel() {
			const value = (0, react.useContext)(Panel);
			if (!value) throw new Error("dsh-superagent page rendered outside its panel");
			return value;
		}
		function usePanelData() {
			const value = (0, react.useContext)(PanelState);
			if (!value) throw new Error("dsh-superagent page rendered outside its panel");
			return value;
		}
		/** Wrap an async action with re-entrancy protection, busy state, optional reload, and error toast reporting. */
		function useAction(action, { reload } = {}) {
			const { notify } = usePanel();
			const [busy, setBusy] = (0, react.useState)(false);
			const running = (0, react.useRef)(false);
			const run = async (...args) => {
				if (running.current) return false;
				running.current = true;
				setBusy(true);
				try {
					await action(...args);
					await reload?.();
					return true;
				} catch (failure) {
					notify(errorText(failure));
					return false;
				} finally {
					running.current = false;
					setBusy(false);
				}
			};
			return {
				run,
				busy
			};
		}
		const messages = (t) => ({
			offline: t("offline"),
			notRunning: t("hostNotRunning"),
			serverError: (status) => t("serverError", { status }),
			requestFailed: (status) => t("requestFailed", { status }),
			setup: (problem) => problem.values.output ? `${setupText(t, problem)}\n${problem.values.output}` : setupText(t, problem),
			user: ({ code, values }) => t(`userError.${code}`, values.part ? {
				...values,
				part: valueLabel(t, "promptPart", values.part)
			} : values)
		});
		function Toast({ text, onDone, holdMs = 3e3 }) {
			const done = (0, react.useRef)(onDone);
			done.current = onDone;
			(0, react.useEffect)(() => {
				const timer = setTimeout(() => done.current(), holdMs + 1e3);
				return () => clearTimeout(timer);
			}, [holdMs]);
			return (0, react_dom.createPortal)(/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
				className: "dt-toast",
				role: "status",
				style: { ["--dt-toast-hold"]: `${holdMs}ms` },
				children: text
			}), document.body);
		}
		const stay = () => {};
		const noSession = async () => {};
		function PanelProvider({ t, interval = 5e3, openSession = noSession, navigate = stay, back = stay, backLabel = "", children }) {
			const copy = (0, react.useRef)(t);
			copy.current = t;
			const call = (0, react.useMemo)(() => caller(() => messages(copy.current)), []);
			const [toast, setToast] = (0, react.useState)();
			const notify = (0, react.useCallback)((text) => setToast({
				text,
				id: Date.now()
			}), []);
			const [restarting, setRestarting] = (0, react.useState)();
			const [restarts, setRestarts] = (0, react.useState)(0);
			const restart = (0, react.useCallback)(() => setRestarting({ down: false }), []);
			const { data: state, error, reload } = usePoll(() => call("GET state"), [call], restarting ? 1e3 : interval);
			if (restarting && !!error !== restarting.down) {
				setRestarting(error ? { down: true } : void 0);
				if (!error) setRestarts(restarts + 1);
			}
			(0, react.useEffect)(() => {
				if (!restarting) return;
				const timer = setTimeout(() => setRestarting(void 0), 3e4);
				return () => clearTimeout(timer);
			}, [restarting]);
			const context = (0, react.useMemo)(() => ({
				t,
				call,
				navigate,
				back,
				backLabel,
				openSession,
				notify,
				restart
			}), [
				t,
				call,
				navigate,
				back,
				backLabel,
				openSession,
				notify,
				restart
			]);
			const data = (0, react.useMemo)(() => ({
				state,
				error,
				reload,
				setup: state?.setup,
				running: state?.load.running ?? 0,
				restarts
			}), [
				state,
				error,
				reload,
				restarts
			]);
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Panel.Provider, {
				value: context,
				children: /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(PanelState.Provider, {
					value: data,
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("style", { children: client_default }),
						children,
						toast && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Toast, {
							text: toast.text,
							onDone: () => setToast(void 0)
						}, toast.id)
					]
				})
			});
		}
		//#endregion
		//#region src/client/draft.tsx
		/**
		* Optimistic settings draft state with sessionStorage persistence and three-way rebase against concurrent saves.
		*/
		const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
		const isRecord = (value) => !!value && typeof value === "object" && !Array.isArray(value);
		const LIST_KEYS = ["id", "chatId"];
		const named = (list, field) => list.every((item) => isRecord(item) && typeof item[field] === "string") && new Set(list.map((item) => item[field])).size === list.length;
		/**
		* Three-way merge between `base`, local `mine`, and remote `theirs`.
		* Merges objects by key and arrays of keyed records (`id` or `chatId`) by element: a key or element removed by one side is
		* deleted if the other side left it unchanged; a removal against a modification keeps `mine` and is recorded in `conflicts`.
		*/
		function merge3(base, mine, theirs, conflicts = [], path = []) {
			if (same(mine, base) || same(mine, theirs)) return theirs;
			if (same(theirs, base)) return mine;
			if (Array.isArray(mine) && Array.isArray(theirs) && (base === void 0 || Array.isArray(base))) {
				const lists = [
					base ?? [],
					mine,
					theirs
				];
				const field = LIST_KEYS.find((name) => lists.every((list) => named(list, name)));
				if (field) return mergeList(lists, field, conflicts, path);
			}
			if (!isRecord(base) || !isRecord(mine) || !isRecord(theirs)) {
				conflicts.push(path);
				return mine;
			}
			const merged = {};
			for (const key of /* @__PURE__ */ new Set([...Object.keys(theirs), ...Object.keys(mine)])) {
				const value = merge3(base[key], mine[key], theirs[key], conflicts, [...path, key]);
				if (value !== void 0) merged[key] = value;
			}
			return merged;
		}
		function mergeList([base, mine, theirs], field, conflicts, path) {
			const name = (item) => String(item[field]);
			const [before, ours, others] = [
				base,
				mine,
				theirs
			].map((list) => new Map(list.map((item) => [name(item), item])));
			const order = theirs.map(name);
			mine.forEach((item, index) => {
				if (order.includes(name(item))) return;
				const previous = mine.slice(0, index).map(name).reverse().find((key) => order.includes(key));
				order.splice(previous === void 0 ? 0 : order.indexOf(previous) + 1, 0, name(item));
			});
			return order.flatMap((key) => {
				const value = merge3(before.get(key), ours.get(key), others.get(key), conflicts, [...path, key]);
				return value === void 0 ? [] : [value];
			});
		}
		function read(key) {
			if (!key) return void 0;
			try {
				const stored = JSON.parse(sessionStorage.getItem(key) ?? "null");
				return stored && "base" in stored && "value" in stored && Number.isInteger(stored.revision) ? stored : void 0;
			} catch (error) {
				return;
			}
		}
		const FAILURES = /* @__PURE__ */ new Set([
			"conflict",
			"invalid",
			"failed",
			"unstored"
		]);
		/**
		* State machine for a settings draft.
		* Holds submitted values in `awaitingRevision` until the polled revision catches up, and rebases active edits onto newer remote revisions via `merge3`.
		*/
		function draftReducer(state, action) {
			const { phase, draft, seen } = state;
			switch (action.type) {
				case "edit":
					if (phase === "saving" || phase === "awaitingRevision") return state;
					if (same(action.value, action.saved)) return {
						phase: "clean",
						seen
					};
					return {
						phase: "editing",
						seen,
						notice: state.notice && FAILURES.has(state.notice.kind) ? state.notice : void 0,
						draft: {
							base: draft?.base ?? action.saved,
							value: action.value,
							revision: draft?.revision ?? action.revision ?? 0,
							...action.meta === void 0 ? {} : { meta: action.meta }
						}
					};
				case "discard": return phase === "saving" || phase === "awaitingRevision" ? state : {
					phase: "clean",
					seen
				};
				case "submit": return phase === "editing" ? {
					...state,
					phase: "saving"
				} : state;
				case "saved": return phase === "saving" && draft ? {
					phase: "awaitingRevision",
					seen,
					sent: {
						value: draft.value,
						revision: action.revision,
						restarting: action.restarting
					}
				} : state;
				case "refused": return {
					...state,
					phase: phase === "saving" ? "editing" : phase,
					notice: action.notice
				};
				case "revisionArrived": {
					if (phase === "saving") return state;
					const { revision, saved } = action;
					if (state.sent) return revision >= state.sent.revision ? {
						phase: "clean",
						seen: revision
					} : {
						...state,
						seen: revision
					};
					if (!draft || draft.revision === revision) return {
						...state,
						seen: revision
					};
					const paths = [];
					const value = merge3(draft.base, draft.value, saved, paths);
					if (same(value, saved)) return {
						phase: "clean",
						seen: revision
					};
					return {
						phase: "editing",
						seen: revision,
						draft: {
							...draft,
							base: saved,
							value,
							revision
						},
						notice: paths.length ? {
							kind: "conflict",
							revision,
							paths
						} : {
							kind: "merged",
							revision
						}
					};
				}
			}
		}
		function saveBarText(t, { phase, sent, notice }, words = {}) {
			switch (notice?.kind) {
				case "conflict": return {
					error: words.conflict?.(notice.revision, notice.paths) ?? t("saveConflict"),
					status: ""
				};
				case "invalid": return {
					error: t("invalidSettings", { fields: notice.fields.join(t("listSeparator")) }),
					status: ""
				};
				case "failed": return {
					error: notice.error,
					status: ""
				};
				case "unstored": return {
					error: t("draftFailed", { error: notice.error }),
					status: ""
				};
				case "merged": return { status: words.merged?.(notice.revision) ?? t("saveMerged") };
				case "rebasing": return { status: t("saveRebasing") };
			}
			if (phase === "awaitingRevision") return { status: t(sent?.restarting ? "savedRestarting" : "saved") };
			return { status: phase === "clean" ? t("saved") : words.editing ?? t(notice?.kind === "restored" ? "draftRestored" : "draftKept") };
		}
		/** Manage a settings draft, persisting unsaved edits in `sessionStorage` and rebasing them when newer server revisions arrive. */
		function useDraft({ key, saved, revision, save, reload }) {
			const { restart } = usePanel();
			const [state, dispatch] = (0, react.useReducer)(draftReducer, void 0, () => {
				const stored = read(key);
				const initial = stored ? {
					phase: "editing",
					draft: stored,
					notice: { kind: "restored" }
				} : { phase: "clean" };
				return revision === void 0 ? initial : draftReducer(initial, {
					type: "revisionArrived",
					saved,
					revision
				});
			});
			if (state.phase !== "saving" && revision !== void 0 && revision !== state.seen) dispatch({
				type: "revisionArrived",
				saved,
				revision
			});
			(0, react.useEffect)(() => {
				if (!key) return;
				try {
					if (state.draft) sessionStorage.setItem(key, JSON.stringify(state.draft));
					else sessionStorage.removeItem(key);
				} catch (failure) {
					dispatch({
						type: "refused",
						notice: {
							kind: "unstored",
							error: errorText(failure)
						}
					});
				}
			}, [key, state.draft]);
			const failed = (failure) => dispatch({
				type: "refused",
				notice: {
					kind: "failed",
					error: errorText(failure)
				}
			});
			const submit = async (event) => {
				event?.preventDefault();
				const { draft } = state;
				if (state.phase !== "editing" || !draft) return;
				dispatch({ type: "submit" });
				let result;
				try {
					result = await save(draft.value, draft.revision, draft.base);
				} catch (failure) {
					const fields = failure instanceof ApiError ? failure.issues.map((issue) => issue.path) : [];
					if (failure instanceof ApiError && failure.status === 409) await reload().then(() => dispatch({
						type: "refused",
						notice: { kind: "rebasing" }
					}), failed);
					else dispatch({
						type: "refused",
						notice: fields.length ? {
							kind: "invalid",
							fields
						} : {
							kind: "failed",
							error: errorText(failure)
						}
					});
					return;
				}
				dispatch({
					type: "saved",
					revision: result.revision,
					restarting: !!result.restarting
				});
				if (result.restarting) restart();
				else await reload().catch(failed);
			};
			return {
				state,
				value: state.sent?.value ?? state.draft?.value ?? saved,
				meta: state.draft?.meta,
				revision: state.draft?.revision ?? revision ?? 0,
				dirty: state.draft !== void 0,
				busy: state.phase === "saving" || state.phase === "awaitingRevision",
				submit,
				edit: (value, meta) => dispatch({
					type: "edit",
					value,
					meta,
					saved,
					revision
				}),
				discard: () => dispatch({ type: "discard" })
			};
		}
		/** Sticky save/discard bar for a settings block; transfers focus back to its parent block when hidden so keyboard navigation does not reset. */
		function SaveBar({ state, dirty, busy, words, status, onDiscard, onSave }) {
			const { t } = usePanel();
			const line = saveBarText(t, state, words);
			const shown = dirty || busy || !!line.error;
			const bar = (0, react.useRef)(null);
			const block = (0, react.useRef)(null);
			const focused = (0, react.useRef)(false);
			(0, react.useLayoutEffect)(() => {
				if (shown) {
					block.current = bar.current?.parentElement ?? null;
					return;
				}
				const lost = !document.activeElement || document.activeElement === document.body;
				if (focused.current && block.current && lost) {
					block.current.tabIndex = -1;
					block.current.focus({ preventScroll: true });
				}
				focused.current = false;
			}, [shown]);
			if (!shown) return null;
			const leave = (next) => {
				if (next && !bar.current?.contains(next)) focused.current = false;
			};
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				ref: bar,
				className: "dt-savebar",
				onFocus: () => {
					focused.current = true;
				},
				onBlur: (event) => leave(event.relatedTarget),
				children: [
					line.error ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
						className: "dt-error dt-clamp",
						role: "alert",
						children: line.error
					}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
						className: "dt-hint",
						"aria-live": "polite",
						children: status ?? line.status
					}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
						variant: "ghost",
						size: "sm",
						disabled: !dirty || busy,
						onClick: onDiscard,
						children: t("discard")
					}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
						variant: "primary",
						size: "sm",
						disabled: !dirty || busy,
						...onSave ? { onClick: onSave } : { type: "submit" },
						children: t("save")
					})
				]
			});
		}
		//#endregion
		//#region src/client/marks.ts
		function ticketMark(t, ticket) {
			switch (ticket.stage) {
				case "ended": return {
					label: valueLabel(t, "outcome", ticket.ended?.outcome),
					tone: "neutral",
					dot: "idle",
					icon: "stop"
				};
				case "person": {
					const action = ticket.action;
					const icon = action === "review" ? "review" : action === "failed" ? "alert" : action === "blocked" ? "blocked" : action === "delivery" ? "inbox" : "ask";
					return {
						label: t(`stage.${action}`),
						tone: action === "failed" ? "danger" : "warning",
						dot: action === "failed" ? "error" : "warning",
						icon
					};
				}
				case "working": return ticket.action === "queued" ? {
					label: t("stage.queued"),
					tone: "neutral",
					dot: "idle",
					icon: "queue"
				} : {
					label: t("stage.working"),
					tone: "info",
					dot: "ongoing",
					icon: "running"
				};
				default: return {
					label: t("stage.idle"),
					tone: "neutral",
					dot: "idle",
					icon: "clock"
				};
			}
		}
		const reportDot = (report) => report === "failed" ? "error" : report === "blocked" || report === "waiting" ? "warning" : report === "ready" ? "done" : "ongoing";
		const THREAD_MARKS = {
			error: {
				dot: "error",
				icon: "alert",
				label: "threadPollFailed"
			},
			evaluating: {
				dot: "ongoing",
				icon: "running",
				label: "threadEvaluating"
			},
			queued: {
				dot: "warning",
				icon: "queue",
				label: "threadQueued"
			},
			subscribed: {
				dot: "done",
				icon: "inbox",
				label: "threadSubscribed"
			},
			dormant: {
				dot: "idle",
				icon: "clock",
				label: "threadDormantShort"
			},
			unsubscribed: {
				dot: "idle",
				icon: "hash",
				label: "threadUnsubscribed"
			}
		};
		function threadMark(t, thread) {
			const { dot, icon, label } = THREAD_MARKS[thread.stage];
			return {
				dot,
				icon,
				label: t(label, { count: thread.pending })
			};
		}
		const SOURCE_MARKS = {
			missing: {
				dot: "idle",
				label: "sourceNotInstalled"
			},
			off: {
				dot: "idle",
				label: "sourceOff"
			},
			error: {
				dot: "error",
				label: "sourceState.error"
			},
			setup: {
				dot: "idle",
				label: "sourceState.setup"
			},
			starting: {
				dot: "ongoing",
				label: "sourceState.ongoing"
			},
			paused: {
				dot: "warning",
				label: "sourceState.warning"
			},
			ready: {
				dot: "done",
				label: "sourceState.done"
			}
		};
		const sourceMark = (t, state) => ({
			dot: SOURCE_MARKS[state].dot,
			label: t(SOURCE_MARKS[state].label)
		});
		const DECISION_MARKS = {
			accept: {
				dot: "done",
				icon: "decision",
				tone: "success"
			},
			reopen: {
				dot: "done",
				icon: "refresh",
				tone: "success"
			},
			stop: {
				dot: "idle",
				icon: "stop",
				tone: "danger"
			},
			ignore: {
				dot: "idle",
				icon: "dismiss",
				tone: "neutral"
			},
			unavailable: {
				dot: "warning",
				icon: "alert",
				tone: "warning"
			},
			wouldAccept: {
				dot: "idle",
				icon: "dismiss",
				tone: "warning"
			}
		};
		/** Maps a Decision outcome to its visual mark, distinguishing `wouldAccept` (an ignore that observe mode would have accepted). */
		function decisionMark(t, outcome) {
			return {
				...DECISION_MARKS[outcome],
				label: outcome === "wouldAccept" ? t("wouldAccept") : valueLabel(t, "decision", outcome)
			};
		}
		//#endregion
		//#region src/client/markdown.ts
		function shortUrl(url) {
			try {
				const parsed = new URL(url);
				const path = parsed.pathname.length > 24 ? `${parsed.pathname.slice(0, 24)}…` : parsed.pathname;
				return `${parsed.host}${path === "/" ? "" : path}`;
			} catch (error) {
				return url;
			}
		}
		/** Splits plain text into text and bare-URL link nodes, excluding trailing sentence punctuation from URLs. */
		function linkify(text) {
			return text.split(/(https?:\/\/[^\s)，。]*[^\s)，。.,;:!?'"])/).filter(Boolean).map((part) => /^https?:\/\//.test(part) ? {
				kind: "link",
				text: shortUrl(part),
				url: part
			} : {
				kind: "text",
				text: part
			});
		}
		function inlines(text) {
			return text.split(/(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\(https?:\/\/[^)\s]+\))/).flatMap((part) => {
				if (/^\*\*[^*]+\*\*$/.test(part)) return [{
					kind: "bold",
					text: part.slice(2, -2)
				}];
				if (/^`[^`]+`$/.test(part)) return [{
					kind: "code",
					text: part.slice(1, -1)
				}];
				const link = /^\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)$/.exec(part);
				return link ? [{
					kind: "link",
					text: link[1],
					url: link[2]
				}] : linkify(part);
			});
		}
		function markdownBlocks(text) {
			const blocks = [];
			let list;
			for (const line of text.split("\n")) {
				const item = /^\s*[-*]\s+(.*)$/.exec(line) ?? /^\s*\d+[.)]\s+(.*)$/.exec(line);
				if (item) {
					const ordered = !/^\s*[-*]/.test(line);
					if (!list || list.ordered !== ordered) blocks.push(list = {
						kind: "list",
						ordered,
						items: []
					});
					list.items.push(item[1]);
					continue;
				}
				list = void 0;
				const heading = /^#{1,6}\s+(.*)$/.exec(line);
				if (line.trim()) blocks.push(heading ? {
					kind: "heading",
					text: heading[1]
				} : {
					kind: "paragraph",
					text: line
				});
			}
			return blocks;
		}
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
		//#region src/client/route.ts
		/** Typed panel routes, route parser, and sessionStorage location history. */
		const TABS = [
			"overview",
			"source",
			"trigger",
			"eval",
			"execution",
			"settings"
		];
		const SETTINGS_GROUPS = [
			"source",
			"eval",
			"execution",
			"prompts",
			"deployment"
		];
		const HOME = { page: "overview" };
		const settingsRoute = (group, query = {}) => ({
			page: "settings",
			query: {
				group,
				...query
			}
		});
		const setupPage = (place) => place === "deployment" ? settingsRoute("deployment") : settingsRoute("source", { source: place });
		const routeLabel = (t, route) => route.id ? t(route.page === "trigger" ? "term.thread" : "term.ticket") : t(`tab.${route.page}`);
		const pick = (values, value) => values.find((item) => item === value);
		function compact(query) {
			const set = Object.entries(query).filter(([, value]) => value !== void 0);
			return set.length ? Object.fromEntries(set) : void 0;
		}
		/** Validate and normalize a stored route, dropping unrecognized query filters or removed tabs (such as the legacy `policy` tab). */
		function parseRoute(value) {
			const { page, id, query } = value ?? {};
			const text = (name) => typeof query?.[name] === "string" ? query[name] : void 0;
			const record = typeof id === "string" && id ? id : void 0;
			switch (page) {
				case "overview":
				case "source": return { page };
				case "trigger": return record ? {
					page,
					id: record,
					query: compact({ trigger: text("trigger") })
				} : {
					page,
					query: compact({ filter: pick(THREAD_FILTERS, query?.filter) })
				};
				case "eval": return {
					page,
					query: compact({
						filter: pick(DECISION_FILTERS, query?.filter),
						window: query?.window === "24h" ? "24h" : void 0
					})
				};
				case "execution": return record ? {
					page,
					id: record
				} : {
					page,
					query: compact({ filter: pick(TICKET_FILTERS, query?.filter) })
				};
				case "settings": return {
					page,
					query: {
						group: pick(SETTINGS_GROUPS, query?.group) ?? "source",
						...compact({
							source: text("source"),
							version: text("version")
						})
					}
				};
				default: return;
			}
		}
		const ROUTE_KEY = "dsh-superagent/route";
		const lastSettingsGroup = ({ route, group }) => route.page === "settings" ? route.query.group : group ?? "source";
		function initialLocation() {
			try {
				const stored = JSON.parse(sessionStorage.getItem(ROUTE_KEY) ?? "null");
				const route = parseRoute(stored?.route);
				const stack = Array.isArray(stored?.stack) ? stored.stack : [];
				if (route) return {
					route,
					stack: stack.flatMap((item) => parseRoute(item) ?? []),
					group: pick(SETTINGS_GROUPS, stored?.group)
				};
			} catch (error) {}
			return {
				route: HOME,
				stack: []
			};
		}
		function remember(location) {
			try {
				sessionStorage.setItem(ROUTE_KEY, JSON.stringify(location));
			} catch (failure) {}
		}
		//#endregion
		//#region src/client/widgets.tsx
		/** Context-aware shared UI widgets: page/section headers, timestamps, Markdown rendering, and confirmation actions. */
		const external = {
			target: "_blank",
			rel: "noopener noreferrer"
		};
		function When({ at }) {
			const { t } = usePanel();
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("time", {
				dateTime: at,
				title: fullTime(at, t("lang")),
				children: when(at, t("lang"))
			});
		}
		function SetupMessage({ problem, lead }) {
			const { t } = usePanel();
			const text = setupText(t, problem);
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [lead ? t("setupProblem", { detail: text }) : text, problem.values.output && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
				className: "dt-detail dt-mono dt-clamp",
				children: problem.values.output
			})] });
		}
		function Section({ title, count, children, action, hint, badge, icon }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("section", {
				className: "dt-section",
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("h2", {
					className: "dt-section-title",
					children: [
						icon && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
							className: "dt-section-icon",
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, {
								name: icon,
								size: 14
							})
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
							className: "dt-section-name",
							children: title
						}),
						count !== void 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
							className: "dt-count",
							children: count
						}),
						hint && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(InfoTip, { text: hint }),
						badge,
						action && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
							style: { marginLeft: "auto" },
							children: action
						})
					]
				}), children]
			});
		}
		function Hint({ children }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
				className: "dt-hint",
				children
			});
		}
		function LabelValue({ label, value }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("span", {
				className: "dt-lv",
				children: [
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
						className: "dt-lv-label",
						children: label
					}),
					" ",
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
						className: "dt-lv-value",
						children: value
					})
				]
			});
		}
		function KeyValues({ rows }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("dl", {
				className: "dt-kv",
				children: rows.map(([key, value], index) => /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					style: { display: "contents" },
					children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("dt", { children: key }), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("dd", { children: value })]
				}, index))
			});
		}
		function Inlines({ parts }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(react_jsx_runtime.Fragment, { children: parts.map((part, index) => part.kind === "bold" ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("strong", { children: part.text }, index) : part.kind === "code" ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("code", {
				className: "dt-code",
				children: part.text
			}, index) : part.kind === "link" ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("a", {
				className: "dt-inline-link",
				href: part.url,
				title: part.url,
				...external,
				children: part.text
			}, index) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(react.Fragment, { children: part.text }, index)) });
		}
		/** Renders a safe Markdown subset (headings, lists, paragraphs, bold, inline code, links) without interpreting raw HTML. */
		function MarkdownLite({ text }) {
			const { t } = usePanel();
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
				className: "dt-md",
				children: markdownBlocks(readableMarkers(t, text)).map((block, index) => {
					if (block.kind !== "list") return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
						className: block.kind === "heading" ? "dt-md-heading" : void 0,
						children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Inlines, { parts: inlines(block.text) })
					}, index);
					const items = block.items.map((item, at) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("li", { children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Inlines, { parts: inlines(item) }) }, at));
					return block.ordered ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ol", { children: items }, index) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", { children: items }, index);
				})
			});
		}
		function MoreToggle({ open, onToggle }) {
			const { t } = usePanel();
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
				type: "button",
				className: "dt-textlink dt-more",
				"aria-expanded": open,
				onClick: onToggle,
				children: open ? t("collapse") : t("expand")
			});
		}
		function ClampText({ text }) {
			const [open, setOpen] = (0, react.useState)(false);
			const long = text.length > 480 || text.split("\n").length > 8;
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
				className: long && !open ? "dt-event-text dt-clamp-8" : "dt-event-text",
				children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Inlines, { parts: linkify(text) })
			}), long && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(MoreToggle, {
				open,
				onToggle: () => setOpen(!open)
			})] });
		}
		function ConfirmButton({ label, title, message, onConfirm, variant = "ghost", icon }) {
			const { t } = usePanel();
			const [open, setOpen] = (0, react.useState)(false);
			const confirm = useAction(onConfirm);
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
				variant,
				size: "sm",
				icon: icon && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, {
					name: icon,
					size: 14
				}),
				onClick: () => setOpen(true),
				children: label
			}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Modal, {
				open,
				onClose: () => setOpen(false),
				title,
				closeLabel: t("close"),
				description: message,
				footer: /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
					variant: "ghost",
					onClick: () => setOpen(false),
					children: t("cancel")
				}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
					variant: "primary",
					disabled: confirm.busy,
					onClick: () => {
						confirm.run().then((done) => {
							if (done) setOpen(false);
						});
					},
					children: t("confirm")
				})] })
			})] });
		}
		function SessionButton({ sessionId, label, variant = "ghost" }) {
			const { t, openSession, notify } = usePanel();
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
				variant,
				size: "sm",
				icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, {
					name: "session",
					size: 14
				}),
				onClick: () => {
					openSession(sessionId).catch((error) => notify(errorText(error)));
				},
				children: label ?? t("openSession")
			});
		}
		function ExternalLink({ href, children, icon = "external" }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("a", {
				className: "dt-inline-link dt-icon-link",
				href,
				...external,
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, {
					name: icon,
					size: 13
				}), children]
			});
		}
		function ActionLink({ href, children, icon = "external" }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("a", {
				className: "dt-btn dt-btn-outline dt-btn-sm",
				href,
				...external,
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
					className: "dt-btn-icon",
					children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, {
						name: icon,
						size: 14
					})
				}), children]
			});
		}
		function StageMark({ state, icon, label }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("span", {
				className: "dt-stage",
				"data-state": state,
				children: [state === "ongoing" ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(StateDot, { state: "ongoing" }) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, {
					name: icon,
					size: 14
				}), label]
			});
		}
		function LoadState({ error, loading }) {
			const { t } = usePanel();
			if (error) return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
				className: "dt-error",
				role: "alert",
				children: error.message
			});
			return loading ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("loading") }) : null;
		}
		function LoadMore({ onMore }) {
			const { t } = usePanel();
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
				variant: "outline",
				size: "sm",
				icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, {
					name: "chevron-down",
					size: 14
				}),
				onClick: onMore,
				children: t("loadMore")
			});
		}
		function StatusHead({ hint, settings }) {
			const { t, navigate } = usePanel();
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-status-head",
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("h2", {
					className: "dt-status-title",
					children: [t("statusTitle"), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(InfoTip, { text: hint })]
				}), settings && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
					variant: "ghost",
					size: "sm",
					icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "settings" }),
					onClick: () => navigate(settingsRoute(settings)),
					children: t("tab.settings")
				})]
			});
		}
		function PageHead({ title, children }) {
			const { back, backLabel } = usePanel();
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-page-head",
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
					variant: "ghost",
					size: "sm",
					icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "chevron-left" }),
					onClick: back,
					children: backLabel
				}), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-page-title",
					children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("h2", { children: title }), children && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
						className: "dt-actions",
						children
					})]
				})]
			});
		}
		/** Trigger a host setup re-check and restart, prompting for confirmation when running Assignments would be interrupted. */
		function CheckSetupButton() {
			const { t, call, notify, restart } = usePanel();
			const { running } = usePanelData();
			const check = async () => {
				await call("POST setup/check");
				notify(t("setupChecking"));
				restart();
			};
			const action = useAction(check);
			if (running > 0) {
				const message = t("setupCheckInterrupts", { count: running });
				return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ConfirmButton, {
					variant: "outline",
					icon: "refresh",
					label: t("setupCheck"),
					title: t("setupCheck"),
					message,
					onConfirm: check
				});
			}
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
				variant: "outline",
				size: "sm",
				icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, {
					name: "refresh",
					size: 14
				}),
				disabled: action.busy,
				onClick: () => {
					action.run();
				},
				children: t("setupCheck")
			});
		}
		//#endregion
		//#region src/client/rows.tsx
		/** Shared list rows for Tickets, Threads, and Decisions, plus Source fact chips and automated-message run folding. */
		function TicketLine({ ticket, question, onChanged, context }) {
			const { t, call, navigate } = usePanel();
			const status = ticketMark(t, ticket);
			const after = async (request) => {
				await request;
				await onChanged?.();
			};
			const note = question && ticket.note && {
				...ticket.note,
				text: readableMarkers(t, ticket.note.text)
			};
			const answer = ticket.reply && ticket.stage === "person" && ticket.action === "answer" ? ticket.reply : void 0;
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("li", {
				className: "dt-row dt-link dt-ticket",
				"data-state": question ? status.dot : void 0,
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
					className: "dt-ticket-stage",
					children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(StageMark, {
						state: status.dot,
						icon: status.icon,
						label: status.label
					})
				}), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-ticket-body",
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
							className: "dt-row-title",
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
								type: "button",
								className: "dt-open",
								onClick: () => navigate({
									page: "execution",
									id: ticket.id
								}),
								children: ticket.title
							})
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
							className: "dt-row-meta dt-ticket-meta",
							children: [
								ticket.threads.map((thread) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ThreadChip, { thread }, thread.key)),
								context && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ContextTag, {}),
								ticket.undelivered > 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LabelValue, {
									label: t("ticketUndeliveredLabel"),
									value: ticket.undelivered
								}),
								note ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
									className: note.error ? "dt-ticket-note dt-ticket-note-error" : "dt-ticket-note",
									title: note.text,
									children: note.text
								}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(When, { at: ticket.updatedAt })
							]
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
							className: "dt-ticket-actions",
							children: onChanged && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [
								answer && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ActionLink, {
									href: answer.url,
									icon: "message",
									children: t("answerIn", { source: valueLabel(t, "source", answer.source) })
								}),
								ticket.actions.retry && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ConfirmButton, {
									variant: "outline",
									icon: "refresh",
									label: t("retry"),
									title: t("retryTitle"),
									message: t("retryConfirm", { title: ticket.title }),
									onConfirm: () => after(call("POST tickets/:id/retry", { id: ticket.id }))
								}),
								ticket.actions.retry && ticket.sessionId && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SessionButton, {
									variant: "outline",
									sessionId: ticket.sessionId
								}),
								ticket.actions.stop && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ConfirmButton, {
									variant: "outline",
									icon: "stop",
									label: t("stop"),
									title: t("stopConfirmTitle"),
									message: t("stopConfirm", { title: ticket.title }),
									onConfirm: () => after(call("POST tickets/:id/stop", { id: ticket.id }))
								})
							] })
						})
					]
				})]
			});
		}
		function ContextTag() {
			const { t } = usePanel();
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Tag, {
				tone: "quiet",
				title: t("contextOnlyHint"),
				children: t("contextOnly")
			});
		}
		/** Thread list row; on a Ticket page, `ticketId` omits that Ticket from fanout targets and `context` marks context-only threads. */
		function ThreadLine({ thread, ticketId, context }) {
			const { t, navigate } = usePanel();
			const live = thread.tickets.filter((ticket) => ticket.state === "open" && ticket.id !== ticketId);
			const { dot, icon, label } = threadMark(t, thread);
			const reaches = live.length > 0 && `${live[0].title}${live.length > 1 ? t("andMore", { count: live.length - 1 }) : ""}`;
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("li", {
				className: "dt-row dt-link dt-ticket",
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
					className: "dt-ticket-stage",
					children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(StageMark, {
						state: dot,
						icon,
						label
					})
				}), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-ticket-body",
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
							className: "dt-row-title",
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
								type: "button",
								className: "dt-open",
								title: thread.pollError,
								onClick: () => navigate({
									page: "trigger",
									id: thread.key
								}),
								children: readableMarkers(t, thread.title)
							})
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
							className: "dt-row-quote dt-line",
							children: thread.latest && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [
								actorName(t, thread.latest.actor),
								t("labelSeparator"),
								readableMarkers(t, thread.latest.preview) || t("empty")
							] })
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
							className: "dt-row-meta dt-line",
							children: [
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)(ThreadChip, { thread }),
								context && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ContextTag, {}),
								thread.pollError ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
									className: "dt-line-text dt-error-text",
									children: thread.pollError
								}) : reaches && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LabelValue, {
									label: t("fanoutTo"),
									value: reaches
								}),
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)(When, { at: thread.lastAt })
							]
						})
					]
				})]
			});
		}
		function DecisionLine({ decision }) {
			const { t, navigate } = usePanel();
			const matched = decision.rules.filter((rule) => rule.matched).map((rule) => rule.name);
			const mark = decisionMark(t, decision.outcome);
			const preview = readableMarkers(t, decision.preview);
			const reason = decision.reason ? reasonLabel(t, decision.reason) : "";
			const open = () => decision.ticketId ? navigate({
				page: "execution",
				id: decision.ticketId
			}) : navigate({
				page: "trigger",
				id: decision.thread,
				query: { trigger: decision.triggerIds[0] ?? "" }
			});
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("li", {
				className: "dt-row dt-link dt-ticket",
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
					className: "dt-ticket-stage",
					children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(StageMark, {
						state: mark.dot,
						icon: mark.icon,
						label: mark.label
					})
				}), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-ticket-body",
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
							className: "dt-row-title",
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
								type: "button",
								className: "dt-open",
								title: reason || void 0,
								onClick: open,
								children: decision.ticketTitle ?? (decision.threadTitle ? readableMarkers(t, decision.threadTitle) : preview || t("empty"))
							})
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
							className: "dt-row-quote dt-line",
							children: preview
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
							className: "dt-row-meta dt-line",
							children: [
								reason && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
									className: "dt-line-text",
									children: reason
								}),
								matched.length > 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LabelValue, {
									label: t("ruleLabel"),
									value: matched.join(t("listSeparator"))
								}),
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)(When, { at: decision.at })
							]
						})
					]
				})]
			});
		}
		function ThreadChip({ thread }) {
			const { t } = usePanel();
			const cells = /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
				className: "dt-chip-source",
				children: valueLabel(t, "source", thread.source)
			}), Object.entries(thread.facts).map(([id, fact]) => /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("span", {
				className: fact.problem ? "dt-chip-fact dt-chip-problem" : "dt-chip-fact",
				children: [fact.label && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
					className: "dt-chip-label",
					children: localized(t, fact.label)
				}), localized(t, fact.value)]
			}, id))] });
			return thread.url ? /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("a", {
				className: "dt-chip dt-chip-link",
				href: thread.url,
				target: "_blank",
				rel: "noopener noreferrer",
				title: thread.title,
				children: [cells, /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
					className: "dt-chip-open",
					children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, {
						name: "external",
						size: 11
					})
				})]
			}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
				className: "dt-chip",
				children: cells
			});
		}
		/** Group consecutive automated items from the same sender so only the newest is shown by default. */
		function automatedRuns(items, sender) {
			const runs = [];
			for (const item of items) {
				const last = runs.at(-1), from = sender(item);
				if (last && from !== void 0 && sender(last.item) === from) last.earlier.push(item);
				else runs.push({
					item,
					earlier: []
				});
			}
			return runs;
		}
		function Earlier({ items }) {
			const { t } = usePanel();
			const [open, setOpen] = (0, react.useState)(false);
			if (!items.length) return null;
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
				type: "button",
				className: "dt-textlink",
				"aria-expanded": open,
				onClick: () => setOpen(!open),
				children: open ? t("collapse") : t("automatedEarlier", { count: items.length })
			}), open && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
				className: "dt-plain-list dt-hint",
				children: items.map((item) => /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("li", { children: [
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(When, { at: item.at }),
					" · ",
					readableMarkers(t, item.preview) || t("empty")
				] }, item.id))
			})] });
		}
		//#endregion
		//#region src/client/settings-kit.tsx
		/** Shared settings context, block draft hook, form controls, Source schema field renderer, and configuration history. */
		/** Parse a numeric input string, returning `null` when empty so the server rejects blank required numbers instead of coercing to 0. */
		const numberOf = (text) => text.trim() ? Number(text) : null;
		const SettingsContext = (0, react.createContext)(void 0);
		function useSettings() {
			const value = (0, react.useContext)(SettingsContext);
			if (!value) throw new Error("A settings block rendered outside the settings");
			return value;
		}
		function SettingsProvider({ children }) {
			const { call } = usePanel();
			const { restarts } = usePanelData();
			const { data, error, reload } = usePoll(() => call("GET settings"), [call, restarts]);
			if (!data) return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LoadState, {
				error,
				loading: true
			});
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(SettingsContext.Provider, {
				value: {
					settings: data,
					reload
				},
				children: [error && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LoadState, {
					error,
					loading: false
				}), children]
			});
		}
		function useBlockDraft(block, saved, revision, toValue = (draft) => draft) {
			const { t, call, notify } = usePanel();
			const { state } = usePanelData();
			const { reload } = useSettings();
			return useDraft({
				key: `dsh-superagent/draft/${state?.masterId ?? ""}/${block}`,
				saved,
				revision,
				reload,
				save: async (value, from) => {
					const result = await call("PUT settings/:block", {
						block,
						body: {
							value: toValue(value),
							revision: from
						}
					});
					notify(t(result.restarting ? "savedRestarting" : "saved"));
					return result;
				}
			});
		}
		/** Fieldset wrapper that restores focus to the previously active input after a save completes and re-enables the form. */
		function Fields({ disabled, children }) {
			const set = (0, react.useRef)(null);
			const focused = (0, react.useRef)(null);
			(0, react.useLayoutEffect)(() => {
				const active = document.activeElement;
				if (disabled) focused.current = active instanceof HTMLElement && set.current?.contains(active) ? active : null;
				else if (focused.current && (!active || active === document.body)) {
					focused.current.focus({ preventScroll: true });
					focused.current = null;
				}
			}, [disabled]);
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("fieldset", {
				ref: set,
				className: "dt-fieldset",
				disabled,
				children
			});
		}
		function Field({ label, hint, note, children }) {
			const id = (0, react.useId)();
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-field",
				children: [
					/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("span", {
						className: "dt-field-head",
						children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("label", {
							htmlFor: id,
							children: label
						}), hint && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(InfoTip, { text: hint })]
					}),
					(0, react.cloneElement)(children, { id }),
					note && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("small", { children: note })
				]
			});
		}
		function SwitchRow({ label, hint, checked, onChange }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-switch-row",
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-field-head",
					children: [label, hint && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(InfoTip, { text: hint })]
				}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Switch, {
					checked,
					onChange,
					label
				})]
			});
		}
		function ModelField({ id, value, onChange }) {
			const { t, call } = usePanel();
			const [catalog, setCatalog] = (0, react.useState)();
			const [error, setError] = (0, react.useState)();
			(0, react.useEffect)(() => {
				call("GET models").then(setCatalog, (failure) => setError(errorText(failure)));
			}, [call]);
			const current = {
				provider: value?.provider ?? "",
				model: value?.model ?? "",
				effort: value?.reasoningEffort ?? ""
			};
			const set = (next) => {
				const { provider, model, effort } = {
					...current,
					...next
				};
				onChange(provider.trim() || model.trim() || effort.trim() ? {
					provider,
					model,
					...effort ? { reasoningEffort: effort } : {}
				} : null);
			};
			const models = catalog?.groups.find((group) => group.id === current.provider.trim())?.models ?? [];
			const fallback = catalog?.default;
			const input = (name, label, placeholder) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Field, {
				label,
				children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Input, {
					list: `${id}-${name}s`,
					spellCheck: false,
					placeholder,
					value: current[name],
					onChange: (event) => set({ [name]: event.target.value })
				})
			});
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-model",
				children: [
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: fallback ? t("defaultModel", { model: `${fallback.provider} / ${fallback.model}${fallback.reasoningEffort ? ` · ${fallback.reasoningEffort}` : ""}` }) : t("defaultModelUnavailable") }),
					error && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
						className: "dt-error",
						children: t("modelCatalogError", { error })
					}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
						className: "dt-grid3",
						children: [
							input("provider", t("modelProvider"), t("modelInherit")),
							input("model", t("modelName"), t("modelInherit")),
							input("effort", t("modelEffort"), t("modelEffortDefault"))
						]
					}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)("datalist", {
						id: `${id}-providers`,
						children: catalog?.groups.map((group) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("option", {
							value: group.id,
							children: group.name
						}, group.id))
					}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)("datalist", {
						id: `${id}-models`,
						children: models.map((model) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("option", {
							value: model.id,
							children: model.name
						}, model.id))
					}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)("datalist", {
						id: `${id}-efforts`,
						children: (models.find((model) => model.id === current.model.trim())?.reasoning?.efforts ?? []).map((effort) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("option", {
							value: effort.id,
							children: effort.name
						}, effort.id))
					})
				]
			});
		}
		function changeText(t, change, sources) {
			const source = sources.find((item) => item.id === change.source);
			const field = (change.part ? source?.policy?.fields : source?.fields)?.find((item) => item.key === change.field);
			const shown = (value) => value === void 0 || value === null || value === "" ? t("unsetValue") : typeof value === "boolean" ? t(value ? "yes" : "no") : change.code === "mode" ? valueLabel(t, "mode", String(value)) : String(value);
			return t(`change.${change.code}`, {
				items: (change.items ?? []).map((item) => source?.labels[item] ?? item).join(t("listSeparator")),
				from: shown(change.from),
				to: shown(change.to),
				name: change.name ?? "",
				source: source ? localized(t, source.title) : change.source ?? "",
				field: field ? localized(t, field.label) : change.field ?? ""
			});
		}
		/**
		* Collapsible revision history for the specified settings blocks, optionally including all Policy-changing saves.
		* Revisions saved before per-block tracking existed have no `block` and appear under `policy`.
		*/
		function ConfigHistory({ blocks, versions, focus }) {
			const { t, call } = usePanel();
			const { settings } = useSettings();
			const { sources } = settings;
			const [open, setOpen] = (0, react.useState)(!!focus);
			const [data, setData] = (0, react.useState)();
			const [error, setError] = (0, react.useState)();
			const revisions = JSON.stringify([Object.values(settings.blocks).map((block) => block.revision), sources.map((source) => source.revision)]);
			(0, react.useEffect)(() => {
				if (open) call("GET policy/history").then(setData, (failure) => setError(errorText(failure)));
			}, [
				open,
				call,
				revisions
			]);
			const listed = (block) => block ? blocks.some((item) => item === block || item.endsWith(":") && block.startsWith(item)) : blocks.includes("policy");
			const items = data?.items.filter((item) => versions && item.policyChanged || listed(item.block)) ?? [];
			const target = focus ? items.filter((item) => item.policyChanged && item.policyVersion.startsWith(focus)).at(-1) : void 0;
			const scroll = (element) => {
				if (element && !element.dataset.scrolled) {
					element.dataset.scrolled = "1";
					element.scrollIntoView?.({ block: "center" });
				}
			};
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(DisclosureRow, {
				icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "history" }),
				title: t("configHistory"),
				open,
				onToggle: () => setOpen(!open),
				children: /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-disclosure-body",
					children: [error && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
						className: "dt-error",
						children: error
					}), data && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("historyIntro") }),
						focus && !target && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("policyVersionUnrecorded", { version: focus.slice(0, 8) }) }),
						items.length ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
							className: "dt-timeline",
							children: items.map((item) => /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("li", {
								className: item === target ? "dt-event dt-highlight" : "dt-event",
								ref: item === target ? scroll : void 0,
								children: [
									/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
										className: "dt-row-title",
										children: t("historyItem", {
											revision: item.revision,
											source: valueLabel(t, "historySource", item.source)
										})
									}),
									/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
										className: "dt-event-foot",
										children: [when(item.savedAt, t("lang")), item.policyChanged && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [" · ", t("historyPolicyChanged", { version: item.policyVersion.slice(0, 8) })] })]
									}),
									item.changes === null ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("historyNoBaseline") }) : item.changes.length ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
										className: "dt-changes",
										children: item.changes.map((change, index) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("li", { children: changeText(t, change, sources) }, index))
									}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("historyNoChanges") }),
									item.notified.length > 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("historyNotified", {
										count: item.notified.length,
										titles: item.notified.map((ticket) => ticket.title).join(t("listSeparator"))
									}) })
								]
							}, item.revision))
						}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("historyEmpty") })
					] })]
				})
			});
		}
		const ROWS_SHOWN = 6;
		const byName = ([, a], [, b]) => a.localeCompare(b);
		function RowsField({ field, value, saved, onChange, labels, refreshLabels }) {
			const { t, notify } = usePanel();
			const [open, setOpen] = (0, react.useState)(false);
			const refresh = useAction(async () => {
				try {
					const added = await refreshLabels();
					notify(added.length ? t("labelsAdded", { names: added.join(t("listSeparator")) }) : t("labelsCurrent"));
				} catch (failure) {
					notify(t("labelsFailed", { error: errorText(failure) }));
				}
			});
			const label = localized(t, field.label), hint = localized(t, field.hint);
			const rows = Array.isArray(value) ? value : [];
			const set = (index, row) => onChange(rows.map((item, position) => position === index ? row : item));
			const key = field.columns[0];
			const savedKeys = new Set((Array.isArray(saved) ? saved : []).map((row) => row[key.key]));
			const choose = key.type === "text" && key.choose && Object.keys(labels).length ? localized(t, key.choose) : "";
			const choices = (id) => Object.entries(labels).filter(([option]) => option === id || !rows.some((other) => other[key.key] === option)).sort(byName);
			const blank = Object.fromEntries(field.columns.map((column) => [column.key, column.type === "select" ? column.options[0].value : ""]));
			const named = field.columns[1]?.type === "text" ? field.columns[1] : void 0;
			const rowName = (row) => named && row[named.key] || labels[row[key.key] ?? ""] || row[key.key] || "";
			const cell = (row, index, column) => {
				const id = row[key.key] ?? "", change = (next) => set(index, {
					...row,
					[column.key]: next
				});
				if (column === key && (savedKeys.has(id) || !choose && labels[id])) return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
					className: labels[id] ? "dt-row-label" : "dt-row-label dt-mono",
					title: id,
					children: labels[id] ?? id
				}, column.key);
				if (column === key && choose) return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("select", {
					className: "dt-select",
					"aria-label": choose,
					required: true,
					value: id,
					onChange: (event) => change(event.target.value),
					children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("option", {
						value: "",
						disabled: true,
						children: choose
					}), choices(id).map(([option, name]) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("option", {
						value: option,
						children: name
					}, option))]
				}, column.key);
				if (column.type === "select") return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("select", {
					className: "dt-select",
					"aria-label": localized(t, column.label),
					value: row[column.key] ?? "",
					onChange: (event) => change(event.target.value),
					children: column.options.map((option) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("option", {
						value: option.value,
						children: localized(t, option.label)
					}, option.value))
				}, column.key);
				return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Input, {
					className: column.optional ? void 0 : "dt-mono",
					"aria-label": localized(t, column.label),
					placeholder: localized(t, column.label),
					required: !column.optional,
					pattern: column.pattern,
					spellCheck: false,
					value: row[column.key] ?? "",
					onChange: (event) => change(event.target.value)
				}, column.key);
			};
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-field",
				children: [
					/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
						className: "dt-subhead",
						children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("span", {
							className: "dt-field-head",
							children: [
								label,
								hint && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(InfoTip, { text: hint }),
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
									className: "dt-count",
									children: rows.length || ""
								})
							]
						}), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("span", {
							className: "dt-subhead-actions",
							children: [key.type === "text" && key.refresh && refreshLabels && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
								variant: "ghost",
								size: "sm",
								className: refresh.busy ? "dt-btn-busy" : void 0,
								icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "refresh" }),
								disabled: refresh.busy,
								"aria-busy": refresh.busy,
								onClick: () => {
									refresh.run();
								},
								children: localized(t, key.refresh)
							}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
								variant: "ghost",
								size: "sm",
								icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "plus" }),
								onClick: () => {
									setOpen(true);
									onChange([...rows, blank]);
								},
								children: t("addRow")
							})]
						})]
					}),
					rows.length > ROWS_SHOWN && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
						type: "button",
						className: "dt-textlink dt-rows-summary",
						"aria-expanded": open,
						onClick: () => setOpen(!open),
						children: open ? t("collapse") : rows.map(rowName).join(t("listSeparator"))
					}),
					(rows.length <= ROWS_SHOWN || open) && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
						className: "dt-rows",
						style: { ["--dt-columns"]: field.columns.length },
						children: rows.map((row, index) => /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("li", {
							className: "dt-rows-item",
							children: [field.columns.map((column) => cell(row, index, column)), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
								variant: "ghost",
								size: "sm",
								icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "trash" }),
								"aria-label": t("removeRow", { name: labels[row[key.key] ?? ""] || row[key.key] || label }),
								onClick: () => onChange(rows.filter((_, position) => position !== index))
							})]
						}, index))
					})
				]
			});
		}
		function SourceField({ field, value, saved, fact, onChange, labels, refreshLabels }) {
			const { t, navigate } = usePanel();
			const label = localized(t, field.label), hint = localized(t, field.hint);
			switch (field.type) {
				case "switch": return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SwitchRow, {
					label,
					hint,
					checked: value === true,
					onChange
				});
				case "select": return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Field, {
					label,
					hint,
					children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SegmentedControl, {
						className: "dt-segmented dt-field-segmented",
						label,
						value: String(value ?? field.options[0].value),
						options: field.options.map((option) => ({
							value: option.value,
							label: localized(t, option.label)
						})),
						onChange
					})
				});
				case "number": return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Field, {
					label,
					hint,
					children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Input, {
						type: "number",
						min: field.min,
						max: field.max,
						required: true,
						value: String(value ?? ""),
						onChange: (event) => onChange(event.target.value === "" ? "" : Number(event.target.value))
					})
				});
				case "text": return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Field, {
					label,
					hint,
					note: localized(t, fact),
					children: field.choose && Object.keys(labels).length ? /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("select", {
						className: "dt-select",
						value: String(value ?? ""),
						onChange: (event) => onChange(event.target.value),
						children: [
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)("option", {
								value: "",
								children: localized(t, field.choose)
							}),
							value && !labels[String(value)] ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("option", {
								value: String(value),
								children: String(value)
							}) : null,
							Object.entries(labels).sort(byName).map(([option, name]) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("option", {
								value: option,
								children: name
							}, option))
						]
					}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Input, {
						value: String(value ?? ""),
						readOnly: field.readonly,
						pattern: field.pattern,
						spellCheck: false,
						onChange: (event) => onChange(event.target.value)
					})
				});
				case "fact": return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-field",
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("span", {
							className: "dt-field-head",
							children: [label, hint && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(InfoTip, { text: hint })]
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
							className: "dt-mono",
							children: localized(t, fact) || t("empty")
						}),
						field.settings && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("small", { children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
							type: "button",
							className: "dt-textlink",
							onClick: () => navigate(settingsRoute(field.settings)),
							children: t(`openSettingsOf.${field.settings}`)
						}) })
					]
				});
				case "rows": return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(RowsField, {
					field,
					value,
					saved,
					onChange,
					labels,
					refreshLabels
				});
			}
		}
		//#endregion
		//#region src/client/eval.tsx
		/** Eval status view (Decision log) and Eval settings group (Policy rules, per-Source admission, and assessor settings). */
		function EvalStatus({ filter, window, paused }) {
			const { t, call, navigate } = usePanel();
			const [limit, setLimit] = (0, react.useState)(30);
			const { data, error } = usePoll(() => call("GET decisions", { query: {
				limit,
				kind: DECISION_KINDS[filter],
				...window ? { window } : {}
			} }), [
				filter,
				limit,
				window
			]);
			const show = (key, last24h) => navigate({
				page: "eval",
				query: {
					...key === "work" ? {} : { filter: key },
					...last24h ? { window: "24h" } : {}
				}
			}, true);
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [
				/* @__PURE__ */ (0, react_jsx_runtime.jsx)(StatusHead, {
					hint: t("evalStatusIntro"),
					settings: "eval"
				}),
				paused && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("p", {
					className: "dt-banner",
					children: [
						t("evalRecordsPaused"),
						" ",
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
							type: "button",
							className: "dt-textlink",
							onClick: () => navigate({ page: "execution" }),
							children: t("resumeWhere")
						})
					]
				}),
				/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-filters",
					children: [DECISION_FILTERS.map((key) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Pill, {
						active: filter === key,
						onClick: () => {
							setLimit(30);
							show(key, !!window);
						},
						children: t(`decisionFilter.${key}`)
					}, key)), window && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { className: "dt-filter-gap" }), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Pill, {
						active: true,
						onClick: () => show(filter, false),
						children: t("lastDayOnly")
					})] })]
				}),
				/* @__PURE__ */ (0, react_jsx_runtime.jsx)(LoadState, {
					error,
					loading: !data
				}),
				data && (data.items.length ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
					className: "dt-list",
					children: data.items.map((decision) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(DecisionLine, { decision }, decision.id))
				}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("none") })),
				data?.next_offset != null && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LoadMore, { onMore: () => setLimit(limit + 30) })
			] });
		}
		function RuleRow({ rule, expanded, onToggle, onChange, onDuplicate, onRemove }) {
			const { t } = usePanel();
			const name = rule.name.trim() || t("newRule");
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("li", {
				className: "dt-rule",
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(DisclosureRow, {
					icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
						className: "dt-rule-dot",
						"data-enabled": rule.enabled || void 0
					}),
					title: name,
					open: expanded,
					onToggle,
					collapsedContent: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
						className: "dt-rule-preview",
						children: rule.instruction
					}),
					children: /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
						className: "dt-rule-body",
						children: [
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Field, {
								label: t("ruleName"),
								children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Input, {
									value: rule.name,
									required: true,
									maxLength: LIMITS.ruleName,
									onChange: (event) => onChange({
										...rule,
										name: event.target.value
									})
								})
							}),
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Field, {
								label: t("ruleInstruction"),
								children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("textarea", {
									className: "dt-textarea",
									rows: 4,
									required: true,
									maxLength: LIMITS.ruleInstruction,
									value: rule.instruction,
									placeholder: t("ruleInstructionPlaceholder"),
									onChange: (event) => onChange({
										...rule,
										instruction: event.target.value
									})
								})
							}),
							/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
								className: "dt-actions",
								children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
									variant: "ghost",
									size: "sm",
									icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "copy" }),
									onClick: onDuplicate,
									children: t("duplicate")
								}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
									variant: "ghost",
									size: "sm",
									icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "trash" }),
									onClick: onRemove,
									children: t("remove")
								})]
							})
						]
					})
				}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Switch, {
					className: "dt-rule-switch",
					checked: rule.enabled,
					onChange: (enabled) => onChange({
						...rule,
						enabled
					}),
					label: t("ruleEnable", { name })
				})]
			});
		}
		function SourcePart({ source, part, saved, dirty, onChange, reload }) {
			const { t, call, notify } = usePanel();
			const policy = source.policy;
			const sync = policy.sync;
			const run = useAction(() => call("POST policy-sync/:id", { id: source.id }), { reload });
			const syncNow = () => {
				if (dirty) notify(t("syncNeedsSave"));
				else run.run();
			};
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-part",
				children: [
					policy.fields.map((field) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SourceField, {
						field,
						value: part[field.key],
						saved: saved[field.key],
						fact: void 0,
						labels: source.labels,
						onChange: (next) => onChange({
							...part,
							[field.key]: next
						})
					}, field.key)),
					sync && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
						className: "dt-row-buttons",
						children: [
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
								variant: "outline",
								size: "sm",
								icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "refresh" }),
								disabled: run.busy || !sync.ready,
								onClick: syncNow,
								children: localized(t, sync.label)
							}),
							sync.health?.state === "ready" && sync.health.at && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LabelValue, {
								label: t("syncDone"),
								value: when(sync.health.at, t("lang"))
							}),
							sync.health?.state === "error" && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
								className: "dt-error dt-clamp",
								children: sync.health.detail
							})
						]
					}),
					policy.rows ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(AdmissionTable, {
						rows: policy.rows,
						labels: source.labels,
						table: part.admission ?? {},
						explicit: localized(t, policy.explicit),
						onChange: (admission) => onChange({
							...part,
							admission
						})
					}) : /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
						className: "dt-field",
						children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
							className: "dt-field-head",
							children: t("explicitRequest")
						}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { children: localized(t, policy.explicit) })]
					})
				]
			});
		}
		const CELLS = [
			"listedUnaddressed",
			"unlistedAddressed",
			"unlistedUnaddressed"
		];
		function AdmissionTable({ rows, labels, table, explicit, onChange }) {
			const { t } = usePanel();
			const name = (row) => labels[row.id] ?? localized(t, row.label);
			const set = (row, cell, value) => onChange({
				...table,
				[row]: {
					...table[row],
					[cell]: value
				}
			});
			const select = (row, cell) => {
				const value = table[row.id]?.[cell] ?? ADMISSION_DEFAULTS[cell];
				return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("td", { children: /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("span", {
					className: "dt-admission-cell",
					children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("select", {
						className: "dt-select",
						"aria-label": `${name(row)} · ${t(`admissionCell.${cell}`)}`,
						value,
						onChange: (event) => set(row.id, cell, event.target.value),
						children: ADMISSION_OPTIONS[cell].map((option) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("option", {
							value: option,
							children: t(`admissionValue.${option}`)
						}, option))
					}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
						className: "dt-admission-slot",
						children: cell === "unlistedAddressed" && value === "explicit" && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(InfoTip, {
							text: t("admissionAnyoneWarning"),
							icon: "alert",
							warn: true
						})
					})]
				}) }, cell);
			};
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(Section, {
				title: t("admission"),
				hint: t("admissionHint"),
				children: [
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: explicit }),
					/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("table", {
						className: "dt-table dt-admission",
						children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("thead", { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("tr", { children: [
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)("th", {
								rowSpan: 2,
								children: t("admissionScope")
							}),
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)("th", { children: t("admissionListed") }),
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)("th", {
								colSpan: 2,
								children: t("admissionUnlisted")
							})
						] }), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("tr", { children: [
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)("th", { children: t("admissionUnaddressed") }),
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)("th", { children: t("admissionAddressed") }),
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)("th", { children: t("admissionUnaddressed") })
						] })] }), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("tbody", { children: rows.map((row) => /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("tr", { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("td", {
							className: "dt-admission-scope",
							children: [name(row), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("small", { children: localized(t, row.note) })]
						}), CELLS.map((cell) => row.cells[cell] ? select(row, cell) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)("td", {
							className: "dt-admission-na",
							"aria-label": t("admissionNotReceived"),
							children: "—"
						}, cell))] }, row.id)) })]
					}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("admissionFootnote") })
				]
			});
		}
		function PolicyBlock() {
			const { t } = usePanel();
			const { settings: { blocks, sources, policyVersion }, reload } = useSettings();
			const draft = useBlockDraft("policy", blocks.policy.value, blocks.policy.revision);
			const policy = draft.value;
			const [expanded, setExpanded] = (0, react.useState)(/* @__PURE__ */ new Set());
			const parts = sources.filter((source) => source.installed && source.policy);
			const [tab, setTab] = (0, react.useState)();
			const current = parts.find((source) => source.id === tab) ?? parts[0];
			const edit = (next) => draft.edit({
				...policy,
				...next
			});
			const toggle = (id) => {
				const next = new Set(expanded);
				if (next.has(id)) next.delete(id);
				else next.add(id);
				setExpanded(next);
			};
			const insert = (rule, at) => {
				setExpanded(/* @__PURE__ */ new Set([...expanded, rule.id]));
				edit({ rules: [
					...policy.rules.slice(0, at),
					rule,
					...policy.rules.slice(at)
				] });
			};
			const reveal = (target) => {
				if (target instanceof Element && target.closest(".dt-rules")) setExpanded(new Set(policy.rules.map((rule) => rule.id)));
			};
			const part = (id) => policy.sources[id] ?? { allowed: [] };
			const add = () => insert({
				id: crypto.randomUUID(),
				name: "",
				enabled: true,
				instruction: ""
			}, policy.rules.length);
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("form", {
				className: "dt-form dt-block",
				onSubmit: (event) => {
					draft.submit(event);
				},
				onInvalidCapture: (event) => reveal(event.target),
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)(Fields, {
					disabled: draft.busy,
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("h2", {
							className: "dt-block-title",
							children: [t("term.policy"), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(InfoTip, { text: t("policyIntro") })]
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("p", {
							className: "dt-flow",
							children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(LabelValue, {
								label: t("policyVersion"),
								value: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
									className: "dt-mono",
									children: policyVersion.slice(0, 8)
								})
							}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(InfoTip, { text: t("policyVersionHint") })]
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Section, {
							title: t("rules"),
							hint: t("rulesHint"),
							action: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
								variant: "ghost",
								size: "sm",
								icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "plus" }),
								onClick: add,
								children: t("addRule")
							}),
							children: policy.rules.length ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
								className: "dt-rules",
								children: policy.rules.map((rule, index) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(RuleRow, {
									rule,
									expanded: expanded.has(rule.id),
									onToggle: () => toggle(rule.id),
									onChange: (next) => edit({ rules: policy.rules.map((item, position) => position === index ? next : item) }),
									onDuplicate: () => insert({
										...rule,
										id: crypto.randomUUID(),
										name: `${rule.name}${t("copySuffix")}`.slice(0, LIMITS.ruleName)
									}, index + 1),
									onRemove: () => edit({ rules: policy.rules.filter((_, position) => position !== index) })
								}, rule.id))
							}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("rulesEmpty") })
						}),
						current && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(Section, {
							title: t("policyPerSource"),
							hint: t("policyPerSourceHint"),
							children: [parts.length > 1 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
								className: "dt-subtabs",
								role: "tablist",
								"aria-label": t("policyPerSource"),
								children: parts.map((source) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
									type: "button",
									role: "tab",
									"aria-selected": source === current,
									className: "dt-subtab",
									onClick: () => setTab(source.id),
									children: localized(t, source.title)
								}, source.id))
							}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SourcePart, {
								source: current,
								part: part(current.id),
								saved: blocks.policy.value.sources[current.id] ?? {},
								dirty: draft.dirty,
								reload,
								onChange: (next) => edit({ sources: {
									...policy.sources,
									[current.id]: next
								} })
							}, current.id)]
						})
					]
				}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SaveBar, {
					...draft,
					onDiscard: draft.discard
				})]
			});
		}
		function EvalBlock() {
			const { t } = usePanel();
			const block = useSettings().settings.blocks.eval;
			const draft = useBlockDraft("eval", {
				...block.value,
				timeoutSeconds: String(block.value.timeoutSeconds)
			}, block.revision, (value) => ({
				...value,
				timeoutSeconds: numberOf(value.timeoutSeconds)
			}));
			const value = draft.value;
			const edit = (next) => draft.edit({
				...value,
				...next
			});
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("form", {
				className: "dt-form dt-block",
				onSubmit: (event) => {
					draft.submit(event);
				},
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)(Fields, {
					disabled: draft.busy,
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("h2", {
							className: "dt-block-title",
							children: [t("evalSettings"), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(InfoTip, { text: t("evalIntro") })]
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Section, {
							title: t("acceptMode"),
							hint: t(`modeOption.${value.mode}`),
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SegmentedControl, {
								className: "dt-segmented",
								label: t("acceptMode"),
								value: value.mode,
								onChange: (mode) => edit({ mode }),
								options: [
									"off",
									"observe",
									"auto"
								].map((mode) => ({
									value: mode,
									label: valueLabel(t, "mode", mode),
									title: t(`modeOption.${mode}`)
								}))
							})
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Field, {
							label: t("evalTimeout"),
							hint: t("evalTimeoutHint"),
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Input, {
								type: "number",
								min: LIMITS.evalTimeoutSeconds.min,
								max: LIMITS.evalTimeoutSeconds.max,
								required: true,
								value: value.timeoutSeconds,
								onChange: (event) => edit({ timeoutSeconds: event.target.value })
							})
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Section, {
							title: t("assessorModel"),
							hint: t("assessorModelHint"),
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ModelField, {
								id: "dt-eval-model",
								value: value.model,
								onChange: (model) => edit({ model })
							})
						})
					]
				}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SaveBar, {
					...draft,
					onDiscard: draft.discard
				})]
			});
		}
		function EvalSettings({ version }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-form",
				children: [
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(PolicyBlock, {}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(EvalBlock, {}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(ConfigHistory, {
						blocks: ["policy", "eval"],
						versions: true,
						...version ? { focus: version } : {}
					})
				]
			});
		}
		//#endregion
		//#region src/client/execution.tsx
		/** Execution status view (active Tickets and pause control) and Execution settings group (Executor capacity and workspace environment). */
		function ExecutionStatus({ filter: current, state, reload }) {
			const { t, call, navigate } = usePanel();
			const [limit, setLimit] = (0, react.useState)(20);
			const { data, error, reload: reloadTickets } = usePoll(() => call("GET tickets", { query: {
				state: current,
				limit
			} }), [current, limit]);
			const { paused, load: { maxWorkers } } = state;
			const pause = async () => {
				await call("POST executor/pause", { body: { paused: !paused } });
				await reload();
			};
			const status = state.setup.problem ? {
				tone: "warning",
				label: t("executorWaitingSetup")
			} : paused ? {
				tone: "warning",
				label: t("processingPaused")
			} : {
				tone: "ongoing",
				label: t("executorRunning")
			};
			const action = paused ? "resumeProcessing" : "pauseProcessing";
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [
				/* @__PURE__ */ (0, react_jsx_runtime.jsx)(StatusHead, {
					hint: t("executionStatusIntro"),
					settings: "execution"
				}),
				/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-row-meta dt-status-line",
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
							className: "dt-status-text",
							"data-state": status.tone,
							children: status.label
						}),
						!state.setup.problem && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(LabelValue, {
							label: t("executingLabel"),
							value: `${state.load.running} / ${maxWorkers}`
						}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LabelValue, {
							label: t("queuedLabel"),
							value: state.load.queued
						})] }),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)(ConfirmButton, {
							variant: "outline",
							icon: paused ? "play" : "pause",
							label: t(action),
							title: t(action),
							message: t(paused ? "resumeProcessingConfirm" : "pauseProcessingConfirm"),
							onConfirm: pause
						})
					]
				}),
				/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
					className: "dt-filters",
					children: TICKET_FILTERS.map((value) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Pill, {
						active: current === value,
						onClick: () => {
							setLimit(20);
							navigate({
								page: "execution",
								query: value === "open" ? {} : { filter: value }
							}, true);
						},
						children: t(`ticketFilter.${value}`)
					}, value))
				}),
				current === "idle" && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("idleHint") }),
				/* @__PURE__ */ (0, react_jsx_runtime.jsx)(LoadState, {
					error,
					loading: !data
				}),
				data && (data.items.length ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
					className: "dt-list",
					children: data.items.map((ticket) => ticket.stage === "person" ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(TicketLine, {
						ticket,
						question: true,
						onChanged: reloadTickets
					}, ticket.id) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(TicketLine, { ticket }, ticket.id))
				}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("none") })),
				data?.next_offset != null && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LoadMore, { onMore: () => setLimit(limit + 20) })
			] });
		}
		const firstSentence = (text) => /^[^。；;.]*(?:[。；;]|\.(?=\s|$))?/.exec(text)?.[0] ?? text;
		function EnvironmentVariables({ groups, sources, onPick }) {
			const { t } = usePanel();
			const [open, setOpen] = (0, react.useState)(false);
			const owner = (id) => id === "executor" ? t("term.executor") : localized(t, sources.find((source) => source.id === id)?.title ?? id);
			const count = groups.reduce((sum, group) => sum + group.variables.length, 0);
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(DisclosureRow, {
				icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "hash" }),
				title: /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [
					t("environmentVariables"),
					" ",
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
						className: "dt-count",
						children: count
					})
				] }),
				open,
				onToggle: () => setOpen(!open),
				children: /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-disclosure-body",
					children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("environmentPick") }), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("table", {
						className: "dt-table",
						children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("thead", { children: /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("tr", { children: [
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)("th", { children: t("environmentKey") }),
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)("th", { children: t("environmentDescription") }),
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)("th", { children: t("environmentOwner") })
						] }) }), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("tbody", { children: groups.flatMap((group) => group.variables.map((variable) => /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("tr", { children: [
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)("td", { children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
								type: "button",
								className: "dt-textlink dt-mono",
								onClick: () => onPick(variable.key),
								children: variable.key
							}) }),
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)("td", {
								title: localized(t, variable.description),
								children: firstSentence(localized(t, variable.description))
							}),
							/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("td", { children: [owner(group.owner), !group.enabled && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("span", {
								className: "dt-hint",
								children: [" · ", t("sourceOff")]
							})] })
						] }, variable.key))) })]
					})]
				})
			});
		}
		function ExecutionSettings() {
			const { t } = usePanel();
			const { blocks, environment, sources } = useSettings().settings;
			const executor = blocks.executor.value;
			const draft = useBlockDraft("executor", {
				...executor,
				maxWorkers: String(executor.maxWorkers),
				blockedCommands: executor.blockedCommands.join(" ")
			}, blocks.executor.revision, (value) => ({
				...value,
				maxWorkers: numberOf(value.maxWorkers),
				blockedCommands: value.blockedCommands.split(/[\s,]+/).filter(Boolean)
			}));
			const value = draft.value;
			const edit = (next) => draft.edit({
				...value,
				...next
			});
			const prepare = (0, react.useRef)(null);
			const insert = (key) => {
				const field = prepare.current;
				const at = field?.selectionStart ?? value.prepare.length, to = field?.selectionEnd ?? at;
				edit({ prepare: `${value.prepare.slice(0, at)}"$${key}"${value.prepare.slice(to)}` });
				requestAnimationFrame(() => {
					field?.focus();
					const caret = at + key.length + 3;
					field?.setSelectionRange(caret, caret);
				});
			};
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-form",
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("form", {
					className: "dt-form",
					onSubmit: (event) => {
						draft.submit(event);
					},
					children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)(Fields, {
						disabled: draft.busy,
						children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
							className: "dt-form dt-block",
							children: [
								/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("h2", {
									className: "dt-block-title",
									children: [t("term.executor"), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(InfoTip, { text: t("executorIntro") })]
								}),
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Section, {
									title: t("executorModel"),
									hint: t("executorModelHint"),
									children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ModelField, {
										id: "dt-worker-model",
										value: value.model,
										onChange: (model) => edit({ model })
									})
								}),
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Field, {
									label: t("maxWorkers"),
									hint: t("maxWorkersHint"),
									children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Input, {
										type: "number",
										min: LIMITS.maxWorkers.min,
										max: LIMITS.maxWorkers.max,
										required: true,
										value: value.maxWorkers,
										onChange: (event) => edit({ maxWorkers: event.target.value })
									})
								})
							]
						}), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
							className: "dt-form dt-block",
							children: [
								/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("h2", {
									className: "dt-block-title",
									children: [t("term.environment"), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(InfoTip, { text: t("environmentIntro") })]
								}),
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Field, {
									label: t("executionDirectory"),
									hint: t("executionDirectoryHint"),
									note: value.directory ? void 0 : t("executionDirectoryDefault", { root: environment.root }),
									children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Input, {
										className: "dt-mono",
										value: value.directory,
										placeholder: t("executionDirectoryEmpty"),
										spellCheck: false,
										pattern: "/.*",
										onChange: (event) => edit({ directory: event.target.value })
									})
								}),
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Field, {
									label: t("prepareCommand"),
									hint: t("prepareCommandHint"),
									children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("textarea", {
										ref: prepare,
										className: "dt-textarea dt-mono",
										rows: 3,
										maxLength: LIMITS.prepareCommand,
										spellCheck: false,
										placeholder: t("prepareCommandEmpty"),
										value: value.prepare,
										onChange: (event) => edit({ prepare: event.target.value })
									})
								}),
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)(EnvironmentVariables, {
									groups: environment.variables,
									sources,
									onPick: insert
								}),
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Field, {
									label: t("blockedCommands"),
									hint: t("blockedCommandsHint"),
									children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Input, {
										className: "dt-mono",
										value: value.blockedCommands,
										placeholder: t("blockedCommandsNone"),
										spellCheck: false,
										onChange: (event) => edit({ blockedCommands: event.target.value })
									})
								})
							]
						})]
					}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SaveBar, {
						...draft,
						onDiscard: draft.discard
					})]
				}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ConfigHistory, { blocks: ["executor", "pause"] })]
			});
		}
		new Intl.Segmenter("zh", { granularity: "word" });
		//#endregion
		//#region src/setup.ts
		const SETUP_PROBLEMS = {
			foreignFile: ["deployment", "{file} was not written by dsh-superagent; move it, or choose another state directory."],
			gitTooOld: ["deployment", "git does not read the github.com credential configuration dsh-superagent writes; dsh-superagent needs git 2.32 or later."],
			environmentFailed: ["deployment", "Preparing the agent environment failed."],
			repositoryUnset: ["github", "The GitHub Source names no repository."],
			agentCliUnset: ["github", "The agent GitHub CLI is not set."],
			agentCliMissing: ["github", "The agent GitHub CLI was not found."],
			agentCliSignedOut: ["github", "The agent GitHub CLI cannot read its account."],
			agentCliNoAccount: ["github", "The agent GitHub CLI did not report a GitHub account."],
			repositoryUnreadable: ["github", "@{account} cannot read {repository}."],
			repositoryUnreported: ["github", "The agent GitHub CLI did not return {repository}."],
			repositoryReadOnly: ["github", "@{account} cannot push to {repository}."],
			feishuCliFailed: ["feishu", "The bot lark-cli does not work."],
			feishuNoApp: ["feishu", "auth status of the bot lark-cli did not report the app."],
			feishuBotNotReady: ["feishu", "The bot identity of app {app} is {status}; configure the app secret with lark-cli."],
			feishuUserIdentity: ["feishu", "The bot lark-cli allows user identities (strict mode {mode}); give the bot its own lark-cli configuration in strict mode bot, as docs/006-deployment.md describes."],
			feishuNoBot: ["feishu", "The Feishu bot API did not return the bot's open_id."]
		};
		//#endregion
		//#region src/sources/host.ts
		/** Fixed English health templates (`{name}` placeholders); the panel localizes each `code` in the interface language. */
		const HEALTH_TEXT = {
			setupPending: "Waiting for the deployment check",
			sourceOff: "Off",
			feishuCliUnset: "The Source is on, and its bot lark-cli is not set",
			feishuBotMissing: "Waiting for the Feishu bot",
			pollFailures: "{count} consecutive failed polls; last: {error}"
		};
		//#endregion
		//#region src/client/locales.ts
		/**
		* Bilingual UI dictionaries (`[zh, en]`) and glossary groupings, following the domain terms in `docs/001-domain.md`.
		*/
		const TEXT = {
			title: ["Superagent", "Superagent"],
			close: ["关闭", "Close"],
			cancel: ["取消", "Cancel"],
			confirm: ["确定", "Confirm"],
			loading: ["正在读取…", "Loading…"],
			loadMore: ["加载更多", "Load more"],
			offline: ["无法连接到 dsh-superagent 服务。请确认它正在运行（dsh-superagent status），然后重试。", "Cannot reach the dsh-superagent service. Check that it is running (dsh-superagent status), then retry."],
			serverError: ["dsh-superagent 服务内部错误（{status}），请查看运行日志后重试。", "dsh-superagent service error ({status}). Check the log, then retry."],
			requestFailed: ["请求失败（{status}）。", "Request failed ({status})."],
			empty: ["—", "—"],
			yes: ["是", "Yes"],
			no: ["否", "No"],
			"decision.accept": ["接单", "Accept"],
			"decision.reopen": ["续做", "Reopen"],
			"decision.stop": ["停止", "Stop"],
			"decision.ignore": ["忽略", "Ignore"],
			"decision.unavailable": ["未完成", "Unavailable"],
			"strength.explicit": ["明确", "Explicit"],
			"strength.inferred": ["推断", "Inferred"],
			"mode.off": ["关闭", "Off"],
			"mode.observe": ["仅观察", "Observe"],
			"mode.auto": ["自动接单", "Auto"],
			"source.feishu": ["飞书", "Feishu"],
			"source.github": ["GitHub", "GitHub"],
			"source.github-issue": ["GitHub Issue", "GitHub Issue"],
			"health.github": ["GitHub 来源", "GitHub Source"],
			"health.feishu": ["飞书来源", "Feishu Source"],
			"health.momo": ["MoMo 来源", "MoMo Source"],
			"health.history": ["飞书补收", "Feishu recovery"],
			"health.runtime": ["dsh-superagent", "dsh-superagent"],
			"health.models": ["模型服务", "Model service"],
			"health.assessment": ["发给主 Session 的评估", "Evals sent to the main Session"],
			"health.launch": ["派工启动", "Assignment launches"],
			"health.delivery": ["输入送达", "Input delivery to Assignments"],
			"health.relay": ["转达给主 Session 的消息", "Relays to the main Session"],
			"health.notice": ["给主 Session 的通知", "Notices to the main Session"],
			"health.reply": ["发往渠道的消息", "Messages to Channels"],
			"health.worker": ["执行器事件处理", "Executor event handling"],
			"health.evals": ["未完成的评估", "Unavailable Evals"],
			none: ["暂无。", "None."],
			openSession: ["打开 Session", "Open Session"],
			stop: ["停止", "Stop"],
			policyVersion: ["策略版本", "Policy version"],
			mediaMarker: ["[媒体]", "[Media]"],
			forwardMarker: ["[合并转发]", "[Merged forward]"],
			ticketId: ["工单 id", "Ticket id"],
			wouldAccept: ["忽略（可接单，仅观察）", "Ignore (would accept; observe only)"],
			timeline: ["触发时间线", "Trigger timeline"],
			groupMember: ["飞书用户", "Feishu user"],
			feishuBot: ["飞书机器人", "Feishu bot"],
			unknownMention: ["@某人", "@someone"],
			automatedNotice: ["自动通知", "Automated notice"],
			requeue: ["重新评估", "Evaluate again"],
			imageMarker: ["[图片]", "[image]"],
			rules: ["接单规则", "Accept rules"],
			remove: ["删除", "Delete"],
			"historySource.panel": ["管理页", "Management page"],
			"historySource.defaults": ["插件默认值", "Plugin defaults"],
			"historySource.tool": ["主 Session 工具", "Main Session tool"],
			"historySource.sync": ["从群同步", "Sync"],
			"historySource.web": ["管理页", "Management page"],
			"historySource.member-sync": ["成员同步", "Member sync"],
			"historySource.orchestrator-tool": ["主 Session 工具", "Main Session tool"],
			"historySource.internal": ["内部", "Internal"],
			"historySource.policy-sync": ["从群同步", "Sync"],
			"historySource.sections-migration": ["升级迁移", "Upgrade migration"],
			"historySource.vocabulary-migration": ["升级迁移", "Upgrade migration"],
			"historySource.settings-migration": ["升级迁移", "Upgrade migration"],
			listSeparator: ["、", ", "],
			labelSeparator: ["：", ": "],
			lang: ["zh", "en"],
			automatedEarlier: ["同一发送者之前还有 {count} 条自动消息", "{count} earlier automated messages from the same sender"],
			collapse: ["收起", "Collapse"],
			expand: ["展开全文", "Show all"],
			cardMarker: ["[卡片消息]", "[card message]"],
			setupProblem: ["部署检查未通过：{detail}", "Deployment check failed: {detail}"],
			hostNotRunning: ["dsh-superagent 没有响应：它可能正在重启；持续如此时，DSH 的日志写明原因，常见的是配置有误。", "dsh-superagent is not answering: it may be restarting; if this persists, the DSH log names the cause, often a configuration error."],
			savedRestarting: ["已保存，dsh-superagent 正在重启", "Saved; dsh-superagent is restarting"],
			problems: ["系统问题", "System problems"],
			dismiss: ["不再提示", "Dismiss"],
			saved: ["已保存", "Saved"],
			"tab.settings": ["设置", "Settings"],
			statusTitle: ["状态", "Status"],
			executingLabel: ["执行中", "Executing"],
			queuedLabel: ["排队", "Queued"],
			resumeProcessing: ["恢复处理", "Resume processing"],
			resumeProcessingConfirm: ["恢复后继续评估、派工和发送回复。", "Resuming starts Evals, Assignments and replies again."],
			restartInterrupts: ["保存会重启 dsh-superagent：{count} 个进行中的派工会中断，并带恢复说明重新开始。", "Saving restarts dsh-superagent: {count} running Assignments stop and start again with a recovery note."],
			sourceOff: ["已关闭", "Off"],
			executorWaitingSetup: ["执行器等待部署检查", "Executor waiting for the deployment check"],
			panel: ["Superagent", "Superagent"],
			openMaster: ["打开主 Session", "Open main Session"],
			pagesLabel: ["dsh-superagent 页面", "dsh-superagent pages"],
			searchPlaceholder: ["搜索工单、线程、触发或链接", "Search Tickets, Threads, Triggers or links"],
			searchLabel: ["搜索", "Search"],
			searchFound: ["找到 {tickets} 个工单、{threads} 个线程、{items} 条触发", "Found {tickets} Tickets, {threads} Threads and {items} Triggers"],
			searchNone: ["没有找到。可以输入触发文字、GitHub PR 或 Issue 链接、#编号、飞书消息链接或 om_ 开头的消息 id。", "Nothing found. Try Trigger text, a GitHub PR or Issue link, #number, a Feishu message link, or an om_ message id."],
			searchNoneGithub: ["没有找到。可以输入触发文字、GitHub PR 或 Issue 链接或 #编号。", "Nothing found. Try Trigger text, a GitHub PR or Issue link, or #number."],
			"ticket.ended": ["已结束", "ended"],
			sessionListNotReady: ["Session 列表尚未加载，请稍后重试。", "The Session list has not loaded yet; try again shortly."],
			sessionNotListed: ["这个 Session 不在当前会话列表里，可能已被归档或删除。", "This Session is not in the current list; it may have been archived or deleted."],
			searchFiltered: ["被来源过滤：{reason}", "Filtered by its Source: {reason}"],
			searchFoundCapped: ["找到 {tickets} 个工单、{threads} 个线程、前 {items} 条触发（请缩小搜索范围）", "Found {tickets} Tickets, {threads} Threads and the first {items} Triggers (narrow the search)"],
			inThread: ["在 {thread}", "in {thread}"],
			"tab.overview": ["概览", "Overview"],
			"tab.source": ["来源", "Source"],
			"tab.trigger": ["触发", "Trigger"],
			"tab.eval": ["评估", "Eval"],
			"tab.execution": ["执行", "Execution"],
			sourceError: ["{source} 来源异常", "{source} Source failing"],
			needsYouNone: ["没有待处理的工单。", "No pending Tickets."],
			pendingTickets: ["待处理工单", "Pending Tickets"],
			problemEvalOverdue: ["评估超时未决定：{thread}", "Eval overdue: {thread}"],
			problemSetup: ["部署检查未通过，dsh-superagent 暂不接单", "Deployment check failed; dsh-superagent takes no work"],
			problemNoSource: ["没有运行中的来源，不会收到任何触发", "No Source is running; no Triggers arrive"],
			actionOpenSources: ["去打开来源", "Turn on a Source"],
			problemPaused: ["处理已暂停：不开始新的评估，不派工，不发送回复", "Processing paused: no new Evals, Assignments or replies"],
			problemReply: ["{source} 回复发送失败（已重试 {attempts} 次）", "{source} reply failing (retried {attempts} times)"],
			problemRuntime: ["运行异常：{name}", "{name} failing"],
			problemEvalUnavailable: ["评估未完成：{thread}", "Eval unavailable: {thread}"],
			sourceErrorHint: ["来源会在每次轮询时自动重试。持续出现时检查网络和该来源的登录状态。", "The Source retries on every poll. If this persists, check the network and the Source's sign-in."],
			details: ["详情 ›", "Details ›"],
			lastDay: ["过去 24 小时", "Last 24 hours"],
			flowReceivedLabel: ["到达", "Arrived"],
			flowFilteredLabel: ["被过滤", "Filtered"],
			flowDroppedLabel: ["放弃发送", "Not sent"],
			flowJudgedLabel: ["已评估", "Evaluated"],
			flowAcceptedLabel: ["接单或续做", "Accepted or continued"],
			idleLabel: ["等待新触发", "Waiting for a Trigger"],
			problemNoAllowed: ["没有人能发起工作：各来源上的名单都为空，任何请求都不会成为工单", "No one may originate work: the lists on every Source are empty, so no request can become a Ticket"],
			actionAddAllowed: ["去添加", "Add senders"],
			"problemSetupFix.github": ["在设置 › 来源的 GitHub 卡片修正后保存，会重新检查；在 dsh-superagent 之外修复的（例如登录 CLI），点“重新检查”。", "Fix it on the GitHub card of the Source settings and save to check again; after a fix outside dsh-superagent, such as signing a CLI in, choose Check again."],
			"problemSetupFix.feishu": ["在设置 › 来源的飞书卡片修正后保存，会重新检查；在 dsh-superagent 之外修复的（例如配置机器人），点“重新检查”。", "Fix it on the Feishu card of the Source settings and save to check again; after a fix outside dsh-superagent, such as configuring the bot, choose Check again."],
			"problemSetupFix.deployment": ["在部署设置里修正后保存，会重新检查；在 dsh-superagent 之外修复的（例如升级 git），点“重新检查”。", "Fix it in the Deployment settings and save to check again; after a fix outside dsh-superagent, such as upgrading git, choose Check again."],
			problemSetupFeishu: ["飞书机器人检查未通过，飞书来源暂停", "Feishu bot check failed; the Feishu Source is paused"],
			labelsAdded: ["列表已更新，新增：{names}", "List updated, added: {names}"],
			labelsCurrent: ["列表已是最新", "List is up to date"],
			labelsFailed: ["读取失败，列表保持不变：{error}", "Could not read the list; it stays as it was: {error}"],
			sourceNotInstalled: ["插件未安装", "Plugin not installed"],
			sourceNotInstalledHint: ["提供这个来源的插件没有加载，配置按保存时的样子保留。", "The plugin that provides this Source is not loaded; its configuration is kept as saved."],
			sourceEnable: ["运行来源：{name}", "Run Source: {name}"],
			addRow: ["添加", "Add"],
			removeRow: ["移除：{name}", "Remove: {name}"],
			sourceFilteredTitle: ["24 小时内最近被过滤的触发", "Latest Triggers filtered in the last 24 hours"],
			sourceDroppedTitle: ["24 小时内放弃发送的消息", "Not sent in the last 24 hours"],
			sourceDroppedHint: ["这些消息要发往的对话已无法接收，或来源已不再监听该对话，因此放弃发送。", "Their conversation can no longer receive them, or the Source no longer listens to it, so they are not sent."],
			sourceStatusIntro: ["每个来源是否在运行、过去 24 小时到达和被过滤的触发，以及被过滤的原因。", "Whether each Source runs, the Triggers that arrived and were filtered in the last 24 hours, and why they were filtered."],
			sourceReceivedLabel: ["24 小时到达", "Arrived in 24 h"],
			sourceFilteredLabel: ["被过滤", "Filtered"],
			sourceLatestLabel: ["最近", "Latest"],
			advanced: ["高级", "Advanced"],
			"sourceState.done": ["运行中", "Running"],
			"sourceState.ongoing": ["启动中", "Starting"],
			"sourceState.warning": ["待处理", "Pending"],
			"sourceState.error": ["出错", "Failing"],
			sourceOpenSettings: ["去设置", "Open settings"],
			"sourceState.setup": ["等待部署检查", "Waiting for the deployment check"],
			setupFixLink: ["去修正", "Fix it"],
			"openSettingsOf.deployment": ["去部署页修改", "Change it on Deployment"],
			loadEarlier: ["加载更早的触发", "Load earlier Triggers"],
			subscribedTickets: ["订阅此线程的工单", "Tickets subscribed to this Thread"],
			threadNotFound: ["找不到这个线程。", "Thread not found."],
			threadsNone: ["没有符合条件的线程。", "No matching Threads."],
			threadLatest: ["最近 {time}", "Latest {time}"],
			threadCreated: ["创建 {time}", "Created {time}"],
			threadEvaluating: ["评估进行中", "Eval running"],
			pollFailed: ["轮询失败：{error}", "Polling failed: {error}"],
			unsubscribe: ["取消订阅", "Unsubscribe"],
			unsubscribeTitle: ["取消订阅", "Unsubscribe"],
			unsubscribeConfirm: ["取消后，“{title}”的新触发不再扇出给工单，直到下一次接单或关联。", "New Triggers in \"{title}\" will stop fanning out to Tickets until the next accept or attach."],
			unsubscribePending: ["已取消订阅，结果等待注入主 Session。", "Unsubscribed; the receipt is waiting to reach the main Session."],
			openOriginal: ["打开原文", "Open original"],
			evaluatingBanner: ["评估进行中：{count} 条触发，{strength}，{deadline} 到期。", "Eval running: {count} Triggers, {strength}, due {deadline}."],
			noTriggers: ["没有保留的触发。", "No retained Triggers."],
			dispositionQueued: ["已排队，等待评估", "Queued for Eval"],
			dispositionEvaluating: ["评估进行中", "Eval running"],
			dispositionFanout: ["扇出到 {count} 个工单", "Fanned out to {count} Tickets"],
			dispositionDelivered: ["已送达工单", "Delivered to Ticket"],
			dispositionDeliveredHint: ["有人在已有工单的线程上跟进时，消息直接送达工单的执行器，不经评估，也不产生决定。", "A person's follow-up on a Thread with a Ticket goes straight to the Ticket's Executor, with no Eval and no Decision."],
			handedBack: ["“{ticket}”的执行器把这条触发交回评估：{reason}", "The Executor of “{ticket}” handed it back for an Eval: {reason}"],
			inputHandedBack: ["已交回评估：{reason}", "Handed back for an Eval: {reason}"],
			contextOnly: ["仅作上下文", "Context only"],
			contextOnlyHint: ["执行器关注这个线程只为了解情况：这里的消息会送达工单，但不带授权，也不会恢复已结束的工单。", "The Executor follows this Thread only to stay informed: its messages reach the Ticket but grant nothing and resume no ended Ticket."],
			requeueAlready: ["这条触发已经在评估中。", "This Trigger is already in an Eval."],
			andMore: ["等 {count} 个", " and {count} more"],
			newestFirst: ["最新在前", "newest first"],
			openTicket: ["查看工单", "Open Ticket"],
			tagFiltered: ["已过滤：{reason}", "Filtered: {reason}"],
			threadDormantShort: ["工单已结束", "Tickets ended"],
			threadPollFailed: ["轮询失败", "Polling failed"],
			threadQueued: ["排队 {count}", "{count} queued"],
			threadSubscribed: ["已订阅", "Subscribed"],
			threadUnsubscribed: ["未订阅", "Not subscribed"],
			fanoutTo: ["扇出给", "Fans out to"],
			unsubscribeHint: ["取消订阅后，这个线程的新触发不再扇出给工单，直到下一次接单或关联。", "After unsubscribing, new Triggers here stop fanning out to Tickets until the next accept or attach."],
			"threadFilter.subscribed": ["已被订阅", "Subscribed"],
			"threadFilter.evaluating": ["评估中", "Evaluating"],
			"threadFilter.recent": ["24 小时内有新触发", "New Triggers in 24 h"],
			"threadFilter.all": ["全部线程", "All Threads"],
			triggerIntro: ["触发按线程归组；线程决定它们扇出给哪些工单、由哪次评估处理。", "Triggers grouped by Thread; the Thread decides which Tickets they fan out to and which Eval handles them."],
			threadDecisions: ["这个线程的决定 · {count}", "Decisions in this Thread · {count}"],
			policyVersionHint: ["策略版本由接单规则、各来源上的策略和评估的接单模式决定；修改任何一项都会生成新版本，并通知进行中的工单。每个工单记下接单时的版本。", "The rules, the Policy on each Source and the accept mode of Eval make up the Policy version; any change makes a new version and notifies open Tickets. Each Ticket records the version it was accepted under."],
			syncNeedsSave: ["请先保存或放弃修改，再同步。", "Save or discard your changes before syncing."],
			acceptMode: ["接单模式", "Accept mode"],
			"modeOption.off": ["只处理明确的请求，不评估其他触发", "Only explicit requests are handled; other Triggers are not evaluated"],
			"modeOption.observe": ["评估其他触发并记录研判，但不接单", "Other Triggers are evaluated and Assessments recorded, but nothing is accepted"],
			"modeOption.auto": ["其他触发符合规则时接单", "Other Triggers that match a rule are accepted"],
			rulesHint: ["写明可以接什么、应忽略什么，也可以写明按这条规则接下的工单请谁审阅 PR。多条命中只接一单，有冲突或不明确时不接单。", "State what to accept and what to ignore, and optionally who reviews the PRs of Tickets accepted under the rule. Several matches accept once; conflicts or ambiguity accept nothing."],
			addRule: ["添加规则", "Add rule"],
			rulesEmpty: ["暂无规则，不会主动接单。", "No rules; nothing is accepted proactively."],
			ruleName: ["规则名称", "Rule name"],
			ruleInstruction: ["接单条件", "Acceptance condition"],
			ruleInstructionPlaceholder: ["例如：明确要求修正已有说明中的失效链接；不新增或改变产品承诺。", "For example: explicit requests to fix broken links in existing docs; no new product promises."],
			ruleEnable: ["启用规则：{name}", "Enable rule: {name}"],
			newRule: ["新规则", "New rule"],
			duplicate: ["复制", "Duplicate"],
			copySuffix: [" 副本", " copy"],
			evalTimeout: ["单次评估时限 / 秒", "Eval time limit / seconds"],
			evalTimeoutHint: ["主 Session 读取上下文并研判。到期后记为未完成，后续触发重新评估。", "The main Session reads context and assesses. When time runs out the Eval is unavailable and later Triggers are evaluated again."],
			evalIntro: ["评估决定一批触发是否成为工作：推断出的候选能否接单、评估时限和研判模型。", "Eval decides whether a batch of Triggers becomes work: whether inferred candidates may be accepted, the time limit, and the assessor model."],
			evalSettings: ["评估设置", "Eval settings"],
			policyIntro: ["评估依据的规则：接单规则，以及各来源上谁能发起工作。修改会生成新的策略版本，并通知进行中的工单。", "The rules Eval follows: the accept rules, and who may originate work on each Source. A change makes a new Policy version and notifies open Tickets."],
			assessorModel: ["研判模型", "Assessor model"],
			assessorModelHint: ["主 Session 的模型，负责研判和路由。保存后用于新建的主 Session，已有 Session 保持原选择。", "Model of the main Session, which assesses and routes. Applies to a newly created main Session; existing Sessions keep their choice."],
			ruleLabel: ["规则", "Rules"],
			"decisionFilter.work": ["接单与续做", "Accept and reopen"],
			"decisionFilter.stop": ["停止", "Stopped"],
			"decisionFilter.ignore": ["忽略", "Ignored"],
			"decisionFilter.unavailable": ["未完成", "Unavailable"],
			"decisionFilter.all": ["全部", "All"],
			lastDayOnly: ["仅过去 24 小时到达的触发 ✕", "Triggers from the last 24 hours only ✕"],
			evalStatusIntro: ["评估按策略对触发做出的决定，每条写明理由。", "The Decisions Eval made on Triggers under the Policy, each with its reason."],
			policyPerSource: ["在各来源上", "On each Source"],
			policyPerSourceHint: ["策略在每个来源上的部分：谁能通过这个来源发起工作，用这个来源自己的身份；不同来源之间不对应。要让智能体知道同一个人在各来源的账号，写在提示词里。", "The Policy's part on each Source: who may originate work through it, in that Source's own identities, with no mapping between Sources. To tell the agents a person's account on each Source, write it in the prompts."],
			explicitRequest: ["明确的请求", "Explicit request"],
			admission: ["准入", "Admission"],
			admissionHint: ["每个接收范围里，谁的什么消息算明确的请求、推断的候选，或被忽略。行来自来源设置里的接收范围。计入策略版本。", "For each receiving scope, whose messages are explicit requests, inferred candidates, or ignored. The rows come from the receiving scopes in the Source settings. Part of the Policy version."],
			admissionScope: ["接收范围", "Receiving scope"],
			admissionListed: ["名单内", "On the list"],
			admissionUnlisted: ["名单外", "Not on the list"],
			admissionAddressed: ["点名智能体", "Addresses the agent"],
			admissionUnaddressed: ["未 @", "No mention"],
			admissionNotReceived: ["这个范围收不到这类消息", "This scope does not receive these messages"],
			"admissionCell.listedUnaddressed": ["名单内 · 未 @", "On the list · no mention"],
			"admissionCell.unlistedAddressed": ["名单外 · 点名智能体", "Not on the list · addresses the agent"],
			"admissionCell.unlistedUnaddressed": ["名单外 · 未 @", "Not on the list · no mention"],
			"admissionValue.explicit": ["明确的请求", "Explicit request"],
			"admissionValue.inferred": ["推断的候选", "Inferred candidate"],
			"admissionValue.ignore": ["忽略", "Ignore"],
			admissionAnyoneWarning: ["这个范围里任何人点名智能体都能直接发起工作", "Anyone here who addresses the agent can originate work directly"],
			admissionFootnote: ["「推断的候选」按接单模式评估：模式为关闭时忽略。已有工单的线程里的跟进不看这张表。改成更弱的选项时，按这一格接下的进行中工单的授权失效。", "Inferred candidates follow the accept mode and are ignored when it is off. Follow-ups on Threads that have Tickets do not use this table. Weakening a cell revokes the Mandates of open Tickets accepted under it."],
			syncDone: ["上次同步", "Last synced"],
			evalRecordsPaused: ["处理已暂停：新的触发会被记录，但不会被评估。", "Processing is paused: new Triggers are recorded but not evaluated."],
			resumeWhere: ["在执行状态中恢复", "Resume in the Execution status"],
			"outcome.completed": ["已完成", "Completed"],
			"outcome.merged": ["PR 已合并", "Pull request merged"],
			"outcome.closed": ["PR 已关闭（未合并）", "Pull request closed unmerged"],
			"outcome.dropped": ["无需处理", "Nothing to do"],
			"outcome.stopped": ["人工停止", "Stopped by a person"],
			"assignment.pending": ["待启动", "Pending"],
			"assignment.running": ["执行中", "Running"],
			"assignment.ended": ["已结束", "Ended"],
			"report.queued": ["排队", "queued"],
			"report.running": ["执行中", "running"],
			"report.progress": ["进展", "progress"],
			"report.waiting": ["等待", "waiting"],
			"report.ready": ["就绪", "ready"],
			"report.blocked": ["受阻", "blocked"],
			"report.failed": ["失败", "failed"],
			"report.dropped": ["无需处理", "no action needed"],
			"report.completed": ["已完成", "completed"],
			"report.merged": ["已合并", "merged"],
			"report.closed": ["PR 已关闭", "PR closed"],
			"report.stopped": ["已停止", "stopped"],
			"report.open": ["进行中", "open"],
			"input.trigger": ["触发", "Trigger"],
			"input.policy-changed": ["策略变更", "Policy change"],
			"input.reopen": ["续做", "Reopened"],
			"input.resumed": ["恢复：线程上有人发了新消息", "Resumed by a new message on its thread"],
			"input.text": ["dsh-superagent 说明", "dsh-superagent note"],
			"input.note": ["主 Session 的备注", "Orchestrator note"],
			attentionPrefix: ["待人工决定：", "Attention: "],
			stopConfirmTitle: ["停止工单", "Stop Ticket"],
			stopConfirm: ["停止“{title}”？当前派工结束，Session 和执行目录保留；停止收回授权，之后线程里的消息不再恢复它，要继续需要重新接单。", "Stop \"{title}\"? Its current Assignment ends; its Session and directory stay. Stopping withdraws its Mandate: later messages on its Threads do not resume it, and continuing needs a new accept."],
			endedAt: ["{time} {outcome}：{reason}", "{time} {outcome}: {reason}"],
			assignmentNumber: ["第 {number} 次派工", "Assignment {number}"],
			inputDelivered: ["已送达", "Delivered"],
			inputPausedHint: ["未送达：处理已暂停，恢复后送达", "Undelivered: processing is paused; delivery resumes with it"],
			inputWaitingHint: ["未送达：等待派工运行", "Undelivered: waiting for the Assignment to run"],
			inputRetryHint: ["未送达：会自动重试，直到送达", "Undelivered: delivery is retried until it succeeds"],
			deliveryFailedPrefix: ["送达失败：", "Delivery failed: "],
			subscribedThreads: ["订阅的线程", "Subscribed Threads"],
			answerIn: ["去{source}回答", "Answer in {source}"],
			ticketNotFound: ["找不到这个工单。", "Ticket not found."],
			identifiers: ["标识", "Identifiers"],
			"basis.admission": ["准入", "Admission"],
			"basis.followup": ["线程内跟进", "Follow-up in Thread"],
			"basis.observation": ["接收全部消息的群", "Chat receiving all messages"],
			"basis.bot": ["名单内的机器人", "Listed bot"],
			"basis.mode": ["接单模式", "Accept mode"],
			"basis.rules": ["命中规则", "Matched rules"],
			"basis.legacyAuthority": ["旧版授权", "Legacy authority"],
			"legacy.explicit_mention": ["@ 智能体", "Mention"],
			"legacy.proactive_rule": ["主动规则", "Proactive rule"],
			"legacy.thread_followup": ["线程内跟进", "Thread follow-up"],
			ruleMatched: ["{rule} · 匹配：{reason}", "{rule} · matched: {reason}"],
			ruleUnmatched: ["{rule} · 不匹配：{reason}", "{rule} · not matched: {reason}"],
			directionLine: ["实施意图：{intent}；修改依据：{basis}；{design}", "Implementation intent: {intent}; target: {basis}; {design}"],
			intentYes: ["已明确", "established"],
			intentNo: ["未明确", "not established"],
			"targetBasis.specified": ["已明确目标", "specified"],
			"targetBasis.existing-standard": ["既有规范／已验证正确状态", "existing standard or verified correct state"],
			"targetBasis.exploratory": ["探索调研／方案推演", "exploratory research or option synthesis"],
			"targetBasis.undetermined": ["目标未定", "undetermined"],
			designNeeded: ["仍需产品／视觉设计决策", "a product or design decision remains"],
			designNotNeeded: ["无需新增设计决策", "no new design decision"],
			directionEvidence: ["方向证据：{evidence}", "Evidence: {evidence}"],
			maxWorkers: ["并行工单数", "Concurrent Tickets"],
			maxWorkersHint: ["超过并发上限的工单排队等待。", "Tickets beyond the limit wait in a queue."],
			"basis.sender": ["发起人", "Sender"],
			"basis.addressed": ["点名方式", "Addressed by"],
			"addressed.mention": ["@ 智能体", "Mention"],
			"addressed.direct": ["私聊", "Direct message"],
			executorIntro: ["执行器执行派工：每个工单一个执行器 Session 和执行目录。", "The Executor runs Assignments: one Executor Session and directory per Ticket."],
			executorModel: ["执行器模型", "Executor model"],
			executorModelHint: ["保存后用于新建的执行器 Session，已有 Session 保持原选择。留空继承 DSH 默认值。", "Applies to new Executor Sessions; existing Sessions keep their choice. Leave empty to inherit the DSH default."],
			assignmentReportShort: ["报告：{state}", "Report: {state}"],
			assignmentSpan: ["{from} → {to}", "{from} → {to}"],
			inputUndelivered: ["未送达", "Undelivered"],
			mandateDetails: ["授权详情", "Mandate details"],
			now: ["现在", "now"],
			stopHint: ["停止后当前派工结束，Session 和执行目录保留；停止收回授权，之后线程里的消息不再恢复它，要继续需要重新接单。", "Stopping ends the current Assignment; its Session and directory stay. Stopping withdraws its Mandate: later messages on its Threads do not resume it, and continuing needs a new accept."],
			idleHint: ["执行器结束了当前回合，没有提出问题；这些工单订阅的线程收到新触发时继续。", "The Executor ended its turn without asking anything; a new Trigger on a subscribed Thread resumes it."],
			"stage.answer": ["待回答", "Awaiting answer"],
			"stage.review": ["待验收", "Awaiting review"],
			"stage.blocked": ["待处理受阻", "Blocked"],
			"stage.failed": ["待处理失败", "Failed"],
			"stage.delivery": ["输入未送达", "Input undelivered"],
			"stage.queued": ["排队中", "Queued"],
			"stage.working": ["执行中", "Working"],
			"stage.idle": ["等待新触发", "Waiting for a Trigger"],
			deliveredInputs: ["已送达的输入 · {count}", "Delivered Inputs · {count}"],
			endedAtShort: ["{time} {outcome}", "{time} {outcome}"],
			legacyAssignment: ["原始说明", "Original brief"],
			legacyScopeShort: ["未记录（旧版导入）", "Not recorded (legacy import)"],
			retry: ["重试", "Retry"],
			failedPrefix: ["失败：", "Failed: "],
			blockedPrefix: ["受阻：", "Blocked: "],
			retryConfirm: ["为“{title}”结束当前派工并重新派工？授权和订阅不变。", "End the current Assignment of \"{title}\" and start a new one? Mandate and Subscriptions stay."],
			retryTitle: ["重试工单", "Retry Ticket"],
			undeliveredInputs: ["未送达的输入", "Undelivered Inputs"],
			executionStatusIntro: ["执行器的状态，以及按在等谁分组的工单。", "The Executor's state, and the Tickets grouped by who they wait on."],
			ticketUndeliveredLabel: ["未送达", "Undelivered"],
			ticketMandateLabel: ["授权", "Mandate"],
			ticketActorLabel: ["发起", "From"],
			ticketUpdatedLabel: ["更新", "Updated"],
			executionDirectory: ["执行目录的根目录", "Ticket directory root"],
			executionDirectoryDefault: ["留空时用 {root}", "Empty uses {root}"],
			executionDirectoryEmpty: ["留空：默认目录", "Empty: the default directory"],
			openThread: ["打开 {source} 原文", "Open on {source}"],
			executionDirectoryHint: ["每个工单在这里有自己的目录，以工单短名命名；执行器 Session 在其中工作。这只按目录分开工单，不是安全边界。", "Each Ticket gets its own directory here, named by its short name, where its Executor Session works. This separates Tickets by directory only; it is not a security boundary."],
			prepareCommand: ["准备命令", "Prepare command"],
			prepareCommandHint: ["新工单的目录建好前，在根目录下用 sh 运行一次，执行环境的变量是它的环境变量，例如用 git worktree 把仓库检出到 $DSH_SUPERAGENT_DIR。留空就是空目录。失败时工单显示失败，并附上命令的输出。", "Runs once with sh in the root before a new Ticket's directory exists, with the execution environment's variables as its environment, for example to check a repository out to $DSH_SUPERAGENT_DIR with git worktree. Leave it empty for an empty directory. A failure fails the Ticket with the command's output."],
			prepareCommandEmpty: ["留空：空目录", "Empty: an empty directory"],
			blockedCommands: ["禁止调用的命令", "Blocked commands"],
			blockedCommandsHint: ["执行器 Session 调用这些命令名时直接失败，例如用你个人账号登录的 CLI。只拦按名字的调用，用绝对路径仍能运行，所以不是安全边界。gh、git、lark-cli 不能禁止。", "Command names that fail when an Executor Session calls them, such as a CLI signed in to your own account. Only calls by name fail; an absolute path still runs, so this is not a security boundary. gh, git and lark-cli cannot be blocked."],
			blockedCommandsNone: ["以空格分隔；没有", "Separated by spaces; none"],
			environmentIntro: ["执行器和各来源向执行环境登记变量，每个有键、值和说明。准备命令以环境变量读取它们，执行器 Session 在指令里读到它们和说明。工单自己的值来自它的目录和接下它的触发，其余是部署的当前值；不含任何密钥。只能在管理页修改。", "The Executor and the Sources register variables with the execution environment, each with a key, a value and a description. The prepare command reads them as environment variables, and the Executor Session reads them with their descriptions in its instructions. A Ticket's own values follow from its directory and the Trigger that started it; the others are the deployment's current values. None holds a credential. Only the management page can change these settings."],
			environmentVariables: ["可用的环境变量", "Available variables"],
			environmentPick: ["点击键名插入到准备命令。", "Choose a key to insert it into the prepare command."],
			environmentKey: ["键", "Key"],
			environmentDescription: ["说明", "Description"],
			environmentOwner: ["注册者", "Registered by"],
			executorRunning: ["执行器运行中", "Executor running"],
			pauseProcessing: ["暂停处理", "Pause processing"],
			pauseProcessingConfirm: ["暂停后，来源继续记录触发，但不开始新的评估、不派工、不发送回复，直到恢复。", "While paused, Sources keep recording Triggers, but no Evals or Assignments start and no replies are sent until processing resumes."],
			processingPaused: ["处理已暂停", "Processing paused"],
			"ticketFilter.open": ["进行中", "Open"],
			"ticketFilter.person": ["待处理", "Pending"],
			"ticketFilter.working": ["执行中", "Working"],
			"ticketFilter.idle": ["等待新触发", "Waiting for a Trigger"],
			"ticketFilter.ended": ["已结束", "Ended"],
			policyVersionUnrecorded: ["最近的保存记录里没有策略版本 {version}：它来自更早的保存、首次启动时的设置或更早的数据。", "The recent saves do not include Policy version {version}: an older save, the settings at the first start, or older data made it."],
			defaultModel: ["DSH 当前默认：{model}", "DSH default: {model}"],
			defaultModelUnavailable: ["DSH 默认模型暂不可用", "DSH default model unavailable"],
			modelProvider: ["服务商", "Provider"],
			modelName: ["模型", "Model"],
			modelEffort: ["推理强度（可选）", "Reasoning effort (optional)"],
			modelInherit: ["继承 DSH 默认值", "Inherit the DSH default"],
			modelEffortDefault: ["模型默认", "Model default"],
			modelCatalogError: ["无法加载模型建议，仍可填写已知的服务商和模型：{error}", "Model suggestions are unavailable; known Provider and Model names still work: {error}"],
			historyIntro: ["每次保存记一条；改变策略版本的保存（接单规则、各来源上的策略、接单模式）通知进行中的工单。", "Each save is one entry; saves that change the Policy version (rules, the Policy on each Source, accept mode) notify open Tickets."],
			historyItem: ["第 {revision} 次保存 · {source}", "Save {revision} · {source}"],
			historyPolicyChanged: ["生成策略版本 {version}", "New Policy version {version}"],
			historyNoBaseline: ["上一个设置版本没有记录，无法比较。", "The previous revision was not recorded; nothing to compare."],
			historyNoChanges: ["当前设置项没有变化。", "No change to current settings."],
			historyNotified: ["因策略变更通知了 {count} 个进行中的工单：{titles}", "Policy change notified {count} open Tickets: {titles}"],
			historyEmpty: ["还没有记录的版本；下次保存后开始记录。", "No revisions recorded yet; history starts with the next save."],
			"change.mode": ["接单模式：{from} → {to}", "Accept mode: {from} → {to}"],
			"change.timeout": ["评估时限：{from} → {to} 秒", "Eval time limit: {from} → {to} s"],
			"change.ruleAdded": ["新增规则：{name}", "Rule added: {name}"],
			"change.ruleRenamed": ["规则改名：{from} → {to}", "Rule renamed: {from} → {to}"],
			"change.ruleInstruction": ["规则条件修改：{name}", "Rule condition changed: {name}"],
			"change.ruleEnabled": ["规则启用：{name}", "Rule enabled: {name}"],
			"change.ruleDisabled": ["规则停用：{name}", "Rule disabled: {name}"],
			"change.ruleRemoved": ["删除规则：{name}", "Rule removed: {name}"],
			"change.paused": ["暂停处理", "Processing paused"],
			"change.resumed": ["恢复处理", "Processing resumed"],
			"change.maxWorkers": ["并行工单数：{from} → {to}", "Concurrent Tickets: {from} → {to}"],
			"change.executionDirectory": ["执行目录的根目录：{from} → {to}", "Ticket directory root: {from} → {to}"],
			"change.prepareCommand": ["准备命令", "Prepare command"],
			"change.blockedCommands": ["禁止调用的命令：{from} → {to}", "Blocked commands: {from} → {to}"],
			configHistory: ["配置历史", "Configuration history"],
			"change.evalModel": ["研判模型", "Assessor model"],
			"change.executorModel": ["执行器模型", "Executor model"],
			"change.sourceEnabled": ["启用来源：{source}", "Source enabled: {source}"],
			"change.sourceDisabled": ["停用来源：{source}", "Source disabled: {source}"],
			"change.sourceAdmission": ["{source} · 准入修改", "{source} · admission changed"],
			"change.sourceField": ["{source} · {field}：{from} → {to}", "{source} · {field}: {from} → {to}"],
			"change.sourceRowsAdded": ["{source} · {field} 新增：{items}", "{source} · {field} added: {items}"],
			"change.sourceRowsRemoved": ["{source} · {field} 移除：{items}", "{source} · {field} removed: {items}"],
			"change.sourceRowsChanged": ["{source} · {field} 修改：{items}", "{source} · {field} changed: {items}"],
			draftRestored: ["未保存 · 已恢复草稿", "Unsaved · draft restored"],
			draftKept: ["未保存 · 草稿已保留", "Unsaved · draft kept"],
			draftFailed: ["无法保留草稿，请保存后再离开：{error}", "Could not keep the draft; save before leaving: {error}"],
			save: ["保存", "Save"],
			discard: ["放弃修改", "Discard changes"],
			saveConflict: ["设置已在别处修改，其中有你也改过的项；保存会以你的修改为准。", "Settings changed elsewhere, including items you changed too; saving keeps your version of them."],
			saveMerged: ["设置已在别处修改，你的修改已合并到最新版本；请检查后保存。", "Settings changed elsewhere; your changes are merged onto the latest version. Check them, then save."],
			saveRebasing: ["已在别处修改，正在读取最新版本…", "Changed elsewhere; reading the latest version…"],
			invalidSettings: ["这些字段无效：{fields}", "Invalid fields: {fields}"],
			"settingsGroup.source": ["来源", "Sources"],
			"settingsGroup.eval": ["评估", "Eval"],
			"settingsGroup.execution": ["执行", "Execution"],
			"settingsGroup.prompts": ["提示词", "Prompts"],
			"settingsGroup.deployment": ["部署", "Deployment"],
			unsetValue: ["未设置", "not set"],
			promptChanges: ["{count} 处修改", "{count} changes"],
			unsaved: ["未保存", "Unsaved"],
			promptsDraftVersion: ["未保存 · 基于版本 {revision}", "Unsaved · based on version {revision}"],
			"promptPart.runtime/admission": ["主 Session 接单约束", "Main Session accept constraints"],
			"promptPart.runtime/policy": ["策略与启用的规则", "Policy and enabled rules"],
			"promptPart.runtime/handoff/orchestrator": ["工单交付与人工确认（主 Session）", "Ticket handoff and human confirmation (main Session)"],
			"promptPart.runtime/handoff/worker": ["工单交付与人工确认（执行器）", "Ticket handoff and human confirmation (Executor)"],
			"promptPart.runtime/policy/none": ["策略（没有启用的规则时）", "Policy (when no rule is enabled)"],
			"promptPart.skill/feishu": ["飞书技能", "Feishu skill"],
			"promptPart.skill/github": ["GitHub 技能", "GitHub skill"],
			"promptPart.runtime/environment": ["执行环境", "Execution environment"],
			promptViewEdit: ["编辑", "Edit"],
			promptViewFull: ["完整提示词", "Full prompt"],
			promptViewHistory: ["历史", "History"],
			promptSections: ["提示词段落", "Prompt sections"],
			promptTeamGroup: ["团队约定", "Team agreements"],
			promptSkillsGroup: ["技能", "Skills"],
			"promptPartHint.communication": ["何时通知人、消息的写法、GitHub 首行声明、Review 的回复与 review bot", "When to notify people, how messages read, the GitHub first line, review replies and review bots"],
			"promptPartHint.scope": ["工单何时继续、何时暂停并交草稿", "When a Ticket goes on, and when it stops with a draft"],
			"promptPartHint.delivery": ["PR 证据、自动合并条件、提交作者", "PR evidence, the auto-merge condition, the commit author"],
			"promptReadBy.both": ["主 Session 和执行器 Session 都会读到。", "The main Session and Executor Sessions read it."],
			"promptReadBy.skill": ["Session 需要时按名字加载。", "Sessions load it by name when they need it."],
			"promptReadBy.orchestrator": ["只有主 Session 会读到。", "Only the main Session reads it."],
			"promptReadBy.worker": ["只有执行器 Session 会读到。", "Only Executor Sessions read it."],
			promptBuiltInGroup: ["内置段落", "Built-in parts"],
			promptTemplateHint: ["这是模板：保留占位符 {placeholders}，由系统填入内容。", "A template: keep the placeholders {placeholders}, which the system fills in."],
			promptDefaultUpdated: ["默认内容已更新", "Default updated"],
			promptDefaultUpdatedHint: ["升级改了这一段的默认内容，你的文本保持不变。", "An upgrade changed the default of this part; your text stays as it is."],
			promptDefaultUpdatedKnown: ["下面是默认内容的变化。", "Below is how the default changed."],
			promptDefaultUpdatedUnknown: ["系统没有记录你编辑时的默认内容；下面是你的文本与新默认内容的对比。", "The default you edited from was not recorded; below, your text against the new default."],
			promptRemovedParts: ["当前插件版本已没有这些段落，你为它们写的文本不再使用，下次保存时移除：{parts}", "This version no longer has these parts; your text for them is unused and goes at the next save: {parts}"],
			promptKeepMine: ["保留我的文本", "Keep my text"],
			promptTakeDefault: ["改用新的默认内容", "Use the new default"],
			promptFullState: ["共 {count} 段 · {chars} 字符 · {state}", "{count} sections · {chars} characters · {state}"],
			promptCopyAll: ["复制全文", "Copy all"],
			promptChanged: ["已改", "Changed"],
			promptCompare: ["比较对象", "Compare with"],
			promptCompareSaved: ["与已保存比较", "Against saved"],
			promptCompareDefault: ["与默认比较", "Against defaults"],
			promptBuiltInFolded: ["按当前设置生成，不参与比较。", "Generated from the current settings; not compared."],
			promptSameAsSaved: ["与已保存相同。", "Same as saved."],
			promptSameLines: ["… 相同的 {count} 行 …", "… {count} unchanged lines …"],
			copied: ["已复制", "Copied"],
			promptPartTeam: ["团队约定", "Team agreement"],
			promptPartFixed: ["内置", "Built in"],
			promptPartGenerated: ["内置 · 按当前设置生成", "Built in · from the current settings"],
			"promptPart.communication": ["沟通方式", "Communication"],
			"promptPart.scope": ["工单范围", "Ticket scope"],
			"promptPart.delivery": ["交付要求", "Delivery requirements"],
			"promptPart.legacy": ["早期版本的完整配置（载入后是内置文本加它的技能）", "A complete configuration of an earlier version (loading it gives the built-in text and its skills)"],
			"promptPart.runtime/shared": ["共享约定", "Shared rules"],
			"promptPart.runtime/orchestrator": ["主 Session 角色", "Main Session role"],
			"promptPart.runtime/worker": ["执行器角色", "Executor role"],
			"promptPart.runtime/subscriptions": ["订阅", "Subscriptions"],
			"promptPart.runtime/replies": ["回复与确认", "Replies and acknowledgements"],
			"promptPart.runtime/dispatch": ["路由", "Routing"],
			"promptPart.runtime/work": ["执行", "Execution"],
			promptViews: ["查看方式", "View"],
			promptBody: ["Markdown 正文", "Markdown"],
			promptResetSection: ["恢复此段默认内容", "Restore this section default"],
			promptPreviewTarget: ["预览目标", "Preview target"],
			promptPreviewDraft: ["未保存草稿", "unsaved draft"],
			promptPreviewSaved: ["版本 {revision}", "version {revision}"],
			promptEditSource: ["编辑此段", "Edit section"],
			promptHistoryHint: ["载入会替换整套草稿：三个团队段落和团队技能；保存后才生效。", "Loading replaces the whole draft: the three team sections and the team skills; nothing changes until you save."],
			promptHistoryItem: ["版本 {revision} · {time} · {source}", "Version {revision} · {time} · {source}"],
			promptHistoryInitial: ["初始版本", "initial"],
			promptHistoryChanged: ["修改段：{parts}", "Changed: {parts}"],
			promptHistoryNone: ["初始版本或无内容变化", "Initial version or no content change"],
			promptOlder: ["更早版本", "Older versions"],
			promptRestore: ["将这个版本载入草稿", "Load this version into the draft"],
			promptDefaults: ["将整套默认内容载入草稿", "Load all defaults into the draft"],
			promptDraftFromHistory: ["整套草稿来自历史版本 {revision}；保存将创建新版本", "Draft loaded from version {revision}; saving creates a new version"],
			promptDraftFromDefaults: ["整套草稿来自当前插件默认值", "Draft loaded from the current plugin defaults"],
			promptDraftSectionReset: ["已恢复此段默认内容：{part}", "Restored the default of: {part}"],
			promptAddSkill: ["添加自定义技能", "Add a custom skill"],
			promptSkillName: ["名称，例如 testing", "Name, e.g. testing"],
			promptAddSkillAction: ["添加到草稿", "Add to draft"],
			promptSkillNameInvalid: ["技能名称须唯一，仅使用小写字母、数字和连字符，以字母开头。", "Skill names must be unique, start with a letter, and use lowercase letters, digits and hyphens."],
			promptConflict: ["提示词已被修改到版本 {revision}。已保留你的草稿；请比较后重新保存。", "Prompts changed to version {revision}. Your draft is kept; compare and save again."],
			promptConflictParts: ["提示词已被修改到版本 {revision}，其中 {parts} 你也改过；保存会以你的版本为准。", "Prompts changed to version {revision}, including {parts}, which you changed too; saving keeps your version."],
			promptSavedPending: ["已保存；通知等待注入主 Session。", "Saved; the notice is waiting to reach the main Session."],
			promptSessions: ["Session 最近使用的版本", "Versions used by Sessions"],
			promptSessionItem: ["{session}：版本 {revision}", "{session}: version {revision}"],
			promptNoSessions: ["暂无模型请求", "No model requests yet"],
			"promptRole.orchestrator": ["主 Session", "Main Session"],
			"promptRole.worker": ["执行器 Session", "Executor Session"],
			deploymentIntro: ["这台机器上的 dsh-superagent 设置，存放在 DSH 配置文件的 dsh-superagent 条目里；保存后立即生效，不会重启 dsh-superagent。", "dsh-superagent's settings on this machine, kept in the dsh-superagent entry of the DSH configuration; a saved change applies at once, without restarting dsh-superagent."],
			deploymentUnavailable: ["dsh-superagent 启动完成后才能修改这些值。", "These values can be changed once dsh-superagent has started."],
			deploymentDerived: ["仓库与账号", "Repository and accounts"],
			deploymentDerivedHint: ["由来源设置里的仓库和 CLI 得出。", "Derived from the repository and the CLIs in the Source settings."],
			deploymentRepository: ["仓库", "Repository"],
			deploymentAgent: ["智能体账号", "Agent account"],
			deploymentFeishu: ["飞书机器人", "Feishu bot"],
			deploymentFeishuNone: ["未设置", "Not set"],
			deploymentAccountsWhere: ["账号在 dsh-superagent 面板的来源设置里修改。", "Accounts are changed in the Source settings of the dsh-superagent panel."],
			deploymentMachine: ["本机设置", "This machine"],
			deploymentStateDir: ["状态目录", "State directory"],
			deploymentStateDirHint: ["数据库、锁、执行器的命令和智能体的 git 配置所在目录，只能在 DSH 配置文件里修改。", "Holds the database, locks, the Executor's commands and the agent's git configuration; change it only in the DSH configuration file."],
			deploymentLimits: ["上限", "Limits"],
			deploymentLimitsHint: ["本机资源的上限：保存的提示词最长多少字，评估读取线程上下文时最多读几页、每次读取最多等多久。", "Resource limits on this machine: how long a saved prompt may be, and how many Thread pages Eval may read and how long one read may take."],
			deploymentPromptMaxChars: ["提示词配置的最大字符数", "Largest prompt configuration / characters"],
			deploymentContextPages: ["一次研判可读的线程页数", "Thread pages one Assessment may read"],
			deploymentContextTimeout: ["一次上下文读取的时限 / 毫秒", "Time limit of one context read / ms"],
			deploymentRefused: ["DSH 拒绝了这次修改：设置可能已在别处修改。放弃修改后可看到当前值。", "DSH refused the change; the settings may have changed elsewhere. Discard to see the current values."],
			deploymentNoForms: ["这个 DSH 版本不提供配置表单，这些值只能在 DSH 配置文件的 dsh-superagent 条目里修改。", "This DSH version has no configuration forms; change these values in the dsh-superagent entry of the DSH configuration file."],
			deploymentReadOnly: ["只有本机上的浏览器可以修改这些值。", "Only a browser on this machine can change these values."],
			setupCheck: ["重新检查", "Check again"],
			setupChecking: ["正在重新检查，dsh-superagent 正在重启", "Checking again; dsh-superagent is restarting"],
			setupCheckInterrupts: ["重新检查会重启 dsh-superagent：{count} 个进行中的派工会中断，并带恢复说明重新开始。", "Checking again restarts dsh-superagent: {count} running Assignments stop and start again with a recovery note."],
			"reason.not_human": ["自动消息", "Automated message"],
			"reason.not_a_member": ["发送者不在这个来源的名单里", "Sender is not on this Source's list"],
			"reason.no_mention": ["没有点名智能体，且这个来源不接收其余消息", "Does not address the agent, and this Source does not receive the rest"],
			"reason.admission_ignored": ["准入设为忽略", "Admission set to ignore"],
			"reason.chat_not_allowed": ["群不在监听的群里", "Chat is not a listened chat"],
			"reason.direct_messages_not_allowed": ["私聊未开放", "Direct messages are off"],
			"reason.momo_stream_disabled": ["该 MoMo 信号流未开启", "This MoMo stream is off"],
			"reason.observation_only": ["仅观察的群（旧版过滤）", "Observe-only chat (legacy filter)"],
			"reason.untracked_source": ["线程未被订阅", "Thread not subscribed"],
			"reason.issue_assigned": ["Issue 已有负责人", "Issue has an assignee"],
			"reason.issue_closed": ["Issue 已关闭", "Issue is closed"],
			"reason.issue_has_pull_request": ["Issue 已有关联 PR", "Issue has a linked PR"],
			"reason.issue_unclaimed_less_than_day": ["Issue 无人认领未满一天", "Issue unclaimed for less than a day"],
			"reason.task_ended": ["工单已结束", "Ticket ended"],
			"reason.task_paused": ["工单已暂停", "Ticket paused"],
			"reason.subscription_inactive": ["订阅未生效", "Subscription inactive"],
			"reason.subscription_removed": ["订阅已移除", "Subscription removed"],
			"reason.issue_awaiting_eligibility": ["等待 Issue 满足资格", "Waiting for Issue eligibility"],
			"reason.timeout": ["评估超时未决定", "Eval timed out"],
			"reason.policyChanged": ["评估期间策略已变更", "Policy changed during the Eval"],
			"reason.noAdmissible": ["没有可准入的触发", "No admissible Trigger"],
			"reason.startedTicket": ["已经开过工单 {ticket}", "Already started Ticket {ticket}"],
			"reason.acceptedBefore": ["触发 {trigger} 之前已接单", "Trigger {trigger} was accepted before"],
			"reason.routed": ["已转给工单 {ticket}", "Routed to Ticket {ticket}"],
			"reason.stopUnknown": ["要停止的工单不存在或已结束", "The Ticket to stop is unknown or ended"],
			"reason.stopNotExplicit": ["停止需要名单里的人明确要求", "Stopping needs an explicit request from someone on the list"],
			"reason.directionUnsettled": ["实现意图或目标未确定，或还要产品或设计决定", "Intent or target not settled, or a product or design decision is still open"],
			"reason.noRuleMatched": ["没有启用的准入规则匹配", "No enabled admission rule matched"],
			"reason.ignoredFromCard": ["仅凭候选卡片忽略，未经规则研判", "Ignored from its card, without a rule assessment"],
			"reason.observed": ["观察模式：本会接单（{text}）", "Observe mode: would accept ({text})"],
			"reason.explicitRouted": ["名单里的人明确请求，由主 Session 接单", "Explicit request from someone on the list, accepted by the main Session"],
			"reason.legacyImport": ["从旧版工单记录导入", "Imported from a legacy Ticket record"],
			"reason.channelGone": ["对话已无法接收消息", "The conversation can no longer receive messages"],
			"reason.channelIgnored": ["来源已不再监听这个对话", "The Source no longer listens to this conversation"],
			"reason.hostRestarted": ["dsh-superagent 重启", "dsh-superagent restarted"],
			"reason.retried": ["人工重试", "Retried by a person"],
			"reason.completed": ["已完成", "Completed"],
			"reason.dropped": ["无需处理，已关闭", "No action needed; closed"],
			"reason.merged": ["PR 已合并", "PR merged"],
			"reason.closed": ["PR 已关闭", "PR closed"],
			"reason.stopped": ["人工停止", "Stopped by a human"],
			"reason.revoked": ["授权已失效", "Mandate no longer valid"],
			"reason.humanStop": ["有人要求停止", "Someone asked to stop"],
			"reason.forwarded": ["已扇出给该线程的工单", "Fanned out to the Thread's Ticket"],
			"reason.senderNotMember": ["发送者不在这个来源的名单里", "Sender is not on this Source's list"],
			"reason.source_disabled": ["来源已停用", "Source disabled"],
			"reason.issue_sender_or_admission_disabled": ["Issue 发起人不在名单或主动接单已关闭", "Issue sender not on the list, or proactive accept off"],
			"reason.source_not_installed": ["来源插件未加载", "Source plugin not loaded"],
			"reason.issue_unclaimed_less_than_wait": ["Issue 无人认领未满等待时长", "Issue unclaimed for less than the wait"],
			glossary: ["术语表", "Glossary"],
			glossaryIntro: ["界面只显示一种语言；文档、代码和工具使用英文术语。", "The interface shows one language; documents, code and tools use the English terms."],
			glossaryChinese: ["中文", "中文"],
			glossaryEnglish: ["English", "English"],
			glossaryMeaning: ["含义", "Meaning"],
			"term.source": ["来源", "Source"],
			"term.trigger": ["触发", "Trigger"],
			"term.thread": ["线程", "Thread"],
			"term.correlation": ["关联", "Correlation"],
			"term.channel": ["渠道", "Channel"],
			"term.policy": ["策略", "Policy"],
			"term.eval": ["评估", "Eval"],
			"term.gate": ["准入", "Gate"],
			"term.assessment": ["研判", "Assessment"],
			"term.decision": ["决定", "Decision"],
			"term.mandate": ["授权", "Mandate"],
			"term.ticket": ["工单", "Ticket"],
			"term.assignment": ["派工", "Assignment"],
			"term.subscription": ["订阅", "Subscription"],
			"term.fanout": ["扇出", "Fan-out"],
			"term.executor": ["执行器", "Executor"],
			"term.report": ["报告", "Report"],
			"term.attention": ["待人工决定", "Attention"],
			"term.disposition": ["去向", "Disposition"],
			"term.input": ["输入", "Input"],
			"term.scope": ["范围", "Scope"],
			"term.strength": ["强度", "Strength"],
			"term.agent": ["智能体", "Agent"],
			"term.mainSession": ["主 Session", "Main Session"],
			"term.executorSession": ["执行器 Session", "Executor Session"],
			"term.policyVersion": ["策略版本", "Policy version"],
			"meaning.agent": ["以 dsh-superagent 身份工作的虚拟同事：通过 GitHub 账号、飞书机器人等身份在来源上行动", "The virtual colleague dsh-superagent runs: it acts on the Sources through its identities, such as a GitHub account or a Feishu bot"],
			"meaning.mainSession": ["评估触发、接单派工并回复的 DSH Session；提示词里称 orchestrator", "The DSH Session that evaluates Triggers, accepts and dispatches work, and replies; prompts call it the orchestrator"],
			"meaning.executorSession": ["执行器为一个工单运行的 DSH Session；提示词里称 worker", "The DSH Session the Executor runs for one Ticket; prompts call it the worker"],
			"meaning.policyVersion": ["接单规则、各来源上的策略和接单模式的一个组合的标识；每个工单记下接单时的版本", "The identifier of one combination of rules, the Policy on each Source and accept mode; each Ticket records the version it was accepted under"],
			"glossaryGroup.roles": ["角色", "Roles"],
			"meaning.source": ["产生触发的事件流；由插件提供的类型加一份配置（是否运行、监听什么）", "An event stream that produces Triggers; a plugin-provided kind plus one configuration (whether it runs, what it listens to)"],
			"meaning.trigger": ["来源产生的单个不可变事件", "One immutable event produced by a Source"],
			"meaning.thread": ["按时间排列的触发；同一时间只有一个评估", "Triggers in time order; one Eval at a time"],
			"meaning.correlation": ["一个触发同属多个线程时线程之间的关系，只用来补充上下文", "Relation between Threads that share a Trigger; context only"],
			"meaning.channel": ["线程的只写端，用于回复", "The write-only side of a Thread, for replies"],
			"meaning.policy": ["版本化的接单规则和各来源上的名单；决定谁能发起工作、接什么", "Versioned rules and each Source's list; decides who may originate work and what is accepted"],
			"meaning.eval": ["对一批触发做出决定的过程", "The process that turns a batch of Triggers into a Decision"],
			"meaning.gate": ["评估的第一层：谁能发起工作、强度多少", "First Eval layer: who may originate work, and how strongly"],
			"meaning.assessment": ["评估中的模型语义判断", "Eval step where the model judges meaning"],
			"meaning.decision": ["评估的结果", "The result of an Eval"],
			"meaning.mandate": ["接单时产出的授权：强度、范围、依据的策略版本", "Authorization produced by accept: strength, scope and Policy version"],
			"meaning.ticket": ["被授权的工作单位", "An authorized unit of work"],
			"meaning.assignment": ["工单与一个执行器 Session 的绑定", "Binding of a Ticket to one Executor Session"],
			"meaning.subscription": ["工单与线程的关系；主 Session 只在消息明确指向某个工单时才把线程关联给它，执行器可以退订与本工单无关的线程", "Relation between a Ticket and a Thread; the main Session attaches a Thread only when its message points at the Ticket, and the Executor can drop a Thread unrelated to its Ticket"],
			"meaning.fanout": ["订阅线程上的触发作为上下文送达工单，不带授权", "Triggers on a subscribed Thread reach the Ticket as context, without authority"],
			"meaning.executor": ["执行派工的一方：每个工单一个执行器 Session 和执行目录", "What runs Assignments: one Executor Session and directory per Ticket"],
			"meaning.report": ["派工向工单回报的状态", "State an Assignment reports to its Ticket"],
			"meaning.attention": ["工单上等待人回答的问题", "A question on a Ticket waiting for a human"],
			"meaning.disposition": ["一个触发被过滤、评估、扇出的记录", "Where a Trigger went: filtered, evaluated, fanned out"],
			"meaning.input": ["送达工单的上下文（扇出的触发、策略变更、恢复、文本）", "Context delivered to a Ticket (fanned-out Triggers, Policy changes, resumes, text)"],
			"meaning.scope": ["授权允许的工作范围", "The work a Mandate allows"],
			"meaning.strength": ["授权与评估的依据强度", "How strong the grounds of a Mandate or Eval are"],
			legendTitle: ["状态颜色", "Status colors"],
			"legend.done": ["完成、就绪或已接单", "Done, ready or accepted"],
			"legend.ongoing": ["执行中或评估中", "Running or evaluating"],
			"legend.warning": ["等待、受阻或需要人", "Waiting, blocked or needs a person"],
			"legend.error": ["失败或异常", "Failed or failing"],
			"legend.idle": ["已结束、已停用或无后续", "Ended, disabled or no follow-up"],
			"term.environment": ["执行环境", "Execution environment"],
			"meaning.environment": ["每个工单的执行器 Session 和准备命令运行的环境：执行器和各来源登记的变量，每个有键、值和说明", "Where a Ticket's Executor Session and prepare command run: the variables the Executor and the Sources register, each with a key, a value and a description"],
			"userError.unknownTicket": ["找不到这个工单。", USER_ERRORS.unknownTicket[1]],
			"userError.unknownProblem": ["找不到这个未完成的评估。", USER_ERRORS.unknownProblem[1]],
			"userError.unknownTrigger": ["找不到这个触发。", USER_ERRORS.unknownTrigger[1]],
			"userError.unknownAssignment": ["找不到这个派工。", USER_ERRORS.unknownAssignment[1]],
			"userError.unknownBlock": ["没有这个设置块：{block}", USER_ERRORS.unknownBlock[1]],
			"userError.unknownPromptRevision": ["没有提示词版本 {revision}。", USER_ERRORS.unknownPromptRevision[1]],
			"userError.unknownPromptPart": ["没有内置提示词段落 {part}。", USER_ERRORS.unknownPromptPart[1]],
			"userError.ticketEnded": ["工单已结束。", USER_ERRORS.ticketEnded[1]],
			"userError.assignmentEnded": ["这个派工已结束，工单已由较新的派工接手。", USER_ERRORS.assignmentEnded[1]],
			"userError.evalFinished": ["评估 {eval} 已结束，或已被之后的评估取代；请对这个触发当前的评估做决定。", USER_ERRORS.evalFinished[1]],
			"userError.notAdmissible": ["这个触发未通过准入：{reason}", USER_ERRORS.notAdmissible[1]],
			"userError.notExplicit": ["通过 orchestrator_route 接单只用于名单内发送者的明确请求；主动接单的候选请用 orchestrator_eval 和 orchestrator_eval_decide 研判。", USER_ERRORS.notExplicit[1]],
			"userError.ticketStopped": ["有人停止了这个工单；新工作需要通过 orchestrator_route 接单。", USER_ERRORS.ticketStopped[1]],
			"userError.mandateRevoked": ["按当前策略，这个工单的授权已失效；新工作需要通过 orchestrator_route 接单。", USER_ERRORS.mandateRevoked[1]],
			"userError.notRetryable": ["只有进行中的工单可以重试，而且仅当执行器最近一次报告为失败或受阻且此后没有人发过消息，或者向执行器送达输入失败时才可以。", USER_ERRORS.notRetryable[1]],
			"userError.sourceThread": ["这是工单开始时所在的线程，会保持订阅。", USER_ERRORS.sourceThread[1]],
			"userError.followedThread": ["这是工单自己的线程，例如它的 PR，会保持订阅。", USER_ERRORS.followedThread[1]],
			"userError.notFollowing": ["这个工单没有订阅那个线程。", USER_ERRORS.notFollowing[1]],
			"userError.questionWithResult": ["给人的问题不能同时是就绪的结果或回答，请分开报告。", USER_ERRORS.questionWithResult[1]],
			"userError.askerWithoutQuestion": ["提出问题的消息需要附上它提出的问题。", USER_ERRORS.askerWithoutQuestion[1]],
			"userError.notAsker": ["问题必须指明提出它的那条人发的消息，且那条消息已送达这个工单。", USER_ERRORS.notAsker[1]],
			"userError.notAnswerable": ["回答必须指明它所回答的、由人提出的问题，且这个问题已送达这个工单。", USER_ERRORS.notAnswerable[1]],
			"userError.ackEnded": ["工单已结束，不要确认过去的请求。", USER_ERRORS.ackEnded[1]],
			"userError.notReached": ["这个触发不属于这个执行器。", USER_ERRORS.notReached[1]],
			"userError.handedBack": ["这个工单已经交回过这个触发。", USER_ERRORS.handedBack[1]],
			"userError.handedBackHere": ["这个工单的执行器已把这个触发交回，认为它超出本工单的范围：请把它作为新工作接单、关联到另一个工单，或忽略它。", USER_ERRORS.handedBackHere[1]],
			"userError.workerDecides": ["这条消息已通过所在线程送达工单 {tickets}：由工单的执行器判断它是否属于这个工单，不属于的会被交回，之后作为候选到达。只有停止例外，用 orchestrator_route 并把 kind 设为 stop。", USER_ERRORS.workerDecides[1]],
			"userError.ackNoChannel": ["确认需要一条已派给这个执行器、由人发出的原始消息。", USER_ERRORS.ackNoChannel[1]],
			"userError.ackNotPerson": ["请使用最初那条人发的触发，而不是机器人、CI 或执行器的报告。", USER_ERRORS.ackNotPerson[1]],
			"userError.notReady": ["工单还不能交付。进展只在内部保留，等待经过验证的就绪报告；不要把进展当作回答，也不要通过其他渠道发送。", USER_ERRORS.notReady[1]],
			"userError.notAttention": ["待人工决定的消息需要在 human_action 中写明工单当前待人工决定的问题。日常未完成的工作只在内部保留。", USER_ERRORS.notAttention[1]],
			"userError.notQuestion": ["回答必须针对最初由人提出的问题，而不是执行器报告或自动触发。", USER_ERRORS.notQuestion[1]],
			"userError.noAnswer": ["执行器还没有回答这条人发的触发。请等待执行器的报告，或用 orchestrator_ticket_request_status 请求一份（它只对处于等待状态的执行器起作用）；普通进展不能当作回答。", USER_ERRORS.noAnswer[1]],
			"userError.noChannel": ["这个工单或触发没有可以回复的渠道。", USER_ERRORS.noChannel[1]],
			"userError.panelOnlyEnvironment": ["执行环境（执行目录、准备命令、禁止调用的命令）只能在管理页修改。", USER_ERRORS.panelOnlyEnvironment[1]],
			"userError.panelOnlyAccounts": ["部署检查读取的来源字段（例如账号 CLI）只能在管理页修改。", USER_ERRORS.panelOnlyAccounts[1]],
			"userError.setupComplete": ["部署检查已通过。", USER_ERRORS.setupComplete[1]],
			"userError.modelUnavailable": ["{block} 的模型不可用：{error}", USER_ERRORS.modelUnavailable[1]],
			"userError.promptTooLong": ["提示词配置超过 {limit} 个字符。", USER_ERRORS.promptTooLong[1]],
			"userError.promptPlaceholders": ["「{part}」的模板必须保留占位符 {placeholders}，由系统填入内容。", USER_ERRORS.promptPlaceholders[1]],
			"userError.promptPartEmpty": ["「{part}」段落不能为空；要沿用内置文本，请恢复此段默认内容。", USER_ERRORS.promptPartEmpty[1]],
			"userError.sourceNotInstalled": ["{source} 来源的插件没有安装。", USER_ERRORS.sourceNotInstalled[1]],
			"userError.noLabels": ["这个来源没有可以刷新的名称。", USER_ERRORS.noLabels[1]],
			"userError.nothingToSync": ["{source} 来源上的策略没有指定从哪里同步，或者这个来源已关闭或在等待部署检查。", USER_ERRORS.nothingToSync[1]],
			"setup.repositoryUnset": ["GitHub 来源没有设置监听的仓库。", SETUP_PROBLEMS.repositoryUnset[1]],
			"setup.foreignFile": ["{file} 不是 dsh-superagent 写入的文件；移走它，或换一个状态目录。", SETUP_PROBLEMS.foreignFile[1]],
			"setup.gitTooOld": ["git 没有读取 dsh-superagent 为 github.com 写的凭据配置；需要 git 2.32 或更新版本。", SETUP_PROBLEMS.gitTooOld[1]],
			"setup.environmentFailed": ["准备智能体的运行环境失败。", SETUP_PROBLEMS.environmentFailed[1]],
			"setup.agentCliUnset": ["没有设置智能体的 GitHub CLI。", SETUP_PROBLEMS.agentCliUnset[1]],
			"setup.agentCliMissing": ["找不到智能体的 GitHub CLI。", SETUP_PROBLEMS.agentCliMissing[1]],
			"setup.agentCliSignedOut": ["智能体的 GitHub CLI 读不到它的账号。", SETUP_PROBLEMS.agentCliSignedOut[1]],
			"setup.agentCliNoAccount": ["智能体的 GitHub CLI 没有报告 GitHub 账号。", SETUP_PROBLEMS.agentCliNoAccount[1]],
			"setup.repositoryUnreadable": ["@{account} 读不到 {repository}。", SETUP_PROBLEMS.repositoryUnreadable[1]],
			"setup.repositoryUnreported": ["智能体的 GitHub CLI 没有返回 {repository}。", SETUP_PROBLEMS.repositoryUnreported[1]],
			"setup.repositoryReadOnly": ["@{account} 没有 {repository} 的推送权限。", SETUP_PROBLEMS.repositoryReadOnly[1]],
			"setup.feishuCliFailed": ["机器人的 lark-cli 不可用。", SETUP_PROBLEMS.feishuCliFailed[1]],
			"setup.feishuNoApp": ["机器人的 lark-cli 的 auth status 没有报告应用。", SETUP_PROBLEMS.feishuNoApp[1]],
			"setup.feishuBotNotReady": ["应用 {app} 的机器人身份状态是 {status}；用 lark-cli 配置应用密钥。", SETUP_PROBLEMS.feishuBotNotReady[1]],
			"setup.feishuUserIdentity": ["机器人的 lark-cli 允许用户身份（strict mode 为 {mode}）；按 docs/006-deployment.md 给机器人一份 strict mode 为 bot 的单独配置。", SETUP_PROBLEMS.feishuUserIdentity[1]],
			"setup.feishuNoBot": ["飞书机器人接口没有返回机器人的 open_id。", SETUP_PROBLEMS.feishuNoBot[1]],
			"healthCode.setupPending": ["等待部署检查", HEALTH_TEXT.setupPending],
			"healthCode.sourceOff": ["已关闭", HEALTH_TEXT.sourceOff],
			"healthCode.feishuCliUnset": ["来源已打开，还没有设置机器人的 lark-cli", HEALTH_TEXT.feishuCliUnset],
			"healthCode.feishuBotMissing": ["等待飞书机器人", HEALTH_TEXT.feishuBotMissing],
			"healthCode.pollFailures": ["连续 {count} 次轮询失败，最近一次：{error}", HEALTH_TEXT.pollFailures]
		};
		const language = (index) => Object.fromEntries(Object.entries(TEXT).map(([key, pair]) => [key, pair[index]]));
		const zh = language(0);
		const en = language(1);
		/** Glossary terms grouped by stage flow after the acting roles; each key maps to `term.<key>` and `meaning.<key>`. */
		const GLOSSARY = {
			roles: [
				"agent",
				"mainSession",
				"executorSession"
			],
			source: ["source", "channel"],
			trigger: [
				"trigger",
				"thread",
				"correlation",
				"subscription",
				"fanout",
				"disposition"
			],
			eval: [
				"policy",
				"policyVersion",
				"eval",
				"gate",
				"assessment",
				"decision",
				"mandate",
				"scope",
				"strength"
			],
			execution: [
				"executor",
				"environment",
				"ticket",
				"assignment",
				"input",
				"report",
				"attention"
			]
		};
		const GLOSSARY_VALUES = {
			decision: [
				"decision.accept",
				"decision.reopen",
				"decision.stop",
				"decision.ignore",
				"decision.unavailable"
			],
			strength: ["strength.explicit", "strength.inferred"],
			ticket: [
				"stage.answer",
				"stage.review",
				"stage.blocked",
				"stage.failed",
				"stage.delivery",
				"stage.queued",
				"stage.working",
				"stage.idle",
				"ticket.ended"
			],
			assignment: [
				"assignment.pending",
				"assignment.running",
				"assignment.ended"
			],
			report: [
				"report.progress",
				"report.waiting",
				"report.ready",
				"report.blocked",
				"report.failed",
				"report.dropped"
			]
		};
		//#endregion
		//#region src/client/overview.tsx
		function ProblemLine({ problem, onChanged }) {
			const { t, call, navigate } = usePanel();
			const post = useAction((request) => request(), { reload: onChanged });
			const row = (title, detail, route, hint, actions) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("li", {
				className: "dt-row dt-link dt-att dt-att-error",
				children: /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-row-main",
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
							className: "dt-att-what",
							children: route ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
								type: "button",
								className: "dt-open dt-open-wrap",
								onClick: () => navigate(route),
								children: title
							}) : title
						}),
						detail,
						hint && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: hint }),
						actions && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
							className: "dt-row-meta dt-row-buttons",
							children: actions
						})
					]
				})
			});
			const go = (label, route) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
				variant: "outline",
				size: "sm",
				icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, {
					name: "settings",
					size: 14
				}),
				onClick: () => navigate(route),
				children: label
			});
			const raw = (text) => text && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
				className: "dt-error dt-clamp dt-mono",
				children: text
			});
			const worded = (text) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
				className: "dt-error",
				children: text
			});
			switch (problem.kind) {
				case "setup": return row(t(problem.place === "feishu" ? "problemSetupFeishu" : "problemSetup"), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
					className: "dt-error",
					children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SetupMessage, { problem })
				}), setupPage(problem.place), t(`problemSetupFix.${problem.place}`), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(CheckSetupButton, {}));
				case "no-source": return row(t("problemNoSource"), void 0, settingsRoute("source"), void 0, go(t("actionOpenSources"), settingsRoute("source")));
				case "no-allowed": return row(t("problemNoAllowed"), void 0, settingsRoute("eval"), void 0, go(t("actionAddAllowed"), settingsRoute("eval")));
				case "executor-paused": return row(t("problemPaused"), void 0, { page: "execution" }, void 0, /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ConfirmButton, {
					variant: "outline",
					icon: "play",
					label: t("resumeProcessing"),
					title: t("resumeProcessing"),
					message: t("resumeProcessingConfirm"),
					onConfirm: async () => {
						await call("POST executor/pause", { body: { paused: false } });
						await onChanged();
					}
				}));
				case "runtime-error": return row(t("problemRuntime", { name: valueLabel(t, "health", problem.name) }), raw(problem.detail), void 0);
				case "source-error": {
					const health = problem.source.health;
					return row(t("sourceError", { source: localized(t, problem.source.title) }), health.code ? worded(healthText(t, health)) : raw(health.detail), { page: "source" }, t("sourceErrorHint"));
				}
				case "eval-overdue": return row(t("problemEvalOverdue", { thread: readableMarkers(t, problem.thread.title) }), void 0, {
					page: "trigger",
					id: problem.thread.key
				});
				case "eval-unavailable": return row(t("problemEvalUnavailable", { thread: readableMarkers(t, problem.thread.title) }), raw(reasonLabel(t, problem.reason)), {
					page: "trigger",
					id: problem.thread.key,
					query: { trigger: problem.triggerId }
				}, void 0, /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
					variant: "outline",
					size: "sm",
					icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, {
						name: "refresh",
						size: 14
					}),
					disabled: post.busy,
					onClick: () => {
						post.run(() => call("POST triggers/:id/requeue", { id: problem.triggerId }));
					},
					children: t("requeue")
				}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
					variant: "outline",
					size: "sm",
					icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, {
						name: "dismiss",
						size: 14
					}),
					disabled: post.busy,
					onClick: () => {
						post.run(() => call("POST decisions/:id/dismiss", { id: problem.decisionId }));
					},
					children: t("dismiss")
				})] }));
				case "outgoing": return row(t("problemReply", {
					source: valueLabel(t, "source", problem.outgoing.channel.source),
					attempts: problem.outgoing.attempts
				}), raw(problem.outgoing.error), void 0);
			}
		}
		function OverviewPage() {
			const { t, call, navigate } = usePanel();
			const { setup } = usePanelData();
			const { data, error, reload } = usePoll(() => call("GET overview"), []);
			if (!data) return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LoadState, {
				error,
				loading: true
			});
			const stat = (label, value, route) => /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("span", {
				className: "dt-stat",
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
					className: "dt-stat-label",
					children: label
				}), route ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
					type: "button",
					className: "dt-textlink dt-stat-value",
					onClick: () => navigate(route),
					children: value
				}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
					className: "dt-stat-value",
					children: value
				})]
			});
			const more = (route) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
				type: "button",
				className: "dt-textlink dt-more-link",
				onClick: () => navigate(route),
				children: t("details")
			});
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [
				error && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LoadState, {
					error,
					loading: false
				}),
				/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Section, {
					title: t("pendingTickets"),
					count: data.person.length,
					children: data.person.length ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
						className: "dt-list dt-cards",
						children: data.person.map((ticket) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(TicketLine, {
							ticket,
							question: true,
							onChanged: reload
						}, ticket.id))
					}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("needsYouNone") })
				}),
				data.problems.length > 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Section, {
					title: t("problems"),
					count: data.problems.length,
					children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
						className: "dt-list dt-cards",
						children: data.problems.map((problem, index) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ProblemLine, {
							problem,
							onChanged: reload
						}, index))
					})
				}),
				/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Section, {
					title: t("lastDay"),
					action: more({
						page: "trigger",
						query: { filter: "recent" }
					}),
					children: /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
						className: "dt-stats",
						children: [
							stat(t("flowReceivedLabel"), data.flow.received),
							stat(t("flowFilteredLabel"), data.flow.filtered, data.flow.filtered ? { page: "source" } : void 0),
							stat(t("flowJudgedLabel"), data.flow.judged),
							stat(t("flowAcceptedLabel"), data.flow.accepted, {
								page: "eval",
								query: { window: "24h" }
							}),
							data.flow.dropped > 0 && stat(t("flowDroppedLabel"), data.flow.dropped, { page: "source" })
						]
					})
				}),
				/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Section, {
					title: t("term.executor"),
					action: more({ page: "execution" }),
					children: setup?.problem ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("executorWaitingSetup") }) : /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
						className: "dt-stats",
						children: [
							stat(t("executingLabel"), `${data.executor.running} / ${data.executor.maxWorkers}`),
							stat(t("queuedLabel"), data.executor.queued),
							stat(t("idleLabel"), data.executor.idle)
						]
					})
				})
			] });
		}
		//#endregion
		//#region src/client/deployment.tsx
		/**
		* Deployment settings view shared between the panel Settings tab and the DSH Plugin Manager config page.
		* Edits host-level plugin configuration limits through DSH `ConfigForm` when writable.
		*/
		const MACHINE_LIMITS = [
			"promptMaxChars",
			"admissionContextMaxPages",
			"admissionContextTimeoutMs"
		];
		const text = (value) => typeof value === "string" || typeof value === "number" ? String(value) : "";
		const limitsOf = (values) => Object.fromEntries(MACHINE_LIMITS.map((key) => [key, text(values?.[key])]));
		function usePageForm(form) {
			const subscribe = (0, react.useCallback)((listener) => form ? form.subscribe(listener) : () => {}, [form]);
			const state = (0, react.useSyncExternalStore)(subscribe, () => form?.getSnapshot());
			return (0, react.useMemo)(() => form && state ? {
				state,
				mutate: form.mutate.bind(form)
			} : void 0, [form, state]);
		}
		/** Deployment configuration form; falls back to read-only display when DSH config forms are unavailable or read-only. */
		function DeploymentPage({ setup, form, accounts: showAccounts }) {
			const { t, notify } = usePanel();
			const snapshot = form?.state;
			const editable = snapshot?.status === "ready" && snapshot.writable;
			const draft = useDraft({
				saved: limitsOf(editable ? snapshot.value : setup.machine),
				revision: editable ? snapshot.revision : void 0,
				reload: async () => {},
				save: async (value, revision, base) => {
					const ops = MACHINE_LIMITS.filter((key) => value[key].trim() !== base[key].trim()).map((key) => value[key].trim() ? {
						op: "set",
						path: [key],
						value: Number(value[key])
					} : {
						op: "unset",
						path: [key]
					});
					if (!form || !await form.mutate(ops, revision)) throw new Error(t("deploymentRefused"));
					notify(t("saved"));
					return {
						revision: revision + 1,
						restarting: false
					};
				}
			});
			const accounts = setup.accounts;
			const readOnlyHint = !form ? t("deploymentNoForms") : snapshot?.mode === "memory" ? t("deploymentReadOnly") : snapshot?.status === "loading" ? t("loading") : snapshot?.status === "unavailable" ? t("deploymentUnavailable") : !editable ? t("deploymentReadOnly") : void 0;
			const limit = (key, label) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Field, {
				label,
				children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Input, {
					type: "number",
					min: LIMITS[key].min,
					max: LIMITS[key].max,
					step: 1,
					value: draft.value[key],
					disabled: !editable,
					onChange: (event) => draft.edit({
						...draft.value,
						[key]: event.target.value
					})
				})
			});
			const feishu = accounts?.feishu ? accounts.feishu.name || accounts.feishu.botId : setup.feishuProblem ? setupText(t, setup.feishuProblem) : t("deploymentFeishuNone");
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("form", {
				className: "dt-form",
				onSubmit: (event) => {
					draft.submit(event);
				},
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)(Fields, {
					disabled: draft.busy,
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("deploymentIntro") }),
						setup.problem && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
							className: "dt-row-buttons",
							children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
								className: "dt-error",
								role: "status",
								children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SetupMessage, {
									problem: setup.problem,
									lead: true
								})
							}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(CheckSetupButton, {})]
						}),
						showAccounts && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(Section, {
							title: t("deploymentDerived"),
							hint: t("deploymentDerivedHint"),
							children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(KeyValues, { rows: [
								[t("deploymentRepository"), accounts?.repository ?? "—"],
								[t("deploymentAgent"), accounts ? `@${accounts.agent}` : "—"],
								[t("deploymentFeishu"), feishu]
							] }), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("deploymentAccountsWhere") })]
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsxs)(Section, {
							title: t("deploymentMachine"),
							children: [readOnlyHint && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: readOnlyHint }), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
								className: "dt-field",
								children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("span", {
									className: "dt-field-head",
									children: [t("deploymentStateDir"), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(InfoTip, { text: t("deploymentStateDirHint") })]
								}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
									className: "dt-mono",
									children: setup.machine.stateDir
								})]
							})]
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsxs)(Section, {
							title: t("deploymentLimits"),
							hint: t("deploymentLimitsHint"),
							children: [
								limit("promptMaxChars", t("deploymentPromptMaxChars")),
								limit("admissionContextMaxPages", t("deploymentContextPages")),
								limit("admissionContextTimeoutMs", t("deploymentContextTimeout"))
							]
						})
					]
				}), editable && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SaveBar, {
					...draft,
					onDiscard: draft.discard
				})]
			});
		}
		/** Plugin Manager config page; includes derived repository and accounts because Source settings live in the main panel. */
		function PluginPage({ form }) {
			const { t } = usePanel();
			const { state, error } = usePanelData();
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
				className: "dt-embedded",
				children: state ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(DeploymentPage, {
					setup: state.setup,
					form,
					accounts: true
				}) : error ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
					className: "dt-error",
					role: "alert",
					children: error.message
				}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
					className: "dt-hint",
					children: t("loading")
				})
			});
		}
		/** DSH Plugin Manager config view entry; renders nothing in `summary` mode because DSH displays the package description. */
		function PluginConfig({ t, view, form }) {
			return view === "page" ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(PanelProvider, {
				t,
				interval: 1e4,
				children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(PluginPage, { form })
			}) : null;
		}
		//#endregion
		//#region src/client/prompt-config.ts
		const isSkill = (name) => name.startsWith("skill/");
		/** A built-in part, which the editor names `part/<key>`, apart from the team skills (`skill/<name>`). */
		const isPart = (name) => name.startsWith("part/");
		const partKey = (name) => name.slice(5);
		const sections = (config) => [
			...Object.keys(config).filter((name) => name !== "skills" && name !== "overrides"),
			...Object.keys(config.skills).map((name) => `skill/${name}`),
			...Object.keys(config.overrides ?? {}).map((key) => `part/${key}`)
		];
		/** Returns a team section or team skill's text, a built-in part's override, or `undefined` for one the team did not write. */
		const sectionText = (config, name) => isPart(name) ? config.overrides?.[partKey(name)]?.text : isSkill(name) ? config.skills[name.slice(6)] : name !== "skills" && name !== "overrides" && Object.hasOwn(config, name) ? config[name] : void 0;
		/**
		* A configuration with its overrides, none as an empty map, as the editor keeps it: a draft and the version it moves onto then
		* merge override by override, as a host stores no overrides as none. With `parts`, only the overrides of those parts stay, as
		* a version loaded from the history may override a part this version no longer has.
		*/
		const withOverrides = (config, parts) => ({
			...config,
			overrides: Object.fromEntries(Object.entries(config.overrides ?? {}).filter(([key]) => !parts || parts.some((part) => part.key === key)))
		});
		/** The text a built-in part reads with: the team's override, else its built-in text. */
		const partText = (config, part) => config.overrides?.[part.key]?.text ?? part.text;
		/**
		* Override a built-in part with `text`: an override keeps the built-in text it was edited from, the current one when new or
		* when `rebase`, and goes when its text is the built-in text again.
		*/
		function withOverride(config, part, text, rebase = false) {
			const { [part.key]: previous, ...others } = config.overrides ?? {};
			const base = rebase ? part.base : previous?.base ?? part.base;
			return {
				...config,
				overrides: text === void 0 || text === part.text ? others : {
					...others,
					[part.key]: {
						text,
						base
					}
				}
			};
		}
		function withSection(config, name, text) {
			return isSkill(name) ? {
				...config,
				skills: {
					...config.skills,
					[name.slice(6)]: text
				}
			} : {
				...config,
				[name]: text
			};
		}
		function withoutSkill(config, name) {
			const { [name.slice(6)]: _removed, ...skills } = config.skills;
			return {
				...config,
				skills
			};
		}
		/** The sections, skills and overrides of a draft that differ from the saved version; an override re-based counts too. */
		const changedSections = (config, saved) => [.../* @__PURE__ */ new Set([...sections(config), ...sections(saved)])].filter((name) => isPart(name) ? JSON.stringify(config.overrides?.[partKey(name)]) !== JSON.stringify(saved.overrides?.[partKey(name)]) : sectionText(config, name) !== sectionText(saved, name));
		const sectionLabel = (t, view, name) => isPart(name) ? valueLabel(t, "promptPart", partKey(name)) : isSkill(name) ? `${view.skillPrefix}${name.slice(6)}` : valueLabel(t, "promptPart", name);
		const skillNameFree = (name, config, view) => new RegExp(view.skillName).test(name) && !Object.hasOwn(config.skills, name) && !view.builtin.includes(name);
		/** Formats a team prompt part with its heading (omitted for skills, which have no heading). */
		const partWith = (part, base) => part.heading === void 0 ? base : `${part.heading}\n${base}`;
		/** Compute a line diff, folding runs of more than four unchanged lines to their boundary lines and a count. */
		function lineDiff(before, after) {
			const a = before.split("\n"), b = after.split("\n");
			const lcs = Array.from({ length: a.length + 1 }, () => new Array(b.length + 1).fill(0));
			for (let i = a.length - 1; i >= 0; i--) for (let j = b.length - 1; j >= 0; j--) lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
			const lines = [];
			for (let i = 0, j = 0; i < a.length || j < b.length;) if (i < a.length && j < b.length && a[i] === b[j]) {
				lines.push({
					kind: "same",
					text: a[i]
				});
				i++;
				j++;
			} else if (j < b.length && (i === a.length || lcs[i][j + 1] >= lcs[i + 1][j])) lines.push({
				kind: "ins",
				text: b[j++]
			});
			else lines.push({
				kind: "del",
				text: a[i++]
			});
			const folded = [];
			for (let k = 0; k < lines.length;) {
				let end = k;
				while (end < lines.length && lines[end].kind === "same") end++;
				if (end - k > 4) folded.push(lines[k], {
					kind: "fold",
					count: end - k - 2
				}, lines[end - 1]);
				else folded.push(...lines.slice(k, Math.max(end, k + 1)));
				k = Math.max(end, k + 1);
			}
			return folded;
		}
		//#endregion
		//#region src/client/prompts.tsx
		/** Prompts settings group: section/skill editor, full composed prompt preview with diffing, and revision history. */
		const originText = (t, view, from) => from === void 0 ? void 0 : from === "defaults" ? t("promptDraftFromDefaults") : "revision" in from ? t("promptDraftFromHistory", { revision: from.revision }) : t("promptDraftSectionReset", { part: sectionLabel(t, view, from.reset) });
		function PromptsPage() {
			const { call } = usePanel();
			const [view, setView] = (0, react.useState)();
			const [error, setError] = (0, react.useState)();
			const reload = (0, react.useCallback)(async () => {
				setView(await call("GET prompts"));
			}, [call]);
			(0, react.useEffect)(() => {
				reload().catch(setError);
			}, [reload]);
			return view ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(PromptsEditor, {
				view,
				reload
			}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LoadState, {
				loading: true,
				error
			});
		}
		function PromptsEditor({ view, reload }) {
			const { t, call, notify } = usePanel();
			const saved = withOverrides(view.current.config);
			const draft = useDraft({
				key: `dsh-superagent/prompts/${view.masterId}`,
				saved,
				revision: view.revision,
				reload,
				save: async (config, baseRevision) => {
					const result = await call("PUT prompts", { body: {
						config,
						baseRevision
					} });
					notify(t(result.context_delivery === "pending" ? "promptSavedPending" : "saved"));
					return result;
				}
			});
			const config = draft.value;
			const [tab, setTab] = (0, react.useState)("edit");
			const [selection, select] = (0, react.useState)(draft.meta?.selection ?? "communication");
			const selected = (isPart(selection) ? view.parts.some((part) => part.key === partKey(selection)) : sectionText(config, selection) !== void 0) ? selection : "communication";
			const changed = changedSections(config, saved);
			const edit = (next, note = {}) => draft.edit(next, {
				from: note.from ?? draft.meta?.from,
				selection: note.selection ?? selected
			});
			const open = (name) => {
				select(name);
				setTab("edit");
			};
			const words = {
				merged: (revision) => t("promptConflict", { revision }),
				conflict: (revision, paths) => t("promptConflictParts", {
					revision,
					parts: paths.map(([name, item]) => sectionLabel(t, view, item === void 0 ? name : name === "skills" ? `skill/${item}` : name === "overrides" ? `part/${item}` : name)).join(t("listSeparator"))
				}),
				editing: [
					t("promptsDraftVersion", { revision: draft.revision }),
					t("promptChanges", { count: changed.length }),
					originText(t, view, draft.meta?.from)
				].filter(Boolean).join(" · ")
			};
			const tabs = [
				{
					value: "edit",
					label: t("promptViewEdit")
				},
				{
					value: "full",
					label: t("promptViewFull")
				},
				{
					value: "history",
					label: t("promptViewHistory")
				}
			];
			const removed = view.defaultChanged.filter((item) => item.removed).map((item) => item.part);
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-form",
				children: [
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
						className: "dt-subtabs",
						role: "tablist",
						"aria-label": t("promptViews"),
						children: tabs.map((item) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
							type: "button",
							role: "tab",
							className: "dt-subtab",
							"aria-selected": tab === item.value,
							onClick: () => setTab(item.value),
							children: item.label
						}, item.value))
					}),
					removed.length > 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("promptRemovedParts", { parts: removed.join(t("listSeparator")) }) }),
					tab === "edit" && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(PromptSections, {
						config,
						view,
						changed,
						selected,
						onSelect: select,
						onEdit: edit
					}),
					tab === "full" && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(FullPrompt, {
						config,
						view,
						dirty: draft.dirty,
						revision: draft.revision,
						onEdit: open
					}),
					tab === "history" && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(PromptHistory, {
						view,
						from: draft.meta?.from,
						onLoad: (next, from) => edit(withOverrides(next, view.parts), { from })
					}, view.revision),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(SaveBar, {
						...draft,
						words,
						onSave: () => {
							draft.submit();
						},
						onDiscard: () => {
							draft.discard();
							reload().catch((failure) => notify(errorText(failure)));
						}
					})
				]
			});
		}
		function PromptSections({ config, view, changed, selected, onSelect, onEdit }) {
			const { t } = usePanel();
			const [name, setName] = (0, react.useState)("");
			const [invalid, setInvalid] = (0, react.useState)(false);
			const item = (section, children) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
				type: "button",
				className: "dt-nav-item",
				"aria-current": section === selected ? "true" : void 0,
				onClick: () => onSelect(section),
				children
			}, section);
			const unsaved = (section) => changed.includes(section) && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
				className: "dt-changed-dot",
				"aria-label": t("unsaved")
			});
			const add = (event) => {
				event.preventDefault();
				if (!skillNameFree(name.trim(), config, view)) {
					setInvalid(true);
					return;
				}
				const section = `skill/${name.trim()}`;
				setName("");
				onEdit(withSection(config, section, ""), { selection: section });
				onSelect(section);
			};
			const part = isPart(selected) ? view.parts.find((item) => item.key === partKey(selected)) : void 0;
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-prompt",
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("nav", {
					className: "dt-prompt-nav",
					"aria-label": t("promptSections"),
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
							className: "dt-nav-group",
							children: t("promptTeamGroup")
						}),
						view.sections.map((section) => item(section, /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("span", { children: [
							sectionLabel(t, view, section),
							config[section] !== view.defaults[section] && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
								className: "dt-changed-tag",
								children: t("promptChanged")
							}),
							unsaved(section)
						] }), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("small", { children: t(`promptPartHint.${section}`) })] }))),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
							className: "dt-nav-group",
							children: t("promptBuiltInGroup")
						}),
						view.parts.map((entry) => item(`part/${entry.key}`, /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("span", { children: [
							sectionLabel(t, view, `part/${entry.key}`),
							config.overrides?.[entry.key] && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
								className: "dt-changed-tag",
								children: t("promptChanged")
							}),
							updated(config, entry) && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
								className: "dt-changed-tag dt-updated-tag",
								children: t("promptDefaultUpdated")
							}),
							unsaved(`part/${entry.key}`)
						] }))),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
							className: "dt-nav-group",
							children: t("promptSkillsGroup")
						}),
						Object.keys(config.skills).map((skill) => item(`skill/${skill}`, /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("span", { children: [sectionLabel(t, view, `skill/${skill}`), unsaved(`skill/${skill}`)] }))),
						/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("form", {
							className: "dt-add-skill",
							onSubmit: add,
							children: [
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Input, {
									value: name,
									placeholder: t("promptSkillName"),
									"aria-label": t("promptAddSkill"),
									spellCheck: false,
									onChange: (event) => {
										setName(event.target.value);
										setInvalid(false);
									}
								}),
								invalid && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
									className: "dt-error",
									role: "alert",
									children: t("promptSkillNameInvalid")
								}),
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
									variant: "ghost",
									size: "sm",
									type: "submit",
									icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "plus" }),
									children: t("promptAddSkillAction")
								})
							]
						})
					]
				}), part ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(BuiltInEditor, {
					config,
					view,
					part,
					onEdit
				}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(TeamEditor, {
					config,
					view,
					selected,
					onSelect,
					onEdit
				})]
			});
		}
		/** Whether an override was edited from a built-in text that has changed since. */
		const updated = (config, part) => {
			const override = config.overrides?.[part.key];
			return !!override?.base && override.base !== part.base;
		};
		function TeamEditor({ config, view, selected, onSelect, onEdit }) {
			const { t } = usePanel();
			const text = sectionText(config, selected) ?? "";
			const fallback = sectionText(view.defaults, selected);
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-prompt-main",
				children: [
					/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
						className: "dt-subhead",
						children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("h3", {
							className: "dt-section-title",
							children: sectionLabel(t, view, selected)
						}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
							className: "dt-actions",
							children: isSkill(selected) ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
								variant: "outline",
								size: "sm",
								icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "trash" }),
								onClick: () => {
									onEdit(withoutSkill(config, selected), { selection: "communication" });
									onSelect("communication");
								},
								children: t("remove")
							}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
								variant: "outline",
								size: "sm",
								icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "refresh" }),
								disabled: fallback === text,
								onClick: () => onEdit(withSection(config, selected, fallback ?? ""), { from: { reset: selected } }),
								children: t("promptResetSection")
							})
						})]
					}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t(isSkill(selected) ? "promptReadBy.skill" : "promptReadBy.both") }),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)("textarea", {
						className: "dt-textarea dt-mono dt-editor",
						spellCheck: false,
						"aria-label": t("promptBody"),
						value: text,
						onChange: (event) => onEdit(withSection(config, selected, event.target.value))
					})
				]
			});
		}
		/**
		* A built-in part: its text, the team's override or the built-in one, with a reset; a template says which placeholders it
		* keeps; an override whose built-in text changed since shows the change and offers to keep the team's text or take the new one.
		*/
		function BuiltInEditor({ config, view, part, onEdit }) {
			const { t } = usePanel();
			const name = `part/${part.key}`;
			const reset = () => onEdit(withOverride(config, part, void 0), { from: { reset: name } });
			const base = config.overrides?.[part.key]?.base;
			const previous = view.defaultChanged.find((item) => item.part === part.key && item.base === base)?.previous;
			const readBy = part.key.startsWith("skill/") ? "promptReadBy.skill" : part.roles.length > 1 ? "promptReadBy.both" : `promptReadBy.${part.roles[0]}`;
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-prompt-main",
				children: [
					/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
						className: "dt-subhead",
						children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("h3", {
							className: "dt-section-title",
							children: sectionLabel(t, view, name)
						}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
							className: "dt-actions",
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
								variant: "outline",
								size: "sm",
								icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "refresh" }),
								disabled: !config.overrides?.[part.key],
								onClick: reset,
								children: t("promptResetSection")
							})
						})]
					}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t(readBy) }),
					part.placeholders && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("promptTemplateHint", { placeholders: part.placeholders.join(t("listSeparator")) }) }),
					updated(config, part) && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("section", {
						className: "dt-default-updated",
						"aria-label": t("promptDefaultUpdated"),
						children: [
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)("b", { children: t("promptDefaultUpdated") }),
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("promptDefaultUpdatedHint") }),
							previous !== void 0 ? /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("promptDefaultUpdatedKnown") }), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Diff, { lines: lineDiff(previous, part.text) })] }) : /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("promptDefaultUpdatedUnknown") }), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Diff, { lines: lineDiff(partText(config, part), part.text) })] }),
							/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("span", {
								className: "dt-actions",
								children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
									variant: "outline",
									size: "sm",
									onClick: () => onEdit(withOverride(config, part, partText(config, part), true)),
									children: t("promptKeepMine")
								}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
									variant: "outline",
									size: "sm",
									onClick: reset,
									children: t("promptTakeDefault")
								})]
							})
						]
					}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)("textarea", {
						className: "dt-textarea dt-mono dt-editor",
						spellCheck: false,
						"aria-label": t("promptBody"),
						value: partText(config, part),
						onChange: (event) => onEdit(withOverride(config, part, event.target.value))
					})
				]
			});
		}
		const KIND_LABEL = {
			team: "promptPartTeam",
			fixed: "promptPartFixed",
			generated: "promptPartGenerated"
		};
		function FullPrompt({ config, view, dirty, revision, onEdit }) {
			const { t, call, notify } = usePanel();
			const [target, setTarget] = (0, react.useState)("orchestrator");
			const [compare, setCompare] = (0, react.useState)(dirty ? "saved" : "default");
			const [preview, setPreview] = (0, react.useState)();
			const [error, setError] = (0, react.useState)();
			(0, react.useEffect)(() => {
				let active = true;
				call("POST prompts/preview", { body: config }).then((value) => {
					if (active) {
						setPreview({
							config,
							value
						});
						setError(void 0);
					}
				}, (failure) => {
					if (active) setError(failure);
				});
				return () => {
					active = false;
				};
			}, [call, config]);
			if (!preview || error) return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LoadState, {
				loading: true,
				error
			});
			const shown = dirty ? compare : "default";
			const team = isSkill(target) && Object.hasOwn(preview.config.skills, target.slice(6));
			const parts = isSkill(target) ? [{
				name: target,
				kind: team ? "team" : "fixed",
				...team ? {} : { key: target },
				text: preview.value.skills[target.slice(6)] ?? ""
			}] : preview.value.parts[target];
			const builtIn = (key) => view.parts.find((part) => part.key === key);
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-subhead",
				children: [
					/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("select", {
						className: "dt-select dt-inline-select",
						"aria-label": t("promptPreviewTarget"),
						value: target,
						onChange: (event) => setTarget(event.target.value),
						children: [
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)("option", {
								value: "orchestrator",
								children: valueLabel(t, "promptRole", "orchestrator")
							}),
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)("option", {
								value: "worker",
								children: valueLabel(t, "promptRole", "worker")
							}),
							Object.keys(preview.value.skills).map((name) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("option", {
								value: `skill/${name}`,
								children: sectionLabel(t, view, `skill/${name}`)
							}, name))
						]
					}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("promptFullState", {
						count: parts.length,
						chars: parts.reduce((sum, part) => sum + part.text.length, 0),
						state: dirty ? t("promptPreviewDraft") : t("promptPreviewSaved", { revision })
					}) }),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(SegmentedControl, {
						className: "dt-segmented dt-compare",
						label: t("promptCompare"),
						value: shown,
						options: [...dirty ? [{
							value: "saved",
							label: t("promptCompareSaved")
						}] : [], {
							value: "default",
							label: t("promptCompareDefault")
						}],
						onChange: setCompare
					}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
						variant: "outline",
						size: "sm",
						icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "copy" }),
						onClick: () => {
							navigator.clipboard.writeText(parts.map((part) => part.text).join("\n\n")).then(() => notify(t("copied")));
						},
						children: t("promptCopyAll")
					})
				]
			}), parts.map((part) => {
				const { kind } = part;
				const text = sectionText(preview.config, part.name) ?? "";
				const entry = part.key === void 0 ? void 0 : builtIn(part.key);
				const from = (config) => kind === "team" ? partWith(part, sectionText(config, part.name) ?? "") : kind === "fixed" && entry ? partText(config, entry) : void 0;
				const base = from(shown === "saved" ? view.current.config : view.defaults);
				const edited = kind === "team" ? !isSkill(part.name) && text !== sectionText(view.defaults, part.name) : !!entry && !!preview.config.overrides?.[entry.key];
				const template = kind === "generated" && !!entry && preview.config.overrides?.[entry.key]?.text !== view.current.config.overrides?.[entry.key]?.text;
				return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("section", {
					className: "dt-preview-part",
					"data-editable": kind === "team" || entry !== void 0 || void 0,
					children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
						className: "dt-preview-head",
						children: [
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)("b", { children: sectionLabel(t, view, entry ? `part/${entry.key}` : part.name) }),
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { children: t(KIND_LABEL[kind]) }),
							edited && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
								className: "dt-changed-tag",
								children: t("promptChanged")
							}),
							(kind === "team" || entry) && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
								type: "button",
								className: "dt-textlink",
								onClick: () => onEdit(entry ? `part/${entry.key}` : part.name),
								children: t("promptEditSource")
							})
						]
					}), base !== void 0 && base !== part.text ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Diff, { lines: lineDiff(base, part.text) }) : shown === "saved" && !template ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t(kind === "generated" ? "promptBuiltInFolded" : "promptSameAsSaved") }) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)("pre", {
						className: "dt-pre",
						children: part.text
					})]
				}, part.name);
			})] });
		}
		function Diff({ lines }) {
			const { t } = usePanel();
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("pre", {
				className: "dt-pre",
				children: lines.map((line, index) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(react.Fragment, { children: line.kind === "fold" ? /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
					className: "dt-diff-fold",
					children: t("promptSameLines", { count: line.count })
				}), "\n"] }) : line.kind === "ins" ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ins", { children: `${line.text}\n` }) : line.kind === "del" ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("del", { children: `${line.text}\n` }) : `${line.text}\n` }, index))
			});
		}
		function PromptHistory({ view, from, onLoad }) {
			const { t, call } = usePanel();
			const [older, setOlder] = (0, react.useState)();
			const next = older ? older.next_offset : view.next_offset;
			const more = useAction(async (offset) => {
				const page = await call("GET prompts", { query: { offset } });
				setOlder({
					revisions: [...older?.revisions ?? [], ...page.revisions],
					next_offset: page.next_offset
				});
			});
			const load = useAction(async (revision) => {
				onLoad((await call("GET prompts", { query: { revision } })).current.config, { revision });
			});
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-form",
				children: [
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("promptHistoryHint") }),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
						className: "dt-list",
						children: [...view.revisions, ...older?.revisions ?? []].map((version) => /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("li", {
							className: "dt-row",
							children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
								className: "dt-row-main",
								children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
									className: "dt-row-title",
									children: t("promptHistoryItem", {
										revision: version.revision,
										time: version.savedAt ? when(version.savedAt, t("lang")) : t("promptHistoryInitial"),
										source: valueLabel(t, "historySource", version.source)
									})
								}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
									className: "dt-row-meta",
									children: version.changed.length ? t("promptHistoryChanged", { parts: version.changed.map((name) => sectionLabel(t, view, name)).join(t("listSeparator")) }) : t("promptHistoryNone")
								})]
							}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
								className: "dt-row-actions",
								children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
									variant: "outline",
									size: "sm",
									icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "history" }),
									disabled: load.busy || typeof from === "object" && "revision" in from && from.revision === version.revision,
									onClick: () => {
										load.run(version.revision);
									},
									children: t("promptRestore")
								})
							})]
						}, version.revision))
					}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
						className: "dt-actions",
						children: [next !== null && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
							variant: "outline",
							size: "sm",
							icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "chevron-down" }),
							disabled: more.busy,
							onClick: () => {
								more.run(next);
							},
							children: t("promptOlder")
						}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
							variant: "outline",
							size: "sm",
							icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "refresh" }),
							onClick: () => onLoad(view.defaults, "defaults"),
							children: t("promptDefaults")
						})]
					}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
						className: "dt-field",
						children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { children: t("promptSessions") }), view.sessions.length ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
							className: "dt-changes dt-mono",
							children: view.sessions.map((item) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("li", { children: t("promptSessionItem", {
								session: item.sessionId,
								revision: item.revision
							}) }, item.sessionId))
						}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("promptNoSessions") })]
					})
				]
			});
		}
		//#endregion
		//#region src/client/source.tsx
		/** Source status view (health, filtered Triggers, dropped replies) and Source settings cards. */
		function SourceCard({ source }) {
			const { t, call } = usePanel();
			const { running } = usePanelData();
			const { reload } = useSettings();
			const [advancedOpen, setAdvancedOpen] = (0, react.useState)(false);
			const refreshLabels = async () => {
				const { added } = await call("POST sources/:id/labels", { id: source.id });
				await reload();
				return added;
			};
			const draft = useBlockDraft(`source:${source.id}`, source.value, source.revision);
			const value = draft.value;
			const { problem, value: saved } = source;
			const changed = (key) => String(value.config[key] ?? "") !== String(saved.config[key] ?? "");
			const restarts = draft.dirty && source.restarts.some(changed);
			const description = localized(t, source.description);
			const field = (spec) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SourceField, {
				field: spec,
				value: value.config[spec.key],
				saved: saved.config[spec.key],
				labels: source.labels,
				refreshLabels,
				fact: spec.type === "fact" || !changed(spec.key) ? source.facts[spec.key] : void 0,
				onChange: (next) => draft.edit({
					...value,
					config: {
						...value.config,
						[spec.key]: next
					}
				})
			}, spec.key);
			const advanced = source.fields.filter((spec) => spec.advanced);
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("form", {
				id: `dt-source-${source.id}`,
				className: "dt-card",
				onSubmit: (event) => {
					draft.submit(event);
				},
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)(Fields, {
					disabled: draft.busy,
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
							className: "dt-card-head",
							children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
								className: "dt-row-main",
								children: /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
									className: "dt-row-title",
									children: [
										/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
											className: "dt-card-title",
											children: localized(t, source.title)
										}),
										description && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(InfoTip, { text: description }),
										!source.installed && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Tag, {
											tone: "warning",
											children: t("sourceNotInstalled")
										})
									]
								})
							}), source.installed && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Switch, {
								checked: value.enabled,
								onChange: (enabled) => draft.edit({
									...value,
									enabled
								}),
								label: t("sourceEnable", { name: localized(t, source.title) })
							})]
						}),
						problem && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
							className: "dt-row-buttons",
							children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
								className: "dt-error",
								role: "status",
								children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SetupMessage, {
									problem,
									lead: true
								})
							}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(CheckSetupButton, {})]
						}),
						!source.installed && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("sourceNotInstalledHint") }),
						source.installed && source.fields.filter((spec) => !spec.advanced).map(field),
						source.installed && advanced.length > 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(DisclosureRow, {
							icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "settings" }),
							title: t("advanced"),
							open: advancedOpen,
							onToggle: () => setAdvancedOpen(!advancedOpen),
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
								className: "dt-disclosure-body",
								children: advanced.map(field)
							})
						})
					]
				}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SaveBar, {
					...draft,
					status: restarts && running > 0 ? t("restartInterrupts", { count: running }) : void 0,
					onDiscard: draft.discard
				})]
			});
		}
		function SourceSettings({ focus }) {
			const { sources } = useSettings().settings;
			(0, react.useEffect)(() => {
				if (focus) document.getElementById(`dt-source-${focus}`)?.scrollIntoView?.({ block: "start" });
			}, [focus]);
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-form",
				children: [sources.map((source) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SourceCard, { source }, source.id)), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ConfigHistory, { blocks: ["source:"] })]
			});
		}
		function DroppedReplies({ items }) {
			const { t, navigate } = usePanel();
			const [open, setOpen] = (0, react.useState)(false);
			const target = (item) => item.ticket ? {
				route: {
					page: "execution",
					id: item.ticket.id
				},
				name: item.ticket.title
			} : item.thread ? {
				route: {
					page: "trigger",
					id: item.thread
				},
				name: t("term.thread")
			} : void 0;
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(DisclosureRow, {
				icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "dismiss" }),
				title: /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [
					t("sourceDroppedTitle"),
					" ",
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
						className: "dt-count",
						children: items.length
					})
				] }),
				open,
				onToggle: () => setOpen(!open),
				children: /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-disclosure-body",
					children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("sourceDroppedHint") }), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
						className: "dt-list",
						children: items.map((item) => {
							const link = target(item);
							return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("li", {
								className: "dt-row",
								children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Dot, { state: "idle" }), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
									className: "dt-row-main",
									children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
										className: "dt-row-title dt-line",
										children: readableMarkers(t, item.preview) || t("empty")
									}), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
										className: "dt-row-meta",
										children: [
											/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Tag, {
												tone: "neutral",
												children: reasonLabel(t, item.dropped.reason)
											}),
											/* @__PURE__ */ (0, react_jsx_runtime.jsx)(When, { at: item.dropped.at }),
											link && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
												type: "button",
												className: "dt-textlink",
												onClick: () => navigate(link.route),
												children: link.name
											})
										]
									})]
								})]
							}, item.id);
						})
					})]
				})
			});
		}
		function SourceRow({ source }) {
			const { t, navigate } = usePanel();
			const { setup } = usePanelData();
			const [filteredOpen, setFilteredOpen] = (0, react.useState)(false);
			const { problem, dropped } = source;
			const { dot, label: state } = sourceMark(t, source.state);
			const { received, filtered, lastAt } = source.stats;
			const notes = source.enabled && !problem && !setup?.problem ? source.health.filter((item) => item.state === "error" || item.state === "paused") : [];
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("li", {
				className: "dt-row",
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Dot, {
					state: dot,
					label: state
				}), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-row-main",
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
							className: "dt-row-title",
							children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
								className: "dt-row-name",
								children: localized(t, source.title)
							}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
								className: "dt-status-text",
								"data-state": dot,
								children: state
							})]
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
							className: "dt-row-meta",
							children: [
								received > 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LabelValue, {
									label: t("sourceReceivedLabel"),
									value: received
								}),
								filtered > 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LabelValue, {
									label: t("sourceFilteredLabel"),
									value: filtered
								}),
								lastAt && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LabelValue, {
									label: t("sourceLatestLabel"),
									value: when(lastAt, t("lang"))
								})
							]
						}),
						problem && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("p", {
							className: "dt-error",
							children: [
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)(SetupMessage, {
									problem,
									lead: true
								}),
								" ",
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
									type: "button",
									className: "dt-textlink",
									onClick: () => navigate(settingsRoute("source", { source: source.id })),
									children: t("sourceOpenSettings")
								})
							]
						}),
						notes.map((item) => /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("p", {
							className: item.state === "error" ? "dt-error dt-clamp" : "dt-hint dt-clamp",
							children: [
								valueLabel(t, "health", item.name),
								t("labelSeparator"),
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
									className: item.code ? void 0 : "dt-mono",
									children: healthText(t, item)
								})
							]
						}, item.name)),
						source.filtered.length > 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(DisclosureRow, {
							icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "filter" }),
							title: t("sourceFilteredTitle"),
							open: filteredOpen,
							onToggle: () => setFilteredOpen(!filteredOpen),
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
								className: "dt-disclosure-body",
								children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
									className: "dt-list",
									children: source.filtered.map((item) => /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("li", {
										className: "dt-row",
										children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Dot, { state: "idle" }), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
											className: "dt-row-main",
											children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
												className: "dt-row-title",
												children: [
													actorName(t, item.actor),
													t("labelSeparator"),
													readableMarkers(t, item.preview) || t("empty")
												]
											}), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
												className: "dt-row-meta",
												children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Tag, {
													tone: "neutral",
													children: reasonLabel(t, item.reason)
												}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(When, { at: item.at })]
											})]
										})]
									}, item.id))
								})
							})
						}),
						dropped.length > 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(DroppedReplies, { items: dropped })
					]
				})]
			});
		}
		function SourceStatus() {
			const { t, call, navigate } = usePanel();
			const { setup } = usePanelData();
			const { data, error } = usePoll(() => call("GET sources"), []);
			const elsewhere = setup?.problem?.place === "deployment" ? setup.problem : void 0;
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-form",
				children: [
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(StatusHead, {
						hint: t("sourceStatusIntro"),
						settings: "source"
					}),
					elsewhere && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("p", {
						className: "dt-error",
						children: [
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)(SetupMessage, {
								problem: elsewhere,
								lead: true
							}),
							" ",
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
								type: "button",
								className: "dt-textlink",
								onClick: () => navigate(setupPage(elsewhere.place)),
								children: t("setupFixLink")
							})
						]
					}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(LoadState, {
						error,
						loading: !data
					}),
					data && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
						className: "dt-list",
						children: data.map((source) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SourceRow, { source }, source.id))
					})
				]
			});
		}
		//#endregion
		//#region src/client/settings.tsx
		const STAGE_GROUPS = [
			"source",
			"eval",
			"execution"
		];
		function SettingsPage({ group, query, state, deploymentForm }) {
			const { t, navigate } = usePanel();
			const content = (() => {
				switch (group) {
					case "source": return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SettingsProvider, { children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SourceSettings, { ...query.source ? { focus: query.source } : {} }) });
					case "eval": return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SettingsProvider, { children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(EvalSettings, { version: query.version }) });
					case "execution": return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SettingsProvider, { children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ExecutionSettings, {}) });
					case "prompts": return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(PromptsPage, {});
					case "deployment": return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(DeploymentPage, {
						setup: state.setup,
						form: deploymentForm
					});
				}
			})();
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-settings",
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("nav", {
					className: "dt-settings-nav",
					"aria-label": t("tab.settings"),
					children: SETTINGS_GROUPS.map((value) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
						type: "button",
						className: "dt-settings-link",
						"data-stage": STAGE_GROUPS.includes(value) || void 0,
						"aria-current": value === group ? "page" : void 0,
						onClick: () => navigate(settingsRoute(value), true),
						children: t(`settingsGroup.${value}`)
					}, value))
				}), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-settings-body",
					children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("h2", {
						className: "dt-settings-title",
						children: t(`settingsGroup.${group}`)
					}), content]
				})]
			});
		}
		//#endregion
		//#region src/client/thread.tsx
		/** Thread detail page: Trigger timeline with gap-free pagination, Decisions, subscribed Tickets, and correlated Threads. */
		/** Disposition tags for a Trigger; omits `ignore` (the common case) and suppresses fanout tags when every target Ticket is already listed in `subscribed`. */
		function triggerTags(t, trigger, subscribed) {
			const d = trigger.disposition;
			const tags = [];
			if (d.queued) tags.push(/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Tag, {
				tone: "info",
				children: t("dispositionQueued")
			}, "q"));
			else if (d.evaluating) tags.push(/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Tag, {
				tone: "info",
				children: t("dispositionEvaluating")
			}, "e"));
			else if (d.filtered) tags.push(/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Tag, {
				tone: "neutral",
				children: t("tagFiltered", { reason: reasonLabel(t, d.filtered) })
			}, "f"));
			else if (d.decision && d.decision.outcome !== "ignore") {
				const { tone, label } = decisionMark(t, d.decision.outcome);
				tags.push(/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Tag, {
					tone,
					children: label
				}, "d"));
			}
			if (d.delivered) tags.push(/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Tag, {
				tone: "info",
				title: t("dispositionDeliveredHint"),
				children: t("dispositionDelivered")
			}, "o"));
			else if (d.fanout.length && !(subscribed && d.fanout.every((id) => subscribed.has(id)))) tags.push(/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Tag, {
				tone: "info",
				children: t("dispositionFanout", { count: d.fanout.length })
			}, "o"));
			return tags;
		}
		function TriggerItem({ trigger, earlier, target, subscribed, requeue }) {
			const { t, navigate } = usePanel();
			const ticketId = trigger.disposition.decision?.ticketId;
			const scroll = (element) => {
				if (element && target === trigger.id && !element.dataset.scrolled) {
					element.dataset.scrolled = "1";
					element.scrollIntoView?.({ block: "center" });
				}
			};
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("li", {
				id: `trigger-${trigger.id}`,
				className: `dt-event${target === trigger.id ? " dt-highlight" : ""}${trigger.human ? "" : " dt-event-quiet"}`,
				ref: scroll,
				children: [
					/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
						className: "dt-event-foot",
						children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("strong", {
							className: "dt-event-actor",
							children: actorName(t, trigger.actor)
						}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(When, { at: trigger.at })]
					}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(ClampText, { text: readableMarkers(t, trigger.text || trigger.preview) }),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Earlier, { items: earlier }),
					trigger.disposition.handbacks.map((item) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("handedBack", {
						ticket: item.title,
						reason: item.reason
					}) }, item.ticketId)),
					/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
						className: "dt-event-foot",
						children: [
							triggerTags(t, trigger, subscribed),
							ticketId && !subscribed.has(ticketId) && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
								type: "button",
								className: "dt-textlink dt-icon-link",
								onClick: () => navigate({
									page: "execution",
									id: ticketId
								}),
								children: t("openTicket")
							}),
							requeue && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("button", {
								type: "button",
								className: "dt-textlink dt-icon-link dt-reveal",
								disabled: requeue.busy,
								"aria-busy": requeue.busy,
								onClick: requeue.run,
								children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, {
									name: "refresh",
									size: 13
								}), t("requeue")]
							})
						]
					})
				]
			});
		}
		const overlaps = (some, others) => some.some((item) => others.some((other) => other.id === item.id));
		const byTime = (triggers) => [...new Map(triggers.map((item) => [item.id, item])).values()].sort((a, b) => a.at.localeCompare(b.at));
		const gapBetween = (newest, older) => !!older && newest.earlier !== null && !overlaps(newest.timeline, older.triggers);
		function mergeTimeline(newest, older) {
			if (!older || newest.earlier === null || gapBetween(newest, older)) return newest;
			return {
				...newest,
				timeline: byTime([...older.triggers, ...newest.timeline]),
				earlier: older.cursor
			};
		}
		const PAGE = 50;
		/**
		* Manage a Thread's timeline across live polling, deep-linked `target` Triggers, and manual pagination.
		* Fills any gap between the latest polled page and older loaded pages before merging so the timeline remains contiguous.
		*/
		function useThreadTimeline(key, target) {
			const { call, notify } = usePanel();
			const [older, setOlder] = (0, react.useState)();
			const { data: newest, error, reload } = usePoll(() => call("GET threads/:key", {
				key,
				query: { limit: PAGE }
			}), [key]);
			const data = newest && mergeTimeline(newest, older);
			const read = (id) => !!newest?.timeline.some((item) => item.id === id) || !!older?.triggers.some((item) => item.id === id);
			const missing = !!target && !!newest && !read(target);
			(0, react.useEffect)(() => {
				if (!missing) return;
				let active = true;
				call("GET threads/:key", {
					key,
					query: {
						limit: PAGE,
						around: target
					}
				}).then((page) => {
					if (active) setOlder({
						triggers: page.timeline,
						cursor: page.earlier
					});
				}, (failure) => {
					if (active) notify(errorText(failure));
				});
				return () => {
					active = false;
				};
			}, [
				missing,
				call,
				key,
				target,
				notify
			]);
			const gap = !!newest && gapBetween(newest, older);
			(0, react.useEffect)(() => {
				if (!gap || !newest || !older) return;
				let active = true;
				const fill = async () => {
					let run = newest.timeline, cursor = newest.earlier;
					while (cursor !== null && !overlaps(run, older.triggers)) {
						const page = await call("GET threads/:key", {
							key,
							query: {
								limit: PAGE,
								before: cursor
							}
						});
						run = [...page.timeline, ...run];
						cursor = page.earlier;
					}
					if (active) setOlder({
						triggers: byTime([...older.triggers, ...run]),
						cursor: overlaps(run, older.triggers) ? older.cursor : cursor
					});
				};
				fill().catch((failure) => {
					if (active) notify(errorText(failure));
				});
				return () => {
					active = false;
				};
			}, [
				gap,
				newest,
				older,
				call,
				key,
				notify
			]);
			return {
				data,
				error,
				reload,
				earlier: useAction(async (shown) => {
					const page = await call("GET threads/:key", {
						key,
						query: {
							limit: PAGE,
							before: shown.earlier
						}
					});
					setOlder({
						triggers: [...page.timeline, ...shown.timeline],
						cursor: page.earlier
					});
				})
			};
		}
		function ThreadPage({ id, target }) {
			const { t, call, navigate, notify } = usePanel();
			const [decisionsOpen, setDecisionsOpen] = (0, react.useState)(false);
			const { data, error, reload, earlier } = useThreadTimeline(id, target);
			const requeue = useAction(async (trigger) => {
				if (!(await call("POST triggers/:id/requeue", { id: trigger })).queued) notify(t("requeueAlready"));
			}, { reload });
			if (!data) return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(PageHead, { title: t("term.thread") }), error instanceof ApiError && error.missing ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("threadNotFound") }) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LoadState, {
				error,
				loading: true
			})] });
			const subscribed = new Set(data.tickets.map((ticket) => ticket.id));
			const sender = (trigger) => !trigger.human && trigger.id !== target ? `${trigger.actor.source}:${trigger.actor.id}` : void 0;
			const unsubscribe = async () => {
				if ((await call("POST threads/:key/unsubscribe", { key: data.key })).context_delivery === "pending") notify(t("unsubscribePending"));
				await reload();
			};
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [
				/* @__PURE__ */ (0, react_jsx_runtime.jsx)(PageHead, {
					title: readableMarkers(t, data.title),
					children: data.url && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ActionLink, {
						href: data.url,
						children: t("openOriginal")
					})
				}),
				error && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LoadState, {
					error,
					loading: false
				}),
				/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-row-meta dt-status-line",
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { children: valueLabel(t, "source", data.source) }),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { children: t("threadLatest", { time: when(data.lastAt, t("lang")) }) }),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { children: t("threadCreated", { time: when(data.createdAt, t("lang")) }) })
					]
				}),
				data.evaluating && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
					className: "dt-banner",
					children: t("evaluatingBanner", {
						count: data.evaluating.triggers,
						strength: valueLabel(t, "strength", data.evaluating.strength),
						deadline: when(data.evaluating.deadline, t("lang"))
					})
				}),
				data.pollError && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
					className: "dt-error dt-clamp",
					children: t("pollFailed", { error: data.pollError })
				}),
				data.tickets.length > 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Section, {
					title: t("subscribedTickets"),
					count: data.tickets.length,
					children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
						className: "dt-list",
						children: data.tickets.map((ticket) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(TicketLine, {
							ticket,
							context: data.context.includes(ticket.id)
						}, ticket.id))
					})
				}),
				data.decisions.length > 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(DisclosureRow, {
					icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "decision" }),
					title: t("threadDecisions", { count: data.decisions.length }),
					open: decisionsOpen,
					onToggle: () => setDecisionsOpen(!decisionsOpen),
					children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
						className: "dt-disclosure-body",
						children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
							className: "dt-list",
							children: data.decisions.map((decision) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(DecisionLine, { decision }, decision.id))
						})
					})
				}),
				data.correlated.length > 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Section, {
					title: t("term.correlation"),
					children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
						className: "dt-plain-list",
						children: data.correlated.map((item) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("li", { children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
							type: "button",
							className: "dt-textlink",
							onClick: () => navigate({
								page: "trigger",
								id: item.key
							}),
							children: readableMarkers(t, item.title)
						}) }, item.key))
					})
				}),
				/* @__PURE__ */ (0, react_jsx_runtime.jsxs)(Section, {
					title: t("timeline"),
					count: t("newestFirst"),
					children: [data.timeline.length ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ol", {
						className: "dt-timeline",
						children: automatedRuns(data.timeline.slice().reverse(), sender).map(({ item, earlier: folded }) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(TriggerItem, {
							trigger: item,
							earlier: folded,
							target,
							subscribed,
							requeue: item.actions.requeue ? {
								busy: requeue.busy,
								run: () => {
									requeue.run(item.id);
								}
							} : void 0
						}, item.id))
					}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("noTriggers") }), data.earlier && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", { children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
						variant: "outline",
						size: "sm",
						icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, {
							name: "chevron-down",
							size: 14
						}),
						disabled: earlier.busy,
						onClick: () => {
							earlier.run(data);
						},
						children: t("loadEarlier")
					}) })]
				}),
				data.tickets.length > 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-danger-zone",
					children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
						className: "dt-hint",
						children: t("unsubscribeHint")
					}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ConfirmButton, {
						variant: "outline",
						icon: "unsubscribe",
						label: t("unsubscribe"),
						title: t("unsubscribeTitle"),
						message: t("unsubscribeConfirm", { title: data.title }),
						onConfirm: unsubscribe
					})]
				})
			] });
		}
		//#endregion
		//#region src/client/ticket.tsx
		/** Ticket detail page: stage and actions, Mandate details, undelivered/delivered Inputs, subscribed Threads, and Assignments. */
		function InputLine({ input, earlier = [] }) {
			const { t, navigate } = usePanel();
			const trigger = input.kind === "trigger" ? input.trigger : void 0;
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("li", {
				className: "dt-row",
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Dot, {
					state: input.delivered ? "idle" : "warning",
					label: input.delivered ? t("inputDelivered") : t("inputUndelivered")
				}), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-row-main",
					children: [
						trigger ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
							className: "dt-row-title",
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("button", {
								type: "button",
								className: "dt-open",
								onClick: () => navigate({
									page: "trigger",
									id: trigger.thread,
									query: { trigger: trigger.id }
								}),
								children: [
									actorName(t, trigger.actor),
									t("labelSeparator"),
									readableMarkers(t, trigger.preview) || t("empty")
								]
							})
						}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
							className: "dt-row-title",
							children: valueLabel(t, "input", input.kind)
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
							className: "dt-row-meta",
							children: [input.kind === "trigger" && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { children: valueLabel(t, "input", input.kind) }), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(When, { at: input.at })]
						}),
						(input.kind === "text" || input.kind === "note") && input.text && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
							className: "dt-row-quote",
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(MarkdownLite, { text: input.text })
						}),
						trigger?.handback && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("inputHandedBack", { reason: trigger.handback.reason }) }),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Earlier, { items: earlier })
					]
				})]
			});
		}
		function InputList({ inputs }) {
			const sender = (input) => input.kind === "trigger" && input.trigger && !input.trigger.human ? `${input.trigger.actor.source}:${input.trigger.actor.id}` : void 0;
			const shown = (input) => ({
				id: input.id,
				at: input.at,
				preview: input.kind === "trigger" ? input.trigger?.preview ?? "" : ""
			});
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
				className: "dt-list",
				children: automatedRuns(inputs, sender).map((run) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(InputLine, {
					input: run.item,
					earlier: run.earlier.map(shown)
				}, run.item.id))
			});
		}
		function Details({ icon, title, open = false, children }) {
			const [shown, setShown] = (0, react.useState)(open);
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(DisclosureRow, {
				icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: icon }),
				title,
				open: shown,
				onToggle: () => setShown(!shown),
				children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
					className: "dt-disclosure-body",
					children
				})
			});
		}
		function Assignments({ ticket }) {
			const { t } = usePanel();
			const report = (state) => t("assignmentReportShort", { state: valueLabel(t, "report", state) });
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
				className: "dt-list",
				children: ticket.assignments.slice().reverse().map((item, index) => /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("li", {
					className: "dt-row",
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Dot, {
							state: item.state === "running" ? reportDot(item.report?.state) : "idle",
							label: valueLabel(t, "assignment", item.state)
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
							className: "dt-row-main",
							children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
								className: "dt-row-title",
								children: t("assignmentNumber", { number: ticket.assignments.length - index })
							}), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
								className: "dt-row-meta",
								children: [
									item.turnEndedAt && item.report ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Tag, {
										tone: "neutral",
										children: report(item.report.state)
									}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Tag, {
										tone: item.state === "running" ? "info" : "neutral",
										children: valueLabel(t, "assignment", item.state)
									}),
									item.state !== "running" && item.report && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { children: report(item.report.state) }),
									/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { children: t("assignmentSpan", {
										from: when(item.startedAt ?? item.createdAt, t("lang")),
										to: when(item.endedAt ?? item.turnEndedAt, t("lang")) || t("now")
									}) }),
									item.endedReason && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { children: reasonLabel(t, item.endedReason) })
								]
							})]
						}),
						item.ref && item.ref !== ticket.sessionId && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
							className: "dt-row-actions",
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SessionButton, {
								variant: "outline",
								sessionId: item.ref
							})
						})
					]
				}, item.id))
			});
		}
		function MandateDetails({ ticket, actor }) {
			const { t, navigate } = usePanel();
			const { mandate, decision } = ticket;
			const fact = (item) => {
				if (item.name === "legacyAuthority") return valueLabel(t, "legacy", item.value);
				if (item.name === "mode" || item.name === "addressed") return valueLabel(t, item.name, item.value);
				if (item.name === "admission") return valueLabel(t, "admissionCell", item.value);
				if (item.name === "rules") return item.value.map((rule) => rule.name).join(t("listSeparator"));
				return item.name === "sender" ? item.value : t("yes");
			};
			const { legacy } = ticket.basis;
			const facts = ticket.basis.facts.filter((item) => !(item.name === "sender" && item.value === actor));
			const direction = decision?.direction;
			const rows = decision ? [[t("term.trigger"), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("button", {
				type: "button",
				className: "dt-trigger-link",
				onClick: () => navigate({
					page: "trigger",
					id: decision.thread,
					query: { trigger: decision.triggerIds[0] ?? "" }
				}),
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
					className: "dt-trigger-text",
					children: readableMarkers(t, decision.preview) || t("empty")
				}), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("span", {
					className: "dt-row-meta",
					children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("span", { children: [
						valueLabel(t, "source", mandate.actor.source),
						" · ",
						actor
					] }), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(When, { at: decision.at })]
				})]
			})], [t("term.decision"), /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-kv-stack",
				children: [
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { children: decisionMark(t, decision.outcome).label }),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: reasonLabel(t, decision.reason) }),
					decision.rules.map((rule) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t(rule.matched ? "ruleMatched" : "ruleUnmatched", {
						rule: rule.name,
						reason: rule.reason
					}) }, rule.id)),
					direction && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(Hint, { children: [
						t("directionLine", {
							intent: t(direction.implementation_requested ? "intentYes" : "intentNo"),
							basis: valueLabel(t, "targetBasis", direction.target_basis),
							design: t(direction.requires_design_decision ? "designNeeded" : "designNotNeeded")
						}),
						" ",
						t("directionEvidence", { evidence: direction.evidence })
					] })
				]
			})]] : [];
			const version = /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
				type: "button",
				className: "dt-textlink dt-mono",
				onClick: () => navigate(settingsRoute("eval", { version: mandate.policyVersion })),
				children: mandate.policyVersion.slice(0, 8)
			});
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Section, {
				title: t("mandateDetails"),
				icon: "shield",
				children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(KeyValues, { rows: [
					...rows,
					[t("term.scope"), legacy ? t("legacyScopeShort") : mandate.scope || t("empty")],
					...facts.map((item) => [valueLabel(t, "basis", item.name), fact(item)]),
					...legacy ? [] : [[t("policyVersion"), version]]
				] })
			});
		}
		function TicketPage({ id }) {
			const { t, call } = usePanel();
			const { data, error, reload } = usePoll(() => call("GET tickets/:id", { id }), [id]);
			const after = async (request) => {
				await request;
				await reload();
			};
			if (!data) return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(PageHead, { title: t("term.ticket") }), error instanceof ApiError && error.missing ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("ticketNotFound") }) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LoadState, {
				error,
				loading: true
			})] });
			const status = ticketMark(t, data);
			const actor = actorName(t, data.mandate.actor);
			const { legacy } = data.basis;
			const undelivered = data.inputs.filter((input) => !input.delivered);
			const failedText = /^(?:\w+Error|Error)\b[:：]/.test(data.summary);
			const failed = data.stage === "person" && data.action === "failed";
			const opening = data.threads.find((thread) => thread.url);
			const ended = data.ended && (() => {
				const outcome = valueLabel(t, "outcome", data.ended.outcome), reason = reasonLabel(t, data.ended.reason), time = when(data.ended.at, t("lang"));
				return reason ? t("endedAt", {
					time,
					outcome,
					reason
				}) : t("endedAtShort", {
					time,
					outcome
				});
			})();
			const channel = data.channels[0];
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [
				/* @__PURE__ */ (0, react_jsx_runtime.jsxs)(PageHead, {
					title: data.title,
					children: [
						opening?.url && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ActionLink, {
							href: opening.url,
							children: t("openThread", { source: valueLabel(t, "source", opening.source) })
						}),
						data.actions.retry && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ConfirmButton, {
							variant: "outline",
							icon: "refresh",
							label: t("retry"),
							title: t("retryTitle"),
							message: t("retryConfirm", { title: data.title }),
							onConfirm: () => after(call("POST tickets/:id/retry", { id }))
						}),
						data.sessionId && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SessionButton, {
							variant: "outline",
							sessionId: data.sessionId
						})
					]
				}),
				error && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LoadState, {
					error,
					loading: false
				}),
				/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-row-meta dt-status-line",
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)(StageMark, {
							state: status.dot,
							icon: status.icon,
							label: status.label
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)(LabelValue, {
							label: t("ticketMandateLabel"),
							value: valueLabel(t, "strength", data.mandate.strength)
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)(LabelValue, {
							label: t("ticketActorLabel"),
							value: `${valueLabel(t, "source", data.mandate.actor.source)} · ${actor}`
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)(LabelValue, {
							label: t("ticketUpdatedLabel"),
							value: when(data.updatedAt, t("lang"))
						})
					]
				}),
				ended && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: ended }),
				data.attention && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-banner",
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
							className: "dt-banner-label",
							children: t("attentionPrefix")
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)(MarkdownLite, { text: data.attention.question }),
						channel && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
							className: "dt-banner-actions",
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ActionLink, {
								href: channel.url,
								icon: "message",
								children: t("answerIn", { source: valueLabel(t, "source", channel.source) })
							})
						})
					]
				}),
				data.actions.retry && data.summary && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("p", {
					className: `dt-banner${failed ? " dt-danger" : ""}${failedText ? " dt-mono" : ""}`,
					children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
						className: "dt-banner-label",
						children: t(failed ? "failedPrefix" : "blockedPrefix")
					}), data.summary]
				}),
				data.deliveryError && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("p", {
					className: "dt-banner dt-danger dt-mono",
					children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
						className: "dt-banner-label",
						children: t("deliveryFailedPrefix")
					}), data.deliveryError]
				}),
				/* @__PURE__ */ (0, react_jsx_runtime.jsx)(MandateDetails, {
					ticket: data,
					actor
				}),
				undelivered.length > 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(Section, {
					title: t("undeliveredInputs"),
					count: undelivered.length,
					children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: data.deliveryError ? t("inputRetryHint") : data.paused ? t("inputPausedHint") : t("inputWaitingHint") }), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(InputList, { inputs: undelivered })]
				}),
				data.threads.length > 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Section, {
					title: t("subscribedThreads"),
					count: data.threads.length,
					children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
						className: "dt-list",
						children: data.threads.map((thread) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ThreadLine, {
							thread,
							ticketId: data.id,
							context: thread.context
						}, thread.key))
					})
				}),
				/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-details",
					children: [
						data.assignments.length > 1 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Details, {
							icon: "queue",
							title: `${t("term.assignment")} · ${data.assignments.length}`,
							open: true,
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Assignments, { ticket: data })
						}),
						data.environment.length > 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Details, {
							icon: "settings",
							title: t("term.environment"),
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("table", {
								className: "dt-table",
								children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("tbody", { children: data.environment.map((variable) => /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("tr", {
									title: localized(t, variable.description),
									children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("td", {
										className: "dt-mono",
										children: variable.key
									}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("td", {
										className: "dt-mono",
										children: variable.value || /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
											className: "dt-hint",
											children: t("empty")
										})
									})]
								}, variable.key)) })
							})
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Details, {
							icon: "message",
							title: t("term.channel"),
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
								className: "dt-plain-list",
								children: data.channels.map((item, index) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)("li", { children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ExternalLink, {
									href: item.url,
									icon: item.source === "github" ? "pull" : "message",
									children: localized(t, item.label)
								}) }, index))
							})
						}),
						data.inputs.length > undelivered.length && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Details, {
							icon: "inbox",
							title: t("deliveredInputs", { count: data.inputs.length - undelivered.length }),
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(InputList, { inputs: data.inputs.filter((input) => input.delivered) })
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Details, {
							icon: "hash",
							title: t("identifiers"),
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(KeyValues, { rows: [
								[t("ticketId"), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
									className: "dt-mono",
									children: data.id
								})],
								[t("executionDirectory"), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
									className: "dt-mono",
									children: data.directory ?? t("empty")
								})],
								...legacy && data.mandate.scope ? [[t("legacyAssignment"), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
									className: "dt-mono dt-clamp",
									children: data.mandate.scope
								})]] : []
							] })
						})
					]
				}),
				data.actions.stop && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-danger-zone",
					children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
						className: "dt-hint",
						children: t("stopHint")
					}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ConfirmButton, {
						variant: "outline",
						label: t("stop"),
						title: t("stopConfirmTitle"),
						message: t("stopConfirm", { title: data.title }),
						onConfirm: () => after(call("POST tickets/:id/stop", { id }))
					})]
				})
			] });
		}
		//#endregion
		//#region src/client/trigger.tsx
		/** Trigger status view listing Threads filtered by subscription and evaluation activity. */
		function TriggerStatus({ filter }) {
			const { t, call, navigate } = usePanel();
			const [limit, setLimit] = (0, react.useState)(20);
			const { data, error } = usePoll(() => call("GET threads", { query: {
				filter,
				limit
			} }), [filter, limit]);
			const go = (next) => {
				setLimit(20);
				navigate({
					page: "trigger",
					query: next !== "subscribed" ? { filter: next } : {}
				}, true);
			};
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [
				/* @__PURE__ */ (0, react_jsx_runtime.jsx)(StatusHead, { hint: t("triggerIntro") }),
				/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
					className: "dt-filters",
					children: THREAD_FILTERS.map((value) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Pill, {
						active: filter === value,
						onClick: () => go(value),
						children: t(`threadFilter.${value}`)
					}, value))
				}),
				/* @__PURE__ */ (0, react_jsx_runtime.jsx)(LoadState, {
					error,
					loading: !data
				}),
				data && (data.items.length ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
					className: "dt-list",
					children: data.items.map((thread) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ThreadLine, { thread }, thread.key))
				}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Hint, { children: t("threadsNone") })),
				data?.next_offset != null && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(LoadMore, { onMore: () => setLimit(limit + 20) })
			] });
		}
		//#endregion
		//#region src/client/app.tsx
		/** Root panel shell: header with global search and glossary, top-level navigation tabs, and active route view. */
		function Glossary({ open, onClose }) {
			const { t } = usePanel();
			const chinese = t("tab.overview") === zh["tab.overview"];
			const [own, other] = chinese ? [zh, en] : [en, zh];
			const heading = (group) => t(group === "roles" ? "glossaryGroup.roles" : `tab.${group}`);
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Modal, {
				className: "dt-glossary-modal",
				open,
				onClose,
				title: t("glossary"),
				closeLabel: t("close"),
				description: t("glossaryIntro"),
				footer: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
					variant: "primary",
					onClick: onClose,
					children: t("close")
				}),
				children: /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-glossary-body",
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("table", {
							className: "dt-glossary",
							children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("thead", { children: /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("tr", { children: [
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)("th", { children: t(chinese ? "glossaryChinese" : "glossaryEnglish") }),
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)("th", { children: t(chinese ? "glossaryEnglish" : "glossaryChinese") }),
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)("th", { children: t("glossaryMeaning") })
							] }) }), Object.entries(GLOSSARY).map(([group, keys]) => /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("tbody", { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("tr", { children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("th", {
								colSpan: 3,
								scope: "rowgroup",
								className: "dt-glossary-group",
								children: heading(group)
							}) }), keys.map((key) => /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("tr", { children: [
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)("td", { children: own[`term.${key}`] }),
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)("td", { children: other[`term.${key}`] }),
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)("td", { children: own[`meaning.${key}`] })
							] }, key))] }, group))]
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
							className: "dt-legend-title",
							children: t("legendTitle")
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("ul", {
							className: "dt-legend",
							children: [
								"done",
								"ongoing",
								"warning",
								"error",
								"idle"
							].map((state) => /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("li", { children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Dot, { state }), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { children: t(`legend.${state}`) })] }, state))
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("dl", {
							className: "dt-values",
							children: Object.entries(GLOSSARY_VALUES).map(([group, values]) => /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
								style: { display: "contents" },
								children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("dt", { children: own[`term.${group}`] }), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("dd", { children: values.map((key) => `${own[key]} ${other[key]}`).join(" · ") })]
							}, group))
						})
					]
				})
			});
		}
		function Highlight({ text, query }) {
			const index = query ? text.toLowerCase().indexOf(query.toLowerCase()) : -1;
			if (index < 0) return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(react_jsx_runtime.Fragment, { children: text });
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [
				text.slice(0, index),
				/* @__PURE__ */ (0, react_jsx_runtime.jsx)("mark", {
					className: "dt-mark",
					children: text.slice(index, index + query.length)
				}),
				text.slice(index + query.length)
			] });
		}
		function Result({ name, open, children }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("li", {
				className: "dt-row dt-link",
				children: /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-row-main",
					children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
						className: "dt-row-title",
						children: open ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("button", {
							type: "button",
							className: "dt-open",
							onClick: open,
							children: name
						}) : name
					}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
						className: "dt-row-meta",
						children
					})]
				})
			});
		}
		function SearchResults({ result, query, onClose }) {
			const { t, navigate } = usePanel();
			const { setup } = usePanelData();
			const empty = !result.items.length && !result.threads.length && !result.tickets.length;
			const counts = {
				tickets: result.tickets.length,
				threads: result.threads.length,
				items: result.items.length
			};
			const go = (route) => () => {
				onClose();
				navigate(route);
			};
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
				className: "dt-search-results",
				role: "region",
				"aria-label": t("searchLabel"),
				children: [/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-search-head",
					children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
						className: "dt-hint",
						children: empty ? t(setup?.accounts?.feishu ? "searchNone" : "searchNoneGithub") : t(result.items.length >= 20 ? "searchFoundCapped" : "searchFound", counts)
					}), /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
						variant: "ghost",
						size: "sm",
						icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, {
							name: "close",
							size: 14
						}),
						"aria-label": t("close"),
						onClick: onClose
					})]
				}), !empty && /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("ul", {
					className: "dt-list",
					children: [
						result.tickets.map((ticket) => /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(Result, {
							name: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Highlight, {
								text: ticket.title,
								query
							}),
							open: go({
								page: "execution",
								id: ticket.id
							}),
							children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { children: t("term.ticket") }), /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { children: ticket.stage === "ended" ? t("ticket.ended") : ticketMark(t, ticket).label })]
						}, ticket.id)),
						result.threads.map((thread) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Result, {
							name: readableMarkers(t, thread.title),
							open: go({
								page: "trigger",
								id: thread.key
							}),
							children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { children: t("term.thread") })
						}, thread.key)),
						result.items.map((item) => /* @__PURE__ */ (0, react_jsx_runtime.jsxs)(Result, {
							name: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Highlight, {
								text: readableMarkers(t, item.preview) || t("empty"),
								query
							}),
							open: item.filtered === void 0 ? go({
								page: "trigger",
								id: item.threads[0],
								query: { trigger: item.id }
							}) : void 0,
							children: [
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { children: valueLabel(t, "source", item.source) }),
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { children: actorName(t, item.actor) }),
								/* @__PURE__ */ (0, react_jsx_runtime.jsx)(When, { at: item.at }),
								item.threadTitle && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {
									className: "dt-ellipsis",
									children: t("inThread", { thread: readableMarkers(t, item.threadTitle) })
								}),
								item.filtered !== void 0 && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", { children: t("searchFiltered", { reason: reasonLabel(t, item.filtered) }) })
							]
						}, item.id))
					]
				})]
			});
		}
		function Header({ masterId }) {
			const { t, call, openSession, notify } = usePanel();
			const [glossary, setGlossary] = (0, react.useState)(false);
			const [query, setQuery] = (0, react.useState)("");
			const [result, setResult] = (0, react.useState)();
			const latest = (0, react.useRef)(0);
			const show = (value) => {
				latest.current++;
				setResult(value);
			};
			const search = (0, react.useRef)(null);
			(0, react.useEffect)(() => {
				if (!result) return;
				const close = (event) => {
					if (!search.current?.contains(event.target)) show();
				};
				document.addEventListener("pointerdown", close);
				return () => {
					document.removeEventListener("pointerdown", close);
				};
			}, [result]);
			const submit = (event) => {
				event.preventDefault();
				const text = query.trim();
				if (!text) {
					show();
					return;
				}
				const request = ++latest.current;
				call("GET search", { query: { q: text } }).then((value) => {
					if (request === latest.current) setResult({
						query: text,
						value
					});
				}, (failure) => {
					if (request === latest.current) notify(errorText(failure));
				});
			};
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("header", {
				className: "dt-head",
				children: [
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
						className: "dt-head-title",
						children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)("h1", {
							className: "dt-title",
							children: t("title")
						})
					}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
						className: "dt-toolbar",
						children: [
							/* @__PURE__ */ (0, react_jsx_runtime.jsxs)("form", {
								ref: search,
								className: "dt-search",
								role: "search",
								onSubmit: submit,
								onKeyDown: (event) => {
									if (event.key === "Escape") show();
								},
								children: [/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Input, {
									type: "search",
									icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "search" }),
									value: query,
									placeholder: t("searchPlaceholder"),
									"aria-label": t("searchLabel"),
									onChange: (event) => {
										setQuery(event.target.value);
										if (!event.target.value) show();
									}
								}), result && /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SearchResults, {
									result: result.value,
									query: result.query,
									onClose: () => {
										show();
									}
								})]
							}),
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
								variant: "ghost",
								size: "sm",
								icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, { name: "question" }),
								"aria-label": t("glossary"),
								title: t("glossary"),
								"aria-haspopup": "dialog",
								onClick: () => setGlossary(true)
							}),
							/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Button, {
								variant: "outline",
								size: "sm",
								icon: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Icon, {
									name: "session",
									size: 14
								}),
								disabled: !masterId,
								onClick: () => {
									if (masterId) openSession(masterId).catch((failure) => notify(errorText(failure)));
								},
								children: t("openMaster")
							})
						]
					}),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Glossary, {
						open: glossary,
						onClose: () => setGlossary(false)
					})
				]
			});
		}
		function Pages({ route, openTab, deploymentForm }) {
			const { t } = usePanel();
			const { state, error, reload } = usePanelData();
			(0, react.useEffect)(() => {
				document.getElementById(`dt-tab-${route.page}`)?.scrollIntoView?.({
					block: "nearest",
					inline: "nearest"
				});
			}, [route.page]);
			const waiting = error ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
				className: "dt-error",
				role: "alert",
				children: error.message
			}) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
				className: "dt-hint",
				children: t("loading")
			});
			const page = (() => {
				switch (route.page) {
					case "overview": return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(OverviewPage, {});
					case "source": return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SourceStatus, {});
					case "trigger": return route.id !== void 0 ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ThreadPage, {
						id: route.id,
						target: route.query?.trigger
					}, route.id) : /* @__PURE__ */ (0, react_jsx_runtime.jsx)(TriggerStatus, { filter: route.query?.filter ?? "subscribed" });
					case "eval": return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(EvalStatus, {
						filter: route.query?.filter ?? "work",
						window: route.query?.window,
						paused: !!state?.paused
					});
					case "execution": return route.id !== void 0 ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(TicketPage, { id: route.id }, route.id) : state ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(ExecutionStatus, {
						filter: route.query?.filter ?? "open",
						state,
						reload
					}) : waiting;
					case "settings": return state ? /* @__PURE__ */ (0, react_jsx_runtime.jsx)(SettingsPage, {
						group: route.query.group,
						query: route.query,
						state,
						deploymentForm
					}, state.masterId) : waiting;
				}
			})();
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)("div", {
				className: "dt-page",
				children: /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("div", {
					className: "dt-column",
					children: [
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)(Header, { masterId: state?.masterId }),
						error && state && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("p", {
							className: "dt-error",
							role: "status",
							children: error.message
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)(SegmentedTabs, {
							className: "dt-tabs",
							label: t("pagesLabel"),
							value: route.page,
							onChange: openTab,
							items: TABS.map((value) => ({
								value,
								label: t(`tab.${value}`),
								id: `dt-tab-${value}`,
								panelId: "dt-page"
							}))
						}),
						/* @__PURE__ */ (0, react_jsx_runtime.jsx)("main", {
							id: "dt-page",
							role: "tabpanel",
							"aria-labelledby": `dt-tab-${route.page}`,
							className: "dt-main",
							children: page
						})
					]
				})
			});
		}
		/** Root panel component managing route history and shared panel state. */
		function App({ t, openSession, deploymentForm }) {
			const [location, setLocation] = (0, react.useState)(initialLocation);
			(0, react.useEffect)(() => {
				remember(location);
			}, [location]);
			const move = (0, react.useCallback)((next) => setLocation((current) => ({
				...next(current),
				group: lastSettingsGroup(current)
			})), []);
			/** Navigates to `route`; `replace` swaps the current entry (filters, paging) instead of pushing a back step. */
			const navigate = (0, react.useCallback)((route, replace = false) => move((current) => ({
				route,
				stack: replace ? current.stack : [...current.stack, current.route].slice(-20)
			})), [move]);
			const back = (0, react.useCallback)(() => move((current) => ({
				route: current.stack.at(-1) ?? HOME,
				stack: current.stack.slice(0, -1)
			})), [move]);
			const openTab = (0, react.useCallback)((tab) => move((current) => ({
				stack: [],
				route: tab === "settings" ? settingsRoute(lastSettingsGroup(current)) : {
					page: tab,
					id: void 0
				}
			})), [move]);
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(PanelProvider, {
				t,
				openSession,
				navigate,
				back,
				backLabel: routeLabel(t, location.stack.at(-1) ?? HOME),
				children: /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Pages, {
					route: location.route,
					openTab,
					deploymentForm
				})
			});
		}
		//#endregion
		//#region src/client/index.tsx
		/** Browser plugin entry point registering the sidebar icon, main management panel, and Plugin Manager config view. */
		const NS = "dshSuperagent";
		const PANEL_ID = "dsh-superagent";
		const ENTRY = "dsh-superagent";
		function HammerIcon({ size }) {
			return /* @__PURE__ */ (0, react_jsx_runtime.jsxs)("svg", {
				width: size,
				height: size,
				viewBox: "0 0 24 24",
				fill: "none",
				stroke: "currentColor",
				strokeWidth: 1.8,
				strokeLinecap: "round",
				strokeLinejoin: "round",
				"aria-hidden": true,
				children: [
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)("path", { d: "M6 3.5h9l3.5 1.75v2.5L15 9.5H6a1 1 0 0 1-1-1v-4a1 1 0 0 1 1-1z" }),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)("path", { d: "M10 9.5v10.25a1.75 1.75 0 0 0 3.5 0V9.5" }),
					/* @__PURE__ */ (0, react_jsx_runtime.jsx)("path", { d: "M10 15.5h3.5" })
				]
			});
		}
		/** Mounted panel wrapper; cancels any pending Session navigation when a new one starts or the panel unmounts. */
		function Mounted({ ctx, t }) {
			const pending = (0, react.useRef)(void 0);
			(0, react.useEffect)(() => () => {
				pending.current?.abort();
			}, []);
			const openSession = (0, react.useCallback)(async (id) => {
				pending.current?.abort();
				const request = new AbortController();
				pending.current = request;
				try {
					await openKnownSession(ctx.sessions, id, (target) => {
						ctx.uiWorkspace.openSession(target);
					}, request.signal);
				} catch (error) {
					if (error instanceof SessionNavigationError) throw new Error(t(error.code === "not-ready" ? "sessionListNotReady" : "sessionNotListed"));
					throw error;
				}
			}, [ctx, t]);
			const form = usePageForm(ctx.get("configForms")?.get(ENTRY));
			return /* @__PURE__ */ (0, react_jsx_runtime.jsx)(App, {
				t,
				openSession,
				deploymentForm: form
			});
		}
		const inject = [
			"slots",
			"locale",
			"sessions",
			"uiWorkspace"
		];
		/** Registers the panel, sidebar icon, and Plugin Manager config view; `configForms` is optional (without it, machine settings are read-only). */
		function apply(ctx) {
			ctx.effect(() => ctx.locale.register(NS, {
				zh,
				en
			}), "dsh-superagent: dictionaries");
			const t = ctx.locale.bind(NS);
			ctx.slots.inject("main", () => ctx.slots.register({
				name: "main",
				key: PANEL_ID,
				locale: NS,
				inject: () => ({})
			}, (props) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(Mounted, {
				ctx,
				t: props.t
			})));
			ctx.slots.inject("sidebar.panellist", () => ctx.slots.register({
				name: "sidebar.panellist",
				id: PANEL_ID,
				order: 10,
				label: () => t("panel"),
				locale: NS
			}, HammerIcon));
			ctx.slots.inject("plugins.row.config", () => ctx.slots.register({
				name: "plugins.row.config",
				key: `${ENTRY}#${ENTRY}`,
				locale: NS
			}, (props) => /* @__PURE__ */ (0, react_jsx_runtime.jsx)(PluginConfig, {
				t: props.t,
				view: props.view,
				form: props.form
			})));
		}
		//#endregion
		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});
