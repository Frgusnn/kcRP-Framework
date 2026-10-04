-- BasicRP's cart maker: the client half of /createcart (gamemodes/basicrp.lua). The mode sends what carts are made of
-- ("cartmaker_parts": every kind's slots and parts) and opens the window with the cart it put in front of the player - in a
-- world of their own - ("cartmaker" "open;<kind>;<parts>;<x>;<y>;<z>", the cart's middle). This draws the window in the
-- game's own UI, turns the view onto the cart, and sends every choice to the mode, which makes it on that cart at once: the
-- player sees what changes as they pick it. Space asks for the cart, Esc gives it up; the mode's "close" takes the window
-- down. A script the server sends runs in the sandbox: https://docs.kcd-mp.com/lua/client/getting-started/

local catalogue = nil   -- {order = {kind, ...}, [kind] = {slots = {slot, ...}, parts = {[slot] = {part, ...}}}}: the mode's lists
local isOpen = false
local waiting = false   -- asked for the cart; the mode's "close" ends it
local kind = nil        -- the kind in the window
local sel = {}          -- kind -> slot -> the chosen part's index (none = the slot as the mode made it)
local row = 1
local ROWS = {}         -- "kind", then the kind's slots that have more than one part

local X, Y, W = 60, 240, 720      -- the window, in the 1080-row UI space
local ROW_Y, ROW_H = 332, 52
local VIEW_SHIFT = math.rad(18)   -- the view turned this much left of the cart: it stands clear of the window

local KIND_NAMES = {wagon = "Wagon, two horses", cart = "Two-wheeler, one horse"}
local SLOT_NAMES = {body = "Body", axle = "Front axle", wheels = "Wheels", load = "Load", horse1 = "Left horse", horse2 = "Right horse"}
local PART_NAMES = {
  body = {a = "Farm wagon", b = "Box wagon, boards in the bed", b_plain = "Box wagon", c = "Ladder wagon",
    a_covered = "Farm wagon, covered", b_covered = "Box wagon, covered", c_covered = "Ladder wagon, covered"},
  axle = {b = "Plain", b_covered = "The covered wagon's"},
  wheels = {b_covered = "Spoked", b = "Spoked, light", polygonal = "Rough-hewn"},
  load = {none = "Empty", sacks = "Sacks", charcoal = "Charcoal", carpets = "Cloth and crates", stones = "Stones",
    hay_small = "A little hay", hay_medium = "Hay", hay_large = "A full load of hay", goods = "Goods", junk = "Junk",
    cabbage = "Cabbages", market = "Market wares"},
}

math.randomseed(os.time())

-- ------------------------------------------------------------------ the mode's lists
local function list(s)
  local out = {}
  for item in (s or ""):gmatch("[^,]+") do out[#out + 1] = item end
  return out
end

local function index_of(names, name)
  for i, n in ipairs(names) do if n == name then return i end end
  return nil
end

-- "wagon:body=a,b;axle=b,b_covered|cart:load=none,goods"
local function parse(payload)
  local cat = {order = {}}
  for entry in (payload or ""):gmatch("[^|]+") do
    local k, rest = entry:match("^([%w_]+):(.*)$")
    if k then
      local c = {slots = {}, parts = {}}
      for s in rest:gmatch("[^;]+") do
        local slot, names = s:match("^([%w_]+)=(.*)$")
        if slot then
          c.slots[#c.slots + 1] = slot
          c.parts[slot] = list(names)
        end
      end
      cat[k] = c
      cat.order[#cat.order + 1] = k
    end
  end
  return cat
end

-- a part as a player reads it: the table's name, else its own words ("light_grey" -> "Light grey")
local function part_name(slot, part)
  local named = PART_NAMES[slot] and PART_NAMES[slot][part]
  if named then return named end
  local words = part:gsub("_", " ")
  return words:sub(1, 1):upper() .. words:sub(2)
end

local function slot_name(slot)
  if slot == "horse1" and kind == "cart" then return "Horse" end
  return SLOT_NAMES[slot] or part_name("", slot)
end

-- the kind's choices as the mode reads them: "slot=part,..." (only the slots the player set, or the mode told)
local function parts_of(k)
  local c, out = catalogue[k], {}
  for _, slot in ipairs(c.slots) do
    local i = sel[k] and sel[k][slot]
    if i then out[#out + 1] = slot .. "=" .. c.parts[slot][i] end
  end
  return table.concat(out, ",")
end

-- ------------------------------------------------------------------ the rows
local function build_rows()
  ROWS = {}
  if #catalogue.order > 1 then ROWS[1] = "kind" end
  for _, slot in ipairs(catalogue[kind].slots) do
    if #catalogue[kind].parts[slot] > 1 then ROWS[#ROWS + 1] = slot end   -- a slot with one part has nothing to choose
  end
end

local function wrap(i, n) return (i - 1) % n + 1 end

local function value_of(r)
  if r == "kind" then return KIND_NAMES[kind] or part_name("", kind) end
  local names = catalogue[kind].parts[r]
  local i = sel[kind][r] or 1
  return string.format("%s  (%d / %d)", part_name(r, names[i]), i, #names)
end

local function draw_rows()
  for i, r in ipairs(ROWS) do
    local value = value_of(r)
    if i == row then value = "<   " .. value .. "   >" end
    SetUiText("cm_l" .. i, r == "kind" and "Model" or slot_name(r))
    SetUiText("cm_v" .. i, value)
    SetUiColor("cm_l" .. i, i == row and COLOR_GOLD or COLOR_WHITE)
  end
  SetUiPos("cm_sel", X + 20, ROW_Y + (row - 1) * ROW_H - 8)
end

-- everything hangs under one clip of its own: the close takes it down and leaves the mode's other UI alone
local function build()
  build_rows()
  local h = ROW_Y - Y + #ROWS * ROW_H + 120
  DestroyUiElement("cm")
  CreateUiClip("cm")
  CreateUiRect("cm_bg", X, Y, W, h, 0x000000, 58, "cm")
  CreateUiText("cm_title", X + 30, Y + 22, "Build your cart", COLOR_GOLD, 1.2, UI_ALIGN_LEFT, "cm")
  CreateUiRect("cm_sel", X + 20, ROW_Y - 8, W - 40, 46, COLOR_GOLD, 14, "cm")
  for i = 1, #ROWS do
    local y = ROW_Y + (i - 1) * ROW_H
    CreateUiText("cm_l" .. i, X + 40, y, "", COLOR_WHITE, 0.9, UI_ALIGN_LEFT, "cm")
    CreateUiText("cm_v" .. i, X + W - 40, y, "", COLOR_GOLD, 0.9, UI_ALIGN_RIGHT, "cm")
  end
  local hy = ROW_Y + #ROWS * ROW_H + 6
  CreateUiText("cm_hint1", X + 30, hy, "W / S  choose      A / D  change      Q / E  turn", 0xC8C8C8, 0.6, UI_ALIGN_LEFT, "cm")
  CreateUiText("cm_hint2", X + 30, hy + 28, "R  random      Space  build it      Esc  cancel", 0xC8C8C8, 0.6, UI_ALIGN_LEFT, "cm")
  CreateUiText("cm_note", X + 30, hy + 60, "", COLOR_YELLOW, 0.62, UI_ALIGN_LEFT, "cm")
  draw_rows()
end

local function note(text) SetUiText("cm_note", text or "") end

-- the view level and on the cart, a little to its left: the cart stands in the open part of the screen
local function face(cx, cy)
  local px, py = GetPlayerPos()
  if not px or not (player and player.actor and player.actor.PlayerSetViewAngles) then return end
  local dx, dy = cx - px, cy - py
  if dx * dx + dy * dy < 1 then return end
  pcall(player.actor.PlayerSetViewAngles, player.actor, {x = 0, y = 0, z = math.atan2(-dx, dy) + VIEW_SHIFT})
end

-- ------------------------------------------------------------------ the choices
local function set_part(slot, i)
  sel[kind][slot] = i
  SendServerEvent("cartmaker_set", slot .. "=" .. catalogue[kind].parts[slot][i])
end

local function step(r, delta)
  if r == "kind" then
    local order = catalogue.order
    kind = order[wrap((index_of(order, kind) or 1) + delta, #order)]
    sel[kind] = sel[kind] or {}
    SendServerEvent("cartmaker_kind", kind .. ";" .. parts_of(kind))
    build()   -- the other kind's rows
    return
  end
  local names = catalogue[kind].parts[r]
  set_part(r, wrap((sel[kind][r] or 1) + delta, #names))
end

local function randomize()
  local c = catalogue[kind]
  for _, slot in ipairs(c.slots) do sel[kind][slot] = math.random(#c.parts[slot]) end
  SendServerEvent("cartmaker_set", parts_of(kind))
end

-- ------------------------------------------------------------------ open and close
-- the mode's word on what the cart is made of, "slot=part,..."
local function read_parts(k, parts)
  local c = catalogue[k]
  sel[k] = sel[k] or {}
  for slot, part in (parts or ""):gmatch("([%w_]+)=([%w_]+)") do
    if c.parts[slot] then sel[k][slot] = index_of(c.parts[slot], part) end
  end
end

local function close()
  if not isOpen then return end
  isOpen, waiting = false, false
  DestroyUiElement("cm")
  SetKeyboardCapture(false)
end

local function open(k, parts, cx, cy)
  if not catalogue or not catalogue[k] then
    print("cartmaker: the mode sent no parts for a " .. tostring(k))
    return
  end
  kind = k
  sel[k] = {}
  read_parts(k, parts)
  for _, other in ipairs(catalogue.order) do sel[other] = sel[other] or {} end
  row, waiting = 1, false
  isOpen = true
  SetKeyboardCapture(true)   -- the window's keys: the player stands while choosing
  build()
  face(cx, cy)
  SendServerEvent("cartmaker_shown", "")
end

local function done()
  if waiting then return end
  waiting = true
  note("Building your cart ...")
  SendServerEvent("cartmaker_done", "")
  Script.SetTimer(5000, function()
    if isOpen and waiting then
      waiting = false
      note("The server did not answer - Space tries again.")
    end
  end)
end

-- ------------------------------------------------------------------ the callbacks
-- this file's events and keys; the rest go on to what the scripts before it defined (account.lua: the password box)
local nextEvent, nextKey = OnServerEvent, OnKey

function OnServerEvent(name, payload)
  if name == "cartmaker_parts" then
    catalogue = parse(payload)
  elseif name == "cartmaker" then
    if payload == "close" then close() return end
    local k, parts, x, y = payload:match("^open;([%w_]+);([^;]*);([-%d.]+);([-%d.]+);")
    if k then open(k, parts, tonumber(x), tonumber(y)) return end
    k, parts = payload:match("^parts;([%w_]+);(.*)$")   -- the cart of another kind as the mode made it
    if k and isOpen and k == kind then
      read_parts(k, parts)
      draw_rows()
    end
  elseif nextEvent then
    return nextEvent(name, payload)
  end
end

function OnKey(key, pressed)
  if not isOpen then
    if nextKey then return nextKey(key, pressed) end
    return
  end
  if not pressed or waiting then return end
  local r = ROWS[row]
  if key == "w" or key == "up" then row = wrap(row - 1, #ROWS)
  elseif key == "s" or key == "down" then row = wrap(row + 1, #ROWS)
  elseif key == "a" or key == "left" then step(r, -1)
  elseif key == "d" or key == "right" then step(r, 1)
  elseif key == "q" then SendServerEvent("cartmaker_turn", "-30")
  elseif key == "e" then SendServerEvent("cartmaker_turn", "30")
  elseif key == "r" then randomize()
  elseif key == "space" or key == "enter" then done()
  elseif key == "escape" then
    SendServerEvent("cartmaker_cancel", "")
    close()
    return
  else
    return
  end
  if isOpen then draw_rows() end
end
