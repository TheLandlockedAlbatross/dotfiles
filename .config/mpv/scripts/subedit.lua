-- subedit.lua
-- Stage 1: view the currently selected external SRT in a uosc menu, focused
-- on the cue nearest the current playback position. Playback is not paused.
-- Selecting a cue seeks to its start; the menu stays open (Esc closes).
--
-- Stage 2: resolve the real file behind the subtitle source and report it in
-- the menu footnote. Local files are checked directly; Jellyfin stream URLs
-- (what jellyfin-mpv-shim feeds to sub-add) are resolved via the server API
-- using the ApiKey already embedded in the URL, mapped from the server's
-- container path to the storage host path, and probed for writability over
-- batch-mode ssh. The result is cached per source and stashed in
-- state.edit_target for stage 3 (floating nvim + staged push-back).
--
-- Binding: input.conf ->  ctrl+e  script-binding subedit/subedit-open
-- Options: script-opts/subedit.conf (ssh_target, path_map, api_token, ssh_timeout)

local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'
local options = require 'mp.options'

local SCRIPT = mp.get_script_name()

local opts = {
    -- ssh destination that can reach the real subtitle files
    ssh_target = 'root@puck.cerberus-canopus.ts.net',
    -- comma-separated serverprefix=hostprefix rewrites for MediaStream Path
    path_map = '/media/=/mnt/zfs/AOC-Media-12TB-1/',
    -- normally empty: the token is taken from the subtitle URL itself.
    -- Set only if that token cannot see MediaStream Path (needs admin).
    api_token = '',
    ssh_timeout = 6,
}
options.read_options(opts, 'subedit')

local state = {
    cues = nil,        -- parsed cue list for the open menu
    source = nil,      -- path or URL the cues came from
    track_title = nil,
    footnote = nil,
    edit_target = nil, -- resolution result for stage 3
    menu_open = false,
}
local url_cache = {}     -- source URL -> raw srt content
local resolve_cache = {} -- source -> edit_target table

local function osd(text)
    mp.osd_message('subedit: ' .. text, 3)
    msg.info(text)
end

local function is_url(s)
    return s:match('^%a[%w+.-]*://') ~= nil
end

local function strip_bom(s)
    if s:sub(1, 3) == '\239\187\191' then return s:sub(4) end
    return s
end

local function basename(path)
    return path:match('([^/\\]+)$') or path
end

-- ---------------------------------------------------------------------------
-- SRT parsing (stage 1)

-- "00:12:34,567 --> 00:12:36,000" (SRT) or with '.' separators (VTT-style)
local TS_PATTERN = '^%s*(%d+):(%d%d):(%d%d)[,%.](%d%d?%d?)%s*%-%->%s*(%d+):(%d%d):(%d%d)[,%.](%d%d?%d?)'

local function parse_timestamps(line)
    local h1, m1, s1, f1, h2, m2, s2, f2 = line:match(TS_PATTERN)
    if not h1 then return nil end
    local function secs(h, m, s, f)
        return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
            + tonumber((f .. '000'):sub(1, 3)) / 1000
    end
    return secs(h1, m1, s1, f1), secs(h2, m2, s2, f2)
end

local function fmt_time(t)
    local ms = math.floor(t * 1000 + 0.5)
    local h = math.floor(ms / 3600000)
    local m = math.floor(ms % 3600000 / 60000)
    local s = math.floor(ms % 60000 / 1000)
    return string.format('%02d:%02d:%02d,%03d', h, m, s, ms % 1000)
end

