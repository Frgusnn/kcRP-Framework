-- =====================================================================
-- kcRP - Déverrouillage du coffre de la Forge (client)
-- Le serveur envoie "kcrp_workshop_access" avec la clé du coffre aux
-- membres de la compagnie qui entrent dans la zone de l'atelier.
-- Ce script déverrouille alors le coffre dans le jeu du joueur.
-- Les fichiers client se passent la main dans l'ordre alphabétique : on
-- conserve donc le callback défini par les fichiers précédents.
-- =====================================================================

local previousServerEvent = OnServerEvent

-- Cherche l'entité par son nom et appelle Unlock().
-- Retourne un texte de résultat (jamais d'erreur : tout est protégé par pcall).
local function unlockStash(key)
  local ok, result = pcall(function()
    local entity = System.GetEntityByName(key)

    if not entity then
      return "entité introuvable"
    end

    if entity.Unlock then
      entity:Unlock()
      return "déverrouillé"
    end

    return "pas de méthode Unlock"
  end)

  if ok then
    return result
  end

  return "erreur " .. tostring(result)
end

-- Réception des événements serveur.
-- "kcrp_unlock_chest" reste accepté pour compatibilité avec l'ancien nom.
function OnServerEvent(name, payload)
  if name == "kcrp_workshop_access" or name == "kcrp_unlock_chest" then
    ShowNotification("kcRP coffre : " .. unlockStash(tostring(payload or "")))
    return
  end

  if previousServerEvent then
    return previousServerEvent(name, payload)
  end
end
