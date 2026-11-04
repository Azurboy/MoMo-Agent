import EventKit
import Foundation

final class DesktopPIMDriver: @unchecked Sendable {
    private let store = EKEventStore()
    private let lock = NSLock()

    func perform(op: String, argsData: Data) async throws -> Data {
        let args = (try JSONSerialization.jsonObject(with: argsData) as? [String: Any]) ?? [:]
        let result = try await perform(op: op, args: args)
        return try JSONSerialization.data(withJSONObject: result)
    }

    func perform(op: String, args: [String: Any]) async throws -> [String: Any] {
        switch op {
        case "list_reminder_lists", "search_reminders", "read_reminder",
             "create_reminder", "update_reminder", "complete_reminder", "delete_reminder":
            return try await performReminders(op: op, args: args)
        case "list_calendars", "search_calendar_events", "read_calendar_event",
             "create_calendar_event", "update_calendar_event", "delete_calendar_event":
            return try await performCalendar(op: op, args: args)
        case "list_note_folders", "search_notes", "read_note",
             "create_note", "update_note", "delete_note":
            return try await performNotes(op: op, args: args)
        default:
            throw DesktopError.message("未知的个人事项操作：\(op)")
        }
    }

    // MARK: - Reminders (EventKit)

    private func ensureRemindersAccess(isWrite: Bool, op: String) async throws -> [String: Any]? {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        let granted: Bool
        switch status {
        case .fullAccess, .authorized:
            granted = true
        case .writeOnly:
            granted = false
        case .notDetermined:
            granted = (try? await store.requestFullAccessToReminders()) ?? false
        case .denied, .restricted:
            granted = false
        @unknown default:
            granted = false
        }
        guard !granted else { return nil }
        let msg = "请在 Mac「系统设置 -> 隐私与安全性 -> 提醒事项」中允许 MoMo Agent 访问提醒事项。"
        if isWrite {
            return Self.failureReceipt(state: "needs_permission", kind: "reminder", error: msg)
        }
        throw DesktopError.message(msg)
    }

