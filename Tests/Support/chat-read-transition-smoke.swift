// Real WebKit regression: swift Tests/Support/chat-read-transition-smoke.swift [screenshot-directory]
import AppKit
import WebKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 393, height: 540),
                      styleMask: [.titled], backing: .buffered, defer: false)
let web = WKWebView(frame: window.contentView!.bounds)
window.contentView = web
window.orderFront(nil)
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("Apps/iPhoneApp/Features/Assistant/Rendering/Web")
web.loadFileURL(assets.appendingPathComponent("index.html"), allowingReadAccessTo: assets)

Task { @MainActor in
    do {
        func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }
        func capture(_ name: String) async throws {
            guard CommandLine.arguments.count > 1 else { return }
            let image = try await web.takeSnapshot(configuration: nil)
            guard let data = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return }
            try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png"))
        }
        for attempt in 0..<100 {
            if (try? await web.evaluateJavaScript("typeof MoMoChat === 'object'")) as? Bool == true { break }
            if attempt == 99 { throw NSError(domain: "RendererLoadTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(50))
        }
        var passed = true
        for mode in ["light", "dark", "reduced-motion", "reading-history", "english"] {
            let modeJSON = String(data: try JSONEncoder().encode(mode), encoding: .utf8)!
            _ = try await web.evaluateJavaScript("window.mode = \(modeJSON);" + #"""
            window.nowMs = new Date(2026, 10, 3, 15, 30, 0).getTime();
            window.yesterdayBaseMs = new Date(2026, 10, 2, 20, 10, 0).getTime();
            window.todayBaseMs = new Date(2026, 10, 3, 14, 45, 0).getTime();
            window.message = (id,role,text,sentAtMs) => ({id,turnID:id,role,state:'complete',sentAtMs,blocks:[{id:id+':input',type:'text',text}]});
            window.fixture = {sessionID:mode,locale:mode==='english'?'en':'zh-Hans',nowMs,messages:[],busy:true,stopped:false,
              canRegenerate:false,contextState:'idle',waitingForReply:false,
              appearance:{dark:mode==='dark',reduceMotion:mode==='reduced-motion',scale:1}};
            for(let i=0;i<16;i++) {
              const sentAtMs = (i < 8 ? yesterdayBaseMs : todayBaseMs) + (i % 8) * 60_000;
              fixture.messages.push(message('history-'+i,i%2?'assistant':'user','保留历史消息 '+i,sentAtMs));
            }
            fixture.messages.push(message('operation:user','user','你会干嘛',nowMs - 60_000));
            MoMoChat.render(fixture);
            """#)
            try await settle()
            if mode == "reading-history" {
                _ = try await web.evaluateJavaScript("window.scrollTo(0,50)")
                try await settle()
            }
            _ = try await web.evaluateJavaScript(#"""
            window.rows = [...document.querySelectorAll('.turn')];
            window.bubbles = [...document.querySelectorAll('.user-bubble,.prose')];
            window.timestamps = [...document.querySelectorAll('.turn-timestamp > time')];
            window.timestampISOs = timestamps.map(t=>t.getAttribute('datetime'));
            window.textNodes = bubbles.map(b=>b.firstChild);
            window.receipt = rows.at(-1).querySelector('.read-receipt');
            window.baseline = bubbles.map(b=>b.getBoundingClientRect().top);
            window.maxShift = 0; window.minOpacity = 1; window.replays = 0; window.removals = 0;
            window.sampling = true;
            window.observer = new MutationObserver(records => { removals += records.reduce((n,r)=>n+r.removedNodes.length,0); });
            observer.observe(document.querySelector('#transcript'),{childList:true,subtree:true});
            window.onAnimation = event => { if(event.animationName==='user-enter'||event.animationName==='assistant-enter') replays++; };
            document.querySelector('#transcript').addEventListener('animationstart',onAnimation);
            window.sample = () => {
              bubbles.forEach((b,i)=>{
                maxShift=Math.max(maxShift,Math.abs(b.getBoundingClientRect().top-baseline[i]));
                minOpacity=Math.min(minOpacity,Number(getComputedStyle(b).opacity));
              });
              if(sampling) requestAnimationFrame(sample);
            };
            requestAnimationFrame(sample);
            true;
            """#)
            try await capture(mode + "-before")
            // Receipt and canonical echo deliberately arrive in separate frames.
            _ = try await web.evaluateJavaScript("fixture.messages.at(-1).delivery='delivered'; MoMoChat.render(fixture); true")
            try await settle()
            let delivered = try await web.evaluateJavaScript("receipt.textContent===(mode==='english'?'Delivered':'已送达') && receipt.getAttribute('aria-hidden')==='false' && document.querySelector('#working').hidden") as? Bool == true
            passed = passed && delivered
            try await capture(mode + "-delivered")
            _ = try await web.evaluateJavaScript("fixture.messages.at(-1).delivery='read'; fixture.waitingForReply=true; MoMoChat.render(fixture); true")
            try await settle()
            _ = try await web.evaluateJavaScript("fixture.messages.at(-1).blocks[0].id='server-echo:text'; fixture.messages.at(-1).sentAtMs += 650; MoMoChat.render(fixture); true")
            try await settle()
            try await capture(mode + "-read")
            let report = try await web.evaluateJavaScript(#"""
            window.result = {mode:fixture.sessionID,maxShift,minOpacity,replays,removals,
              timestampCount:timestamps.length,
              sameTimestamps:timestamps.length===3 && timestamps.every((t,i)=>t===document.querySelectorAll('.turn-timestamp > time')[i] && t.getAttribute('datetime')===timestampISOs[i]),
              typographyOK:getComputedStyle(bubbles[0]).fontSize==='14px' && getComputedStyle(bubbles[0]).fontWeight==='430' && getComputedStyle(bubbles[0]).lineHeight==='18px' && getComputedStyle(timestamps[0]).fontSize==='12px',
              sameRows:rows.every((n,i)=>n===document.querySelectorAll('.turn')[i]),
              sameBubbles:bubbles.every((n,i)=>n===document.querySelectorAll('.user-bubble,.prose')[i] && n.firstChild===textNodes[i]),
              sameReceipt:receipt!=null && receipt===rows.at(-1).querySelector('.read-receipt'),
              readVisible:Number(getComputedStyle(rows.at(-1).querySelector('.read-receipt')).opacity)===1,
              dotsVisible:!document.querySelector('#working').hidden};
            sampling=false; observer.disconnect();
            document.querySelector('#transcript').removeEventListener('animationstart',onAnimation);
            JSON.stringify(result);
            """#)
            print(report ?? "No result")
            let stable = try await web.evaluateJavaScript("result.maxShift < 0.5 && result.minOpacity===1 && result.replays===0 && result.removals===0 && result.sameTimestamps && result.typographyOK && result.sameRows && result.sameBubbles && result.sameReceipt && result.readVisible && result.dotsVisible && receipt.textContent===(mode==='english'?'Read':'已读')") as? Bool == true
            passed = passed && stable
            _ = try await web.evaluateJavaScript("fixture.messages.push(message('reply','assistant','我可以帮你查资料、整理录音和完成任务。')); fixture.waitingForReply=false; fixture.busy=false; MoMoChat.render(fixture); true")
            try await settle()
            let reply = try await web.evaluateJavaScript("document.querySelector('#working').hidden && rows.at(-1).querySelector('.user-bubble')===bubbles.at(-1) && rows.at(-1).querySelector('.read-receipt')===receipt && receipt?.getAttribute('aria-hidden')==='true'") as? Bool == true
            passed = passed && reply
            try await capture(mode + "-reply")

            // A second, attachment-only send must not revive the previous receipt.
            _ = try await web.evaluateJavaScript(#"""
            fixture.messages.push({id:'attachment',turnID:'attachment',role:'user',state:'complete',
              blocks:[{id:'file',type:'attachment',attachmentID:'file',name:'笔记.txt',format:'TXT',size:'1 KB'}]});
            MoMoChat.render(fixture);
            window.attachment = document.querySelector('.message-attachment');
            window.pendingHidden = [...document.querySelectorAll('.read-receipt')].every(r=>r.getAttribute('aria-hidden')==='true');
            fixture.messages.at(-1).delivery='delivered';
            MoMoChat.render(fixture);
            true;
            """#)
            let attachment = try await web.evaluateJavaScript(#"""
            pendingHidden && attachment===document.querySelector('.message-attachment') &&
            [...document.querySelectorAll('.read-receipt')].filter(r=>r.getAttribute('aria-hidden')==='false').length===1 &&
            [...document.querySelectorAll('.read-receipt')].at(-1).textContent===(mode==='english'?'Delivered':'已送达') &&
            receipt.getAttribute('aria-hidden')==='true'
            """#) as? Bool == true
            passed = passed && attachment
            print("\(mode): reply=\(reply), attachment receipt=\(attachment)")
        }
        guard passed else { throw NSError(domain: "Read transition moved, replaced, or faded a message", code: 1) }
        print("PASS: pending → delivered → read → canonical echo preserves every bubble and frame position; reply hides receipt in place")
        application.terminate(nil)
    } catch { print("FAIL \(error)"); exit(1) }
}
application.run()
