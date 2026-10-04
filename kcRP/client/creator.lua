-- BasicRP's character creator: the client half of a new character and of /look (gamemodes/basicrp.lua). The mode sends the
-- parts it offers ("creator_parts") and opens the creator with the player's look ("creator" "new;<look>" or "edit;<look>");
-- this draws the menu in the game's own UI, shows every change on a preview body in front of the player - only this screen
-- sees it - and asks the server for the look the player settles on. The mode's OnPlayerLookChange takes it, saves it with
-- the account and closes the creator ("creator" "close"). A mode that sends a woman's lists too lets the player pick a
-- woman's body (the Body row): her faces, hair and skins, and no beard. A script the server sends runs in the sandbox:
-- https://docs.kcd-mp.com/lua/client/getting-started/

local parts = nil       -- {faces, styles = {{name, colors, words}}, beards, skins, her = {faces, styles, skins} or nil}: the mode's lists
local isOpen = false
local isNew = false     -- a new character: no cancel
local waiting = false   -- asked the server; the mode's "close" ends it
local female = false    -- the Body row: a woman's body
local sel = {face = 1, style = 1, color = 1, beard = 1, skin = 1}
local row = 1
local turn, near = 0, false

local ROWS = {"face", "style", "color", "beard", "skin"}   -- with "body" first when the mode offers a woman's parts
local LABELS = {body = "Body", face = "Face", style = "Hair", color = "Hair color", beard = "Beard", skin = "Skin"}
local X, Y, W = 60, 280, 620      -- the panel, in the 1080-row UI space
local ROW_Y, ROW_H = 372, 52

math.randomseed(os.time())

