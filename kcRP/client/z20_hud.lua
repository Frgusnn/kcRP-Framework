-- =====================================================================
-- kcRP - HUD métier (client)
-- Affichage seulement : les state bags du serveur restent la source de
-- vérité. Le panneau montre le métier, le grade et l'état de service.
-- =====================================================================

-- Noms des éléments d'interface.
local ROOT = "kcrp_hud"
local PANEL = "kcrp_hud_panel"
local TOP_LINE = "kcrp_hud_top_line"
local TITLE = "kcrp_hud_title"
local JOB = "kcrp_hud_job"
local GRADE = "kcrp_hud_grade"
local DUTY = "kcrp_hud_duty"

local HUD_DURATION = 8000   -- durée d'affichage par défaut (ms)
local BUILD_DELAY = 1200    -- délai avant la construction du HUD (ms)

local hudBuilt = false
local hudVisible = false
local hudHideToken = 0      -- invalide les anciens minuteurs de masquage
local pendingShowDuration = nil

-- État affiché (valeurs lues dans les state bags du joueur).
local state = {
  jobLabel = "Sans emploi",
  gradeLabel = "Habitant",
  duty = "true"
}

-- ---------------------------------------------------------------------
-- Textes et couleurs
-- ---------------------------------------------------------------------

-- Texte de l'état de service.
local function getDutyText()
  if state.jobLabel == "Sans emploi" then
    return "Sans activité"
  end

  if state.duty == "true" then
    return "En service"
  end

  return "Hors service"
end

-- Couleur de l'état de service (gris / vert / ambre).
local function getDutyColor()
  if state.jobLabel == "Sans emploi" then
    return 0xB0B0B0
  end

  if state.duty == "true" then
    return 0x70D070
  end

  return 0xD0A060
end

-- Relit l'état depuis les state bags du joueur local.
-- (Défini AVANT showHud : en Lua, une fonction locale n'est visible que
-- par le code écrit après elle. L'ancien code l'appelait avant sa
-- définition, ce qui provoquait une erreur à l'affichage.)
local function loadInitialState()
  state.jobLabel = GetPlayerState(nil, "kcrp_job_label") or state.jobLabel
  state.gradeLabel = GetPlayerState(nil, "kcrp_job_grade_label") or state.gradeLabel
  state.duty = GetPlayerState(nil, "kcrp_job_duty") or state.duty
end

-- Applique l'état aux éléments déjà créés.
local function updateJob()
  if not hudBuilt then
    return
  end

  SetUiText(JOB, state.jobLabel)
  SetUiText(GRADE, state.gradeLabel)
  SetUiText(DUTY, getDutyText())
  SetUiColor(DUTY, getDutyColor())
end

-- ---------------------------------------------------------------------
-- Affichage
-- ---------------------------------------------------------------------

-- Masque le HUD.
local function hideHud()
  if not hudBuilt then
    return
  end

  HideUiElement(ROOT)
  hudVisible = false
end

-- Affiche le HUD pendant "duration" ms (ou la durée par défaut).
-- Si le HUD n'est pas encore construit, l'affichage est mis en attente.
local function showHud(duration)
  local showFor = tonumber(duration) or HUD_DURATION

  if not hudBuilt then
    pendingShowDuration = showFor
    return
  end

  loadInitialState()
  updateJob()

  ShowUiElement(ROOT)
  hudVisible = true

  -- Chaque affichage invalide le minuteur précédent.
  hudHideToken = hudHideToken + 1
  local token = hudHideToken

  Script.SetTimer(showFor, function()
    if token == hudHideToken then
      hideHud()
    end
  end)
end

-- Construit le panneau (coin haut droit, espace virtuel de 1080 lignes).
local function buildHud()
  if hudBuilt then
    return
  end

  local screenWidth = GetScreenSize()

  local panelWidth = 190
  local panelHeight = 145
  local panelX = screenWidth - panelWidth - 38
  local panelY = 46

  CreateUiClip(ROOT)
  CreateUiRect(PANEL, panelX, panelY, panelWidth, panelHeight, 0x080808, 62, ROOT)
  CreateUiRect(TOP_LINE, panelX, panelY, panelWidth, 2, COLOR_GOLD, 80, ROOT)

  CreateUiText(TITLE, panelX + 18, panelY + 14, "kcRP", COLOR_GOLD, 0.85, UI_ALIGN_LEFT, ROOT)
  CreateUiText(JOB, panelX + 18, panelY + 48, state.jobLabel, COLOR_WHITE, 0.85, UI_ALIGN_LEFT, ROOT)
  CreateUiText(GRADE, panelX + 18, panelY + 78, state.gradeLabel, 0xD0D0D0, 0.66, UI_ALIGN_LEFT, ROOT)
  CreateUiText(DUTY, panelX + 18, panelY + 105, getDutyText(), getDutyColor(), 0.64, UI_ALIGN_LEFT, ROOT)

  hudBuilt = true

  loadInitialState()
  updateJob()
  hideHud()

  -- Un affichage demandé avant la construction est rejoué maintenant.
  if pendingShowDuration then
    local duration = pendingShowDuration
    pendingShowDuration = nil
    showHud(duration)
  end
end

-- ---------------------------------------------------------------------
-- Événements
-- ---------------------------------------------------------------------

-- Réagit aux changements de state bag du joueur local.
local function handleStateChange(scope, id, key, value)
  if scope ~= "player" then
    return
  end

  local ownPid = GetPlayerId()

  if not ownPid or id ~= ownPid then
    return
  end

  if key == "kcrp_job_label" then
    state.jobLabel = value or "Sans emploi"
  elseif key == "kcrp_job_grade_label" then
    state.gradeLabel = value or "Habitant"
  elseif key == "kcrp_job_duty" then
    state.duty = value or "false"
  else
    return
  end

  updateJob()
end

-- On garde les callbacks définis par account.lua, cartmaker.lua, creator.lua.
local previousStateChange = OnStateChange

function OnStateChange(scope, id, key, value)
  handleStateChange(scope, id, key, value)

  if previousStateChange then
    return previousStateChange(scope, id, key, value)
  end
end

local previousServerEvent = OnServerEvent

-- Événements du serveur : affichage du HUD métier et rafraîchissement.
function OnServerEvent(name, payload)
  if name == "kcrp_hud_show_job" then
    showHud(payload)
    return
  end

  if name == "kcrp_hud_refresh" then
    loadInitialState()
    updateJob()
    return
  end

  if previousServerEvent then
    return previousServerEvent(name, payload)
  end
end

-- Construction différée (le HUD du jeu doit être prêt). Un seul minuteur :
-- l'ancien code en programmait deux.
Script.SetTimer(BUILD_DELAY, buildHud)
