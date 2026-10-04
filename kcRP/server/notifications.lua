-- =====================================================================
-- kcRP - Notifications (serveur)
-- API d'envoi de notifications aux joueurs
-- Types : info, success, warning, error
-- =====================================================================

kcRP = kcRP or {}
kcRP.Notify = kcRP.Notify or {}

local DEFAULT_DURATION = 5000  -- 5 secondes

-- ---------------------------------------------------------------------
-- Fonction interne d'envoi
-- ---------------------------------------------------------------------

local function sendNotification(pid, message, type, duration)
  if not IsPlayerConnected(pid) then
    return false
  end
  
  -- Formater le payload
  local payload = tostring(message) .. ";" .. tostring(type) .. ";" .. tostring(duration or DEFAULT_DURATION)
  
  -- Envoyer au client
  SendClientEvent(pid, "kcrp_notify", payload)
  
  return true
end

-- ---------------------------------------------------------------------
-- API publique
-- ---------------------------------------------------------------------

-- Envoyer une notification à un joueur
function kcRP.Functions.Notify(pid, message, type, duration)
  return sendNotification(pid, message, type, duration)
end

-- ---------------------------------------------------------------------
-- Fonctions raccourcies par type
-- ---------------------------------------------------------------------

function kcRP.Notify.Info(pid, message, duration)
  return sendNotification(pid, message, "info", duration)
end

function kcRP.Notify.Success(pid, message, duration)
  return sendNotification(pid, message, "success", duration)
end

function kcRP.Notify.Warning(pid, message, duration)
  return sendNotification(pid, message, "warning", duration)
end

function kcRP.Notify.Error(pid, message, duration)
  return sendNotification(pid, message, "error", duration)
end

-- ---------------------------------------------------------------------
-- Notifications globales (tous les joueurs)
-- ---------------------------------------------------------------------

function kcRP.Notify.All(message, type, duration)
  for _, pid in ipairs(GetPlayers()) do
    sendNotification(pid, message, type, duration)
  end
end

function kcRP.Notify.AllInfo(message, duration)
  kcRP.Notify.All(message, "info", duration)
end

function kcRP.Notify.AllSuccess(message, duration)
  kcRP.Notify.All(message, "success", duration)
end

function kcRP.Notify.AllWarning(message, duration)
  kcRP.Notify.All(message, "warning", duration)
end

function kcRP.Notify.AllError(message, duration)
  kcRP.Notify.All(message, "error", duration)
end

-- ---------------------------------------------------------------------
-- Utilitaires
-- ---------------------------------------------------------------------

-- Notification pour une équipe / groupe (à implémenter plus tard avec un système de teams)
function kcRP.Notify.Team(teamId, message, type, duration)
  -- Placeholder pour future implémentation
  Log("kcRP: Notify.Team not implemented yet")
end

Log("kcRP: server notifications module loaded")