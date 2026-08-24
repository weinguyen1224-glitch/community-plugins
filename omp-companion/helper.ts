// omp-companion helper — bridges Noctalia <-> omp (RPC) + hyprwhspr (voice).
// Spawned by panel.luau: `bun helper.ts --port N --lang vi [--auto-approve] [--cwd DIR]`.

import { readdirSync, readFileSync, statSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

function arg(name: string, def: string): string {
  const i = process.argv.indexOf(name);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : def;
}

function hasFlag(name: string): boolean {
  return process.argv.includes(name);
}

const PORT = parseInt(arg("--port", "4097"), 10);
const LANG = arg("--lang", "vi");
const AUTO_APPROVE = hasFlag("--auto-approve");
const HOME = homedir();
const CWD = arg("--cwd", HOME);
const SESSION_DIR = join(HOME, ".omp", "agent", "sessions");

function resolveBin(name: string, fallbacks: string[]): string | null {
  const found = Bun.which(name);
  if (found) return found;
  for (const f of fallbacks) if (Bun.file(f).exists()) return f;
  return null;
}

const OMP = resolveBin("omp", [join(HOME, ".bun", "bin", "omp")]);
const HYPRWHSPR = resolveBin("hyprwhspr", ["/usr/lib/hyprwhspr/bin/hyprwhspr"]);

// PID file so the panel can kill us on unload.
Bun.write("/tmp/omp-companion.pid", String(process.pid));

function shutdown() {
  if (omp) {
    try {
      omp.kill();
    } catch {}
  }
  try {
    unlinkSync("/tmp/omp-companion.pid");
  } catch {}
  process.exit(0);
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

// --- SSE clients ---
const clients = new Set<ReadableStreamDefaultController<Uint8Array>>();
function broadcast(obj: unknown) {
  const data = `data: ${JSON.stringify(obj)}\n\n`;
  const bytes = new TextEncoder().encode(data);
  for (const c of clients) {
    try {
      c.enqueue(bytes);
    } catch {}
  }
}

// --- omp ---
let omp: any = null;
let ompReady = false;
const queue: string[] = [];
let nextId = 1;

// Pending command responses, keyed by command id.
const pending = new Map<string, (resp: any) => void>();
const cmdQueue: any[] = [];

function sendPrompt(text: string) {
  if (!omp || !ompReady) {
    queue.push(text);
    return;
  }
  omp.stdin.write(
    JSON.stringify({ id: "p" + nextId++, type: "prompt", message: text }) +
      "\n",
  );
}

// Send an RPC command and resolve with its `response` frame.
function sendCommand(cmd: any): Promise<any> {
  const id = "c" + nextId++;
  cmd.id = id;
  return new Promise((res) => {
    pending.set(id, res);
    if (!omp || !ompReady) {
      cmdQueue.push(cmd);
    } else {
      omp.stdin.write(JSON.stringify(cmd) + "\n");
    }
  });
}

function handleFrame(f: any) {
  switch (f.type) {
    case "ready":
      ompReady = true;
      for (const t of queue) sendPrompt(t);
      queue.length = 0;
      for (const c of cmdQueue) omp.stdin.write(JSON.stringify(c) + "\n");
      cmdQueue.length = 0;
      break;
    case "response": {
      const id = f.id;
      if (id && pending.has(id)) {
        const res = pending.get(id)!;
        pending.delete(id);
        res(f);
      }
      break;
    }
    case "message_update": {
      const e = f.assistantMessageEvent;
      if (e && e.type === "text_delta")
        broadcast({ type: "delta", text: e.delta });
      break;
    }
    case "tool_execution_start":
      broadcast({ type: "status", text: "running: " + f.toolName });
      break;
    case "agent_end":
      broadcast({ type: "turn_end" });
      break;
  }
}

function startOmp() {
  if (!OMP) {
    broadcast({ type: "error", text: "omp not found" });
    return;
  }
  const args = ["--mode", "rpc"];
  if (AUTO_APPROVE) args.push("--auto-approve");
  const proc = Bun.spawn([OMP, ...args], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "ignore", // unread pipe fills and blocks omp
    cwd: CWD,
  });
  omp = proc;
  ompReady = false;
  let buf = "";
  const reader = proc.stdout.getReader();
  const pump = (r: any): any => {
    if (r.done) return;
    buf += new TextDecoder().decode(r.value);
    let idx;
    while ((idx = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, idx);
      buf = buf.slice(idx + 1);
      if (line.trim()) {
        try {
          handleFrame(JSON.parse(line));
        } catch {}
      }
    }
    return reader.read().then(pump);
  };
  reader.read().then(pump);
  proc.exited.then(() => {
    if (omp !== proc) return; // replaced by resume
    broadcast({ type: "error", text: "omp exited" });
    process.exit(1);
  });
}

// --- sessions ---
type SessionInfo = {
  id: string;
  title: string;
  timestamp: string;
  cwd: string;
  path: string;
};

function scanSessions(): SessionInfo[] {
  const out: SessionInfo[] = [];
  const walk = (dir: string) => {
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      return;
    }
    for (const e of entries) {
      const p = join(dir, e);
      let st;
      try {
        st = statSync(p);
      } catch {
        continue;
      }
      if (st.isDirectory()) walk(p);
      else if (e.endsWith(".jsonl")) {
        try {
          const head = readFileSync(p, "utf8").split("\n").slice(0, 4);
          let id = "",
            title = "",
            ts = "",
            cwd = "";
          for (const line of head) {
            if (!line.trim()) continue;
            let f;
            try {
              f = JSON.parse(line);
            } catch {
              continue;
            }
            if (f.type === "title") title = f.title || "";
            if (f.type === "session") {
              id = f.id || "";
              ts = f.timestamp || "";
              cwd = f.cwd || "";
            }
          }
          if (id) out.push({ id, title, timestamp: ts, cwd, path: p });
        } catch {}
      }
    }
  };
  walk(SESSION_DIR);
  out.sort((a, b) => (a.timestamp < b.timestamp ? 1 : -1));
  return out;
}

