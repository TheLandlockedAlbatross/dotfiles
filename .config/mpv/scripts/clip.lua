-- clip.lua: mark a begin/end point and cut a clip of the current file with
-- ffmpeg (H.264 + Opus re-encode at visually lossless settings).
-- Marks are stored in ab-loop-a/b so uosc draws the range on the timeline;
-- ab-loop-count is forced to 0 while marking so playback does not loop.
--
-- script-bindings (see input.conf):
--   clip-mark-begin  set begin mark at current position
--   clip-mark-end    set end mark at current position
--   clip-dest        set destination directory (console prompt)
--   clip-clear       clear both marks
--   clip-create      encode the marked range

local options = require 'mp.options'
local utils = require 'mp.utils'

local opts = {
    dest = '~~home/Videos/clips',
    crf = 16,
    preset = 'slow',
    abitrate = '192k',
}
options.read_options(opts, 'clip')

local state = {
    dest = nil,          -- session override from clip-dest
    orig_loop_count = nil,
    encoding = false,
}

local function osd(msg, dur)
    mp.osd_message('clip: ' .. msg, dur or 2)
end

local function expand(p)
    return mp.command_native({'expand-path', p})
end

local function dest_dir()
    return state.dest or expand(opts.dest)
end

local function fmt_ts(t)
    local ms = math.floor(t * 1000 + 0.5)
    local h = math.floor(ms / 3600000)
    local m = math.floor(ms / 60000) % 60
    local s = math.floor(ms / 1000) % 60
    return string.format('%d.%02d.%02d.%03d', h, m, s, ms % 1000)
end

local function fmt_osd(t)
    local ms = math.floor(t * 1000 + 0.5)
    local h = math.floor(ms / 3600000)
    local m = math.floor(ms / 60000) % 60
    local s = math.floor(ms / 1000) % 60
    return string.format('%d:%02d:%02d.%01d', h, m, s, math.floor((ms % 1000) / 100))
end

local function disable_looping()
    if state.orig_loop_count == nil then
        state.orig_loop_count = mp.get_property('ab-loop-count')
        mp.set_property('ab-loop-count', '0')
    end
end

local function mark(which)
    local t = mp.get_property_number('time-pos')
    if not t then
        osd('no file playing')
        return
    end
    disable_looping()
    mp.set_property_number('ab-loop-' .. which, t)
    osd((which == 'a' and 'begin ' or 'end ') .. fmt_osd(t))
end

local function clear()
    mp.set_property('ab-loop-a', 'no')
    mp.set_property('ab-loop-b', 'no')
    if state.orig_loop_count ~= nil then
        mp.set_property('ab-loop-count', state.orig_loop_count)
        state.orig_loop_count = nil
    end
    osd('marks cleared')
end

local function set_dest()
    local ok, input = pcall(require, 'mp.input')
    if not ok then
        osd('mp.input unavailable; set dest in script-opts/clip.conf', 4)
        return
    end
    input.get({
        prompt = 'clip destination dir:',
        default_text = dest_dir(),
        submit = function(text)
            input.terminate()
            if text == '' then return end
            state.dest = expand(text)
            osd('dest: ' .. state.dest, 3)
        end,
    })
end

local function unique_path(dir, base, ext)
    local p = dir .. '/' .. base .. ext
    local n = 2
    while utils.file_info(p) do
        p = dir .. '/' .. base .. '_' .. n .. ext
        n = n + 1
    end
    return p
end

local function create()
    if state.encoding then
        osd('already encoding')
        return
    end
    local a = mp.get_property_number('ab-loop-a')
    local b = mp.get_property_number('ab-loop-b')
    if not a or not b then
        osd('set begin and end marks first')
        return
    end
    if a > b then a, b = b, a end
    if b - a < 0.05 then
        osd('range too short')
        return
    end
    local path = mp.get_property('path')
    if not path then
        osd('no file playing')
        return
    end
    if path:match('^%a[%w+.-]*://') and not path:match('^file://') then
        osd('local files only', 3)
        return
    end
    if not path:match('^/') then
        local dir = mp.get_property('working-directory')
        if dir then path = utils.join_path(dir, path) end
    end

    local dir = dest_dir()
    mp.command_native({name = 'subprocess', args = {'mkdir', '-p', dir},
                       playback_only = false})

    local fname = path:match('([^/]+)$') or 'clip'
    local base = fname:match('(.+)%.[^.]+$') or fname
    local out = unique_path(dir, base .. ' [' .. fmt_ts(a) .. '-' .. fmt_ts(b) .. ']', '.mkv')

    local args = {'ffmpeg', '-nostdin', '-loglevel', 'error',
                  '-ss', string.format('%.3f', a),
                  '-t', string.format('%.3f', b - a),
                  '-i', path, '-map', '0:v:0'}
    local aid = mp.get_property_number('aid')
    local ext_audio = mp.get_property_native('current-tracks/audio/external')
    if aid and not ext_audio then
        table.insert(args, '-map')
        table.insert(args, '0:a:' .. (aid - 1) .. '?')
    end
    for _, v in ipairs({'-c:v', 'libx264', '-preset', opts.preset,
                        '-crf', tostring(opts.crf),
                        '-c:a', 'libopus', '-b:a', opts.abitrate,
                        '-af', 'aformat=channel_layouts=7.1|5.1|stereo|mono',
                        '-map_chapters', '-1', out}) do
        table.insert(args, v)
    end

    state.encoding = true
    osd('encoding ' .. fmt_osd(a) .. ' - ' .. fmt_osd(b) .. ' ...', 4)
    mp.command_native_async(
        {name = 'subprocess', args = args, playback_only = false,
         capture_stderr = true},
        function(ok2, res)
            state.encoding = false
            if ok2 and res.status == 0 and utils.file_info(out) then
                osd('saved ' .. out, 5)
            else
                local err = res and res.stderr or ''
                err = err:match('([^\n]+)%s*$') or 'unknown error'
                osd('FAILED: ' .. err, 8)
                mp.msg.error('ffmpeg failed: ' .. (res and res.stderr or '?'))
            end
        end)
end

mp.add_key_binding(nil, 'clip-mark-begin', function() mark('a') end)
mp.add_key_binding(nil, 'clip-mark-end', function() mark('b') end)
mp.add_key_binding(nil, 'clip-dest', set_dest)
mp.add_key_binding(nil, 'clip-clear', clear)
mp.add_key_binding(nil, 'clip-create', create)
