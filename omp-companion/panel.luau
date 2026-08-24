-- OMP Companion — voice-driven coding assistant panel (chat UI).
-- Bridges Noctalia <-> helper.ts (omp RPC + hyprwhspr voice capture).

local PORT = 4097
local VOICE_LANG = "vi"
local AUTO_APPROVE = true
local CWD = ""

-- chat state
local messages = {}       -- { {role="user"|"assistant", text, id}, ... }
local streaming = false
local current_text = ""
local msg_seq = 0

local status_text = ""
local error_text = ""
local draft = ""
local composer_seq = 0
local sse_stream = nil
local panel_open = false
local listening = false

-- sessions
local sessions = {}          -- { {id, title, timestamp, cwd, path}, ... }
local session_labels = {}    -- flat label array for ui.select
local selected_id = nil      -- id of selected session, or nil
local session_list_rev = 0   -- bumps when list rebuilds (forces select re-render)
local initialized = false    -- true after first onOpen (distinguishes reload vs reopen)

-- slash commands
local slash_commands = {}    -- { {name, description, hint}, ... }

-- layout
local PAD = 12
local WRAP = 436 -- 560 - 2*PAD - scrollbar room
local GAP = 8
local BUBBLE_GAP = 4

-- scroll control
local chat_stick = true
local chat_scroll_rev = 0

local render -- forward declaration

local function base_url()
    return "http://127.0.0.1:" .. tostring(PORT)
end

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Resolve bun: Noctalia's subprocess PATH may not include ~/.bun/bin.
local function resolve_bun()
    if noctalia.commandExists("bun") then
        return "bun"
    end
    local home = noctalia.getenv("HOME") or ""
    if home ~= "" then
        local p = home .. "/.bun/bin/bun"
        if noctalia.fileExists(p) then
            return p
        end
    end
    return "bun"
end

local function post(path, body, cb)
    local req = { url = base_url() .. path, method = "POST" }
    if body ~= nil then
        req.body = body
    end
    noctalia.http(req, cb or function() end)
end

local function get(path, cb)
    noctalia.http({ url = base_url() .. path, method = "GET" }, cb)
end

local function spawn_helper()
    local dir = noctalia.pluginDir()
    if not dir then
        error_text = "plugin dir not found"
        render()
        return
    end
    local bun = resolve_bun()
    local cmd = shq(bun) .. " " .. shq(dir .. "/helper.ts")
        .. " --port " .. tostring(PORT)
        .. " --lang " .. VOICE_LANG
    if AUTO_APPROVE then
        cmd = cmd .. " --auto-approve"
    end
    if CWD ~= "" then
        cmd = cmd .. " --cwd " .. shq(CWD)
    end
    -- Detached fire-and-forget: correct for a long-lived server. The callback
    -- form has a 5s default timeout that would kill the helper.
    noctalia.runAsync(cmd)
end

