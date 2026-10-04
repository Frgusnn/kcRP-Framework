-- =====================================================================
-- kcRP - Compagnies (serveur)
-- Compagnies persistantes, membres, rôles, propriétés et journaux.
-- Première compagnie : la Forge de Kuttenberg.
-- Dépend de : kcRP.Functions.GetPlayer / GetJob (kcRP.lua, jobs.lua).
-- =====================================================================

kcRP = kcRP or {}
kcRP.Functions = kcRP.Functions or {}
kcRP.Companies = kcRP.Companies or {}

local Companies = {}

-- ---------------------------------------------------------------------
-- Configuration de la Forge de Kuttenberg.
-- SOURCE UNIQUE : blacksmith.lua lit ces valeurs via kcRP.Companies.Forge.
-- Les clés sont les noms d'entités natifs relevés avec la commande admin
-- "objectinfo". Elles contiennent des crochets : d'où les [=[ ... ]=].
-- ---------------------------------------------------------------------
Companies.Forge = {
  code      = "blacksmith_kuttenberg",
  label     = "Forge de Kuttenberg",
  jobName   = "blacksmith",
  levelName = "kutnohorsko",
  propertyLabel = "Atelier de la Forge de Kuttenberg",

  -- Porte de l'atelier.
  doorKey = [=[AnimDoor[structures/industrial/workshops/workshop_a1:Door/door_village_right1[structures/industrial/workshops/workshop_a1]_6af586f0-654f-0385-29c4-b96e812b8c88]]=],

  -- Coffre de l'atelier.
  stashKey = [=[stash[profession/blacksmith/smithy_workshop2:profession/blacksmith/smithy_workshop_base1[profession/blacksmith/smithy_workshop2]:Chest/chest4[profession/blacksmith/smithy_workshop2:profession/blacksmith/smithy_workshop_base1[profession/blacksmith/smithy_workshop2]]_019e87f6-0f4b-4f70-a429-0b325f6da28b]]=]
}

-- Rôles, du plus élevé au plus bas.
local ROLE_OWNER = "owner"
local ROLE_MASTER = "master"
local ROLE_SMITH = "smith"
local ROLE_APPRENTICE = "apprentice"

local VALID_ROLES = {
  [ROLE_OWNER] = true,
  [ROLE_MASTER] = true,
  [ROLE_SMITH] = true,
  [ROLE_APPRENTICE] = true
}

local ROLE_LEVEL = {
  [ROLE_OWNER] = 4,
  [ROLE_MASTER] = 3,
  [ROLE_SMITH] = 2,
  [ROLE_APPRENTICE] = 1
}

