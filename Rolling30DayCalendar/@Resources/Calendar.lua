-- Calendar.lua - Month calendar, Monday first.
-- Pure ASCII. Written for both Lua 5.1 and 5.4 (Rainmeter uses either).
--
-- Rainmeter calls Initialize() once and Update() every skin update. Meters do not
-- exist yet during Initialize(), so it only prepares paths; Update() draws.
--
-- Data file: @Resources\Events.txt, one line per date:
--     YYYY-MM-DD=Event one|Event two
-- Event format:  [!] Title [time]     e.g.  AoA 09:30   |   ! COA   |   Lab 2:30pm
--   * time goes after the title (24h or am/pm); it is stored as HH:MM
--   * a leading ! marks an important event/day
-- Comment lines (;) and unrelated lines are kept when saving.

local CELLS     = 42      -- 6 weeks x 7 days
local MAX_LINES = 5       -- event lines in the day panel
local READ_EVERY = 15     -- re-read Events.txt every N updates (1 update = 1 s)

local COLOR_TEXT   = '232,235,241'
local COLOR_MUTED  = '125,136,151'
local COLOR_DIM    = '78,88,102'
local COLOR_WEEKEND = '160,168,180'
local COLOR_ERROR  = '255,110,110'
local COLOR_ACCENT = '110,190,255'
local COLOR_ONACCENT = '19,22,29'
local COLOR_NEXT   = '150,160,175'

local HINT = 'Click a day to view it. Click below to edit: AoA 09:30, ! = important.'

