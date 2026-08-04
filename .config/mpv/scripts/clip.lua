-- clip.lua — Record clips or single frames from video using ffmpeg
-- Keybindings configured via input.conf using script-binding clip/<name>

local utils = require 'mp.utils'
local msg = require 'mp.msg'
local opts = require 'mp.options'
local input = require 'mp.input'

-- Configurable options (overridable via script-opts/clip.conf)
local options = {
    name = "$default",
    save_path = "$default",
    video_ext = "mp4",
    audio_codec = "libopus",
    extra_ffmpeg_opts = "",
}
opts.read_options(options)

-- State
local clip_start_time = nil
local clip_end_time = nil
local active_process = nil


-- HELPERS --------------------------------------------------------------------


local function format_time(seconds)
    -- Filename-safe format: HH-MM-SS.mmm
    local h = math.floor(seconds / 3600)
    local m = math.floor(seconds % 3600 / 60)
    local s = seconds % 60
    return string.format("%02d-%02d-%06.3f", h, m, s)
end

local function format_time_display(seconds)
    -- OSD display format: HH:MM:SS.mmm
    local h = math.floor(seconds / 3600)
    local m = math.floor(seconds % 3600 / 60)
    local s = seconds % 60
    return string.format("%02d:%02d:%06.3f", h, m, s)
end

local function format_time_ffmpeg(seconds)
    -- ffmpeg timestamp format: HH:MM:SS.mmm
    local h = math.floor(seconds / 3600)
    local m = math.floor(seconds % 3600 / 60)
    local s = seconds % 60
    return string.format("%02d:%02d:%06.3f", h, m, s)
end

local function get_video_filename_no_ext()
    local filename = mp.get_property("filename")
    if not filename then return "unknown" end
    local dot = filename:match("^.*()%.")
    if dot then
        return filename:sub(1, dot - 1)
    end
    return filename
end

local function get_video_directory()
    local path = mp.get_property("path")
    if not path then return nil end
    -- Check if it's a network stream
    if path:find("://") then
        return os.getenv("HOME") .. "/Videos"
    end
    local dir, _ = utils.split_path(path)
    if dir == "" or dir == "." then
        dir = mp.get_property("working-directory") or os.getenv("HOME")
    end
    return dir
end

local function is_single_frame()
    return clip_start_time and clip_end_time and math.abs(clip_end_time - clip_start_time) < 0.001
end

local function resolve_default_name()
    local base = get_video_filename_no_ext()
    local ts = tostring(os.time())
    if is_single_frame() then
        return "clip_" .. base .. "_" .. format_time(clip_start_time) .. "_" .. ts
    else
        return "clip_" .. base .. "_" .. format_time(clip_start_time) .. "_" .. format_time(clip_end_time) .. "_" .. ts
    end
end

local function resolve_name()
    local name = options.name
    local default_name = resolve_default_name()
    if name == "$default" then
        return default_name
    end
    return name:gsub("%$default", default_name)
end

local function resolve_save_path()
    local path = options.save_path
    if path == "$default" then
        return get_video_directory()
    end
    -- Allow $default as component in path
    local vid_dir = get_video_directory() or ""
    path = path:gsub("%$default", vid_dir)
    -- Must be absolute
    if path:sub(1, 1) ~= "/" then
        mp.osd_message("Clip error: save_path must be absolute or $default", 3)
        return nil
    end
    return path
end

local function split_args(str)
    if not str or str == "" then return {} end
    local args = {}
    -- Simple split on spaces, respecting double quotes
    local in_quote = false
    local current = ""
    for i = 1, #str do
        local c = str:sub(i, i)
        if c == '"' then
            in_quote = not in_quote
        elseif c == ' ' and not in_quote then
            if #current > 0 then
                table.insert(args, current)
                current = ""
            end
        else
            current = current .. c
        end
    end
    if #current > 0 then
        table.insert(args, current)
    end
    return args
end

local function rm_file(path)
    mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = {"rm", "-f", "--", path},
    })
end


-- ACTIONS --------------------------------------------------------------------


local function clip_start_action()
    local pos = mp.get_property_number("time-pos")
    if not pos then
        mp.osd_message("Clip: no file loaded", 2)
        return
    end
    clip_start_time = pos
    mp.osd_message("Clip start: " .. format_time_display(pos), 2)
end

