-- =====================================================================
-- kcRP - Métiers (serveur)
-- Persistance SQL, synchronisation des états joueur et commandes.
-- Dépend de : shared/jobs.lua, kcRP.Functions.GetPlayer (kcRP.lua).
-- =====================================================================

kcRP = kcRP or {}
kcRP.Functions = kcRP.Functions or {}
kcRP.Events = kcRP.Events or {}

local Jobs = {}

-- ---------------------------------------------------------------------
-- Utilitaires internes
-- ---------------------------------------------------------------------

-- Retourne le handle de base de données du mode (nil si non configurée).
local function getDatabase()
  return GetDatabase()
end

-- Retourne la définition d'un métier (table partagée) ou nil.
local function getDefinition(jobName)
  local all = kcRP.Shared and kcRP.Shared.Jobs or {}
  return all[tostring(jobName or ""):lower()]
end

-- Retourne la définition d'un grade d'un métier ou nil.
local function getGrade(definition, gradeLevel)
  if not definition then
    return nil
  end

  return definition.grades[tonumber(gradeLevel) or 0]
end

-- Date UTC au format ISO 8601, utilisée pour les colonnes updated_at.
local function utcNow()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- ---------------------------------------------------------------------
-- API publique (kcRP.Functions)
-- ---------------------------------------------------------------------

-- Définition complète d'un métier.
function kcRP.Functions.GetJobDefinition(jobName)
  return getDefinition(jobName)
end

-- Définition d'un grade d'un métier.
function kcRP.Functions.GetJobGrade(jobName, gradeLevel)
  return getGrade(getDefinition(jobName), gradeLevel)
end

-- Métier courant d'un joueur (table PlayerData.job) ou nil.
function kcRP.Functions.GetJob(pid)
  local player = kcRP.Functions.GetPlayer(pid)
  return player and player.PlayerData.job or nil
end

-- Publie le métier du joueur dans ses state bags (lus par le HUD client).
function kcRP.Functions.SyncJobState(pid)
  local player = kcRP.Functions.GetPlayer(pid)

  if not player or not IsPlayerConnected(pid) then
    return false
  end

  local job = player.PlayerData.job or {}
  local grade = job.grade or {}

  SetPlayerState(pid, "kcrp_job", tostring(job.name or "unemployed"))
  SetPlayerState(pid, "kcrp_job_label", tostring(job.label or "Sans emploi"))
  SetPlayerState(pid, "kcrp_job_grade", tostring(grade.level or 0))
  SetPlayerState(pid, "kcrp_job_grade_label", tostring(grade.label or "Habitant"))
  SetPlayerState(pid, "kcrp_job_duty", job.onduty and "true" or "false")

  return true
end

-- Sauvegarde le métier du joueur (upsert). Asynchrone, journalise l'erreur.
function kcRP.Functions.SaveJob(pid)
  local player = kcRP.Functions.GetPlayer(pid)
  local database = getDatabase()

  if not database or not player or not player.PlayerData.characterId then
    return false
  end

  local job = player.PlayerData.job or {}
  local grade = job.grade or {}

  database:Execute(
    [[
      INSERT INTO player_jobs (player_id, job_name, grade_level, onduty, updated_at)
      VALUES (@id, @job, @grade, @duty, @updated)
      ON DUPLICATE KEY UPDATE
        job_name = @job,
        grade_level = @grade,
        onduty = @duty,
        updated_at = @updated
    ]],
    {
      id = player.PlayerData.characterId,
      job = job.name or "unemployed",
      grade = grade.level or 0,
      duty = job.onduty and 1 or 0,
      updated = utcNow()
    },
    function(_, _, err)
      if err then
        Log("kcRP: job save failed for " .. player.PlayerData.name .. ": " .. tostring(err))
      end
    end
  )

  return true
end

