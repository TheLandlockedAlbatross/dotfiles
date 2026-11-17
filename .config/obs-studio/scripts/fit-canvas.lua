-- fit-canvas.lua: the canvas follows the scene.
--
-- Whenever the program scene changes, the canvas is resized to exactly fit
-- the monitor sources visible in it and they are placed edge to edge at
-- native size. So a scene with one monitor records at that monitor's size, a
-- scene with several records at their combined size, and there is never any
-- scaling or black border.
-- After hiding or showing a monitor inside a scene, switch scenes or press
-- "Fit now" in Tools > Scripts.
--
-- A "monitor source" is a Screen Capture (PipeWire) source named after a
-- Hyprland output, as `hyprctl monitors` names it. Scenes with none are left
-- alone.
-- Monitors keep their desk arrangement when the visible ones form a full
-- rectangle; otherwise (a diagonal pair, three of four) they go side by side.
--
-- The canvas cannot change while recording, streaming or the replay buffer is
-- running, so the fit waits and is applied when the output stops.
--
-- Threading: the canvas may only be reset from OBS's UI thread. Frontend
-- events and the script's property callbacks run there. Script timers and
-- scene item signals do not (timers fire on the graphics thread, and a reset
-- from there hangs OBS), so nothing here uses them.

obs = obslua

local KIND = "pipewire-screen-capture-source"
local scale_percent = 100
local fitting = false

local function log(msg)
  obs.script_log(obs.LOG_INFO, msg)
end

