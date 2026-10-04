-- =====================================================================
-- kcRP - Forge de Kuttenberg (serveur)
--   * PNJ "Maître forgeron" : menu réservé aux membres de la compagnie
--   * Coffre de l'atelier  : réservé au métier forgeron
--   * Porte de l'atelier   : réservée au métier forgeron
--   * Déverrouillage natif du coffre pour les membres (via script client)
-- Le craft reste 100 % natif KCD2 : aucun menu de craft kcRP.
-- Dépend de : companies.lua (kcRP.Companies.Forge, IsCompanyMember),
--             jobs.lua (kcRP.Functions.GetJob).
-- =====================================================================

kcRP = kcRP or {}
kcRP.Blacksmith = kcRP.Blacksmith or {}

-- ---------------------------------------------------------------------
-- Configuration (les clés viennent de companies.lua : source unique)
-- ---------------------------------------------------------------------
local Forge = (kcRP.Companies and kcRP.Companies.Forge) or {}

local COMPANY_CODE = Forge.code or "blacksmith_kuttenberg"
local JOB_NAME = Forge.jobName or "blacksmith"
local LEVEL_NAME = Forge.levelName or "kutnohorsko"
local STASH_KEY = Forge.stashKey
local DOOR_KEY = Forge.doorKey

local NPC_NAME = "Maître forgeron"
local NPC_X, NPC_Y, NPC_Z, NPC_YAW = 810.6, 3362.5, 141.4, 22
local NPC_CLEAN_RADIUS = 2.5      -- rayon (m) du nettoyage des anciens PNJ
local WORKSHOP_RADIUS = 12.0      -- rayon (m) de la zone de l'atelier
local DIALOGUE_ID = 4100          -- identifiant du dialogue du PNJ
local EVENT_ACCESS = "kcrp_workshop_access" -- événement envoyé au client

local npcId = nil                 -- id de l'acteur courant
local workshopZone = nil          -- id de la zone de l'atelier

if not STASH_KEY or not DOOR_KEY then
  Log("kcRP: blacksmith keys missing; load companies.lua before blacksmith.lua")
end

-- ---------------------------------------------------------------------
-- Utilitaires
-- ---------------------------------------------------------------------

-- Vrai si le joueur a le métier de forgeron (vérification synchrone,
-- nécessaire dans les callbacks de porte et de coffre).
local function hasForgeJob(pid)
  local getJob = kcRP.Functions and kcRP.Functions.GetJob
  local job = getJob and getJob(pid) or nil

  return job ~= nil and job.name == JOB_NAME
end

-- Envoie au client la clé du coffre à déverrouiller (côté jeu).
local function sendWorkshopAccess(pid)
  if STASH_KEY then
    SendClientEvent(pid, EVENT_ACCESS, STASH_KEY)
  end
end

-- ---------------------------------------------------------------------
-- PNJ
-- ---------------------------------------------------------------------

-- Détruit tout acteur nommé situé près de l'emplacement du PNJ.
-- Un /reload relance Lua sans détruire les acteurs : sans ce balayage,
-- un nouveau PNJ s'empilerait à chaque rechargement.
local function clearOldNpcs()
  for _, id in ipairs(GetEntities() or {}) do
    local ex, ey = GetEntityPos(id)

    if ex and (GetEntityName(id) or "") ~= ""
      and math.sqrt((ex - NPC_X) ^ 2 + (ey - NPC_Y) ^ 2) <= NPC_CLEAN_RADIUS then
      DestroyEntity(id)
    end
  end

  npcId = nil
end