function readHistory(path: string): { role: string; text: string }[] {
  const out: { role: string; text: string }[] = [];
  try {
    const lines = readFileSync(path, "utf8").split("\n");
    for (const line of lines) {
      if (!line.trim()) continue;
      let f;
      try {
        f = JSON.parse(line);
      } catch {
        continue;
      }
      if (f.type === "message" && f.message) {
        const role = f.message.role;
        const content = f.message.content;
        if (Array.isArray(content)) {
          const text = content
            .filter((b: any) => b.type === "text")
            .map((b: any) => b.text)
            .join("");
          if (text) out.push({ role, text });
        }
      }
    }
  } catch {}
  return out;
}

// --- voice capture ---
let listening = false;
async function listen() {
  if (listening) return;
  if (!HYPRWHSPR) {
    broadcast({ type: "error", text: "hyprwhspr not found" });
    return;
  }
  listening = true;
  broadcast({ type: "status", text: "listening" });
  try {
    const proc = Bun.spawn([HYPRWHSPR, "record", "capture", "--lang", LANG], {
      stdout: "pipe",
      stderr: "ignore", // unread pipe fills and blocks hyprwhspr
    });
    const out = await new Response(proc.stdout).text();
    const text = out.trim();
    if (text) {
      broadcast({ type: "status", text: "transcribed" });
      sendPrompt(text);
    } else {
      broadcast({ type: "error", text: "no transcription" });
    }
  } catch (e: any) {
    broadcast({ type: "error", text: "capture failed: " + e.message });
  } finally {
    listening = false;
  }
}

function stopListening() {
  if (!HYPRWHSPR) return;
  Bun.spawn([HYPRWHSPR, "record", "stop"], {
    stdout: "ignore",
    stderr: "ignore",
  });
}

// --- HTTP server ---
Bun.serve({
  port: PORT,
  hostname: "127.0.0.1",
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/health") return Response.json({ ok: true });
    if (url.pathname === "/prompt" && req.method === "POST") {
      sendPrompt(await req.text());
      return Response.json({ ok: true });
    }
    if (url.pathname === "/listen" && req.method === "POST") {
      listen();
      return Response.json({ ok: true });
    }
    if (url.pathname === "/stop" && req.method === "POST") {
      stopListening();
      return Response.json({ ok: true });
    }
    if (url.pathname === "/sessions") {
      return Response.json({ sessions: scanSessions() });
    }
    if (url.pathname === "/commands") {
      const resp = await sendCommand({ type: "get_available_commands" });
      const commands = resp?.data?.commands || [];
      return Response.json({ commands });
    }
    if (url.pathname === "/history") {
      const id = url.searchParams.get("id") || "";
      const s = scanSessions().find((x) => x.id === id || x.id.startsWith(id));
      if (!s) return Response.json({ messages: [] }, { status: 404 });
      return Response.json({ messages: readHistory(s.path), session: s });
    }
    if (url.pathname === "/resume" && req.method === "POST") {
      const id = (await req.text()).trim();
      const s = scanSessions().find((x) => x.id === id || x.id.startsWith(id));
      if (s) {
        await sendCommand({ type: "switch_session", sessionPath: s.path });
        broadcast({ type: "status", text: "resumed" });
      }
      return Response.json({ ok: true });
    }
    if (url.pathname === "/new" && req.method === "POST") {
      await sendCommand({ type: "new_session" });
      const state = await sendCommand({ type: "get_state" });
      const id = state?.data?.sessionId || "";
      const path = state?.data?.sessionFile || "";
      broadcast({ type: "status", text: "new session" });
      return Response.json({ ok: true, id, path });
    }
    if (url.pathname === "/stream") {
      let controller: ReadableStreamDefaultController<Uint8Array> | null = null;
      return new Response(
        new ReadableStream({
          start(c) {
            controller = c;
            clients.add(c);
          },
          cancel() {
            if (controller) clients.delete(controller);
          },
        }),
        {
          headers: {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
          },
        },
      );
    }
    if (url.pathname === "/shutdown" && req.method === "POST") {
      shutdown();
    }
    return Response.json({ ok: false }, { status: 404 });
  },
});

startOmp();
