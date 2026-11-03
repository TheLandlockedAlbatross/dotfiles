-- subedit.lua - edit the subtitle you are watching, from inside mpv.
--
-- Three atomic steps, each reported on screen so you can trust what happened:
--   1. ASSESS   what subtitles this item really has (none / external .srt /
--               external other format / embedded text / image), via the
--               subedit-apply service next to Jellyfin (it sees the real files).
--   2. FETCH    the genuine subtitle text and open a uosc menu on the cue
--               nearest the current playback time. Enter on a cue opens mpv's
--               input console pre-filled with that cue's text.
--   3. SUBMIT   Enter in the console posts the edit to the server; Esc cancels
--               and nothing is sent. The server replaces the cue in the sidecar
--               atomically (with a one-time .bak), or writes a new sidecar when
--               the source is embedded / not .srt, then Jellyfin is refreshed
--               and the track in mpv is reloaded. The outcome is shown as OSD.
--
-- Line breaks inside a cue are shown in the console as " \n " and turned back
-- into real line breaks on submit.
--
-- Binding:  input.conf ->  ctrl+e  script-binding subedit/subedit-open
-- Options:  script-opts/subedit.conf
--   apply_url   base url of subedit-apply (default the puck node, https 8448)
--   lang        language tag for a NEW sidecar (default en)
--   api_token   optional Jellyfin token; normally NOT needed - the shim's own
--               Authorization header on mpv (http-header-fields) is reused,
--               and a token in the track url is used as a fallback.
-- Self-test:  SUBEDIT_SELFTEST=<srt> [SUBEDIT_T=<s>] mpv --no-config --idle=once --script=subedit.lua

local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'
local options = require 'mp.options'
local input_ok, input = pcall(require, 'mp.input')

local opts = {
    apply_url = 'https://jellyfin.cerberus-canopus.ts.net:8448',
    lang = 'en',
    api_token = '',
}
options.read_options(opts, 'subedit')

local state = {
    menu_open = false,
    source = nil,      -- track url / path the cues came from
    cues = nil,
    assess = nil,      -- result of step 1
    sub = nil,         -- the server-side stream dict we are editing (or nil)
    item = nil, msid = nil,
    editing = false,
}

-- ---------------------------------------------------------------------------
-- helpers

local function osd(text, secs)
    mp.osd_message('[subedit] ' .. text, secs or 4)
    msg.info(text)
end

local function fmt_time(t)
    local h = math.floor(t / 3600)
    local m = math.floor(t % 3600 / 60)
    local s = t % 60
    return string.format('%02d:%02d:%06.3f', h, m, s):gsub('%.', ',')
end

local function fmt_srt(t)
    local h = math.floor(t / 3600)
    local m = math.floor(t % 3600 / 60)
    local s = math.floor(t % 60)
    local ms = math.floor((t - math.floor(t)) * 1000 + 0.5)
    return string.format('%02d:%02d:%02d,%03d', h, m, s, ms)
end

local function is_url(s)
    return s and s:match('^https?://') ~= nil
end

local function player_auth_header()
    local fields = mp.get_property_native('http-header-fields')
    if type(fields) == 'table' then
        for _, f in ipairs(fields) do
            if type(f) == 'string' and f:lower():match('^authorization:%s*mediabrowser') then
                return f
            end
        end
    end
    return nil
end

local function auth_header()
    local h = player_auth_header()
    if h then return h end
    local token = opts.api_token ~= '' and opts.api_token or nil
    if not token then
        local tl = mp.get_property_native('track-list') or {}
        for _, t in ipairs(tl) do
            local u = t['external-filename'] or ''
            token = token or u:match('[?&][Aa]pi_?[Kk]ey=(%w+)')
        end
        local path = mp.get_property('path') or ''
        token = token or path:match('[?&][Aa]pi_?[Kk]ey=(%w+)')
    end
    if not token then return nil end
    return 'Authorization: MediaBrowser Client="subedit", Device="mpv", DeviceId="subedit", Version="1", Token="' .. token .. '"'
