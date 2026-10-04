-- =====================================================================
-- kcRP - Notifications (client)
-- Notifications avec préfixes par type
-- =====================================================================

kcRP = kcRP or {}

local DEFAULT_DURATION = 5000

-- Préfixes par type
local PREFIXES = {
  info = "[INFO]",
  success = "[SUCCÈS]",
  warning = "[ATTENTION]",
  error = "[ERREUR]"
}

function kcRP.Notify(message, type, duration)
  local prefix = PREFIXES[type] or PREFIXES.info
  ShowNotification(prefix .. " " .. tostring(message))
end

-- Raccourcis
kcRP.NotifyInfo = function(msg) kcRP.Notify(msg, "info") end
kcRP.NotifySuccess = function(msg) kcRP.Notify(msg, "success") end
kcRP.NotifyWarning = function(msg) kcRP.Notify(msg, "warning") end
kcRP.NotifyError = function(msg) kcRP.Notify(msg, "error") end

-- Callback serveur
local previousServerEvent = OnServerEvent

function OnServerEvent(name, payload)
  if name == "kcrp_notify" then
    local message, type, duration = payload:match("^([^;]+);([^;]+);?(%d*)")
    if message then
      kcRP.Notify(message, type, tonumber(duration) or DEFAULT_DURATION)
    end
    return
  end

  if name == "bank_state" then
    print("=== bank_state REÇU ===", payload)
    return
  end
  
  if previousServerEvent then
    return previousServerEvent(name, payload)
  end
end

Log("kcRP: client notifications module loaded")