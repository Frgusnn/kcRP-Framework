-- =====================================================================
-- kcRP - Notifications (client)
-- Affichage de notifications style GTA (en haut à droite)
-- Types : info, success, warning, error
-- =====================================================================

local notifications = {}
local activeNotifications = {}
local MAX_NOTIFICATIONS = 5
local DEFAULT_DURATION = 5000  -- 5 secondes

-- Configuration des styles par type
local STYLES = {
  info = {
    color = { 52, 152, 219 },      -- Bleu
    icon = "ℹ",
    bgColor = { 10, 10, 10 }
  },
  success = {
    color = { 46, 204, 113 },      -- Vert
    icon = "✓",
    bgColor = { 10, 10, 10 }
  },
  warning = {
    color = { 241, 196, 15 },      -- Jaune
    icon = "⚠",
    bgColor = { 10, 10, 10 }
  },
  error = {
    color = { 231, 76, 60 },       -- Rouge
    icon = "✕",
    bgColor = { 10, 10, 10 }
  }
}

-- Position et dimensions
local START_X = 1280               -- Largeur écran (1080p)
local START_Y = 80                 -- Marge du haut
local WIDTH = 320                  -- Largeur notification
local HEIGHT = 60                  -- Hauteur notification
local SPACING = 10                 -- Espacement entre notifications

-- ---------------------------------------------------------------------
-- Utilitaires
-- ---------------------------------------------------------------------

-- Calcule la position Y pour une notification (empilement)
local function calculateY(index)
  return START_Y + (index - 1) * (HEIGHT + SPACING)
end

-- ---------------------------------------------------------------------
-- Création d'une notification
-- ---------------------------------------------------------------------

local function createNotificationElement(id, message, type)
  local style = STYLES[type] or STYLES.info
  local x = START_X - WIDTH - 20
  local y = calculateY(#activeNotifications + 1)
  
  CreateUiClip("notif_" .. id)
  CreateUiRect("notif_bg_" .. id, x, y, WIDTH, HEIGHT, 0x000000, 180, "notif_" .. id)
  CreateUiRect("notif_bar_" .. id, x, y, 6, HEIGHT, (style.color[1] * 65536) + (style.color[2] * 256) + style.color[3], 255, "notif_" .. id)
  CreateUiText("notif_icon_" .. id, x + 18, y + 18, style.icon, 0xFFFFFF, 1.2, UI_ALIGN_LEFT, "notif_" .. id)
  
  local maxLength = 45
  local displayMessage = #message > maxLength and (message:sub(1, maxLength - 3) .. "...") or message
  CreateUiText("notif_text_" .. id, x + 42, y + 20, displayMessage, 0xFFFFFF, 0.85, UI_ALIGN_LEFT, "notif_" .. id)
  
  table.insert(activeNotifications, { id = id, message = message, type = type })
  
  Script.SetTimer(duration or DEFAULT_DURATION, function()
    DestroyUiElement("notif_" .. id)
    for i, notif in ipairs(activeNotifications) do
      if notif.id == id then
        table.remove(activeNotifications, i)
        break
      end
    end
  end)
end

function kcRP.Notify(message, type, duration)
  type = type or "info"
  duration = duration or DEFAULT_DURATION
  
  if not STYLES[type] then
    type = "info"
  end
  
  local id = os.time() .. math.random(1000, 9999)
  createNotificationElement(id, message, type)
end

local previousServerEvent = OnServerEvent

function OnServerEvent(name, payload)
  if name == "kcrp_notify" then
    local message, type, duration = payload:match("^([^;]+);([^;]+);?(%d*)")
    if message then
      kcRP.Notify(message, type, tonumber(duration) or DEFAULT_DURATION)
    end
    return
  end
  
  if previousServerEvent then
    return previousServerEvent(name, payload)
  end
end
-- ---------------------------------------------------------------------
-- Suppression d'une notification
-- ---------------------------------------------------------------------

local function removeNotification(id)
  -- Trouver l'index de la notification
  local index = nil
  for i, notif in ipairs(activeNotifications) do
    if notif.id == id then
      index = i
      break
    end
  end
  
  if not index then return end
  
  -- Détruire les éléments UI
  DestroyUiElement("notif_" .. id)
  
  -- Retirer du tableau
  table.remove(activeNotifications, index)
  
  -- Replacer les notifications restantes
  for i, notif in ipairs(activeNotifications) do
    local newX = START_X - WIDTH - 20
    local newY = calculateY(i)
    SetUiPos("notif_bg_" .. notif.id, newX, newY)
    SetUiPos("notif_bar_" .. notif.id, newX, newY)
    SetUiPos("notif_icon_" .. notif.id, newX + 18, newY + 18)
    SetUiPos("notif_text_" .. notif.id, newX + 42, newY + 20)
  end
end

-- ---------------------------------------------------------------------
-- API publique
-- ---------------------------------------------------------------------

function kcRP.Notify(message, type, duration)
  -- Validation
  type = type or "info"
  duration = duration or DEFAULT_DURATION
  
  if not STYLES[type] then
    type = "info"
  end
  
  -- Générer un ID unique
  local id = os.time() .. math.random(1000, 9999)
  
  -- Limiter le nombre de notifications
  if #activeNotifications >= MAX_NOTIFICATIONS then
    -- Retirer la plus ancienne
    local oldest = activeNotifications[1]
    removeNotification(oldest.id)
  end
  
  -- Créer la notification
  createNotificationElement(id, message, type)
  
  -- Ajouter au tableau
  table.insert(activeNotifications, {
    id = id,
    message = message,
    type = type,
    createdAt = os.time()
  })
  
  -- Programmer la suppression
  Script.SetTimer(duration, function()
    removeNotification(id)
  end)
end

-- ---------------------------------------------------------------------
-- Fonctions raccourcies
-- ---------------------------------------------------------------------

kcRP.NotifyInfo = function(msg, dur) kcRP.Notify(msg, "info", dur) end
kcRP.NotifySuccess = function(msg, dur) kcRP.Notify(msg, "success", dur) end
kcRP.NotifyWarning = function(msg, dur) kcRP.Notify(msg, "warning", dur) end
kcRP.NotifyError = function(msg, dur) kcRP.Notify(msg, "error", dur) end

-- ---------------------------------------------------------------------
-- Callbacks serveur
-- ---------------------------------------------------------------------

local previousServerEvent = OnServerEvent

function OnServerEvent(name, payload)
  if name == "kcrp_notify" then
    local message, type, duration = payload:match("^([^;]+);([^;]+);?(%d*)")
    if message then
      kcRP.Notify(message, type, tonumber(duration) or DEFAULT_DURATION)
    end
    return
  end
  
  if previousServerEvent then
    return previousServerEvent(name, payload)
  end
end

Log("kcRP: client notifications module loaded")