-- Attribue un métier et un grade à un joueur.
--   options.onduty   : force l'état de service (sinon valeur par défaut du métier)
--   options.skipSave : n'écrit pas en base (utilisé au chargement)
-- Correction : au chargement, l'ancien code sauvegardait le service par
-- défaut du métier avant de relire la base, ce qui écrasait l'état réel.
function kcRP.Functions.SetJob(pid, jobName, gradeLevel, reason, options)
  options = options or {}

  local player = kcRP.Functions.GetPlayer(pid)

  if not player then
    return false, "Joueur introuvable."
  end

  jobName = tostring(jobName or ""):lower()

  local definition = getDefinition(jobName)

  if not definition then
    return false, "Métier inconnu."
  end

  gradeLevel = tonumber(gradeLevel) or 0

  local grade = getGrade(definition, gradeLevel)

  if not grade then
    return false, "Grade invalide pour ce métier."
  end

  local oldJob = player.PlayerData.job
  local onduty = definition.defaultDuty == true

  if options.onduty ~= nil then
    onduty = options.onduty == true
  end

  player.PlayerData.job = {
    name = jobName,
    label = definition.label,
    grade = {
      level = gradeLevel,
      name = grade.name,
      label = grade.label,
      payment = grade.payment or 0,
      isBoss = grade.isBoss == true
    },
    onduty = onduty
  }

  kcRP.Functions.SyncJobState(pid)

  if not options.skipSave then
    kcRP.Functions.SaveJob(pid)
  end

  Log(string.format(
    "kcRP: job of %s#%d changed to %s grade %d (%s)",
    player.PlayerData.name, pid, jobName, gradeLevel, tostring(reason or "no reason")
  ))

  if kcRP.Events.Emit then
    kcRP.Events.Emit("player:jobChanged", player, oldJob, player.PlayerData.job, reason)
  end

  return true
end

-- Change l'état de service (en/hors service) et le sauvegarde.
function kcRP.Functions.SetDuty(pid, onduty, reason)
  local player = kcRP.Functions.GetPlayer(pid)

  if not player then
    return false, "Joueur introuvable."
  end

  local job = player.PlayerData.job

  if not job or job.name == "unemployed" then
    return false, "Vous n'avez pas de métier actif."
  end

  local oldDuty = job.onduty == true
  job.onduty = onduty == true

  kcRP.Functions.SyncJobState(pid)
  kcRP.Functions.SaveJob(pid)

  Log(string.format(
    "kcRP: duty of %s#%d changed %s -> %s (%s)",
    player.PlayerData.name, pid, tostring(oldDuty), tostring(job.onduty), tostring(reason or "no reason")
  ))

  if kcRP.Events.Emit then
    kcRP.Events.Emit("player:dutyChanged", player, oldDuty, job.onduty, reason)
  end

  return true
end

-- Charge le métier sauvegardé d'un personnage et l'applique au joueur.
function kcRP.Functions.LoadJob(pid, characterId)
  local player = kcRP.Functions.GetPlayer(pid)
  local database = getDatabase()

  if not database or not player or not characterId then
    return
  end

  database:Query(
    "SELECT job_name, grade_level, onduty FROM player_jobs WHERE player_id = @id",
    { id = characterId },
    function(rows, err)
      if err then
        Log("kcRP: job load failed for character " .. tostring(characterId) .. ": " .. tostring(err))
        return
      end

      -- Le joueur a pu se déconnecter ou changer de session pendant la requête.
      if not IsPlayerConnected(pid) or kcRP.Functions.GetPlayer(pid) ~= player then
        return
      end

      local row = rows and rows[1]

      -- Première connexion : métier par défaut, en service.
      if not row then
        kcRP.Functions.SetJob(pid, "unemployed", 0, "default job", { onduty = true })
        return
      end

      local jobName = tostring(row.job_name or "unemployed"):lower()
      local gradeLevel = tonumber(row.grade_level) or 0
      local onduty = tonumber(row.onduty) == 1

      -- skipSave : on ne réécrit pas ce que l'on vient de lire.
      local ok = kcRP.Functions.SetJob(pid, jobName, gradeLevel, "database load", {
        onduty = onduty,
        skipSave = true
      })

      -- Ligne corrompue : retour au métier par défaut.
      if not ok then
        kcRP.Functions.SetJob(pid, "unemployed", 0, "invalid database fallback", { onduty = true })
      end

      local job = player.PlayerData.job

      Log(string.format(
        "kcRP: job loaded for %s#%d: %s grade %d, duty %s",
        player.PlayerData.name, pid, job.name, job.grade.level, tostring(job.onduty)
      ))
    end
  )
end

-- ---------------------------------------------------------------------
-- Cycle de vie
-- ---------------------------------------------------------------------

