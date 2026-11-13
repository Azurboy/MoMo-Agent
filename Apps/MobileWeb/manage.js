"use strict";
const byID = id => document.getElementById(id);
async function ownerRequest(path, body) {
  const response = await fetch(path, body ? {method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)} : {});
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || "暂时无法连接");
  return result;
}
async function refresh() {
  try {
    const {local, public: external, devices} = await ownerRequest("/info");
    byID("local-url").href = local;
    const address = byID("mobile-url");
    if (external) {
      const link = document.createElement("a");
      link.href = external; link.textContent = external; address.replaceChildren(link);
    } else address.textContent = "当前仅本机试用。为手表和其他手机配置 HTTPS 访问地址后，此处会显示连接地址。";
    const rows = devices.map(device => {
      const row = document.createElement("li");
      const label = document.createElement("span");
      label.textContent = (device.role === "watch" ? "Apple Watch" : "手机网页") + " · " + new Date(device.created*1000).toLocaleString();
      const button = document.createElement("button"); button.textContent = "解除配对";
      button.onclick = () => act(button, async () => {await ownerRequest("/revoke", {id:device.id}); await refresh();});
      row.append(label,button); return row;
    });
    byID("devices").replaceChildren(...(rows.length ? rows : ["还没有已配对的设备。"]));
    byID("error").textContent = "";
  } catch (error) {byID("error").textContent = error.message;}
}
async function act(button, action) {
  button.disabled = true;
  try { await action(); }
  catch(error) { byID("error").textContent = error.message; }
  finally { button.disabled = false; }
}
document.querySelectorAll("button[data-role]").forEach(button => {
  let timer;
  button.onclick = () => act(button, async () => {
    const role = button.dataset.role;
    const {code,expires_in:ttl} = await ownerRequest("/invite", {role});
    byID(role).textContent = code.slice(0,4) + " " + code.slice(4) + " · 10 分钟有效";
    clearTimeout(timer);
    timer = setTimeout(() => { byID(role).textContent = "配对码已到期"; },ttl*1000);
  });
});
refresh();
setInterval(() => {if (!document.hidden) refresh();},12000);