end

-- curl wrapper; cb(body|nil, http_status|nil)
local function http(method, url, header, body, cb)
    local args = {'curl', '-sL', '--max-time', '40', '-o', '-', '-w', '\n%{http_code}', '-X', method}
    if header then table.insert(args, '-H'); table.insert(args, header) end
    if body then
        table.insert(args, '-H'); table.insert(args, 'Content-Type: application/json')
        table.insert(args, '--data-binary'); table.insert(args, body)
    end
    table.insert(args, url)
    mp.command_native_async({name = 'subprocess', capture_stdout = true, capture_stderr = true, args = args},
        function(ok, res)
            if not ok or not res or res.status ~= 0 then return cb(nil, nil) end
            local out = res.stdout or ''
            local code = tonumber(out:match('(%d+)%s*$'))
            local payload = out:gsub('\n?%d+%s*$', '')
            cb(payload, code)
        end)
end

-- ---------------------------------------------------------------------------
-- SRT parsing (kept from stage 1)

local function parse_ts(s)
    local h, m, sec, ms = s:match('(%d+):(%d+):(%d+)[,.](%d+)')
    if not h then return nil end
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(sec) + tonumber(ms) / (10 ^ #ms)
end

local function parse_srt(text)
    text = text:gsub('^\239\187\191', ''):gsub('\r\n', '\n'):gsub('\r', '\n')
    local lines = {}
    for l in (text .. '\n'):gmatch('(.-)\n') do table.insert(lines, l) end
    local cues, i, n = {}, 1, #lines
    while i <= n do
        if lines[i]:match('^%s*$') then
            i = i + 1
        else
            local j = i
            while j <= n and not lines[j]:match('^%s*$') do j = j + 1 end
            local ts_line
            for k = i, j - 1 do
                if lines[k]:find('-->', 1, true) then ts_line = k; break end
            end
            if ts_line then
                local a, b = lines[ts_line]:match('^%s*(.-)%s*%-%->%s*(.-)%s*$')
                local st, en = parse_ts(a or ''), parse_ts(b or '')
                if st and en then
                    local txt = {}
                    for k = ts_line + 1, j - 1 do table.insert(txt, lines[k]) end
                    table.insert(cues, {start = st, stop = en, text = table.concat(txt, '\n'),
                                        ts_line = ts_line, text_line = ts_line + 1,
                                        file_idx = tonumber(lines[i]:match('^%s*(%d+)%s*$'))})
                end
            end
            i = j
        end
    end
    return cues
end

local function nearest(cues, t)
    if #cues == 0 then return nil end
    local lo, hi = 1, #cues
    while lo < hi do
        local mid = math.ceil((lo + hi) / 2)
        if cues[mid].start <= t then lo = mid else hi = mid - 1 end
    end
    if cues[lo].start > t then return 1 end
    if t <= cues[lo].stop then return lo end
    if lo < #cues and (cues[lo + 1].start - t) < (t - cues[lo].stop) then return lo + 1 end
    return lo
end

local function cues_to_srt(cues)
    local out = {}
    for i, c in ipairs(cues) do
        out[#out + 1] = string.format('%d\n%s --> %s\n%s\n', i, fmt_srt(c.start), fmt_srt(c.stop), c.text)
    end
    return table.concat(out, '\n')
end

-- ---------------------------------------------------------------------------
-- step 1: assess

local function current_item()
    local path = mp.get_property('path') or ''
    local item = path:match('/Videos/([%w%-]+)/stream') or path:match('/Videos/([%w%-]+)/')
    local msid = path:match('[?&]MediaSourceId=(%w+)')
    return item, msid
end

local function selected_sub_track()
    local tl = mp.get_property_native('track-list') or {}
    for _, t in ipairs(tl) do
        if t.type == 'sub' and t.selected then return t end
    end
    return nil
end

local KIND_LABEL = {
    external_srt = 'external .srt (edits go into the file itself)',
    external_other = 'external non-srt (edits create a new .srt sidecar)',
    embedded_text = 'embedded text track (edits create a new .srt sidecar)',
    image = 'image-based (not editable)',
}

-- picks the stream to edit: the one mpv has selected (matched by index in its
-- url), else the first editable one. Returns sub, label.
local function choose_stream(assess, track)
    local want = nil
    if track and track['external-filename'] then
        want = tonumber((track['external-filename']):match('/Subtitles/(%d+)/'))
    end
    local pick
    if want then
        for _, s in ipairs(assess.subs) do if s.index == want then pick = s end end
    end
    if not pick then
        for _, s in ipairs(assess.subs) do if s.editable ~= 'none' then pick = s; break end end
    end
    if not pick and #assess.subs > 0 then pick = assess.subs[1] end
    return pick
end

local function describe(assess, sub)
    if not sub then
        return 'no subtitle streams on this item - nothing to edit'
    end
    local where = sub.path and (' - ' .. sub.path:match('[^/]+$')) or ''
    local flag = ''
    if sub.editable == 'in_place' then
        flag = sub.writable and '' or ' [file NOT writable]'
    elseif sub.editable == 'sidecar' then
        flag = assess.video_dir_writable and (' -> ' .. (assess.new_sidecar or ''):match('[^/]+$')) or ' [dir NOT writable]'
    end
    return string.format('stream %d %s: %s%s%s', sub.index, sub.codec or '?', KIND_LABEL[sub.kind] or sub.kind, where, flag)
end

local function assess(cb)
    local item, msid = current_item()
    local path = mp.get_property('path') or ''
    if not item then
        if not is_url(path) then
            return cb({local_file = true, path = path})
        end
        return cb(nil, 'not a Jellyfin item (cannot parse item id from ' .. path:sub(1, 60) .. ')')
    end
    local header = auth_header()
    if not header then return cb(nil, 'no Jellyfin auth available (no player header, no token in url)') end
    local url = string.format('%s/state?item=%s%s&lang=%s', opts.apply_url, item, msid and ('&msid=' .. msid) or '', opts.lang)
    http('GET', url, header, nil, function(body, code)
        local data = body and utils.parse_json(body)
        if code ~= 200 or not data or not data.subs then
            return cb(nil, string.format('assess failed (HTTP %s%s)', tostring(code), data and data.detail and (': ' .. data.detail) or ''))
        end
        data.item, data.msid = item, data.msid or msid
        data.header = header
        cb(data)
    end)
end

-- ---------------------------------------------------------------------------
-- step 2: fetch + place

local function fetch_text(assess, sub, cb)
    if assess.local_file then
        local f = io.open(sub.path, 'r')
        if not f then return cb(nil, 'cannot read ' .. sub.path) end
        local t = f:read('*a'); f:close()
        return cb(t)
    end
    if sub.editable == 'in_place' then
        local url = string.format('%s/srt?item=%s&msid=%s&index=%d', opts.apply_url, assess.item, assess.msid or '', sub.index)
        return http('GET', url, assess.header, nil, function(body, code)
            if code == 200 and body then return cb(body) end
            cb(nil, 'could not fetch the sidecar from the server (HTTP ' .. tostring(code) .. ')')
        end)
    end
    -- embedded / other format: Jellyfin converts it to srt for us
    local base = (mp.get_property('path') or ''):match('^(https?://[^/]+)')
    local url = string.format('%s/Videos/%s/%s/Subtitles/%d/0/Stream.srt', base, assess.item, assess.msid, sub.index)
    http('GET', url, assess.header, nil, function(body, code)
        if code == 200 and body then return cb(body) end
        cb(nil, 'Jellyfin would not convert this track to srt (HTTP ' .. tostring(code) .. ')')
    end)
end

local function build_menu(cues, sel, title, footnote)
    local items = {}
    for i, c in ipairs(cues) do
        items[i] = {
            title = c.text:gsub('\n', ' '),
            hint = fmt_srt(c.start):sub(1, 8),
            value = {'script-message-to', 'subedit', 'subedit-edit', tostring(i)},
            keep_open = true,
        }
    end
    return {
        type = 'subedit', title = title, items = items, selected_index = sel,
        footnote = footnote, search_style = 'on_demand', on_close = {'script-message-to', 'subedit', 'subedit-closed'},
    }
end

local function open_menu(reselect)
    local cues = state.cues
    local t = (mp.get_property_number('time-pos') or 0) - (mp.get_property_number('sub-delay') or 0)
    local sel = reselect or nearest(cues, t) or 1
    local title = state.sub and (state.assess.local_file and 'Local subtitle' or describe(state.assess, state.sub)) or 'Subtitles'
    local foot = state.sub and (state.sub.editable == 'none' and 'view only' or 'Enter = edit this cue, Esc = close') or ''
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(build_menu(cues, sel, title, foot)))
    state.menu_open = true
end

-- ---------------------------------------------------------------------------
-- step 3: submit

local function reload_track(new_index)
    if new_index then
        local base = (mp.get_property('path') or ''):match('^(https?://[^/]+)')
        local url = string.format('%s/Videos/%s/%s/Subtitles/%d/0/Stream.srt', base, state.assess.item, state.assess.msid, new_index)
        mp.commandv('sub-add', url, 'select', 'subedit ' .. opts.lang)
    else
        mp.commandv('sub-reload')
    end
end

local function submit(i, new_text)
    local c = state.cues[i]
    local sub, assess = state.sub, state.assess
    if assess.local_file then
        c.text = new_text
        local f = io.open(sub.path, 'w')
        if not f then return osd('could not write ' .. sub.path) end
        f:write(cues_to_srt(state.cues)); f:close()
        mp.commandv('sub-reload')
        return osd('saved cue ' .. i .. ' to ' .. sub.path:match('[^/]+$'))
    end
    local mode = sub.editable == 'in_place' and 'in_place' or 'sidecar'
    local body = {
        item = assess.item, msid = assess.msid, index = sub.index, mode = mode, lang = opts.lang,
        cue = {n = i, start = fmt_srt(c.start), stop = fmt_srt(c.stop), old_text = c.text, new_text = new_text},
    }
    if mode == 'sidecar' then
        local old = c.text
        c.text = new_text
        body.full_srt = cues_to_srt(state.cues)
        c.text = old
    end
    osd('submitting cue ' .. i .. ' (' .. mode .. ')...', 30)
    http('POST', opts.apply_url .. '/apply', assess.header, utils.format_json(body), function(resp, code)
        local d = resp and utils.parse_json(resp) or {}
        local outcome = d.outcome or ('no response (HTTP ' .. tostring(code) .. ')')
        if outcome == 'replaced_in_place' then
            c.text = new_text
            reload_track(nil)
            osd(string.format('saved cue %d in place%s', i, d.backup and ' (backup: .bak)' or ''), 5)
        elseif outcome == 'sidecar_created' then
            c.text = new_text
            sub.editable = 'in_place'; sub.kind = 'external_srt'; sub.path = d.path
            if d.new_index then sub.index = d.new_index end
            reload_track(d.new_index)
            osd(string.format('created sidecar %s%s', (d.path or ''):match('[^/]+$'), d.new_index and ' and switched to it' or (' (' .. tostring(d.note) .. ')')), 7)
        elseif outcome == 'conflict' then
            osd('NOT saved: ' .. tostring(d.detail) .. ' - reopen to refetch', 8)
        else
            osd('NOT saved: ' .. outcome .. (d.detail and (': ' .. d.detail) or ''), 8)
        end
        if state.menu_open then open_menu(i) end
    end)
end

local function edit_cue(i)
    local c = state.cues[i]
    if not c then return end
    if not state.sub or state.sub.editable == 'none' then
        return osd('this subtitle is not editable (' .. (state.sub and state.sub.kind or 'none') .. ')')
    end
    if not input_ok then return osd('mpv input console not available (need mpv >= 0.38)') end
    -- hide the menu while the console is up, keep our state
    mp.commandv('script-message-to', 'uosc', 'close-menu', 'subedit')
    state.editing = true
    local shown = c.text:gsub('\n', ' \\n ')
    input.get({
        prompt = string.format('cue %d  %s -> %s :', i, fmt_srt(c.start):sub(1, 8), fmt_srt(c.stop):sub(1, 8)),
        default_text = shown,
        cursor_position = #shown + 1,
        submit = function(text)
            input.terminate()
            state.editing = false
            local new_text = text:gsub('%s*\\n%s*', '\n'):gsub('^%s+', ''):gsub('%s+$', '')
            if new_text == c.text then
                osd('unchanged, nothing sent')
                return open_menu(i)
            end
            if new_text == '' then
                osd('empty text, nothing sent')
                return open_menu(i)
            end
            submit(i, new_text)
        end,
        closed = function()
            if state.editing then
                state.editing = false
                osd('edit cancelled, nothing sent')
                open_menu(i)
            end
        end,
    })
end

-- ---------------------------------------------------------------------------
-- entry

local function start()
    if state.menu_open then
        mp.commandv('script-message-to', 'uosc', 'close-menu', 'subedit')
        state.menu_open = false
        return
    end
    local track = selected_sub_track()
    osd('assessing subtitles...', 10)
    assess(function(a, err)
        if not a then return osd(err) end
        state.assess = a
        local sub
        if a.local_file then
            local ext = track and track['external-filename']
            if not ext then return osd('local file: no external subtitle selected') end
            sub = {index = track.id, path = ext, editable = 'in_place', kind = 'external_srt', codec = 'srt'}
        else
            sub = choose_stream(a, track)
        end
        state.sub = sub
        osd(describe(a, sub), 6)
        if not sub then return end
        if sub.editable == 'none' and not (track and track['external-filename']) then
            return osd('view only: ' .. describe(a, sub), 6)
        end
        fetch_text(a, sub, function(text, ferr)
            if not text then return osd(ferr, 8) end
            local cues = parse_srt(text)
            if #cues == 0 then return osd('no cues parsed from the subtitle', 6) end
            state.cues = cues
            state.source = sub.path or sub.index
            open_menu()
        end)
    end)
end

mp.register_script_message('subedit-edit', function(i) edit_cue(tonumber(i)) end)
mp.register_script_message('subedit-closed', function()
    if not state.editing then state.menu_open = false end
end)
mp.add_key_binding(nil, 'subedit-open', start)
mp.register_event('end-file', function()
    state.cues, state.assess, state.sub, state.menu_open = nil, nil, nil, false
end)

-- ---------------------------------------------------------------------------
-- self-test (parser + nearest), no network
local selftest = os.getenv('SUBEDIT_SELFTEST')
if selftest then
    local f = io.open(selftest, 'r')
    local text = f and f:read('*a') or ''
    if f then f:close() end
    local cues = parse_srt(text)
    print('cues: ' .. #cues)
    local t = tonumber(os.getenv('SUBEDIT_T') or '0')
    local n = nearest(cues, t)
    print(string.format('nearest to %.3f: cue %s%s', t, tostring(n), n and (' "' .. cues[n].text:gsub('\n', ' | ') .. '"') or ''))
    print('roundtrip ok: ' .. tostring(#parse_srt(cues_to_srt(cues)) == #cues))
    mp.command('quit')
end