-- Crée le maître forgeron (après nettoyage). Réservé au niveau de Kuttenberg.
local function createNpc()
  if GetLevel() ~= LEVEL_NAME then
    Log("kcRP: blacksmith NPC skipped; current level is " .. tostring(GetLevel()))
    return
  end

  clearOldNpcs()

  npcId = CreateActor(nil, NPC_X, NPC_Y, NPC_Z, NPC_YAW, NPC_NAME, nil, "none")

  if not npcId then
    Log("kcRP: could not create blacksmith NPC")
    return
  end

  SetActorInvulnerable(npcId, true)
  SetActorPrompt(npcId, "Parler")
  SetEntityData(npcId, "kcrp_role", "blacksmith_npc")
  SetEntityData(npcId, "kcrp_company", COMPANY_CODE)

  Log("kcRP: blacksmith NPC created with id " .. tostring(npcId))
end

kcRP.Blacksmith.CreateNpc = createNpc

-- Id de l'acteur courant (utilisé par la boutique pour fermer l'écran quand on s'éloigne).
function kcRP.Blacksmith.GetNpcId()
  return npcId
end

-- ---------------------------------------------------------------------
-- Zone de l'atelier
-- ---------------------------------------------------------------------

-- Crée (ou recrée) la zone cylindrique autour de l'atelier.
local function createWorkshopZone()
  if GetLevel() ~= LEVEL_NAME then
    return
  end

  if workshopZone then
    DestroyZone(workshopZone)
    workshopZone = nil
  end

  workshopZone = CreateCircleZone(NPC_X, NPC_Y, WORKSHOP_RADIUS, NPC_Z - 6.0, NPC_Z + 6.0)
end

-- ---------------------------------------------------------------------
-- Cycle de vie
-- ---------------------------------------------------------------------

-- Démarrage du mode : PNJ et zone.
local previousGameModeInit = OnGameModeInit

function OnGameModeInit()
  if previousGameModeInit then
    previousGameModeInit()
  end

  createNpc()
  createWorkshopZone()
end

-- Arrêt / rechargement : retire le PNJ et la zone.
local previousGameModeExit = OnGameModeExit

function OnGameModeExit()
  clearOldNpcs()

  if workshopZone then
    DestroyZone(workshopZone)
    workshopZone = nil
  end

  if previousGameModeExit then
    previousGameModeExit()
  end
end

-- ---------------------------------------------------------------------
-- Zone : déverrouillage du coffre pour les membres
-- ---------------------------------------------------------------------

-- À l'entrée de la zone, un membre de la compagnie reçoit l'ordre de
-- déverrouiller le coffre dans son jeu (le serveur ne peut pas le faire).
local previousEnterZone = OnPlayerEnterZone

function OnPlayerEnterZone(pid, zone)
  if workshopZone and zone == workshopZone
    and kcRP.Functions and kcRP.Functions.IsCompanyMember then

    kcRP.Functions.IsCompanyMember(pid, COMPANY_CODE, function(isMember, _, err)
      if err or not isMember or not IsPlayerConnected(pid) then
        return
      end

      sendWorkshopAccess(pid)
    end)
  end

  if previousEnterZone then
    return previousEnterZone(pid, zone)
  end
end

-- ---------------------------------------------------------------------
-- Coffre et porte
-- ---------------------------------------------------------------------

-- Coffre : seuls les forgerons peuvent l'ouvrir. Retourner false refuse.
local previousOpenContainer = OnPlayerOpenContainer

function OnPlayerOpenContainer(pid, key)
  if STASH_KEY and key == STASH_KEY then
    if not hasForgeJob(pid) then
      SendClientMessage(pid, COLOR_RED, "Ce coffre appartient à la Forge de Kuttenberg.")
      return false
    end

    SendClientMessage(pid, COLOR_GOLD, "Vous ouvrez le coffre de la Forge de Kuttenberg.")
    return true
  end

  if previousOpenContainer then
    return previousOpenContainer(pid, key)
  end

  return true
end