local DAYS   = { 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat' }
local MONTHS = { 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' }
local MONTHS_FULL = { 'January', 'February', 'March', 'April', 'May', 'June', 'July',
                      'August', 'September', 'October', 'November', 'December' }

local TRANSPARENT = 'Fill Color 0,0,0,0 | StrokeWidth 0'

local state = {
  eventsPath = nil,
  initError  = nil,
  raw        = nil,
  lines      = {},
  events     = {},   -- "YYYY-MM-DD" -> normalised "A|B"
  cells      = {},   -- cell index -> { key=, month=, year= }
  todayKey   = nil,
  viewY      = nil,
  viewM      = nil,
  selKey     = nil,
  editKey    = nil,
  force      = true,
  ticks      = 0,
  statusUntil = 0,
  lastError  = nil,
  missingWarned = false,
  timed      = {},   -- { t = epoch, title = }
  upcoming   = {},   -- { days =, title = } for the date-only fallback
  lastCountdown = nil,
}

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local function log(msg, level)
  pcall(function() SKIN:Bang('!Log', 'Calendar.lua: ' .. tostring(msg), level or 'Debug') end)
end

local function trim(s)
  return (tostring(s):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Remove characters that would break Rainmeter bang parsing or the file format.
local function clean(s)
  s = tostring(s or '')
  s = s:gsub('[%c]', ' ')
  s = s:gsub('"', "'")
  s = s:gsub('%[', '('):gsub('%]', ')')
  return s
end

local function splitEvents(value)
  local list = {}
  for part in (tostring(value or '') .. '|'):gmatch('([^|]*)|') do
    part = trim(part)
    if part ~= '' then list[#list + 1] = part end
  end
  return list
end

local function fmtKey(d)
  return string.format('%04d-%02d-%02d', d.year, d.month, d.day)
end

local function fmtLabel(d)
  return string.format('%s, %02d %s %d', DAYS[d.wday], d.day, MONTHS[d.month], d.year)
end

local function keyParts(key)
  local y, m, d = key:match('^(%d+)-(%d+)-(%d+)$')
  return tonumber(y), tonumber(m), tonumber(d)
end

local function keyTime(key, hour, min)
  local y, m, d = keyParts(key)
  return os.time({ year = y, month = m, day = d, hour = hour or 12, min = min or 0, sec = 0 })
end

local function setOpt(meter, option, value)
  SKIN:Bang('!SetOption', meter, option, tostring(value))
end

local function setStatus(msg, kind, seconds)
  -- kind: 'error' | 'ok' | nil (hint)
  local text, color = HINT, COLOR_MUTED
  if kind == 'error' then
    text, color = 'ERROR: ' .. clean(msg), COLOR_ERROR
  elseif kind == 'ok' then
    text, color = clean(msg), COLOR_ACCENT
  end
  setOpt('Footer', 'Text', text)
  setOpt('Footer', 'FontColor', color)
  SKIN:Bang('!UpdateMeter', 'Footer')
  SKIN:Bang('!Redraw')
  state.statusUntil = (seconds and seconds > 0) and (os.time() + seconds) or 0
end

local function reportError(err)
  local msg = tostring(err)
  if msg ~= state.lastError then
    state.lastError = msg
    log(msg, 'Error')
  end
  pcall(setStatus, msg, 'error', 0)
end

---------------------------------------------------------------------------
-- event text: "[!] Title [time]"
---------------------------------------------------------------------------
-- Finds a time anywhere in the text: "14:30", "2:30pm", "2:30 pm", "9am", "9 pm".
-- (An older "@14:30" form is still understood.) Returns title-without-time, hour,
-- minute, or nil when there is no valid time.
local function parseTime(part)
  local s, e, h, m = part:find('@?%s*%f[%d](%d%d?):(%d%d)%f[%D]')
  if not s then
    local p
    s, e, h, p = part:find('@?%s*%f[%d](%d%d?)()%s*[aApP][mM]%f[%A]')
    if not s then return nil end
    e = p - 1
    m = 0
  end
  h, m = tonumber(h), tonumber(m)
  local rest = part:sub(e + 1)
  local ap = rest:match('^%s*([aApP])[mM]%f[%A]')
  if ap then
    local _, ae = rest:find('^%s*[aApP][mM]%f[%A]')
    e = e + ae
    if h < 1 or h > 12 then return nil end
    if ap:lower() == 'a' then
      if h == 12 then h = 0 end
    else
      if h ~= 12 then h = h + 12 end
    end
  end
  if h > 23 or m > 59 then return nil end
  local title = trim((part:sub(1, s - 1) .. ' ' .. part:sub(e + 1)):gsub('%s+', ' '))
  return title, h, m
end

-- One event part -> { imp, title, h, m, time, sortKey, text } or nil when empty.
local function parseEvent(part)
  part = trim(part)
  local imp = false
  if part:sub(1, 1) == '!' then
    imp = true
    part = trim((part:gsub('^!+', '')))
  end
  if part == '' then return nil end
  local title, h, m = parseTime(part)
  if not h then title, h, m = part, nil, nil end
  local ev = { imp = imp, title = title, h = h, m = m }
  if h then
    ev.time = string.format('%02d:%02d', h, m)
    ev.sortKey = h * 60 + m
  else
    ev.time = ''
    ev.sortKey = -1            -- untimed events first
  end
  local text = (imp and '! ' or '') .. title
  if h then text = text .. ((title ~= '') and ' ' or '') .. ev.time end
  ev.text = text
  return ev
end

-- All events of a day: untimed first, then by time; stable for equal times.
local function parseEvents(value)
  local list = {}
  for _, part in ipairs(splitEvents(clean(value))) do
    local ev = parseEvent(part)
    if ev then
      ev.idx = #list + 1
      list[#list + 1] = ev
    end
  end
  table.sort(list, function(a, b)
    if a.sortKey ~= b.sortKey then return a.sortKey < b.sortKey end
    return a.idx < b.idx
  end)
  return list
end

local function normalise(value)
  local texts = {}
  for _, ev in ipairs(parseEvents(value)) do texts[#texts + 1] = ev.text end
  return table.concat(texts, '|')
end

---------------------------------------------------------------------------
-- paths and file I/O
---------------------------------------------------------------------------
local function resolveResourcesPath()
  local p = SKIN:ReplaceVariables('#@#')
  if p == nil or p == '' or p == '#@#' then
    p = SKIN:ReplaceVariables('#CURRENTPATH#')
    if p == nil or p == '' or p == '#CURRENTPATH#' then
      error('Cannot resolve #@# or #CURRENTPATH#; is the skin inside Documents\\Rainmeter\\Skins?')
    end
    if not p:match('[\\/]$') then p = p .. '\\' end
    p = p .. '@Resources\\'
  end
  if not p:match('[\\/]$') then p = p .. '\\' end
  return p
end

local function readFile(path)
  local f, err = io.open(path, 'rb')
  if not f then return nil, err end
  local data = f:read('*a') or ''
  f:close()
  if data:sub(1, 3) == '\239\187\191' then data = data:sub(4) end -- strip UTF-8 BOM
  return data
end

local function writeFile(path, data)
  local f, err = io.open(path, 'wb')
  if not f then return false, err end
  local ok, werr = f:write(data)
  f:close()
  if not ok then return false, werr end
  return true
end

local function parse(raw)
  state.lines, state.events = {}, {}
  for line in (raw .. '\n'):gmatch('([^\n]*)\n') do
    line = line:gsub('\r$', '')
    state.lines[#state.lines + 1] = line
    local key, value = line:match('^%s*(%d%d%d%d%-%d%d%-%d%d)%s*=(.*)$')
    if key then
      local norm = normalise(value)
      if norm ~= '' then state.events[key] = norm end
    end
  end
  if state.lines[#state.lines] == '' then state.lines[#state.lines] = nil end
end

-- returns true if the file content changed since the last read
local function loadEvents()
  local raw, err = readFile(state.eventsPath)
  if raw == nil then
    if not state.missingWarned then
      state.missingWarned = true
      log('Events.txt not found at ' .. state.eventsPath .. ' (' .. tostring(err) .. '). It will be created on first save.', 'Warning')
    end
    raw = ''
  end
  if raw ~= state.raw then
    state.raw = raw
    parse(raw)
    return true
  end
  return false
end

local function saveEventsFile()
  local out = {}
  for i = 1, #state.lines do out[i] = state.lines[i] end
  local text = table.concat(out, '\r\n')
  if #out > 0 then text = text .. '\r\n' end
  if state.raw and state.raw ~= '' then
    writeFile(state.eventsPath:gsub('%.txt$', '.bak'), state.raw)  -- backup first
  end
  local ok, err = writeFile(state.eventsPath, text)
  if not ok then error('Cannot write ' .. state.eventsPath .. ': ' .. tostring(err)) end
  state.raw = text
end

---------------------------------------------------------------------------
-- countdown (next timed event; falls back to the next day that has events)
---------------------------------------------------------------------------
local updateCountdown

local function rebuildCountdownData()
  state.timed, state.upcoming = {}, {}
  local keys = {}
  for key in pairs(state.events) do
    if key >= state.todayKey then keys[#keys + 1] = key end
  end
  table.sort(keys)
  local todayNoon = keyTime(state.todayKey)
  for _, key in ipairs(keys) do
    local pick
    for _, ev in ipairs(parseEvents(state.events[key])) do
      if ev.h then
        state.timed[#state.timed + 1] = {
          t = keyTime(key, ev.h, ev.m),
          title = (ev.title ~= '') and ev.title or 'Event',
        }
      end
      -- date-only fallback: today only counts untimed events (timed ones may be past)
      if key ~= state.todayKey or not ev.h then
        if pick == nil or (ev.imp and not pick.imp) then pick = ev end
      end
    end
    if pick then
      state.upcoming[#state.upcoming + 1] = {
        days = math.floor((keyTime(key) - todayNoon) / 86400 + 0.5),
        title = (pick.title ~= '') and pick.title or 'Event',
      }
    end
  end
end

local function formatDiff(secs)
  local d = math.floor(secs / 86400)
  local h = math.floor((secs % 86400) / 3600)
  local m = math.floor((secs % 3600) / 60)
  local sec = secs % 60
  if d > 0 then return string.format('%dd %dh %dm', d, h, m) end
  if h > 0 then return string.format('%dh %02dm', h, m) end
  return string.format('%dm %02ds', m, sec)
end

updateCountdown = function()
  local now = os.time()
  local best
  for _, e in ipairs(state.timed) do
    local diff = e.t - now
    if diff > -60 and (best == nil or diff < best.diff) then best = { diff = diff, title = e.title } end
  end
  local text, color
  if best then
    local title = clean(best.title)
    if best.diff <= 0 then text = 'Now - ' .. title
    else text = 'In ' .. formatDiff(best.diff) .. ' - ' .. title end
    color = COLOR_ACCENT
  elseif state.upcoming[1] then
    local u = state.upcoming[1]
    if u.days <= 0 then text = 'Today - ' .. clean(u.title)
    elseif u.days == 1 then text = 'Tomorrow - ' .. clean(u.title)
    else text = 'In ' .. u.days .. 'd - ' .. clean(u.title) end
    color = COLOR_NEXT
  else
    text, color = 'No upcoming events', COLOR_MUTED
  end
  if text ~= state.lastCountdown then
    state.lastCountdown = text
    setOpt('Countdown', 'Text', text)
    setOpt('Countdown', 'FontColor', color)
    SKIN:Bang('!UpdateMeter', 'Countdown')
    SKIN:Bang('!Redraw')
  end
end

---------------------------------------------------------------------------
-- rendering
---------------------------------------------------------------------------
local function renderGrid()
  local vy, vm = state.viewY, state.viewM
  setOpt('MonthTitle', 'Text', MONTHS_FULL[vm] .. ' ' .. vy)

  local first = os.date('*t', os.time({ year = vy, month = vm, day = 1, hour = 12 }))
  local offset = (first.wday + 5) % 7           -- Monday = 0 ... Sunday = 6
  state.cells = {}

  for i = 1, CELLS do
    local t = os.time({ year = vy, month = vm, day = 1 - offset + (i - 1), hour = 12 })
    local d = os.date('*t', t)
    local key = fmtKey(d)
    local col = ((i - 1) % 7) + 1
    state.cells[i] = { key = key, year = d.year, month = d.month }

    local inMonth  = (d.month == vm)
    local isToday  = (key == state.todayKey)
    local selected = (key == state.selKey)
    local evs = parseEvents(state.events[key])
    local important = false
    for _, ev in ipairs(evs) do if ev.imp then important = true end end

    local numColor
    if isToday then numColor = COLOR_ONACCENT
    elseif not inMonth then numColor = COLOR_DIM
    elseif col >= 6 then numColor = COLOR_WEEKEND
    else numColor = COLOR_TEXT end

    local n = string.format('%02d', i)
    local cell = 'Cell' .. n
    setOpt(cell .. 'Day', 'Text', d.day)
    setOpt(cell .. 'Day', 'FontColor', numColor)

    if selected then
      setOpt(cell, 'Shape', 'Rectangle 1,1,42,36,8 | Fill Color 38,65,91,255 | StrokeWidth 1 | Stroke Color 110,190,255,190')
    else
      setOpt(cell, 'Shape', 'Rectangle 1,1,42,36,8 | Fill Color 0,0,0,1 | StrokeWidth 0')
    end
    setOpt(cell, 'Shape2', isToday and 'Ellipse 22,13,11 | Fill Color 110,190,255,255 | StrokeWidth 0'
                                    or ('Ellipse 22,13,11 | ' .. TRANSPARENT))
    if #evs > 0 then
      local dot
      if important then dot = inMonth and COLOR_ACCENT or '70,120,160'
      else dot = inMonth and COLOR_MUTED or '70,80,95' end
      setOpt(cell, 'Shape3', 'Ellipse 22,30,' .. (important and '2.5' or '2') .. ' | Fill Color ' .. dot .. ',255 | StrokeWidth 0')
    else
      setOpt(cell, 'Shape3', 'Ellipse 22,30,2 | ' .. TRANSPARENT)
    end
    if important then
      setOpt(cell, 'Shape4', 'Ellipse 22,30,4.5 | Fill Color 0,0,0,0 | StrokeWidth 1 | Stroke Color 110,190,255,' .. (inMonth and '170' or '90'))
    else
      setOpt(cell, 'Shape4', 'Ellipse 22,30,4.5 | ' .. TRANSPARENT)
    end
  end
end

local function renderPanel()
  local y, m, d = keyParts(state.selKey)
  local info = os.date('*t', os.time({ year = y, month = m, day = d, hour = 12 }))
  local heading = fmtLabel(info)
  if state.selKey == state.todayKey then heading = heading .. ' (today)' end
  setOpt('DayHeading', 'Text', heading)

  local evs = parseEvents(state.events[state.selKey])
  if #evs == 0 then
    setOpt('DayCount', 'Text', 'No events')
  else
    setOpt('DayCount', 'Text', #evs .. ((#evs == 1) and ' event' or ' events'))
  end

  for k = 1, MAX_LINES do
    local title, time, tcolor, timecolor = ' ', ' ', COLOR_TEXT, COLOR_MUTED
    if #evs == 0 then
      if k == 1 then title, tcolor = 'Nothing planned. Click here to add.', COLOR_MUTED end
    elseif #evs > MAX_LINES and k == MAX_LINES then
      title, tcolor = '+' .. (#evs - (MAX_LINES - 1)) .. ' more', COLOR_MUTED
    elseif evs[k] then
      local ev = evs[k]
      title = (ev.title ~= '') and ev.title or 'Event'
      time = (ev.time ~= '') and ev.time or ' '
      if ev.imp then tcolor, timecolor = COLOR_ACCENT, COLOR_ACCENT end
    end
    setOpt('Ev' .. k .. 'Title', 'Text', title)
    setOpt('Ev' .. k .. 'Title', 'FontColor', tcolor)
    setOpt('Ev' .. k .. 'Time', 'Text', time)
    setOpt('Ev' .. k .. 'Time', 'FontColor', timecolor)
  end
end

local function renderAll()
  renderGrid()
  renderPanel()
  rebuildCountdownData()
  state.lastCountdown = nil
  updateCountdown()
  SKIN:Bang('!UpdateMeter', '*')
  SKIN:Bang('!Redraw')
end

local function showMonth(year, month)
  state.viewY, state.viewM = year, month
  local firstKey = string.format('%04d-%02d-01', year, month)
  local ty, tm = keyParts(state.todayKey)
  if ty == year and tm == month then state.selKey = state.todayKey else state.selKey = firstKey end
end

local function tick()
  if state.initError then error(state.initError) end
  state.ticks = state.ticks + 1
  local now = os.date('*t')
  local key = fmtKey(now)
  local changed = state.force

  if key ~= state.todayKey then            -- first run, or midnight rollover
    state.todayKey = key
    state.viewY, state.viewM, state.selKey = now.year, now.month, key
    changed = true
  end

  if changed or (state.ticks % READ_EVERY == 0) then
    if loadEvents() then changed = true end
  end

  if changed then
    renderAll()
    state.force = false
    state.lastError = nil
    setStatus(nil, nil, 0)                 -- hint text, clears any earlier error
  elseif state.statusUntil > 0 and os.time() >= state.statusUntil then
    setStatus(nil, nil, 0)
  end
  updateCountdown()
end

---------------------------------------------------------------------------
-- Rainmeter entry points
---------------------------------------------------------------------------
function Initialize()
  local ok, err = pcall(function()
    state.eventsPath = resolveResourcesPath() .. 'Events.txt'
  end)
  if not ok then
    state.initError = tostring(err)
    log(state.initError, 'Error')
  else
    log('Events file: ' .. state.eventsPath, 'Notice')
  end
  state.force = true
end

function Update()
  local ok, err = pcall(tick)
  if not ok then
    state.force = true                     -- retry on the next update
    reportError(err)
  end
  return 0
end

-- Click on a day cell (1..42).
function SelectDay(i)
  local ok, err = pcall(function()
    local cell = state.cells[tonumber(i)]
    if not cell then error('SelectDay: grid not ready') end
    state.selKey = cell.key
    if cell.month ~= state.viewM then state.viewY, state.viewM = cell.year, cell.month end
    renderAll()
  end)
  if not ok then reportError(err) end
end

local function shiftMonth(delta)
  local ok, err = pcall(function()
    local m, y = state.viewM + delta, state.viewY
    if m < 1 then m, y = 12, y - 1 elseif m > 12 then m, y = 1, y + 1 end
    showMonth(y, m)
    renderAll()
  end)
  if not ok then reportError(err) end
end

function PrevMonth() shiftMonth(-1) end
function NextMonth() shiftMonth(1) end

-- TODAY: jump to the current month, select today, re-read the data file.
function GoToday()
  local ok, err = pcall(function()
    local now = os.date('*t')
    state.todayKey = fmtKey(now)
    showMonth(now.year, now.month)
    state.raw = nil
    loadEvents()
    renderAll()
    setStatus('Refreshed', 'ok', 3)
  end)
  if not ok then reportError(err) end
end

-- Click on the day panel: open the input box (placed over the heading by the .ini).
function EditDay()
  local ok, err = pcall(function()
    if not state.selKey then error('EditDay: no day selected') end
    state.editKey = state.selKey
    SKIN:Bang('!SetOption', 'InputEvent', 'DefaultValue', state.events[state.selKey] or '')
    SKIN:Bang('!UpdateMeasure', 'InputEvent')
    SKIN:Bang('!CommandMeasure', 'InputEvent', 'ExecuteBatch 1')
  end)
  if not ok then reportError(err) end
end

-- Called by InputText Command1 after it stored the text in the EditValue variable.
function SaveEvent()
  local ok, err = pcall(function()
    local key = state.editKey
    if not key then error('SaveEvent: no day selected') end
    local value = normalise(SKIN:GetVariable('EditValue'))

    loadEvents()                           -- pick up Notepad edits made since last read

    local newLine = (value ~= '') and (key .. '=' .. value) or nil
    local out, replaced = {}, false
    for _, line in ipairs(state.lines) do
      local k = line:match('^%s*(%d%d%d%d%-%d%d%-%d%d)%s*=')
      if k == key then
        if newLine and not replaced then
          out[#out + 1] = newLine
          replaced = true
        end                                -- otherwise: deleted or duplicate line
      else
        out[#out + 1] = line
      end
    end
    if newLine and not replaced then out[#out + 1] = newLine end
    if #out == 0 then out[1] = '; Format: YYYY-MM-DD=Event one|Event two' end
    state.lines = out

    saveEventsFile()
    state.editKey = nil
    state.events[key] = (value ~= '') and value or nil
    renderAll()
    setStatus((value == '') and ('Cleared ' .. key) or ('Saved ' .. key), 'ok', 5)
  end)
  if not ok then reportError(err) end
end