-- Returns a list of cues. Line numbers are 1-based positions in the source
-- file: ts_line is the timestamp line, text_line the first text line (what
-- stage 3 will point the editor at), file_idx the cue's own index number if
-- the file has one.
local function parse_srt(content)
    local lines = {}
    for line in (content .. '\n'):gmatch('(.-)\r?\n') do
        lines[#lines + 1] = line
    end
    local cues = {}
    local i = 1
    while i <= #lines do
        local start, stop = parse_timestamps(lines[i])
        if start then
            local text = {}
            local j = i + 1
            while j <= #lines and lines[j]:match('%S') do
                text[#text + 1] = lines[j]
                j = j + 1
            end
            local file_idx
            if i > 1 then file_idx = lines[i - 1]:match('^%s*(%d+)%s*$') end
            cues[#cues + 1] = {
                start = start,
                stop = stop,
                text = table.concat(text, ' / '),
                ts_line = i,
                text_line = math.min(i + 1, j),
                file_idx = file_idx and tonumber(file_idx) or nil,
            }
            i = j
        else
            i = i + 1
        end
    end
    return cues
end

-- Index of the cue containing t, else the closest one by start/stop distance.
local function nearest(cues, t)
    if #cues == 0 then return nil end
    local lo, hi = 1, #cues
    while lo < hi do
        local mid = math.ceil((lo + hi) / 2)
        if cues[mid].start <= t then lo = mid else hi = mid - 1 end
    end
    if cues[lo].start > t then return 1 end          -- t is before the first cue
    if t <= cues[lo].stop then return lo end          -- inside cue lo
    if lo < #cues and (cues[lo + 1].start - t) < (t - cues[lo].stop) then
        return lo + 1
    end
    return lo
end

-- ---------------------------------------------------------------------------
-- Real-file resolution (stage 2)

-- Jellyfin external-subtitle delivery URL:
--   https://host[:port]/Videos/{item}/{mediasource}/Subtitles/{index}/{start}/Stream.srt?ApiKey=...
local function parse_stream_url(url)
    local base, rest = url:match('^(https?://[^/?#]+)(/.*)$')
    if not base then return nil end
    local item, msid, index = rest:match('/Videos/([%w%-]+)/(%w+)/Subtitles/(%d+)/%d+/Stream%.%w+')
    if not item then return nil end
    local token = url:match('[?&][Aa]pi_?[Kk]ey=(%w+)')
    return { base = base, item = item, msid = msid, index = tonumber(index), token = token }
end

local function norm_id(s)
    return (s:lower():gsub('%-', ''))
end

local function map_path(server_path)
    for rule in opts.path_map:gmatch('[^,]+') do
        local from, to = rule:match('^(.-)=(.*)$')
        if from and from ~= '' and server_path:sub(1, #from) == from then
            return to .. server_path:sub(#from + 1)
        end
    end
    return nil
end

local function sh_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function http_get(url, cb)
    mp.command_native_async({
        name = 'subprocess',
        capture_stdout = true,
        capture_stderr = true,
        args = {'curl', '-sfL', '--max-time', '10', url},
    }, function(ok, res)
        if not ok or not res or res.status ~= 0 then return cb(nil) end
        cb(res.stdout)
    end)
end

-- cb('WRITABLE'|'READONLY'|'MISSING'|'ssh failed (...)')
local function probe_remote(path, cb)
    local remote = 'p=' .. sh_quote(path)
        .. '; if test -w "$p"; then echo WRITABLE;'
        .. ' elif test -e "$p"; then echo READONLY;'
        .. ' else echo MISSING; fi'
    mp.command_native_async({
        name = 'subprocess',
        capture_stdout = true,
        capture_stderr = true,
        args = {
            'timeout', tostring(opts.ssh_timeout),
            'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
            '-o', 'ControlMaster=auto', '-o', 'ControlPath=/tmp/subedit-ssh-%C',
            '-o', 'ControlPersist=600',
            opts.ssh_target, remote,
        },
    }, function(ok, res)
        local out = ok and res and res.status == 0 and (res.stdout or ''):match('%u+')
        if out then return cb(out) end
        cb(string.format('ssh failed (exit %s)', res and res.status or '?'))
    end)
end

local function host_label()
    return opts.ssh_target:match('@(.+)$') or opts.ssh_target
end

local function resolve_target(source, cb)
    if resolve_cache[source] then return cb(resolve_cache[source]) end
    local function done(t)
        resolve_cache[source] = t
        cb(t)
    end
    if not is_url(source) then
        local w = io.open(source, 'r+')
        if w then
            w:close()
            return done({editable = true, kind = 'local', path = source,
                         desc = 'editable (local): ' .. source})
        end
        local r = io.open(source, 'r')
        if r then
            r:close()
            return done({editable = false, desc = 'view only (local file not writable)'})
        end
        return done({editable = false, desc = 'view only (local file unreadable)'})
    end
    local p = parse_stream_url(source)
    if not p then
        return done({editable = false, desc = 'view only (unrecognized stream url)'})
    end
    local token = opts.api_token ~= '' and opts.api_token or p.token
    if not token then
        return done({editable = false,
                     desc = 'view only (no token in url; set api_token in script-opts)'})
    end
    http_get(p.base .. '/Items/' .. p.item .. '/PlaybackInfo?api_key=' .. token,
        function(body)
            local data = body and utils.parse_json(body)
            if not data or not data.MediaSources then
                return done({editable = false, desc = 'view only (api request failed)'})
            end
            local server_path
            for _, ms in ipairs(data.MediaSources) do
                if norm_id(ms.Id or '') == norm_id(p.msid) then
                    for _, st in ipairs(ms.MediaStreams or {}) do
                        if st.Type == 'Subtitle' and st.Index == p.index then
                            server_path = st.Path
                        end
                    end
                end
            end
            if not server_path then
                return done({editable = false,
                             desc = 'view only (no Path in api response; token may lack admin)'})
            end
            local host_path = map_path(server_path)
            if not host_path then
                return done({editable = false,
                             desc = 'view only (no path mapping for ' .. server_path .. ')'})
            end
            probe_remote(host_path, function(status)
                if status == 'WRITABLE' then
                    done({editable = true, kind = 'remote', path = host_path,
                          ssh = opts.ssh_target,
                          desc = 'editable on ' .. host_label() .. ': ' .. host_path})
                elseif status == 'READONLY' or status == 'MISSING' then
                    done({editable = false,
                          desc = 'view only (file ' .. status:lower() .. ' on ' .. host_label() .. ')'})
                else
                    done({editable = false, desc = 'view only (' .. status .. ')'})
                end
            end)
        end)
end

-- ---------------------------------------------------------------------------
-- Menu

local function build_menu(cues, t, selected)
    local items = {}
    for i, c in ipairs(cues) do
        items[i] = {
            title = c.text ~= '' and c.text or '(empty cue)',
            hint = fmt_time(c.start),
            active = t >= c.start and t <= c.stop,
            keep_open = true,
            value = {'script-message-to', SCRIPT, 'subedit-activate', tostring(i)},
        }
    end
    return {
        type = 'subedit',
        title = state.track_title or basename(state.source or 'subtitles'),
        footnote = state.footnote or '',
        items = items,
        selected_index = selected,
        on_close = {'script-message-to', SCRIPT, 'subedit-closed'},
    }
end

local function with_content(source, cb)
    if not is_url(source) then
        local f = io.open(source, 'rb')
        if not f then return osd('cannot read ' .. source) end
        local content = f:read('*all')
        f:close()
        return cb(content)
    end
    if url_cache[source] then return cb(url_cache[source]) end
    osd('fetching subtitles...')
    mp.command_native_async({
        name = 'subprocess',
        capture_stdout = true,
        capture_stderr = true,
        args = {'curl', '-sfL', '--max-time', '10', source},
    }, function(ok, res)
        if not ok or not res or res.status ~= 0 or not res.stdout or res.stdout == '' then
            local detail = res and res.stderr or ''
            return osd('fetch failed ' .. detail)
        end
        url_cache[source] = res.stdout
        cb(res.stdout)
    end)
end

local function current_sub_time()
    return (mp.get_property_number('time-pos') or 0)
        - (mp.get_property_number('sub-delay') or 0)
end

local function open_menu()
    if state.menu_open then
        mp.commandv('script-message-to', 'uosc', 'close-menu', 'subedit')
        return
    end
    local track = mp.get_property_native('current-tracks/sub')
    if not track then return osd('no subtitle track selected') end
    if not track.external then
        return osd('embedded subtitles not supported (external srt only)')
    end
    local source = track['external-filename']
    if not source then return osd('track has no external filename') end
    with_content(source, function(content)
        content = strip_bom(content)
        if content:sub(1, 13) == '[Script Info]' then
            return osd('ASS subtitles not supported (srt only)')
        end
        local cues = parse_srt(content)
        if #cues == 0 then return osd('no cues parsed from ' .. basename(source)) end
        state.cues = cues
        state.source = source
        state.track_title = track.title
        local cached = resolve_cache[source]
        state.edit_target = cached
        state.footnote = cached and cached.desc or 'checking file access...'
        local t = current_sub_time()
        local sel = nearest(cues, t)
        mp.commandv('script-message-to', 'uosc', 'open-menu',
            utils.format_json(build_menu(cues, t, sel)))
        state.menu_open = true
        if not cached then
            resolve_target(source, function(target)
                state.edit_target = target
                state.footnote = target.desc
                msg.info('resolved: ' .. target.desc)
                if state.menu_open and state.source == source then
                    local t2 = current_sub_time()
                    mp.commandv('script-message-to', 'uosc', 'update-menu',
                        utils.format_json(build_menu(cues, t2, nearest(cues, t2))))
                end
            end)
        end
    end)
end

mp.register_script_message('subedit-activate', function(i)
    local c = state.cues and state.cues[tonumber(i)]
    if not c then return end
    local delay = mp.get_property_number('sub-delay') or 0
    mp.commandv('seek', tostring(c.start + delay + 0.001), 'absolute+exact')
    -- refresh active highlight for the new position, keep selection on the cue
    local menu = build_menu(state.cues, c.start + 0.001, tonumber(i))
    mp.commandv('script-message-to', 'uosc', 'update-menu', utils.format_json(menu))
end)

mp.register_script_message('subedit-closed', function()
    state.menu_open = false
end)

mp.register_event('end-file', function()
    url_cache = {}
    resolve_cache = {}
    state.cues = nil
    state.edit_target = nil
    state.menu_open = false
end)

-- ---------------------------------------------------------------------------
-- Offline self-tests (no network, no uosc):
--   SUBEDIT_SELFTEST=<file.srt> [SUBEDIT_T=<secs>] mpv --no-config --idle=once --script=subedit.lua
--   SUBEDIT_SELFTEST_URL=<url> [SUBEDIT_SELFTEST_PATH=<serverpath>] mpv --no-config --idle=once --script=subedit.lua
local selftest = os.getenv('SUBEDIT_SELFTEST')
local selftest_url = os.getenv('SUBEDIT_SELFTEST_URL')
if selftest or selftest_url then
    if selftest then
        local f = assert(io.open(selftest, 'rb'))
        local content = strip_bom(f:read('*all'))
        f:close()
        local cues = parse_srt(content)
        print('cues: ' .. #cues)
        for k, c in ipairs(cues) do
            print(string.format('%d\t%s --> %s\tts_line=%d text_line=%d idx=%s\t%s',
                k, fmt_time(c.start), fmt_time(c.stop), c.ts_line, c.text_line,
                tostring(c.file_idx), c.text))
        end
        local t = tonumber(os.getenv('SUBEDIT_T') or '0')
        print(string.format('nearest to %.3f: cue %s', t, tostring(nearest(cues, t))))
    end
    if selftest_url then
        local p = parse_stream_url(selftest_url)
        if p then
            print(string.format('base=%s item=%s msid=%s index=%d token=%s',
                p.base, p.item, p.msid, p.index, tostring(p.token)))
        else
            print('url parse failed')
        end
        local sp = os.getenv('SUBEDIT_SELFTEST_PATH')
        if sp then print('mapped: ' .. tostring(map_path(sp))) end
    end
    mp.command('quit')
    return
end

mp.add_key_binding(nil, 'subedit-open', open_menu)