-- Porte : seuls les forgerons la manipulent. Le jeu l'a déjà ouverte quand
-- ce callback est appelé : un refus la fait se rouvrir puis se refermer
-- (limite de l'API, la porte ne peut pas être refusée avant son mouvement).
local previousUseDoor = OnPlayerUseDoor

function OnPlayerUseDoor(pid, key, open, locked)
  if DOOR_KEY and key == DOOR_KEY and not hasForgeJob(pid) then
    SendClientMessage(pid, COLOR_RED, "Cette porte appartient à la Forge de Kuttenberg.")
    return false
  end

  if previousUseDoor then
    return previousUseDoor(pid, key, open, locked)
  end
end

-- ---------------------------------------------------------------------
-- Dialogue du PNJ
-- ---------------------------------------------------------------------

-- Affiche le menu au joueur (déjà reconnu comme membre).
local function showMenu(pid)
  local ok, reason = ShowPlayerDialogue(
    pid,
    DIALOGUE_ID,
    NPC_NAME,
    "Bienvenue à la Forge de Kuttenberg. Que désirez-vous faire ?",
    { "Boutique", "Gestion des membres", "Informations de la forge", "Quitter" },
    npcId
  )

  if not ok then
    Log("kcRP: blacksmith dialogue failed: " .. tostring(reason))
    SendClientMessage(pid, COLOR_RED, "Impossible d'ouvrir le dialogue : " .. tostring(reason))
  end
end

-- Interaction avec le PNJ : vérification asynchrone de l'appartenance à
-- la compagnie, puis menu. Retourne false pour bloquer la suite côté jeu.
local previousInteractActor = OnPlayerInteractActor

function OnPlayerInteractActor(pid, id)
  if not npcId or id ~= npcId then
    if previousInteractActor then
      return previousInteractActor(pid, id)
    end

    return true
  end

  if not (kcRP.Functions and kcRP.Functions.IsCompanyMember) then
    SendClientMessage(pid, COLOR_RED, "Le système d'entreprise n'est pas disponible.")
    return false
  end

  kcRP.Functions.IsCompanyMember(pid, COMPANY_CODE, function(isMember, _, err)
    if not IsPlayerConnected(pid) then
      return
    end

    if err then
      Log("kcRP: blacksmith access check failed: " .. tostring(err))
      SendClientMessage(pid, COLOR_RED, "Impossible de vérifier vos droits d'entreprise.")
      return
    end

    if not isMember then
      SendClientMessage(pid, COLOR_RED, "Cette forge est réservée aux membres de la Forge de Kuttenberg.")
      return
    end

    showMenu(pid)
  end)

  return false
end

-- Actions du menu, indexées par le numéro du choix (1 = premier).
-- Le choix 4 (Quitter) et la fermeture (0) ne font rien.
local MENU_ACTIONS = {
  [1] = function(pid)
    if kcRP.ForgeShop then
      kcRP.ForgeShop.Open(pid)
    else
      SendClientMessage(pid, COLOR_RED, "La boutique de plans n'est pas disponible.")
    end
  end,
  [2] = function(pid)
    SendClientMessage(pid, COLOR_GOLD, "La gestion des membres sera disponible prochainement.")
  end,
  [3] = function(pid)
    SendClientMessage(pid, COLOR_GOLD, "----- Forge de Kuttenberg -----")
    SendClientMessage(pid, COLOR_WHITE, "Compagnie : Forge de Kuttenberg")
    SendClientMessage(pid, COLOR_WHITE, "Métier : Forgeron")
    SendClientMessage(pid, COLOR_WHITE, "Craft : forge native du jeu")
  end
}

-- Réponse au dialogue : exécute l'action du choix.
local previousDialogueResponse = OnDialogueResponse

function OnDialogueResponse(pid, dialogId, option, reason)
  if dialogId ~= DIALOGUE_ID then
    if previousDialogueResponse then
      return previousDialogueResponse(pid, dialogId, option, reason)
    end

    return
  end

  local action = MENU_ACTIONS[option]

  if action then
    action(pid)
  end
end

Log("kcRP: blacksmith workshop module loaded")