    private func performReminders(op: String, args: [String: Any]) async throws -> [String: Any] {
        let writeOps: Set<String> = ["create_reminder", "update_reminder", "complete_reminder", "delete_reminder"]
        if let denied = try await ensureRemindersAccess(isWrite: writeOps.contains(op), op: op) {
            return denied
        }

        switch op {
        case "list_reminder_lists":
            let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
            let lists = store.calendars(for: .reminder).map { cal -> [String: Any] in
                [
                    "id": cal.calendarIdentifier,
                    "title": cal.title,
                    "source": cal.source?.title ?? "",
                    "allows_modifications": cal.allowsContentModifications,
                    "is_default": cal.calendarIdentifier == defaultID
                ]
            }
            return ["ok": true, "lists": lists]

        case "search_reminders":
            let calendars = resolveReminderCalendars(listID: args["list_id"] as? String, listName: args["list_name"] as? String)
            let status = (args["status"] as? String ?? "incomplete").lowercased()
            let predicate: NSPredicate
            switch status {
            case "completed":
                predicate = store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: calendars)
            case "all":
                predicate = store.predicateForReminders(in: calendars)
            default:
                predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
            }
            let reminders = await fetchReminders(matching: predicate)
            let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let limit = min(100, max(1, Self.intArg(args["limit"]) ?? 30))
            var matched: [[String: Any]] = []
            for item in reminders {
                let title = item.title ?? ""
                let notes = item.notes ?? ""
                if !query.isEmpty && !title.lowercased().contains(query) && !notes.lowercased().contains(query) {
                    continue
                }
                matched.append(Self.serializeReminder(item))
                if matched.count >= limit { break }
            }
            return ["ok": true, "items": matched, "count": matched.count]

        case "read_reminder":
            guard let id = (args["reminder_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
                throw DesktopError.message("缺少 reminder_id。")
            }
            guard let item = findReminder(id: id) else {
                throw DesktopError.message("未找到指定的待办事项（\(id)）。")
            }
            return ["ok": true, "item": Self.serializeReminder(item)]

        case "create_reminder":
            let title = (args["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return Self.failureReceipt(state: "needs_clarification", kind: "reminder", error: "待办标题不能为空。")
            }
            guard let calendar = resolveTargetCalendar(
                entityType: .reminder,
                id: args["list_id"] as? String,
                name: args["list_name"] as? String,
                fallback: store.defaultCalendarForNewReminders()
            ) else {
                return Self.failureReceipt(state: "failed", kind: "reminder", error: "未找到可写入的提醒事项列表。")
            }
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = calendar
            reminder.title = title
            if let notes = args["notes"] as? String, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reminder.notes = notes
            }
            if let priority = Self.intArg(args["priority"]), (0...9).contains(priority) {
                reminder.priority = priority
            }
            if let dueRaw = (args["due_at"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !dueRaw.isEmpty {
                guard let parsed = Self.parseDateInput(dueRaw) else {
                    return Self.failureReceipt(state: "needs_clarification", kind: "reminder", error: "无法解析截止时间：\(dueRaw)")
                }
                reminder.dueDateComponents = parsed.components
                if !parsed.dateOnly && args["remind_at"] == nil {
                    reminder.addAlarm(EKAlarm(absoluteDate: parsed.date))
                }
            }
            if let remindRaw = (args["remind_at"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !remindRaw.isEmpty,
               let remindParsed = Self.parseDateInput(remindRaw) {
                reminder.alarms = [EKAlarm(absoluteDate: remindParsed.date)]
            }
            do {
                try lockedSaveReminder(reminder, commit: true)
            } catch {
                return Self.failureReceipt(state: "failed", kind: "reminder", error: error.localizedDescription)
            }
            let serialized = Self.serializeReminder(reminder)
            return Self.successReceipt(kind: "reminder", id: reminder.calendarItemIdentifier, fields: Self.reminderReceiptFields(serialized), item: serialized)

        case "update_reminder":
            let id = (args["reminder_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, let reminder = findReminder(id: id) else {
                return Self.failureReceipt(state: "failed", kind: "reminder", error: "未找到要修改的待办事项。")
            }
            if let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                reminder.title = title
            }
            if let notes = args["notes"] as? String {
                reminder.notes = notes.isEmpty ? nil : notes
            }
            if let priority = Self.intArg(args["priority"]), (0...9).contains(priority) {
                reminder.priority = priority
            }
            if args["list_id"] != nil || args["list_name"] != nil,
               let cal = resolveTargetCalendar(entityType: .reminder, id: args["list_id"] as? String, name: args["list_name"] as? String, fallback: nil) {
                reminder.calendar = cal
            }
            if let dueRaw = args["due_at"] as? String {
                let trimmed = dueRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    reminder.dueDateComponents = nil
                    reminder.alarms = nil
                } else if let parsed = Self.parseDateInput(trimmed) {
                    reminder.dueDateComponents = parsed.components
                    if !parsed.dateOnly {
                        reminder.alarms = [EKAlarm(absoluteDate: parsed.date)]
                    } else {
                        reminder.alarms = nil
                    }
                } else {
                    return Self.failureReceipt(state: "needs_clarification", kind: "reminder", error: "无法解析截止时间：\(trimmed)")
                }
            }
            if let completed = args["completed"] as? Bool {
                reminder.isCompleted = completed
                reminder.completionDate = completed ? Date() : nil
            }
            do {
                try lockedSaveReminder(reminder, commit: true)
            } catch {
                return Self.failureReceipt(state: "failed", kind: "reminder", error: error.localizedDescription)
            }
            let serialized = Self.serializeReminder(reminder)
            return Self.successReceipt(kind: "reminder", id: reminder.calendarItemIdentifier, fields: Self.reminderReceiptFields(serialized), item: serialized)

        case "complete_reminder":
            let id = (args["reminder_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, let reminder = findReminder(id: id) else {
                return Self.failureReceipt(state: "failed", kind: "reminder", error: "未找到要更新完成状态的待办事项。")
            }
            let completed = (args["completed"] as? Bool) ?? true
            reminder.isCompleted = completed
            reminder.completionDate = completed ? Date() : nil
            do {
                try lockedSaveReminder(reminder, commit: true)
            } catch {
                return Self.failureReceipt(state: "failed", kind: "reminder", error: error.localizedDescription)
            }
            let serialized = Self.serializeReminder(reminder)
            return Self.successReceipt(kind: "reminder", id: reminder.calendarItemIdentifier, fields: Self.reminderReceiptFields(serialized), item: serialized)

        case "delete_reminder":
            let id = (args["reminder_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, let reminder = findReminder(id: id) else {
                return Self.failureReceipt(state: "failed", kind: "reminder", error: "未找到要删除的待办事项。")
            }
            let serialized = Self.serializeReminder(reminder)
            let itemID = reminder.calendarItemIdentifier
            do {
                try lockedRemoveReminder(reminder, commit: true)
            } catch {
                return Self.failureReceipt(state: "failed", kind: "reminder", error: error.localizedDescription)
            }
            return Self.successReceipt(kind: "reminder", id: itemID, fields: Self.reminderReceiptFields(serialized), item: serialized)

        default:
            throw DesktopError.message("未知的提醒事项操作：\(op)")
        }
    }

    // MARK: - Calendar (EventKit)

    private func ensureCalendarAccess(isWrite: Bool) async throws -> [String: Any]? {
        let status = EKEventStore.authorizationStatus(for: .event)
        let granted: Bool
        switch status {
        case .fullAccess, .authorized:
            granted = true
        case .writeOnly:
            granted = false
        case .notDetermined:
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        case .denied, .restricted:
            granted = false
        @unknown default:
            granted = false
        }
        guard !granted else { return nil }
        let msg = "请在 Mac「系统设置 -> 隐私与安全性 -> 日历」中允许 MoMo Agent 访问日历。"
        if isWrite {
            return Self.failureReceipt(state: "needs_permission", kind: "event", error: msg)
        }
        throw DesktopError.message(msg)
    }

    private func performCalendar(op: String, args: [String: Any]) async throws -> [String: Any] {
        let writeOps: Set<String> = ["create_calendar_event", "update_calendar_event", "delete_calendar_event"]
        if let denied = try await ensureCalendarAccess(isWrite: writeOps.contains(op)) {
            return denied
        }

        switch op {
        case "list_calendars":
            let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
            let calendars = store.calendars(for: .event).map { cal -> [String: Any] in
                [
                    "id": cal.calendarIdentifier,
                    "title": cal.title,
                    "source": cal.source?.title ?? "",
                    "allows_modifications": cal.allowsContentModifications,
                    "is_default": cal.calendarIdentifier == defaultID
                ]
            }
            return ["ok": true, "calendars": calendars]

        case "search_calendar_events":
            let now = Date()
            let start = ((args["start_at"] as? String).flatMap { Self.parseDateInput($0)?.date }) ?? now.addingTimeInterval(-86400)
            let end = ((args["end_at"] as? String).flatMap { Self.parseDateInput($0)?.date }) ?? start.addingTimeInterval(14 * 86400)
            let calendars = resolveEventCalendars(calendarID: args["calendar_id"] as? String, calendarName: args["calendar_name"] as? String)
            let predicate = store.predicateForEvents(withStart: start, end: max(end, start.addingTimeInterval(60)), calendars: calendars)
            let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
            let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let limit = min(100, max(1, Self.intArg(args["limit"]) ?? 30))
            var items: [[String: Any]] = []
            for ev in events {
                let hay = "\(ev.title ?? "") \(ev.location ?? "") \(ev.notes ?? "")".lowercased()
                if !query.isEmpty && !hay.contains(query) { continue }
                items.append(Self.serializeEvent(ev))
                if items.count >= limit { break }
            }
            return ["ok": true, "items": items, "count": items.count]

        case "read_calendar_event":
            guard let id = (args["event_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                  let ev = findEvent(id: id) else {
                throw DesktopError.message("未找到指定的日程。")
            }
            return ["ok": true, "item": Self.serializeEvent(ev)]

        case "create_calendar_event":
            let title = (args["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return Self.failureReceipt(state: "needs_clarification", kind: "event", error: "日程标题不能为空。")
            }
            guard let startRaw = (args["start_at"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let startParsed = Self.parseDateInput(startRaw) else {
                return Self.failureReceipt(state: "needs_clarification", kind: "event", error: "请提供有效的开始时间（start_at）。")
            }
            guard let calendar = resolveTargetCalendar(
                entityType: .event,
                id: args["calendar_id"] as? String,
                name: args["calendar_name"] as? String,
                fallback: store.defaultCalendarForNewEvents
            ) else {
                return Self.failureReceipt(state: "failed", kind: "event", error: "未找到可写入的日历。")
            }
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = title
            let isAllDay = (args["all_day"] as? Bool) ?? startParsed.dateOnly
            event.isAllDay = isAllDay
            event.startDate = startParsed.date
            if let endRaw = (args["end_at"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !endRaw.isEmpty,
               let endParsed = Self.parseDateInput(endRaw) {
                event.endDate = max(endParsed.date, startParsed.date)
            } else {
                event.endDate = isAllDay ? startParsed.date : startParsed.date.addingTimeInterval(3600)
            }
            if let loc = (args["location"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !loc.isEmpty {
                event.location = loc
            }
            if let notes = (args["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                event.notes = notes
            }
            if let alertMinutes = Self.intArg(args["alert_minutes_before"]), alertMinutes >= 0 {
                event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-alertMinutes * 60)))
            }
            do {
                try lockedSaveEvent(event, commit: true)
            } catch {
                return Self.failureReceipt(state: "failed", kind: "event", error: error.localizedDescription)
            }
            let serialized = Self.serializeEvent(event)
            return Self.successReceipt(kind: "event", id: event.eventIdentifier ?? "", fields: Self.eventReceiptFields(serialized), item: serialized)

        case "update_calendar_event":
            let id = (args["event_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, let event = findEvent(id: id) else {
                return Self.failureReceipt(state: "failed", kind: "event", error: "未找到要修改的日程。")
            }
            if let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                event.title = title
            }
            if let allDay = args["all_day"] as? Bool {
                event.isAllDay = allDay
            }
            if let startRaw = (args["start_at"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !startRaw.isEmpty {
                guard let parsed = Self.parseDateInput(startRaw) else {
                    return Self.failureReceipt(state: "needs_clarification", kind: "event", error: "无法解析开始时间：\(startRaw)")
                }
                let duration = max(0, (event.endDate ?? parsed.date).timeIntervalSince(event.startDate ?? parsed.date))
                event.startDate = parsed.date
                if args["end_at"] == nil {
                    event.endDate = parsed.date.addingTimeInterval(duration > 0 ? duration : 3600)
                }
            }
            if let endRaw = (args["end_at"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !endRaw.isEmpty {
                guard let parsed = Self.parseDateInput(endRaw) else {
                    return Self.failureReceipt(state: "needs_clarification", kind: "event", error: "无法解析结束时间：\(endRaw)")
                }
                event.endDate = max(parsed.date, event.startDate)
            }
            if let loc = args["location"] as? String {
                event.location = loc.isEmpty ? nil : loc
            }
            if let notes = args["notes"] as? String {
                event.notes = notes.isEmpty ? nil : notes
            }
            if args["calendar_id"] != nil || args["calendar_name"] != nil,
               let cal = resolveTargetCalendar(entityType: .event, id: args["calendar_id"] as? String, name: args["calendar_name"] as? String, fallback: nil) {
                event.calendar = cal
            }
            do {
                try lockedSaveEvent(event, commit: true)
            } catch {
                return Self.failureReceipt(state: "failed", kind: "event", error: error.localizedDescription)
            }
            let serialized = Self.serializeEvent(event)
            return Self.successReceipt(kind: "event", id: event.eventIdentifier ?? "", fields: Self.eventReceiptFields(serialized), item: serialized)

        case "delete_calendar_event":
            let id = (args["event_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, let event = findEvent(id: id) else {
                return Self.failureReceipt(state: "failed", kind: "event", error: "未找到要删除的日程。")
            }
            let serialized = Self.serializeEvent(event)
            let eventID = event.eventIdentifier ?? id
            do {
                try lockedRemoveEvent(event, commit: true)
            } catch {
                return Self.failureReceipt(state: "failed", kind: "event", error: error.localizedDescription)
            }
            return Self.successReceipt(kind: "event", id: eventID, fields: Self.eventReceiptFields(serialized), item: serialized)

        default:
            throw DesktopError.message("未知的日历操作：\(op)")
        }
    }

    // MARK: - Notes (JXA via NSAppleEventsUsageDescription)

    private struct NotesJXARunResult: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    private func performNotes(op: String, args: [String: Any]) async throws -> [String: Any] {
        let payloadData = try JSONSerialization.data(withJSONObject: ["op": op, "args": args])
        guard let payloadString = String(data: payloadData, encoding: .utf8) else {
            throw DesktopError.message("无法编码备忘录请求。")
        }
        let result = try await Task.detached {
            try Self.runNotesJXAProcess(payloadString: payloadString)
        }.value
        if result.status != 0 {
            if result.stderr.contains("-1743") || result.stderr.lowercased().contains("not authorized") {
                let msg = "请在 Mac「系统设置 -> 隐私与安全性 -> 自动化」中允许 MoMo Agent 控制「备忘录」。"
                return Self.failureReceipt(state: "needs_permission", kind: "note", error: msg)
            }
            throw DesktopError.message("备忘录操作失败：\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard let parsed = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw DesktopError.message("无法解析备忘录返回数据。")
        }
        if (parsed["ok"] as? Bool) == false {
            if let st = parsed["state"] as? String {
                return Self.failureReceipt(state: st, kind: "note", error: parsed["error"] as? String ?? "备忘录操作未完成。")
            }
            throw DesktopError.message(parsed["error"] as? String ?? "备忘录操作未完成。")
        }
        if ["create_note", "update_note", "delete_note"].contains(op), let item = parsed["item"] as? [String: Any] {
            let fields: [String: Any] = [
                "title": item["title"] as? String ?? "",
                "folder": item["folder"] as? String ?? ""
            ]
            return Self.successReceipt(kind: "note", id: item["id"] as? String ?? "", fields: fields, item: item)
        }
        return parsed
    }

    private static func runNotesJXAProcess(payloadString: String) throws -> NotesJXARunResult {
        let script = #"""
        ObjC.import('Foundation');
        function escHtml(s) {
          return String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
        }
        function toNoteHtml(title, body) {
          const t = escHtml(title);
          const raw = String(body || '');
          const hasHtml = /<(?:div|p|ul|ol|li|h[1-6]|br|b|i|strong|em)\b/i.test(raw);
          const rendered = hasHtml ? raw : raw.split(/\r?\n/).map(line => line.trim() ? '<div>' + escHtml(line) + '</div>' : '<div><br></div>').join('');
          return '<div><h1>' + t + '</h1></div>' + (rendered ? rendered : '');
        }
        function iso(d) { try { return d ? new Date(d.getTime()).toISOString() : null; } catch (e) { return null; } }
        function serializeNote(n, includeBody) {
          const obj = {
            id: String(n.id()),
            title: String(n.name() || ''),
            created_at: iso(n.creationDate()),
            updated_at: iso(n.modificationDate())
          };
          try { obj.folder = String(n.container().name() || ''); } catch (e) { obj.folder = ''; }
          if (includeBody) {
            const plain = String(n.plaintext() || '');
            obj.body_text = plain;
            obj.preview = plain.slice(0, 240);
          } else {
            obj.preview = String(n.plaintext() || '').slice(0, 200);
          }
          return obj;
        }
        function run() {
          const env = $.NSProcessInfo.processInfo.environment;
          const raw = ObjC.unwrap(env.objectForKey('MOMO_PIM_JXA_PAYLOAD'));
          const req = JSON.parse(raw);
          const op = req.op, args = req.args || {};
          const Notes = Application('Notes');
          if (op === 'list_note_folders') {
            const folders = [];
            for (const acc of Notes.accounts()) {
              const accName = String(acc.name() || '');
              for (const f of acc.folders()) {
                const fname = String(f.name() || '');
                if (fname === 'Recently Deleted' || fname === '最近删除') continue;
                folders.push({ id: String(f.id()), name: fname, account: accName });
              }
            }
            return JSON.stringify({ ok: true, folders });
          }
          function findFolder(folderId, folderName) {
            for (const acc of Notes.accounts()) {
              for (const f of acc.folders()) {
                if (folderId && String(f.id()) === folderId) return f;
                if (folderName && String(f.name()).toLowerCase() === folderName.toLowerCase()) return f;
              }
            }
            return Notes.defaultAccount().defaultFolder();
          }
          function findNoteById(id) {
            const matches = Notes.notes.whose({ id: id })();
            return matches && matches.length ? matches[0] : null;
          }
          if (op === 'search_notes') {
            const q = String(args.query || '').trim().toLowerCase();
            const limit = Math.min(50, Math.max(1, Number(args.limit || 20)));
            const container = (args.folder_id || args.folder_name) ? findFolder(args.folder_id, args.folder_name) : Notes;
            const all = container.notes();
            const items = [];
            for (let i = 0; i < all.length && items.length < limit; i++) {
              const n = all[i];
              let folderName = '';
              try { folderName = String(n.container().name() || ''); } catch (e) {}
              if (folderName === 'Recently Deleted' || folderName === '最近删除') continue;
              const name = String(n.name() || '');
              const plain = q ? String(n.plaintext() || '') : '';
              if (q && !name.toLowerCase().includes(q) && !plain.toLowerCase().includes(q)) continue;
              items.push(serializeNote(n, false));
            }
            return JSON.stringify({ ok: true, items, count: items.length });
          }
          if (op === 'read_note') {
            const n = findNoteById(String(args.note_id || ''));
            if (!n) return JSON.stringify({ ok: false, error: '未找到指定的备忘录。' });
            return JSON.stringify({ ok: true, item: serializeNote(n, true) });
          }
          if (op === 'create_note') {
            const title = String(args.title || '').trim();
            if (!title) return JSON.stringify({ ok: false, state: 'needs_clarification', error: '备忘录标题不能为空。' });
            const folder = findFolder(args.folder_id, args.folder_name);
            const note = Notes.Note({ body: toNoteHtml(title, args.body || '') });
            folder.notes.push(note);
            const item = serializeNote(note, true);
            return JSON.stringify({ ok: true, state: 'succeeded', item });
          }
          if (op === 'update_note') {
            const n = findNoteById(String(args.note_id || ''));
            if (!n) return JSON.stringify({ ok: false, state: 'failed', error: '未找到要修改的备忘录。' });
            const title = String(args.title || n.name() || '').trim() || '备忘录';
            if (args.append) {
              const extra = String(args.body || '').split(/\r?\n/).map(line => line.trim() ? '<div>' + escHtml(line) + '</div>' : '<div><br></div>').join('');
              n.body = String(n.body() || '') + '<div><br></div>' + extra;
            } else {
              n.body = toNoteHtml(title, args.body !== undefined ? args.body : n.plaintext());
            }
            const item = serializeNote(n, true);
            return JSON.stringify({ ok: true, state: 'succeeded', item });
          }
          if (op === 'delete_note') {
            const n = findNoteById(String(args.note_id || ''));
            if (!n) return JSON.stringify({ ok: false, state: 'failed', error: '未找到要删除的备忘录。' });
            const item = serializeNote(n, false);
            Notes.delete(n);
            return JSON.stringify({ ok: true, state: 'succeeded', item });
          }
          return JSON.stringify({ ok: false, error: 'Unsupported notes op: ' + op });
        }
        """#

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-l", "JavaScript", "-e", script]
        var env = ProcessInfo.processInfo.environment
        env["MOMO_PIM_JXA_PAYLOAD"] = payloadString
        proc.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return NotesJXARunResult(status: proc.terminationStatus, stdout: outData, stderr: errText)
    }

    // MARK: - Helpers

    private func lockedSaveReminder(_ reminder: EKReminder, commit: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        try store.save(reminder, commit: commit)
    }

    private func lockedRemoveReminder(_ reminder: EKReminder, commit: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        try store.remove(reminder, commit: commit)
    }

    private func lockedSaveEvent(_ event: EKEvent, commit: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        try store.save(event, span: .thisEvent, commit: commit)
    }

    private func lockedRemoveEvent(_ event: EKEvent, commit: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        try store.remove(event, span: .thisEvent, commit: commit)
    }

    private struct ReminderArrayBox: @unchecked Sendable {
        let items: [EKReminder]
    }

    private func fetchReminders(matching predicate: NSPredicate) async -> [EKReminder] {
        let box: ReminderArrayBox = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { items in
                continuation.resume(returning: ReminderArrayBox(items: items ?? []))
            }
        }
        return box.items
    }

    private func findReminder(id: String) -> EKReminder? {
        if let item = store.calendarItem(withIdentifier: id) as? EKReminder { return item }
        return store.calendarItems(withExternalIdentifier: id).compactMap { $0 as? EKReminder }.first
    }

    private func findEvent(id: String) -> EKEvent? {
        if let ev = store.event(withIdentifier: id) { return ev }
        return store.calendarItems(withExternalIdentifier: id).compactMap { $0 as? EKEvent }.first
    }

    private func resolveReminderCalendars(listID: String?, listName: String?) -> [EKCalendar]? {
        let all = store.calendars(for: .reminder)
        if let id = listID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            let matched = all.filter { $0.calendarIdentifier == id }
            return matched.isEmpty ? nil : matched
        }
        if let name = listName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let matched = all.filter { $0.title.caseInsensitiveCompare(name) == .orderedSame }
            return matched.isEmpty ? nil : matched
        }
        return nil
    }

    private func resolveEventCalendars(calendarID: String?, calendarName: String?) -> [EKCalendar]? {
        let all = store.calendars(for: .event)
        if let id = calendarID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            let matched = all.filter { $0.calendarIdentifier == id }
            return matched.isEmpty ? nil : matched
        }
        if let name = calendarName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let matched = all.filter { $0.title.caseInsensitiveCompare(name) == .orderedSame }
            return matched.isEmpty ? nil : matched
        }
        return nil
    }

    private func resolveTargetCalendar(entityType: EKEntityType, id: String?, name: String?, fallback: EKCalendar?) -> EKCalendar? {
        let writable = store.calendars(for: entityType).filter { $0.allowsContentModifications }
        if let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
           let found = writable.first(where: { $0.calendarIdentifier == id }) {
            return found
        }
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
           let found = writable.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
            return found
        }
        if let fallback, fallback.allowsContentModifications { return fallback }
        return writable.first
    }

    private struct ParsedDate {
        let date: Date
        let components: DateComponents
        let dateOnly: Bool
    }

    private static func parseDateInput(_ raw: String) -> ParsedDate? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cal = Calendar.current
        if trimmed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            let df = DateFormatter()
            df.calendar = cal
            df.timeZone = .current
            df.dateFormat = "yyyy-MM-dd"
            guard let d = df.date(from: trimmed) else { return nil }
            var comps = cal.dateComponents([.year, .month, .day], from: d)
            comps.calendar = cal
            return ParsedDate(date: d, components: comps, dateOnly: true)
        }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoStd = ISO8601DateFormatter()
        isoStd.formatOptions = [.withInternetDateTime]
        if let d = isoFrac.date(from: trimmed) ?? isoStd.date(from: trimmed) {
            var comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
            comps.calendar = cal
            comps.timeZone = .current
            return ParsedDate(date: d, components: comps, dateOnly: false)
        }
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            let df = DateFormatter()
            df.calendar = cal
            df.timeZone = .current
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = fmt
            if let d = df.date(from: trimmed) {
                var comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
                comps.calendar = cal
                comps.timeZone = .current
                return ParsedDate(date: d, components: comps, dateOnly: false)
            }
        }
        return nil
    }

    private static func formatISO(_ date: Date?) -> String? {
        guard let date else { return nil }
        let fmt = ISO8601DateFormatter()
        fmt.timeZone = .current
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }

    private static func serializeReminder(_ item: EKReminder) -> [String: Any] {
        var dueAt: String? = nil
        var dateOnly = false
        if var comps = item.dueDateComponents {
            comps.calendar = comps.calendar ?? .current
            if comps.hour == nil {
                dateOnly = true
                if let y = comps.year, let m = comps.month, let d = comps.day {
                    dueAt = String(format: "%04d-%02d-%02d", y, m, d)
                }
            } else if let d = comps.date {
                dueAt = formatISO(d)
            }
        }
        var dict: [String: Any] = [
            "id": item.calendarItemIdentifier,
            "title": item.title ?? "",
            "list_id": item.calendar?.calendarIdentifier ?? "",
            "list_name": item.calendar?.title ?? "",
            "completed": item.isCompleted,
            "priority": item.priority,
            "notes": item.notes ?? ""
        ]
        if let dueAt {
            dict["due_at"] = dueAt
            dict["date_only"] = dateOnly
        }
        if let completedAt = formatISO(item.completionDate) {
            dict["completed_at"] = completedAt
        }
        return dict
    }

    private static func reminderReceiptFields(_ item: [String: Any]) -> [String: Any] {
        var fields: [String: Any] = [
            "title": item["title"] as? String ?? "",
            "completed": item["completed"] as? Bool ?? false,
            "list": item["list_name"] as? String ?? "",
            "timezone": TimeZone.current.identifier
        ]
        if let due = item["due_at"] as? String {
            fields["dueAt"] = due
        }
        return fields
    }

    private static func serializeEvent(_ ev: EKEvent) -> [String: Any] {
        var dict: [String: Any] = [
            "id": ev.eventIdentifier ?? "",
            "title": ev.title ?? "",
            "calendar_id": ev.calendar?.calendarIdentifier ?? "",
            "calendar_name": ev.calendar?.title ?? "",
            "all_day": ev.isAllDay,
            "location": ev.location ?? "",
            "notes": ev.notes ?? ""
        ]
        if let start = formatISO(ev.startDate) { dict["start_at"] = start }
        if let end = formatISO(ev.endDate) { dict["end_at"] = end }
        return dict
    }

    private static func eventReceiptFields(_ item: [String: Any]) -> [String: Any] {
        var fields: [String: Any] = [
            "title": item["title"] as? String ?? "",
            "calendar": item["calendar_name"] as? String ?? "",
            "allDay": item["all_day"] as? Bool ?? false,
            "timezone": TimeZone.current.identifier
        ]
        if let start = item["start_at"] as? String { fields["start"] = start }
        if let end = item["end_at"] as? String { fields["end"] = end }
        return fields
    }

    private static func successReceipt(kind: String, id: String, fields: [String: Any], item: [String: Any]) -> [String: Any] {
        [
            "ok": true,
            "actionID": UUID().uuidString.lowercased(),
            "state": "succeeded",
            "resource": [
                "kind": kind,
                "id": id,
                "fields": fields
            ],
            "item": item
        ]
    }

    private static func failureReceipt(state: String, kind: String, error: String) -> [String: Any] {
        [
            "ok": false,
            "actionID": UUID().uuidString.lowercased(),
            "state": state,
            "error": error,
            "resource": ["kind": kind, "fields": [:]]
        ]
    }

    private static func intArg(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }
}