-- Cache code -> id de compagnie (l'id ne change jamais pendant une session).
local companyIdCache = {}

-- ---------------------------------------------------------------------
-- Utilitaires internes
-- ---------------------------------------------------------------------

-- Handle de base de données du mode.
local function getDatabase()
  return GetDatabase()
end

-- Date UTC ISO 8601.
local function utcNow()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- Journal préfixé "kcRP companies:".
local function log(message)
  Log("kcRP companies: " .. tostring(message))
end

-- Objet joueur kcRP (nil si indisponible).
local function getPlayer(pid)
  if not kcRP.Functions.GetPlayer then
    return nil
  end

  return kcRP.Functions.GetPlayer(pid)
end

-- Identifiant de personnage (players.id) d'un joueur connecté.
local function getCharacterId(pid)
  local player = getPlayer(pid)

  if not player or not player.PlayerData then
    return nil
  end

  return player.PlayerData.characterId
end

-- Niveau numérique d'un rôle (0 si inconnu).
local function getRoleLevel(role)
  return ROLE_LEVEL[role] or 0
end

-- Lit une compagnie complète par son code. callback(row, err).
local function getCompanyByCode(code, callback)
  local database = getDatabase()

  if not database then
    callback(nil, "Database unavailable")
    return
  end

  database:Query(
    [[
      SELECT id, code, label, job_name, level_name, owner_character_id, bank_balance, active
      FROM companies
      WHERE code = @code
      LIMIT 1
    ]],
    { code = code },
    function(rows, err)
      if err then
        callback(nil, err)
        return
      end

      local row = rows and rows[1] or nil

      if row then
        companyIdCache[code] = row.id
      end

      callback(row, nil)
    end
  )
end

-- Retourne l'id d'une compagnie, depuis le cache si possible. callback(id, err).
local function getCompanyId(code, callback)
  if companyIdCache[code] then
    callback(companyIdCache[code], nil)
    return
  end

  getCompanyByCode(code, function(company, err)
    callback(company and company.id or nil, err)
  end)
end

-- Écrit une ligne du journal de la compagnie (company_logs).
local function writeLog(companyId, characterId, action, details)
  local database = getDatabase()

  if not database or not companyId then
    return
  end

  database:Execute(
    [[
      INSERT INTO company_logs (company_id, character_id, action, details, created_at)
      VALUES (@company_id, @character_id, @action, @details, @created_at)
    ]],
    {
      company_id = companyId,
      character_id = characterId,
      action = tostring(action or "unknown"),
      details = tostring(details or ""),
      created_at = utcNow()
    },
    function(_, _, err)
      if err then
        log("company log write failed: " .. tostring(err))
      end
    end
  )
end

-- ---------------------------------------------------------------------
-- API publique (kcRP.Functions) - lecture
-- ---------------------------------------------------------------------

-- Rôle du joueur dans la compagnie. callback(role|nil, err).
function kcRP.Functions.GetCompanyRole(pid, companyCode, callback)
  local database = getDatabase()
  local characterId = getCharacterId(pid)

  if not database or not characterId then
    callback(nil, "Character unavailable")
    return
  end

  getCompanyId(companyCode, function(companyId, companyErr)
    if companyErr or not companyId then
      callback(nil, companyErr or "Company not found")
      return
    end

    database:Query(
      [[
        SELECT role
        FROM company_members
        WHERE company_id = @company_id AND character_id = @character_id AND active = 1
        LIMIT 1
      ]],
      { company_id = companyId, character_id = characterId },
      function(rows, err)
        if err then
          callback(nil, err)
          return
        end

        local row = rows and rows[1] or nil
        callback(row and row.role or nil, nil)
      end
    )
  end)
end

-- Le joueur est-il membre actif ? callback(isMember, role, err).
function kcRP.Functions.IsCompanyMember(pid, companyCode, callback)
  kcRP.Functions.GetCompanyRole(pid, companyCode, function(role, err)
    callback(role ~= nil, role, err)
  end)
end

-- Le joueur a-t-il au moins le rôle demandé ? callback(allowed, role, err).
function kcRP.Functions.HasCompanyRole(pid, companyCode, minimumRole, callback)
  kcRP.Functions.GetCompanyRole(pid, companyCode, function(role, err)
    if err then
      callback(false, nil, err)
      return
    end

    callback(getRoleLevel(role) >= getRoleLevel(minimumRole), role, nil)
  end)
end

-- Liste des membres actifs, triés par rôle puis par nom. callback(rows, err).
function kcRP.Functions.GetCompanyMembers(companyCode, callback)
  local database = getDatabase()

  if not database then
    callback(nil, "Database unavailable")
    return
  end

  getCompanyId(companyCode, function(companyId, companyErr)
    if companyErr or not companyId then
      callback(nil, companyErr or "Company not found")
      return
    end

    database:Query(
      [[
        SELECT m.character_id, m.role, m.joined_at, p.name
        FROM company_members m
        LEFT JOIN players p ON p.id = m.character_id
        WHERE m.company_id = @company_id AND m.active = 1
        ORDER BY
          CASE m.role
            WHEN 'owner' THEN 4
            WHEN 'master' THEN 3
            WHEN 'smith' THEN 2
            WHEN 'apprentice' THEN 1
            ELSE 0
          END DESC,
          p.name ASC
      ]],
      { company_id = companyId },
      function(rows, err)
        if err then
          callback(nil, err)
          return
        end

        callback(rows or {}, nil)
      end
    )
  end)
end

-- ---------------------------------------------------------------------
-- API publique - gestion des membres (maître ou propriétaire requis)
-- ---------------------------------------------------------------------

-- Ajoute (ou réactive) un membre. callback(ok, err).
-- Règle : on ne peut pas attribuer un rôle égal ou supérieur au sien.
function kcRP.Functions.AddCompanyMember(actorPid, targetPid, companyCode, role, callback)
  local database = getDatabase()
  local actorId = getCharacterId(actorPid)
  local targetId = getCharacterId(targetPid)

  if not database or not actorId or not targetId then
    callback(false, "Character unavailable")
    return
  end

  if not VALID_ROLES[role] then
    callback(false, "Invalid role")
    return
  end

  kcRP.Functions.GetCompanyRole(actorPid, companyCode, function(actorRole, roleErr)
    if roleErr or not actorRole then
      callback(false, "No company permission")
      return
    end

    if getRoleLevel(actorRole) < getRoleLevel(ROLE_MASTER) then
      callback(false, "Insufficient company permission")
      return
    end

    if getRoleLevel(role) >= getRoleLevel(actorRole) then
      callback(false, "You cannot assign an equal or higher role")
      return
    end

    getCompanyId(companyCode, function(companyId, companyErr)
      if companyErr or not companyId then
        callback(false, companyErr or "Company not found")
        return
      end

      database:Execute(
        [[
          INSERT INTO company_members (
            company_id, character_id, role, active,
            assigned_by_character_id, joined_at, updated_at
          )
          VALUES (@company_id, @character_id, @role, 1, @assigned_by, @joined_at, @updated_at)
          ON DUPLICATE KEY UPDATE
            role = @role,
            active = 1,
            assigned_by_character_id = @assigned_by,
            updated_at = @updated_at
        ]],
        {
          company_id = companyId,
          character_id = targetId,
          role = role,
          assigned_by = actorId,
          joined_at = utcNow(),
          updated_at = utcNow()
        },
        function(_, _, err)
          if err then
            callback(false, err)
            return
          end

          writeLog(companyId, actorId, "member_added", "character_id=" .. targetId .. ";role=" .. role)
          callback(true, nil)
        end
      )
    end)
  end)
end

-- Change le rôle d'un membre. callback(ok, err).
-- Règles : le propriétaire est intouchable ; on ne modifie pas un rôle égal
-- ou supérieur au sien et on n'en attribue pas non plus.
function kcRP.Functions.SetCompanyRole(actorPid, targetPid, companyCode, newRole, callback)
  local database = getDatabase()
  local actorId = getCharacterId(actorPid)
  local targetId = getCharacterId(targetPid)

  if not database or not actorId or not targetId then
    callback(false, "Character unavailable")
    return
  end

  if not VALID_ROLES[newRole] then
    callback(false, "Invalid role")
    return
  end

  kcRP.Functions.GetCompanyRole(actorPid, companyCode, function(actorRole, actorErr)
    if actorErr or not actorRole then
      callback(false, "No company permission")
      return
    end

    if getRoleLevel(actorRole) < getRoleLevel(ROLE_MASTER) then
      callback(false, "Insufficient company permission")
      return
    end

    kcRP.Functions.GetCompanyRole(targetPid, companyCode, function(targetRole, targetErr)
      if targetErr or not targetRole then
        callback(false, "Target is not a company member")
        return
      end

      if targetRole == ROLE_OWNER then
        callback(false, "The owner role cannot be changed here")
        return
      end

      if getRoleLevel(targetRole) >= getRoleLevel(actorRole) then
        callback(false, "You cannot modify an equal or higher role")
        return
      end

      if getRoleLevel(newRole) >= getRoleLevel(actorRole) then
        callback(false, "You cannot assign an equal or higher role")
        return
      end

      getCompanyId(companyCode, function(companyId, companyErr)
        if companyErr or not companyId then
          callback(false, companyErr or "Company not found")
          return
        end

        database:Execute(
          [[
            UPDATE company_members
            SET role = @role, assigned_by_character_id = @assigned_by, updated_at = @updated_at
            WHERE company_id = @company_id AND character_id = @character_id AND active = 1
          ]],
          {
            role = newRole,
            assigned_by = actorId,
            updated_at = utcNow(),
            company_id = companyId,
            character_id = targetId
          },
          function(_, _, err)
            if err then
              callback(false, err)
              return
            end

            writeLog(companyId, actorId, "role_changed", "character_id=" .. targetId .. ";role=" .. newRole)
            callback(true, nil)
          end
        )
      end)
    end)
  end)
end

-- Retire un membre (désactivation logique). callback(ok, err).
-- Règles : le propriétaire ne peut pas être retiré ; pas de retrait d'un
-- rôle égal ou supérieur au sien.
function kcRP.Functions.RemoveCompanyMember(actorPid, targetPid, companyCode, callback)
  local database = getDatabase()
  local actorId = getCharacterId(actorPid)
  local targetId = getCharacterId(targetPid)

  if not database or not actorId or not targetId then
    callback(false, "Character unavailable")
    return
  end

  kcRP.Functions.GetCompanyRole(actorPid, companyCode, function(actorRole, actorErr)
    if actorErr or not actorRole then
      callback(false, "No company permission")
      return
    end

    if getRoleLevel(actorRole) < getRoleLevel(ROLE_MASTER) then
      callback(false, "Insufficient company permission")
      return
    end

    kcRP.Functions.GetCompanyRole(targetPid, companyCode, function(targetRole, targetErr)
      if targetErr or not targetRole then
        callback(false, "Target is not a company member")
        return
      end

      if targetRole == ROLE_OWNER then
        callback(false, "The owner cannot be removed")
        return
      end

      if getRoleLevel(targetRole) >= getRoleLevel(actorRole) then
        callback(false, "You cannot remove an equal or higher role")
        return
      end

      getCompanyId(companyCode, function(companyId, companyErr)
        if companyErr or not companyId then
          callback(false, companyErr or "Company not found")
          return
        end

        database:Execute(
          [[
            UPDATE company_members
            SET active = 0, assigned_by_character_id = @assigned_by, updated_at = @updated_at
            WHERE company_id = @company_id AND character_id = @character_id
          ]],
          {
            assigned_by = actorId,
            updated_at = utcNow(),
            company_id = companyId,
            character_id = targetId
          },
          function(_, _, err)
            if err then
              callback(false, err)
              return
            end

            writeLog(companyId, actorId, "member_removed", "character_id=" .. targetId)
            callback(true, nil)
          end
        )
      end)
    end)
  end)
end

-- ---------------------------------------------------------------------
-- Initialisation de la base
-- ---------------------------------------------------------------------

-- Exécute une liste d'instructions SQL dans l'ordre.
-- Une instruction "optional" qui échoue est journalisée puis ignorée ;
-- toute autre erreur arrête la séquence. onDone(ok) est appelé à la fin.
local function runSequence(statements, index, onDone)
  local statement = statements[index]

  if not statement then
    onDone(true)
    return
  end

  getDatabase():Execute(statement.sql, {}, function(_, _, err)
    if err then
      log(statement.name .. " failed: " .. tostring(err))

      if not statement.optional then
        onDone(false)
        return
      end
    end

    runSequence(statements, index + 1, onDone)
  end)
end

-- Crée ou met à jour la compagnie de la Forge et sa propriété d'atelier.
function Companies.EnsureBlacksmithForge()
  local database = getDatabase()
  local forge = Companies.Forge

  if not database then
    return
  end

  database:Execute(
    [[
      INSERT INTO companies (code, label, job_name, level_name, active, created_at, updated_at)
      VALUES (@code, @label, @job_name, @level_name, 1, @created_at, @updated_at)
      ON DUPLICATE KEY UPDATE
        label = @label,
        job_name = @job_name,
        level_name = @level_name,
        active = 1,
        updated_at = @updated_at
    ]],
    {
      code = forge.code,
      label = forge.label,
      job_name = forge.jobName,
      level_name = forge.levelName,
      created_at = utcNow(),
      updated_at = utcNow()
    },
    function(_, _, err)
      if err then
        log("Forge de Kuttenberg creation failed: " .. tostring(err))
        return
      end

      getCompanyByCode(forge.code, function(company, companyErr)
        if companyErr or not company then
          log("Forge de Kuttenberg lookup failed: " .. tostring(companyErr))
          return
        end

        -- Une seule ligne "workshop" par compagnie : on la met à jour si elle
        -- existe (clés natives à jour), sinon on la crée.
        database:Query(
          "SELECT id FROM company_properties WHERE company_id = @company_id AND property_type = 'workshop' LIMIT 1",
          { company_id = company.id },
          function(rows, selectErr)
            if selectErr then
              log("Forge property lookup failed: " .. tostring(selectErr))
              return
            end

            -- Les paramètres doivent correspondre exactement au SQL de chaque cas.
            local sql
            local params

            if rows and rows[1] then
              sql = [[
                UPDATE company_properties
                SET level_name = @level_name, label = @label,
                    door_key = @door_key, stash_key = @stash_key, updated_at = @now
                WHERE id = @id
              ]]
              params = {
                id = rows[1].id,
                level_name = forge.levelName,
                label = forge.propertyLabel,
                door_key = forge.doorKey,
                stash_key = forge.stashKey,
                now = utcNow()
              }
            else
              sql = [[
                INSERT INTO company_properties (
                  company_id, property_type, level_name, label,
                  door_key, stash_key, burglary_allowed, active, created_at, updated_at
                )
                VALUES (
                  @company_id, 'workshop', @level_name, @label,
                  @door_key, @stash_key, 1, 1, @now, @now
                )
              ]]
              params = {
                company_id = company.id,
                level_name = forge.levelName,
                label = forge.propertyLabel,
                door_key = forge.doorKey,
                stash_key = forge.stashKey,
                now = utcNow()
              }
            end

            database:Execute(sql, params, function(_, _, propertyErr)
              if propertyErr then
                log("Forge property save failed: " .. tostring(propertyErr))
                return
              end

              log("Forge de Kuttenberg ready")
            end)
          end
        )
      end)
    end
  )
end

-- Crée les tables (si besoin), migre les colonnes de clés, puis installe la Forge.
local function createTables()
  local database = getDatabase()

  if not database then
    log("companies disabled: database unavailable")
    return
  end

  local statements = {
    {
      name = "companies table",
      sql = [[
        CREATE TABLE IF NOT EXISTS companies (
          id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
          code VARCHAR(64) NOT NULL UNIQUE,
          label VARCHAR(128) NOT NULL,
          job_name VARCHAR(32) NOT NULL,
          level_name VARCHAR(32) NOT NULL,
          owner_character_id INT NULL,
          bank_balance DOUBLE PRECISION NOT NULL DEFAULT 0,
          active SMALLINT NOT NULL DEFAULT 1,
          created_at VARCHAR(32),
          updated_at VARCHAR(32),
          FOREIGN KEY (owner_character_id) REFERENCES players(id) ON DELETE SET NULL
        )
      ]]
    },
    {
      name = "company_members table",
      sql = [[
        CREATE TABLE IF NOT EXISTS company_members (
          company_id INT NOT NULL,
          character_id INT NOT NULL,
          role VARCHAR(32) NOT NULL,
          active SMALLINT NOT NULL DEFAULT 1,
          assigned_by_character_id INT NULL,
          joined_at VARCHAR(32),
          updated_at VARCHAR(32),
          PRIMARY KEY (company_id, character_id),
          KEY company_members_character (character_id),
          FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE,
          FOREIGN KEY (character_id) REFERENCES players(id) ON DELETE CASCADE,
          FOREIGN KEY (assigned_by_character_id) REFERENCES players(id) ON DELETE SET NULL
        )
      ]]
    },
    {
      name = "company_properties table",
      sql = [[
        CREATE TABLE IF NOT EXISTS company_properties (
          id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
          company_id INT NOT NULL,
          property_type VARCHAR(32) NOT NULL,
          level_name VARCHAR(32) NOT NULL,
          label VARCHAR(128) NOT NULL,
          door_key VARCHAR(512) NULL,
          stash_key VARCHAR(512) NULL,
          burglary_allowed SMALLINT NOT NULL DEFAULT 1,
          active SMALLINT NOT NULL DEFAULT 1,
          created_at VARCHAR(32),
          updated_at VARCHAR(32),
          KEY company_properties_company (company_id),
          FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE
        )
      ]]
    },
    {
      -- Migration : une base créée avec VARCHAR(255) ne peut pas contenir la
      -- clé du coffre (plus de 300 caractères). Sans effet si déjà large.
      name = "company_properties key columns migration",
      optional = true,
      sql = [[
        ALTER TABLE company_properties
          MODIFY door_key VARCHAR(512) NULL,
          MODIFY stash_key VARCHAR(512) NULL
      ]]
    },
    {
      name = "company_logs table",
      sql = [[
        CREATE TABLE IF NOT EXISTS company_logs (
          id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
          company_id INT NOT NULL,
          character_id INT NULL,
          action VARCHAR(64) NOT NULL,
          details TEXT,
          created_at VARCHAR(32),
          KEY company_logs_company (company_id),
          KEY company_logs_character (character_id),
          FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE,
          FOREIGN KEY (character_id) REFERENCES players(id) ON DELETE SET NULL
        )
      ]]
    }
  }

  runSequence(statements, 1, function(ok)
    if not ok then
      return
    end

    log("companies database ready")
    Companies.EnsureBlacksmithForge()
  end)
end

-- ---------------------------------------------------------------------
-- Premier propriétaire
-- ---------------------------------------------------------------------

-- Si la Forge n'a pas de propriétaire et que le joueur est forgeron, il le devient.
function Companies.AssignFirstOwner(pid)
  local database = getDatabase()
  local characterId = getCharacterId(pid)

  if not database or not characterId then
    return
  end

  local getJob = kcRP.Functions.GetJob
  local job = getJob and getJob(pid) or nil

  if not job or job.name ~= Companies.Forge.jobName then
    return
  end

  getCompanyByCode(Companies.Forge.code, function(company, companyErr)
    if companyErr or not company or tonumber(company.owner_character_id) then
      return
    end

    -- "owner_character_id IS NULL" rend l'attribution atomique : un seul
    -- joueur peut gagner la course.
    database:Execute(
      [[
        UPDATE companies
        SET owner_character_id = @character_id, updated_at = @updated_at
        WHERE id = @company_id AND owner_character_id IS NULL
      ]],
      { character_id = characterId, updated_at = utcNow(), company_id = company.id },
      function(affected, _, err)
        if err or not affected or affected < 1 then
          return
        end

        database:Execute(
          [[
            INSERT INTO company_members (
              company_id, character_id, role, active,
              assigned_by_character_id, joined_at, updated_at
            )
            VALUES (@company_id, @character_id, 'owner', 1, @character_id, @joined_at, @updated_at)
            ON DUPLICATE KEY UPDATE role = 'owner', active = 1, updated_at = @updated_at
          ]],
          {
            company_id = company.id,
            character_id = characterId,
            joined_at = utcNow(),
            updated_at = utcNow()
          },
          function(_, _, memberErr)
            if memberErr then
              log("first owner assignment failed: " .. tostring(memberErr))
              return
            end

            writeLog(company.id, characterId, "owner_assigned", "first owner assigned")

            local player = getPlayer(pid)
            log("Forge de Kuttenberg owner assigned to " .. tostring(player and player.PlayerData.name or characterId))
          end
        )
      end
    )
  end)
end

-- Appelée quand un personnage est connecté.
function Companies.OnPlayerLoggedIn(pid)
  Companies.AssignFirstOwner(pid)
end

-- ---------------------------------------------------------------------
-- Cycle de vie
-- ---------------------------------------------------------------------

-- Chaîne OnGameModeInit : les tables sont créées au démarrage du mode.
local previousGameModeInit = OnGameModeInit

function OnGameModeInit()
  if previousGameModeInit then
    previousGameModeInit()
  end

  createTables()
end

kcRP.Companies = Companies

Log("kcRP: companies module loaded")
