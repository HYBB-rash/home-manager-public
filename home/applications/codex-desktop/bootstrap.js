const { app } = require("electron");

const appId = process.env.CODEX_LINUX_APP_ID || "codex-desktop";
const displayName = process.env.CODEX_LINUX_APP_DISPLAY_NAME || "Codex";

app.setDesktopName(`${appId}.desktop`);
app.setName(displayName);

require("./.vite/build/early-bootstrap.js");