-- Split assistant text into code / non-code segments. MarkdownView doesn't wrap
-- fenced code blocks, so code renders as a wrapping monospace label.
local function split_markdown(txt)
    local segs = {}
    local in_code = false
    local buf = {}
    local function flush()
        if #buf > 0 then
            segs[#segs + 1] = { code = in_code, text = table.concat(buf) }
            buf = {}
        end
    end
    for line in (txt .. "\n"):gmatch("([^\n]*)\n") do
        local stripped = line:match("^%s*(.*)$") or ""
        if stripped:sub(1, 3) == "```" then
            flush()
            in_code = not in_code
        else
            buf[#buf + 1] = line .. "\n"
        end
    end
    flush()
    return segs
end

-- Render a single message bubble. User hugs right, assistant hugs left.
local function render_message(msg)
    if type(msg) ~= "table" then
        return nil
    end
    local role = msg.role
    local text = msg.text or ""
    if text == "" then
        return nil
    end

    local is_user = (role == "user")
    local header_text = is_user and noctalia.tr("panel.role_user") or noctalia.tr("panel.role_assistant")
    local header_color = is_user and "secondary" or "primary"

    local cells = { ui.label({ text = header_text, fontWeight = "bold", color = header_color, fontSize = 11 }) }

    if is_user then
        cells[#cells + 1] = ui.label({ text = text, maxWidth = WRAP, flexGrow = 1 })
    else
        local segs = split_markdown(text)
        for _, seg in ipairs(segs) do
            if seg.code then
                cells[#cells + 1] = ui.column({
                    padding = 8,
                    radius = 8,
                    fill = "surface_variant/0.45",
                }, {
                    ui.label({
                        text = seg.text:gsub("\n+$", ""),
                        fontSize = 12,
                        fontFamily = "monospace",
                        maxWidth = WRAP - 16,
                    }),
                })
            else
                cells[#cells + 1] = ui.markdown({ text = seg.text, width = WRAP })
            end
        end
    end

    local msg_id = msg.id or ""
    return ui.row({ key = "msg_" .. msg_id, justify = is_user and "end" or "start", align = "start" }, {
        ui.column({ gap = BUBBLE_GAP, align = is_user and "end" or "start" }, cells),
    })
end

-- Thinking bubble shown while the agent is processing (no text yet).
local function render_thinking()
    return ui.row({ justify = "start", align = "start" }, {
        ui.column({ gap = BUBBLE_GAP, align = "start" }, {
            ui.label({ text = noctalia.tr("panel.role_assistant"), fontWeight = "bold", color = "primary", fontSize = 11 }),
            ui.row({ gap = 6, align = "center" }, {
                ui.glyph({ name = "loader", color = "primary" }),
                ui.label({ text = noctalia.tr("panel.thinking"), opacity = 0.7, fontSize = 12 }),
            }),
        }),
    })
end

local function handle_event(obj)
    local t = obj.type
    if t == "delta" then
        current_text = current_text .. (obj.text or "")
        render()
    elseif t == "status" then
        local s = obj.text or ""
        if s == "listening" then
            listening = true
            status_text = noctalia.tr("panel.status.listening")
        elseif s == "transcribed" then
            listening = false
            status_text = noctalia.tr("panel.status.transcribed")
        else
            status_text = s
        end
        render()
    elseif t == "error" then
        listening = false
        error_text = obj.text or ""
        streaming = false
        render()
    elseif t == "turn_end" then
        if current_text ~= "" then
            msg_seq = msg_seq + 1
            messages[#messages + 1] = { role = "assistant", text = current_text, id = tostring(msg_seq) }
        end
        current_text = ""
        streaming = false
        status_text = ""
        chat_scroll_rev = chat_scroll_rev + 1
        chat_stick = true
        render()
    end
end

local function connect_sse()
    sse_stream = noctalia.httpStream(
        { url = base_url() .. "/stream", method = "GET", headers = { "Accept: text/event-stream" } },
        function(line)
            local data = line:match("^data: (.*)$")
            if not data then
                return
            end
            local ok, obj = pcall(noctalia.json.decode, data)
            if ok and type(obj) == "table" then
                handle_event(obj)
            end
        end,
        function(_result)
            sse_stream = nil
            if not panel_open then
                return
            end
            noctalia.runAsync("sleep 1 && echo done", function(_)
                if panel_open then
                    connect_sse()
                end
            end)
        end
    )
end

local function ensure_helper(on_ready, attempts)
    attempts = attempts or 0
    noctalia.http({ url = base_url() .. "/health", method = "GET" }, function(resp)
        if resp.ok and resp.status == 200 then
            on_ready()
        elseif attempts < 10 then
            spawn_helper()
            noctalia.runAsync("sleep 1 && echo done", function(_)
                ensure_helper(on_ready, attempts + 1)
            end)
        else
            error_text = "helper failed to start"
            render()
        end
    end)
end

local function load_sessions(cb)
    get("/sessions", function(resp)
        if not (resp.ok and resp.status == 200) then
            if cb then cb() end
            return
        end
        local ok, data = pcall(noctalia.json.decode, resp.body)
        if not ok or type(data) ~= "table" then
            if cb then cb() end
            return
        end
        local list = data.sessions or {}
        sessions = {}
        session_labels = {}
        for i, s in ipairs(list) do
            sessions[i] = s
            local label = (s.title and s.title ~= "") and s.title or s.id or ("session " .. i)
            if s.timestamp and s.timestamp ~= "" then
                label = label .. "  ·  " .. s.timestamp
            end
            session_labels[i] = label
        end
        session_list_rev = session_list_rev + 1
        render()
        if cb then cb() end
    end)
end

-- Find the 1-based index of a session by id.
local function find_index(id)
    for i, s in ipairs(sessions) do
        if s.id == id then
            return i
        end
    end
    return nil
end

-- Fetch slash commands from omp (non-skill) for inline suggestions.
local function load_commands()
    get("/commands", function(resp)
        if not (resp.ok and resp.status == 200) then
            return
        end
        local ok, data = pcall(noctalia.json.decode, resp.body)
        if not ok or type(data) ~= "table" then
            return
        end
        local list = data.commands or {}
        slash_commands = {}
        for _, c in ipairs(list) do
            if c.source ~= "skill" then
                slash_commands[#slash_commands + 1] = c
            end
        end
        render()
    end)
end

-- Commands matching the current `/prefix` being typed in the composer.
-- Returns nil when the draft is not a bare `/prefix` (no args yet).
local function slash_suggestions()
    local prefix = draft:match("^%s*/([%w_:%-]*)$")
    if prefix == nil then
        return nil
    end
    local out = {}
    for _, c in ipairs(slash_commands) do
        local name = c.name or ""
        if prefix == "" or name:sub(1, #prefix) == prefix then
            out[#out + 1] = c
        end
        if #out >= 8 then
            break
        end
    end
    return out
end

-- Persist the selected session id so a panel reopen restores it.
local function persist_selection()
    if selected_id then
        noctalia.state.set("selected_session_id", selected_id)
    end
end

-- Jump straight into a session by id: load its history, then resume omp.
local function open_session_by_id(id)
    if not find_index(id) then
        return
    end
    selected_id = id
    persist_selection()
    get("/history?id=" .. id, function(resp)
        local new_msgs = {}
        if resp.ok and resp.status == 200 then
            local ok, data = pcall(noctalia.json.decode, resp.body)
            if ok and type(data) == "table" then
                local msgs = data.messages or {}
                for i, m in ipairs(msgs) do
                    new_msgs[i] = { role = m.role, text = m.text, id = "h" .. i }
                end
            end
        end
        messages = new_msgs
        current_text = ""
        streaming = false
        error_text = ""
        status_text = ""
        post("/resume", id)
        chat_scroll_rev = chat_scroll_rev + 1
        chat_stick = true
        render()
    end)
end

-- Jump into a session by 1-based index (used by the select onChange).
local function open_session(index)
    if sessions[index] then
        open_session_by_id(sessions[index].id)
    end
end

-- Start a fresh session.
local function new_session()
    messages = {}
    current_text = ""
    streaming = false
    error_text = ""
    status_text = ""
    post("/new", nil, function(resp)
        local id, path = nil, nil
        if resp.ok and resp.status == 200 then
            local ok, data = pcall(noctalia.json.decode, resp.body)
            if ok and type(data) == "table" then
                id = data.id
                path = data.path
            end
        end
        if id then
            -- new_session does not write a file until the first message, so
            -- insert a synthetic entry instead of re-scanning the filesystem.
            table.insert(sessions, 1, { id = id, title = "", timestamp = "", cwd = "", path = path })
            session_labels = {}
            for i, s in ipairs(sessions) do
                local label = (s.title and s.title ~= "") and s.title or s.id or ("session " .. i)
                if s.timestamp and s.timestamp ~= "" then
                    label = label .. "  ·  " .. s.timestamp
                end
                session_labels[i] = label
            end
            session_list_rev = session_list_rev + 1
            selected_id = id
            persist_selection()
        end
        render()
    end)
    chat_scroll_rev = chat_scroll_rev + 1
    chat_stick = true
    render()
end

local function send_draft(text)
    if streaming then
        return
    end
    text = text or draft
    if type(text) ~= "string" or text == "" then
        return
    end

    -- Slash command: open omp's TUI in a real terminal, auto-entering the command.
    local tname, targs = text:match("^%s*/([%w_:%-]+)%s*(.*)$")
    if tname then
        local slash = "/" .. tname
        if targs ~= "" then
            slash = slash .. " " .. targs
        end
        local dir = noctalia.pluginDir()
        if dir then
            noctalia.runInTerminal("sh " .. shq(dir .. "/open-tui.sh") .. " " .. shq(slash))
        end
        draft = ""
        composer_seq = composer_seq + 1
        render()
        return
    end

    msg_seq = msg_seq + 1
    messages[#messages + 1] = { role = "user", text = text, id = tostring(msg_seq) }
    current_text = ""
    streaming = true
    error_text = ""
    status_text = ""
    post("/prompt", text)
    draft = ""
    composer_seq = composer_seq + 1
    chat_scroll_rev = chat_scroll_rev + 1
    chat_stick = true
    render()
end

render = function()
    local rows = {}

    -- header
    rows[#rows + 1] = ui.row({ justify = "space_between", align = "center" }, {
        ui.label({ text = noctalia.tr("panel.title"), fontWeight = "bold", fontSize = 14 }),
        ui.label({ text = status_text, color = "secondary", fontSize = 11, maxLines = 1 }),
    })

    if error_text ~= "" then
        rows[#rows + 1] = ui.label({ text = error_text, color = "error", fontSize = 12, maxWidth = 520 })
    end

    -- voice toggle: one button flips between listen and stop
    rows[#rows + 1] = ui.button({
        glyph = listening and "microphone-off" or "microphone",
        text = listening and noctalia.tr("panel.stop") or noctalia.tr("panel.listen"),
        variant = listening and "secondary" or "primary",
        onClick = function()
            if listening then
                post("/stop")
                listening = false
            else
                error_text = ""
                post("/listen")
                listening = true
            end
            render()
        end,
    })

    -- session selector: pick a session to jump straight into it
    if #session_labels > 0 then
        local select_props = {
            key = "session_select_" .. session_list_rev,
            options = session_labels,
            placeholder = noctalia.tr("panel.session_placeholder"),
            flexGrow = 1,
            onChange = function(idx)
                local n = tonumber(idx)
                if n ~= nil then
                    open_session(math.floor(n) + 1)
                end
            end,
        }
        local sel_index = find_index(selected_id)
        if sel_index ~= nil then
            select_props.selectedIndex = sel_index - 1
        end
        rows[#rows + 1] = ui.row({ gap = 8, align = "center" }, {
            ui.select(select_props),
            ui.button({
                glyph = "plus",
                text = noctalia.tr("panel.new"),
                variant = "secondary",
                onClick = new_session,
            }),
        })
    end

    -- message list
    local msg_items = {}
    if #messages == 0 and not streaming then
        msg_items[#msg_items + 1] = ui.label({ text = noctalia.tr("panel.empty"), opacity = 0.6 })
    else
        for _, m in ipairs(messages) do
            local rendered = render_message(m)
            if rendered then
                msg_items[#msg_items + 1] = rendered
            end
        end
        if streaming and current_text == "" then
            msg_items[#msg_items + 1] = render_thinking()
        elseif streaming and current_text ~= "" then
            local rendered = render_message({ role = "assistant", text = current_text, id = "stream" })
            if rendered then
                msg_items[#msg_items + 1] = rendered
            end
        end
    end

    rows[#rows + 1] = ui.scroll({
        key = "chat_messages",
        flexGrow = 1,
        gap = GAP,
        stickToBottom = chat_stick,
        scrollToBottomRev = chat_scroll_rev,
        onScroll = function(offset, maxOffset)
            local o = tonumber(offset) or 0
            local mo = tonumber(maxOffset) or 0
            chat_stick = (o >= mo - 1)
        end,
    }, msg_items)

    rows[#rows + 1] = ui.separator({})

    -- composer
    rows[#rows + 1] = ui.row({ gap = 8, align = "end" }, {
        ui.input({
            key = "composer_" .. composer_seq,
            value = draft,
            placeholder = noctalia.tr("panel.placeholder"),
            multiline = true,
            submitOnEnter = true,
            flexGrow = 1,
            onChange = function(text)
                local was_slash = draft:match("^%s*/") ~= nil
                draft = text
                if was_slash or text:match("^%s*/") ~= nil then
                    render()
                end
            end,
            onSubmit = function(text)
                send_draft(text)
            end,
        }),
        ui.button({
            glyph = "send",
            variant = "primary",
            tooltip = noctalia.tr("panel.send"),
            enabled = not streaming,
            onClick = function()
                send_draft(draft)
            end,
        }),
    })

    -- inline slash suggestions while typing a bare `/prefix`
    local suggs = slash_suggestions()
    if suggs and #suggs > 0 then
        local sugg_rows = {}
        for _, c in ipairs(suggs) do
            local name = c.name or ""
            local desc = c.description or ""
            if #desc > 40 then
                desc = desc:sub(1, 40) .. "…"
            end
            local label = "/" .. name
            if desc ~= "" then
                label = label .. "  —  " .. desc
            end
            sugg_rows[#sugg_rows + 1] = ui.button({
                text = label,
                variant = "ghost",
                onClick = function()
                    draft = "/" .. name .. " "
                    composer_seq = composer_seq + 1
                    render()
                end,
            })
        end
        rows[#rows + 1] = ui.column({ gap = 4 }, sugg_rows)
    end

    panel.render(ui.column({ padding = PAD, gap = GAP, flexGrow = 1 }, rows))
end

function onOpen(_context)
    panel_open = true
    PORT = tonumber(noctalia.getConfig("port")) or 4097
    VOICE_LANG = noctalia.getConfig("voice_language") or "vi"
    AUTO_APPROVE = noctalia.getConfig("auto_approve") ~= false
    CWD = noctalia.getConfig("cwd") or ""
    ensure_helper(function()
        connect_sse()
        load_commands()
        load_sessions(function()
            if not initialized then
                -- First open after plugin load: point at the newest session.
                initialized = true
                if sessions[1] then
                    open_session_by_id(sessions[1].id)
                end
            else
                -- Reopen: restore the session that was active before closing.
                local id = noctalia.state.get("selected_session_id")
                if id then
                    open_session_by_id(id)
                end
            end
        end)
    end)
    render()
end

function onClose()
    panel_open = false
    if sse_stream then
        sse_stream.stop()
        sse_stream = nil
    end
end

function onExit()
    if sse_stream then
        sse_stream.stop()
        sse_stream = nil
    end
    noctalia.runAsync("kill $(cat /tmp/omp-companion.pid) 2>/dev/null")
end
