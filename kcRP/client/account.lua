-- BasicRP's password box: the client half of the login (gamemodes/basicrp.lua). The mode opens it with "auth"
-- "register;<line>" (a name without an account chooses a password) or "login;<line>" (the password to log in), and takes it
-- down with "auth" "close"; the line under the field says what went wrong. The box holds the keyboard while it is up: the
-- password shows as stars, Enter sends it, Backspace takes a character back, Esc leaves the server and closes the game.
-- The characters come from OnTextInput (as the keyboard layout makes them), Enter / Backspace / Esc from OnKey.
-- A script the server sends runs in the sandbox: https://docs.kcd-mp.com/lua/client/getting-started/

local kind = nil       -- "register" | "login" while the box is up
local chars = {}       -- the password typed so far, one character per entry
local waiting = false  -- sent: the server's answer comes next
local MAX_LENGTH = 32
local W, H = 760, 300  -- the box, in the 1080-row UI space, centred across the screen

local TITLES = {register = "Create your account", login = "Log in"}

local function lines(k)
  local name = GetPlayerName() or "you"
  if k == "register" then
    return "The name " .. name .. " has no account here yet.", "Choose a password to make it yours."
  end
  return "Welcome, " .. name .. ".", "Enter your password."
end

local function field()
  return "Password:   " .. string.rep("*", #chars) .. "_"
end

local function note(text) SetUiText("acc_note", text or "") end

-- everything hangs under one clip of its own: the close takes it down and leaves the mode's other UI alone
local function build()
  local sw = GetScreenSize()
  local x, y = math.floor((sw - W) / 2), 300
  local cx = x + W / 2
  local line1, line2 = lines(kind)
  DestroyUiElement("acc")
  CreateUiClip("acc")
  CreateUiRect("acc_bg", x, y, W, H, 0x000000, 72, "acc")
  CreateUiRect("acc_top", x, y, W, 2, COLOR_GOLD, 70, "acc")          -- a thin gold frame, as the game's own boxes have
  CreateUiRect("acc_bottom", x, y + H - 2, W, 2, COLOR_GOLD, 70, "acc")
  CreateUiText("acc_title", cx, y + 24, TITLES[kind], COLOR_GOLD, 1.2, UI_ALIGN_CENTRE, "acc")
  CreateUiText("acc_line1", cx, y + 86, line1, COLOR_WHITE, 0.8, UI_ALIGN_CENTRE, "acc")
  CreateUiText("acc_line2", cx, y + 118, line2, COLOR_WHITE, 0.8, UI_ALIGN_CENTRE, "acc")
  CreateUiRect("acc_field_bg", x + 120, y + 160, W - 240, 46, 0x000000, 60, "acc")
  CreateUiText("acc_field", cx, y + 168, field(), COLOR_WHITE, 0.95, UI_ALIGN_CENTRE, "acc")
  CreateUiText("acc_note", cx, y + 220, "", COLOR_YELLOW, 0.7, UI_ALIGN_CENTRE, "acc")
  CreateUiText("acc_hint", cx, y + 256, "Enter  OK          Esc  Exit", 0xC8C8C8, 0.65, UI_ALIGN_CENTRE, "acc")
end

local function open(k, line)
  local rebuild = kind ~= k
  kind, chars, waiting = k, {}, false
  if rebuild then build() else SetUiText("acc_field", field()) end
  note(line)
  SetKeyboardCapture(true)   -- the box has the keys: nobody walks off, Enter does not open the chat, Esc is the box's
end

local function close()
  if not kind then return end
  kind, chars, waiting = nil, {}, false
  DestroyUiElement("acc")
  SetKeyboardCapture(false)
end

local function send()
  if waiting then return end
  if #chars == 0 then note("Type a password first.") return end
  if kind == "register" and #chars < 4 then note("A password is 4 characters or more.") return end
  SendServerEvent("auth_" .. kind, table.concat(chars))
  chars = {}   -- the answer brings the box back empty (a wrong password is typed again)
  SetUiText("acc_field", field())
  waiting = true
  note(kind == "register" and "Making your account ..." or "Checking ...")
  Script.SetTimer(8000, function()
    if waiting then
      waiting = false
      note("No answer from the server - Enter tries again.")
    end
  end)
end

-- the callbacks: this file's events and keys, the rest handed on to what the scripts before it defined
local nextEvent, nextKey, nextText = OnServerEvent, OnKey, OnTextInput

function OnServerEvent(name, payload)
  if name ~= "auth" then
    if nextEvent then return nextEvent(name, payload) end
    return
  end
  local k, line = payload:match("^(%a+);?(.*)$")
  if k == "close" then return close() end
  if k == "register" or k == "login" then open(k, line) end
end

function OnKey(key, pressed)
  if not kind then
    if nextKey then return nextKey(key, pressed) end
    return
  end
  if not pressed then return end
  if key == "enter" or key == "np_enter" then
    send()
  elseif key == "backspace" and not waiting then
    table.remove(chars)
    SetUiText("acc_field", field())
  elseif key == "escape" then
    QuitGame()   -- leaves the server and closes the game
  end
end

function OnTextInput(text)
  if not kind then
    if nextText then return nextText(text) end
    return
  end
  if waiting or text:find("%s") or #chars >= MAX_LENGTH then return end   -- no spaces in a password
  chars[#chars + 1] = text
  SetUiText("acc_field", field())
end

SendServerEvent("auth_ready", "")   -- the box can open now (again after a reload of the scripts)