-- ------------------------------------------------------------------ the mode's lists
local function list(s)
  local out = {}
  for item in (s or ""):gmatch("[^,]+") do out[#out + 1] = item end
  return out
end

-- a hair color's word: what its name adds to the style's other colors ("m_hair_005_dark_brown" -> "Dark brown")
local function color_words(colors)
  if #colors < 2 then return {"-"} end
  local prefix = colors[1]
  for _, name in ipairs(colors) do
    while prefix ~= "" and name:sub(1, #prefix) ~= prefix do prefix = prefix:sub(1, -2) end
  end
  prefix = prefix:match("^(.*_)") or ""   -- whole words: black and blonde share "bl"
  local words = {}
  for i, name in ipairs(colors) do
    local word = name:sub(#prefix + 1):gsub("_", " ")
    if word == "" then word = "natural" end
    words[i] = word:sub(1, 1):upper() .. word:sub(2)
  end
  return words
end

local function styles_of(value)
  local styles = {}
  for entry in value:gmatch("[^;]+") do
    local style, colors = entry:match("^([^:]+):(.*)$")
    if style then
      local c = list(colors)
      styles[#styles + 1] = {name = style, colors = c, words = color_words(c)}
    end
  end
  return styles
end

local function parse(payload)
  local p = {faces = {}, styles = {}, beards = {}, skins = {}}
  local her = {faces = {}, styles = {}, skins = {}}
  for key, value in payload:gmatch("(%a+)=([^|]*)") do
    if key == "faces" then p.faces = list(value)
    elseif key == "beards" then p.beards = list(value)
    elseif key == "skins" then p.skins = list(value)
    elseif key == "hair" then p.styles = styles_of(value)
    elseif key == "ffaces" then her.faces = list(value)   -- a woman's (she has no beard)
    elseif key == "fskins" then her.skins = list(value)
    elseif key == "fhair" then her.styles = styles_of(value) end
  end
  if #her.faces > 0 and #her.styles > 0 then p.her = her end
  return p
end

-- ------------------------------------------------------------------ the choice
local function wrap(i, n) if n < 1 then return 1 end return (i - 1) % n + 1 end
local function index_of(t, v) for i, x in ipairs(t) do if x == v then return i end end return nil end
local function random_index(t) if #t < 1 then return 1 end return math.random(#t) end

-- the lists of the body chosen: a man's, or a woman's
local function set() return female and parts.her or parts end

local function current_look()
  local p = set()
  local style = p.styles[sel.style]
  return {gender = female and "female" or nil, head = p.faces[sel.face], hair = style and style.colors[sel.color],
          beard = not female and parts.beards[sel.beard] or nil, body = p.skins[sel.skin]}
end

local function randomize()
  local p = set()
  sel.face = random_index(p.faces)
  sel.style = random_index(p.styles)
  sel.color = random_index(p.styles[sel.style] and p.styles[sel.style].colors or {})
  sel.beard = random_index(parts.beards)
  sel.skin = random_index(p.skins)
end

-- the indices of a look the server sent; a part it does not have is a random one
local function choose(look)
  female = look.gender == "female" and parts.her ~= nil
  randomize()
  local p = set()
  sel.face = index_of(p.faces, look.head) or sel.face
  for si, style in ipairs(p.styles) do
    local ci = index_of(style.colors, look.hair)
    if ci then sel.style, sel.color = si, ci break end
  end
  sel.beard = index_of(parts.beards, look.beard) or sel.beard
  sel.skin = index_of(p.skins, look.body) or sel.skin
end

-- a new style keeps the color the player picked when it has it
local function set_style(i)
  local p = set()
  local word = p.styles[sel.style] and p.styles[sel.style].words[sel.color]
  sel.style = i
  sel.color = index_of(p.styles[i].words, word) or 1
end

local function step(kind, delta)
  local p = set()
  if kind == "body" then female = not female randomize()   -- the other body's own lists: a face, hair and skin of hers (his)
  elseif kind == "face" then sel.face = wrap(sel.face + delta, #p.faces)
  elseif kind == "style" then set_style(wrap(sel.style + delta, #p.styles))
  elseif kind == "color" then sel.color = wrap(sel.color + delta, #p.styles[sel.style].colors)
  elseif kind == "beard" then if not female then sel.beard = wrap(sel.beard + delta, #parts.beards) end
  elseif kind == "skin" then sel.skin = wrap(sel.skin + delta, #p.skins) end
end

local function value_of(kind)
  local p = set()
  if kind == "body" then return female and "Woman" or "Man" end
  if kind == "face" then return string.format("%d / %d", sel.face, #p.faces) end
  if kind == "style" then
    local name = p.styles[sel.style].name
    if name == "x_hair_20" then return "Shaved" end
    if name == "m_hair_tonsure" then return "Tonsure" end
    local cut = name:match("^m_hair_barber_0*(%d+)$")
    if cut then return "Barber's cut " .. cut end
    return string.format("%d / %d", sel.style, #p.styles)
  end
  if kind == "color" then return p.styles[sel.style].words[sel.color] or "-" end
  if kind == "beard" then
    if female or parts.beards[sel.beard] == "m_beard_00" then return "None" end
    return string.format("%d / %d", sel.beard, #parts.beards)
  end
  return string.format("%d / %d", sel.skin, #p.skins)
end

-- ------------------------------------------------------------------ the screen
local function show_preview()
  ShowLookPreview(current_look(), {distance = near and 0.9 or 1.6, turn = turn})
end

local function hints()
  return "W / S  choose      A / D  change      Q / E  turn", "Z  closer      R  random      Space  done" .. (isNew and "" or "      Esc  cancel")
end

local function draw_rows()
  for i, kind in ipairs(ROWS) do
    local value = value_of(kind)
    if i == row then value = "<   " .. value .. "   >" end
    SetUiText("cc_v" .. i, value)
    SetUiColor("cc_l" .. i, i == row and COLOR_GOLD or COLOR_WHITE)
  end
  SetUiPos("cc_sel", X + 20, ROW_Y + (row - 1) * ROW_H - 8)
end

-- everything hangs under one clip of its own: the creator's close takes it down and leaves the mode's other UI alone
local function build()
  ROWS = parts.her and {"body", "face", "style", "color", "beard", "skin"} or {"face", "style", "color", "beard", "skin"}
  local extra = (#ROWS - 5) * ROW_H   -- the Body row pushes the hints down
  DestroyUiElement("cc")
  CreateUiClip("cc")
  CreateUiRect("cc_bg", X, Y, W, 440 + extra, 0x000000, 58, "cc")
  CreateUiText("cc_title", X + 30, Y + 22, isNew and "Make your character" or "Your character", COLOR_GOLD, 1.2, UI_ALIGN_LEFT, "cc")
  CreateUiRect("cc_sel", X + 20, ROW_Y - 8, W - 40, 46, COLOR_GOLD, 14, "cc")
  for i, kind in ipairs(ROWS) do
    local y = ROW_Y + (i - 1) * ROW_H
    CreateUiText("cc_l" .. i, X + 40, y, LABELS[kind], COLOR_WHITE, 0.9, UI_ALIGN_LEFT, "cc")
    CreateUiText("cc_v" .. i, X + W - 40, y, "", COLOR_GOLD, 0.9, UI_ALIGN_RIGHT, "cc")
  end
  local keys1, keys2 = hints()
  CreateUiText("cc_hint1", X + 30, Y + 346 + extra, keys1, 0xC8C8C8, 0.6, UI_ALIGN_LEFT, "cc")
  CreateUiText("cc_hint2", X + 30, Y + 374 + extra, keys2, 0xC8C8C8, 0.6, UI_ALIGN_LEFT, "cc")
  CreateUiText("cc_note", X + 30, Y + 406 + extra, "", COLOR_YELLOW, 0.62, UI_ALIGN_LEFT, "cc")
  draw_rows()
end

local function note(text) SetUiText("cc_note", text) end

local function close()
  if not isOpen then return end
  isOpen, waiting = false, false
  HideLookPreview()
  DestroyUiElement("cc")
  SetKeyboardCapture(false)
end

local function open(new, look)
  if not parts or #parts.faces == 0 or #parts.styles == 0 then
    print("creator: the mode sent no parts to choose from")
    return
  end
  isNew = new
  waiting = false
  row, turn, near = 1, 0, false
  choose(look)
  isOpen = true
  SetKeyboardCapture(true)   -- the menu's keys: the player stands while choosing
  build()
  show_preview()
end

local function done()
  if waiting then return end
  if RequestLookChange(current_look()) then
    waiting = true
    note("Saving your look ...")
    Script.SetTimer(5000, function()
      if isOpen and waiting then
        waiting = false
        note("The server did not take this look - Space tries again.")
      end
    end)
  end
end

-- ------------------------------------------------------------------ the callbacks
-- this file's events and keys; the rest go on to what the scripts before it defined (account.lua: the password box)
local nextEvent, nextKey = OnServerEvent, OnKey

function OnServerEvent(name, payload)
  if name == "creator_parts" then
    parts = parse(payload)
  elseif name == "creator" then
    if payload == "close" then close() return end
    local kind, line = payload:match("^(%a+);(.*)$")
    if kind then open(kind == "new", LookFromString(line)) end
  elseif nextEvent then
    return nextEvent(name, payload)
  end
end

function OnKey(key, pressed)
  if not isOpen then
    if nextKey then return nextKey(key, pressed) end
    return
  end
  if not pressed then return end
  local kind = ROWS[row]
  if key == "w" or key == "up" then row = wrap(row - 1, #ROWS)
  elseif key == "s" or key == "down" then row = wrap(row + 1, #ROWS)
  elseif key == "a" or key == "left" then step(kind, -1) show_preview()
  elseif key == "d" or key == "right" then step(kind, 1) show_preview()
  elseif key == "q" then turn = turn - 30 show_preview()
  elseif key == "e" then turn = turn + 30 show_preview()
  elseif key == "z" then near = not near show_preview()
  elseif key == "r" then randomize() show_preview()
  elseif key == "space" or key == "enter" then done()
  elseif key == "escape" and not isNew then
    SendServerEvent("creator_cancel", "")
    close()
    return
  else
    return
  end
  if isOpen then draw_rows() end
end

-- the look the mode took: the creator's work is done (the mode's "close" follows)
function OnLookChange(look)
  if isOpen and waiting then close() end
end