-- Hyprland outputs by name: { w, h, col, row }
local function monitors()
  local pipe = io.popen("hyprctl monitors -j 2>/dev/null")
  if not pipe then return {} end
  local out = pipe:read("*a")
  pipe:close()
  local data = obs.obs_data_create_from_json('{"m":' .. (out ~= "" and out or "[]") .. "}")
  if not data then return {} end
  local arr = obs.obs_data_get_array(data, "m")
  local list, xs, ys = {}, {}, {}
  for i = 0, obs.obs_data_array_count(arr) - 1 do
    local it = obs.obs_data_array_item(arr, i)
    local w, h = obs.obs_data_get_int(it, "width"), obs.obs_data_get_int(it, "height")
    if obs.obs_data_get_int(it, "transform") % 2 == 1 then w, h = h, w end
    local m = { name = obs.obs_data_get_string(it, "name"), w = w, h = h,
                x = obs.obs_data_get_int(it, "x"), y = obs.obs_data_get_int(it, "y") }
    list[#list + 1] = m
    xs[m.x], ys[m.y] = true, true
    obs.obs_data_release(it)
  end
  obs.obs_data_array_release(arr)
  obs.obs_data_release(data)
  local function rank(set)
    local keys, pos = {}, {}
    for k in pairs(set) do keys[#keys + 1] = k end
    table.sort(keys)
    for i, k in ipairs(keys) do pos[k] = i end
    return pos
  end
  local col, row, by_name = rank(xs), rank(ys), {}
  for _, m in ipairs(list) do
    m.col, m.row = col[m.x], row[m.y]
    by_name[m.name] = m
  end
  return by_name
end

-- Positions for the picked monitors plus the canvas size that fits them.
local function place(picked)
  table.sort(picked, function(a, b)
    if a.m.row ~= b.m.row then return a.m.row < b.m.row end
    return a.m.col < b.m.col
  end)
  local cols, rows, ncols, nrows = {}, {}, 0, 0
  for _, p in ipairs(picked) do
    if not cols[p.m.col] then cols[p.m.col] = 0; ncols = ncols + 1 end
    if not rows[p.m.row] then rows[p.m.row] = 0; nrows = nrows + 1 end
    cols[p.m.col] = math.max(cols[p.m.col], p.m.w)
    rows[p.m.row] = math.max(rows[p.m.row], p.m.h)
  end
  if #picked ~= ncols * nrows then -- not a full rectangle: one row
    local x, h = 0, 0
    for _, p in ipairs(picked) do
      p.x, p.y = x, 0
      x, h = x + p.m.w, math.max(h, p.m.h)
    end
    return x, h
  end
  local function offsets(sizes)
    local keys, at, total = {}, {}, 0
    for k in pairs(sizes) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do at[k] = total; total = total + sizes[k] end
    return at, total
  end
  local col_x, width = offsets(cols)
  local row_y, height = offsets(rows)
  for _, p in ipairs(picked) do p.x, p.y = col_x[p.m.col], row_y[p.m.row] end
  return width, height
end

local function output_running()
  return obs.obs_frontend_recording_active() or obs.obs_frontend_streaming_active()
      or obs.obs_frontend_replay_buffer_active()
end

local function even(n)
  return math.max(2, math.floor(n / 2 + 0.5) * 2)
end

local function fit()
  if fitting then return end
  local scene_source = obs.obs_frontend_get_current_scene()
  if not scene_source then return end
  fitting = true
  local mons = monitors()
  local items = obs.obs_scene_enum_items(obs.obs_scene_from_source(scene_source))
  local picked = {}
  for _, item in ipairs(items or {}) do
    local source = obs.obs_sceneitem_get_source(item)
    local m = mons[obs.obs_source_get_name(source)]
    if m and obs.obs_source_get_unversioned_id(source) == KIND
        and obs.obs_sceneitem_visible(item) then
      picked[#picked + 1] = { item = item, m = m }
    end
  end
  if #picked > 0 then
    local width, height = place(picked)
    local out_w, out_h = even(width * scale_percent / 100), even(height * scale_percent / 100)
    local cfg = obs.obs_frontend_get_profile_config()
    local changed = obs.config_get_uint(cfg, "Video", "BaseCX") ~= width
        or obs.config_get_uint(cfg, "Video", "BaseCY") ~= height
        or obs.config_get_uint(cfg, "Video", "OutputCX") ~= out_w
        or obs.config_get_uint(cfg, "Video", "OutputCY") ~= out_h
    if changed and output_running() then
      log("canvas change waits until recording/streaming stops")
    else
      if changed then
        obs.config_set_uint(cfg, "Video", "BaseCX", width)
        obs.config_set_uint(cfg, "Video", "BaseCY", height)
        obs.config_set_uint(cfg, "Video", "OutputCX", out_w)
        obs.config_set_uint(cfg, "Video", "OutputCY", out_h)
        obs.config_save(cfg)
        obs.obs_frontend_reset_video()
        log(string.format("canvas %dx%d, output %dx%d", width, height, out_w, out_h))
      end
      -- After the reset: OBS rescales item positions with the canvas.
      local pos, one = obs.vec2(), obs.vec2()
      one.x, one.y = 1, 1
      for _, p in ipairs(picked) do
        pos.x, pos.y = p.x, p.y
        obs.obs_sceneitem_set_bounds_type(p.item, obs.OBS_BOUNDS_NONE)
        obs.obs_sceneitem_set_alignment(p.item, 5) -- top left
        obs.obs_sceneitem_set_rot(p.item, 0)
        obs.obs_sceneitem_set_scale(p.item, one)
        obs.obs_sceneitem_set_pos(p.item, pos)
      end
    end
  end
  obs.sceneitem_list_release(items)
  obs.obs_source_release(scene_source)
  fitting = false
end

local function on_event(event)
  if event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED
      or event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING
      or event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED
      or event == obs.OBS_FRONTEND_EVENT_PROFILE_CHANGED
      or event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED
      or event == obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED
      or event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED then
    fit()
  end
end

function script_description()
  return "<b>Fit canvas to scene</b><br>Resizes the canvas to exactly fit the monitor "
      .. "sources visible in the current scene, at native resolution. Switch scenes "
      .. "and the canvas follows."
end

function script_properties()
  local props = obs.obs_properties_create()
  obs.obs_properties_add_int_slider(props, "scale_percent",
    "Output size (% of canvas)", 10, 100, 5)
  obs.obs_properties_add_button(props, "fit_now", "Fit now", function()
    fit()
    return false
  end)
  return props
end

function script_defaults(settings)
  obs.obs_data_set_default_int(settings, "scale_percent", 100)
end

function script_update(settings)
  scale_percent = obs.obs_data_get_int(settings, "scale_percent")
  fit()
end

function script_load(settings)
  obs.obs_frontend_add_event_callback(on_event)
end
