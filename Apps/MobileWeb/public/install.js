'use strict';
const promptButton = document.getElementById('install-prompt');
const feedback = document.getElementById('install-feedback');
let installer;
function installed() {
  document.getElementById('install-already').hidden = false;
  document.getElementById('ios-steps').hidden = true;
  promptButton.hidden = true;
  feedback.textContent = '';
}
if (matchMedia('(display-mode: standalone)').matches || navigator.standalone === true) installed();
window.addEventListener('beforeinstallprompt', event => {
  event.preventDefault();
  installer = event;
  promptButton.hidden = false;
});
promptButton.addEventListener('click', async () => {
  if (!installer) return;
  const prompt = installer;
  installer = undefined;
  promptButton.hidden = true;
  try {
    await prompt.prompt();
    const result = await prompt.userChoice;
    if (result.outcome === 'accepted') installed();
  } catch {
    feedback.textContent = '请从浏览器菜单添加到主屏幕。';
  }
});
window.addEventListener('appinstalled', installed);
if ('serviceWorker' in navigator && window.isSecureContext) {
  navigator.serviceWorker.register('/sw.js').catch(() => {});
}