-- Crée la table player_jobs si nécessaire. Appelée par kcRP.lua.
function Jobs.InitDatabase()
  local database = GetDatabase()

  if not database then
    Log("kcRP: jobs disabled; no database available.")
    return false
  end

  Log("kcRP: creating/checking player_jobs table...")

  database:Execute([[
    CREATE TABLE IF NOT EXISTS player_jobs (
      player_id INT NOT NULL PRIMARY KEY,
      job_name VARCHAR(32) NOT NULL DEFAULT 'unemployed',
      grade_level INT NOT NULL DEFAULT 0,
      onduty SMALLINT NOT NULL DEFAULT 1,
      updated_at VARCHAR(32),
      FOREIGN KEY (player_id) REFERENCES players(id) ON DELETE CASCADE
    )
  ]], {}, function(_, _, err)
    if err then
      Log("kcRP: player_jobs table creation failed: " .. tostring(err))
      return
    end

    Log("kcRP: jobs database ready")
  end)

  return true
end

-- Appelée quand un personnage est connecté : charge son métier.
function Jobs.OnPlayerLoggedIn(pid, characterId)
  local player = kcRP.Functions.GetPlayer(pid)

  if not player then
    return
  end

  player.PlayerData.characterId = characterId
  player.PlayerData.loggedIn = true

  kcRP.Functions.LoadJob(pid, characterId)
end

-- Appelée à la déconnexion : sauvegarde finale du métier.
function Jobs.OnPlayerDisconnect(pid)
  kcRP.Functions.SaveJob(pid)
end

-- ---------------------------------------------------------------------
-- Commandes : /job, /duty, /setjob (admin)
-- Retourne true si la commande a été traitée.
-- ---------------------------------------------------------------------
function Jobs.HandleCommand(pid, cmd, args)
  local player = kcRP.Functions.GetPlayer(pid)

  if cmd == "job" or cmd == "duty" or cmd == "setjob" then
    if not player then
      SendClientMessage(pid, COLOR_RED, "kcRP: PlayerData indisponible.")
      return true
    end
  end

  if cmd == "job" then
    local job = player.PlayerData.job
    local grade = job.grade or {}

    SendClientMessage(pid, COLOR_GOLD,
      string.format("Métier : %s — %s", job.label, grade.label or "Sans grade"))
    SendClientMessage(pid, COLOR_WHITE,
      string.format("Service : %s | Salaire futur : %s Groschen",
        job.onduty and "en service" or "hors service", tostring(grade.payment or 0)))

    return true
  end

  if cmd == "duty" then
    local ok, reason = kcRP.Functions.SetDuty(pid, not player.PlayerData.job.onduty, "player command")

    if not ok then
      SendClientMessage(pid, COLOR_RED, tostring(reason))
      return true
    end

    SendClientMessage(pid, COLOR_GREEN,
      player.PlayerData.job.onduty and "Vous êtes maintenant en service."
        or "Vous êtes maintenant hors service.")

    return true
  end

  if cmd == "setjob" then
    if not kcRP.Functions.HasPermission(pid, "admin") then
      SendClientMessage(pid, COLOR_RED, "/setjob est réservé aux administrateurs.")
      return true
    end

    local target, jobName, gradeLevel = sscanf(args, "usd")

    if target == false then
      SendClientMessage(pid, COLOR_RED, "Usage : /setjob <joueur> <métier> <grade>")
      return true
    end

    local targetPlayer = kcRP.Functions.GetPlayer(target)

    if not targetPlayer then
      SendClientMessage(pid, COLOR_RED, "Joueur absent du registre kcRP.")
      return true
    end

    local ok, reason = kcRP.Functions.SetJob(
      target, jobName, gradeLevel, "admin command by " .. GetPlayerName(pid))

    if not ok then
      SendClientMessage(pid, COLOR_RED, tostring(reason))
      return true
    end

    local job = targetPlayer.PlayerData.job

    SendClientMessage(pid, COLOR_GREEN,
      string.format("%s est maintenant %s — %s.", targetPlayer.PlayerData.name, job.label, job.grade.label))
    SendClientMessage(target, COLOR_GOLD,
      string.format("Votre métier est maintenant : %s — %s.", job.label, job.grade.label))

    -- Le HUD doit s'afficher chez le joueur concerné, pas chez l'admin.
    SendClientEvent(target, "kcrp_hud_show_job", "8000")

    return true
  end

  return false
end

kcRP.Jobs = Jobs

Log("kcRP: server jobs module loaded")