local function clip_stop_action()
    local pos = mp.get_property_number("time-pos")
    if not pos then
        mp.osd_message("Clip: no file loaded", 2)
        return
    end
    if not clip_start_time then
        mp.osd_message("Clip: set start first (Ctrl+Shift+S)", 2)
        return
    end
    clip_end_time = pos
    -- Swap if needed
    if clip_end_time < clip_start_time then
        clip_start_time, clip_end_time = clip_end_time, clip_start_time
    end
    if math.abs(clip_end_time - clip_start_time) < 0.001 then
        mp.osd_message("Clip: single frame at " .. format_time_display(clip_start_time), 2)
    else
        local duration = clip_end_time - clip_start_time
        mp.osd_message(string.format("Clip end: %s (duration: %.1fs)",
            format_time_display(clip_end_time), duration), 2)
    end
end

local function clip_write_action()
    if not clip_start_time or not clip_end_time then
        mp.osd_message("Clip: set start and end first", 2)
        return
    end
    if active_process then
        mp.osd_message("Clip: write already in progress", 2)
        return
    end

    local file_path = mp.get_property("path")
    if not file_path then
        mp.osd_message("Clip: no file loaded", 2)
        return
    end

    -- Resolve output path
    local save_dir = resolve_save_path()
    if not save_dir then return end
    local name = resolve_name()
    local single_frame = is_single_frame()

    local ext = single_frame and "png" or options.video_ext
    local output_filename = name .. "." .. ext
    local final_path = utils.join_path(save_dir, output_filename)
    local temp_path = final_path .. ".part"

    -- Build ffmpeg args
    local args = {"ffmpeg", "-y"}

    if single_frame then
        -- Single frame extraction
        table.insert(args, "-ss")
        table.insert(args, format_time_ffmpeg(clip_start_time))
        table.insert(args, "-i")
        table.insert(args, file_path)
        table.insert(args, "-frames:v")
        table.insert(args, "1")
        table.insert(args, "-update")
        table.insert(args, "1")
        table.insert(args, "-f")
        table.insert(args, "image2")
    else
        -- Clip extraction
        table.insert(args, "-ss")
        table.insert(args, format_time_ffmpeg(clip_start_time))
        table.insert(args, "-i")
        table.insert(args, file_path)
        table.insert(args, "-t")
        table.insert(args, tostring(clip_end_time - clip_start_time))
        table.insert(args, "-c")
        table.insert(args, "copy")
        table.insert(args, "-c:a")
        table.insert(args, options.audio_codec)
        table.insert(args, "-f")
        table.insert(args, ext)

        -- Extra ffmpeg options
        local extra = split_args(options.extra_ffmpeg_opts)
        for _, arg in ipairs(extra) do
            table.insert(args, arg)
        end
    end

    table.insert(args, temp_path)

    msg.info("ffmpeg args: " .. utils.to_string(args))
    mp.osd_message("Clip: writing...", 60)

    active_process = mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, function(success, result, error)
        active_process = nil

        if not success or (result and result.status ~= 0) then
            local err_msg = "unknown error"
            if result and result.stderr then
                -- Get last non-empty line of stderr for the most useful error
                for line in result.stderr:gmatch("[^\n]+") do
                    err_msg = line
                end
            elseif error then
                err_msg = tostring(error)
            end
            msg.error("ffmpeg failed: " .. (result and result.stderr or err_msg))
            mp.osd_message("Clip failed: " .. err_msg, 5)
            rm_file(temp_path)
            return
        end

        -- Atomic rename
        local ok, rename_err = os.rename(temp_path, final_path)
        if not ok then
            msg.warn("os.rename failed (" .. tostring(rename_err) .. "), trying mv")
            local mv = mp.command_native({
                name = "subprocess",
                playback_only = false,
                capture_stderr = true,
                args = {"mv", "--", temp_path, final_path},
            })
            if mv.status ~= 0 then
                mp.osd_message("Clip: rename failed: " .. tostring(mv.stderr), 5)
                return
            end
        end

        mp.osd_message("Clip saved: " .. final_path, 3)
        msg.info("Clip saved: " .. final_path)
    end)
end

local function clip_convert_action()
    if active_process then
        mp.osd_message("Clip: write already in progress", 2)
        return
    end

    local file_path = mp.get_property("path")
    if not file_path then
        mp.osd_message("Clip: no file loaded", 2)
        return
    end

    local save_dir = resolve_save_path()
    if not save_dir then return end

    local base = get_video_filename_no_ext()
    local ext = options.video_ext
    local date_str = os.date("%Y-%m-%d_%H-%M-%S")
    local output_filename = base .. "_" .. date_str .. "." .. ext
    local final_path = utils.join_path(save_dir, output_filename)
    local temp_path = final_path .. ".part"

    local args = {"ffmpeg", "-y", "-i", file_path, "-c", "copy", "-c:a", options.audio_codec, "-f", ext}

    local extra = split_args(options.extra_ffmpeg_opts)
    for _, arg in ipairs(extra) do
        table.insert(args, arg)
    end
    table.insert(args, temp_path)

    msg.info("ffmpeg convert args: " .. utils.to_string(args))
    mp.osd_message("Clip: converting full file...", 60)

    active_process = mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, function(success, result, error)
        active_process = nil

        if not success or (result and result.status ~= 0) then
            local err_msg = "unknown error"
            if result and result.stderr then
                for line in result.stderr:gmatch("[^\n]+") do
                    err_msg = line
                end
            elseif error then
                err_msg = tostring(error)
            end
            msg.error("ffmpeg failed: " .. (result and result.stderr or err_msg))
            mp.osd_message("Convert failed: " .. err_msg, 5)
            rm_file(temp_path)
            return
        end

        local ok, rename_err = os.rename(temp_path, final_path)
        if not ok then
            msg.warn("os.rename failed (" .. tostring(rename_err) .. "), trying mv")
            local mv = mp.command_native({
                name = "subprocess",
                playback_only = false,
                capture_stderr = true,
                args = {"mv", "--", temp_path, final_path},
            })
            if mv.status ~= 0 then
                mp.osd_message("Convert: rename failed: " .. tostring(mv.stderr), 5)
                return
            end
        end

        mp.osd_message("Converted: " .. final_path, 3)
        msg.info("Converted: " .. final_path)
    end)
end

local function clip_cancel_action()
    if active_process then
        mp.abort_async_command(active_process)
        active_process = nil
    end
    clip_start_time = nil
    clip_end_time = nil
    mp.osd_message("Clip cancelled", 2)
end


-- OPTIONS MENU (uosc graphical menu) -----------------------------------------


-- Which field is currently being edited (nil = main menu)
local editing_field = nil

local option_fields = {
    {key = "name",              title = "Name",              hint = "$default for auto"},
    {key = "save_path",         title = "Save Path",         hint = "$default for video dir"},
    {key = "video_ext",         title = "Video Extension",   hint = "e.g. mp4, mkv, webm"},
    {key = "audio_codec",       title = "Audio Codec",       hint = "e.g. libopus, aac, copy"},
    {key = "extra_ffmpeg_opts", title = "Extra FFmpeg Opts",  hint = "additional flags"},
}

local function open_main_menu()
    editing_field = nil
    local items = {}
    for _, field in ipairs(option_fields) do
        local val = options[field.key]
        if val == "" then val = "(empty)" end
        table.insert(items, {
            title = field.title,
            hint = val,
            value = field.key,
        })
    end
    local menu_data = utils.format_json({
        type = "clip_options",
        title = "Clip Options",
        callback = {"clip", "clip-menu-event"},
        items = items,
    })
    mp.commandv("script-message-to", "uosc", "open-menu", menu_data)
end

local function open_edit_menu(field_key)
    editing_field = field_key
    local field = nil
    for _, f in ipairs(option_fields) do
        if f.key == field_key then field = f; break end
    end
    if not field then return end

    local current = options[field_key]
    local menu_data = utils.format_json({
        type = "clip_option_edit",
        title = "Edit: " .. field.title,
        footnote = field.hint,
        search_style = "palette",
        search_debounce = "submit",
        search_suggestion = current,
        on_search = {"script-message-to", "clip", "clip-menu-search"},
        callback = {"clip", "clip-menu-event"},
        items = {},
    })
    mp.commandv("script-message-to", "uosc", "open-menu", menu_data)
end

-- Handle menu item activation (clicking an option in main menu)
mp.register_script_message("clip-menu-event", function(json)
    local event = utils.parse_json(json)
    if not event then return end

    if event.type == "activate" and event.value and not editing_field then
        -- Clicked an option in main menu -> open edit palette for it
        open_edit_menu(event.value)
    end
end)

-- Handle search submit (typing a new value and pressing enter)
-- uosc sends raw args: query, menu_id (not JSON) for on_search table callbacks
mp.register_script_message("clip-menu-search", function(query, menu_id)
    if editing_field and query then
        if query ~= "" then
            options[editing_field] = query
        end
        -- Return to main menu
        open_main_menu()
    end
end)

local function clip_options_action()
    open_main_menu()
end


-- CLEANUP --------------------------------------------------------------------


mp.add_hook("on_unload", 10, function()
    input.terminate()
end)


-- BINDINGS -------------------------------------------------------------------


mp.add_key_binding(nil, "clip_start", clip_start_action)
mp.add_key_binding(nil, "clip_stop", clip_stop_action)
mp.add_key_binding(nil, "clip_write", clip_write_action)
mp.add_key_binding(nil, "clip_cancel", clip_cancel_action)
mp.add_key_binding(nil, "clip_convert", clip_convert_action)
mp.add_key_binding(nil, "clip_options", clip_options_action)
