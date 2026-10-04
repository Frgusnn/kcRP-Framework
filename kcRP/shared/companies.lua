-- kcRP Companies
-- Persistent company foundation.
-- First registered company: Forge de Kuttenberg.

kcRP = kcRP or {}
kcRP.Companies = kcRP.Companies or {}
kcRP.Functions = kcRP.Functions or {}

local db = GetDatabase()

local COMPANY_BLACKSMITH_KUTTENBERG = "blacksmith_kuttenberg"

local function log(message)
  Log("kcRP companies: " .. tostring(message))
end

local function getPlayerAccountId(pid)
  local player = players and players[pid]

  if not player then
    return nil
  end

  return player.id
end

local function getCompanyId(code, callback)
  if not db then
    callback(nil, "Database unavailable")
    return
  end

  db:Query(
    "SELECT id FROM companies WHERE code = :code LIMIT 1",
    {
      code = code
    },
    function(rows, err)
      if err then
        callback(nil, err)
        return
      end

      if not rows or not rows[1] then
        callback(nil, nil)
        return
      end

      callback(tonumber(rows[1].id), nil)
    end
  )
end

local function addLog(companyId, playerId, action, details)
  if not db or not companyId then
    return
  end

  db:Execute(
    [[
      INSERT INTO company_logs (
        company_id,
        player_id,
        action,
        details,
        created_at
      )
      VALUES (
        :company_id,
        :player_id,
        :action,
        :details,
        UTC_TIMESTAMP()
      )
    ]],
    {
      company_id = companyId,
      player_id = playerId,
      action = action,
      details = details or ""
    },
    function(_, _, err)
      if err then
        log("could not write company log: " .. tostring(err))
      end
    end
  )
end

local function ensureBlacksmithCompany()
  if not db then
    log("database unavailable; companies disabled")
    return
  end

  db:Execute(
    [[
      INSERT INTO companies (
        code,
        label,
        job_name,
        level_name,
        door_key,
        stash_key,
        burglary_allowed,
        created_at
      )
      VALUES (
        :code,
        :label,
        :job_name,
        :level_name,
        :door_key,
        :stash_key,
        :burglary_allowed,
        UTC_TIMESTAMP()
      )
      ON DUPLICATE KEY UPDATE
        label = VALUES(label),
        job_name = VALUES(job_name),
        level_name = VALUES(level_name),
        door_key = VALUES(door_key),
        stash_key = VALUES(stash_key),
        burglary_allowed = VALUES(burglary_allowed)
    ]],
    {
      code = COMPANY_BLACKSMITH_KUTTENBERG,
      label = "Forge de Kuttenberg",
      job_name = "blacksmith",
      level_name = "kutnohorsko",
      door_key = "door.workshop_a1",
      stash_key = "chest.smithy_workshop2",
      burglary_allowed = 1
    },
    function(_, _, err)
      if err then
        log("could not create Forge de Kuttenberg: " .. tostring(err))
        return
      end

      log("Forge de Kuttenberg ready")
    end
  )
end

function kcRP.Functions.GetCompanyMemberRole(pid, companyCode, callback)
  local playerId = getPlayerAccountId(pid)

  if not playerId then
    callback(nil, "Player account unavailable")
    return
  end

  getCompanyId(companyCode, function(companyId, companyErr)
    if companyErr then
      callback(nil, companyErr)
      return
    end

    if not companyId then
      callback(nil, "Company not found")
      return
    end

    db:Query(
      [[
        SELECT role
        FROM company_members
        WHERE company_id = :company_id
          AND player_id = :player_id
          AND active = 1
        LIMIT 1
      ]],
      {
        company_id = companyId,
        player_id = playerId
      },
      function(rows, err)
        if err then
          callback(nil, err)
          return
        end

        if not rows or not rows[1] then
          callback(nil, nil)
          return
        end

        callback(rows[1].role, nil)
      end
    )
  end)
end

function kcRP.Functions.IsCompanyMember(pid, companyCode, callback)
  kcRP.Functions.GetCompanyMemberRole(
    pid,
    companyCode,
    function(role, err)
      callback(role ~= nil, role, err)
    end
  )
end

function kcRP.Functions.AddCompanyMember(companyCode, targetPid, role, assignedByPid, callback)
  local validRoles = {
    owner = true,
    master = true,
    smith = true,
    apprentice = true
  }

  if not validRoles[role] then
    callback(false, "Invalid company role")
    return
  end

  local targetId = getPlayerAccountId(targetPid)

  if not targetId then
    callback(false, "Target account unavailable")
    return
  end

  local assignedById = assignedByPid and getPlayerAccountId(assignedByPid) or nil

  getCompanyId(companyCode, function(companyId, companyErr)
    if companyErr then
      callback(false, companyErr)
      return
    end

    if not companyId then
      callback(false, "Company not found")
      return
    end

    db:Execute(
      [[
        INSERT INTO company_members (
          company_id,
          player_id,
          role,
          active,
          assigned_by,
          joined_at
        )
        VALUES (
          :company_id,
          :player_id,
          :role,
          1,
          :assigned_by,
          UTC_TIMESTAMP()
        )
        ON DUPLICATE KEY UPDATE
          role = VALUES(role),
          active = 1,
          assigned_by = VALUES(assigned_by),
          joined_at = UTC_TIMESTAMP()
      ]],
      {
        company_id = companyId,
        player_id = targetId,
        role = role,
        assigned_by = assignedById
      },
      function(_, _, err)
        if err then
          callback(false, err)
          return
        end

        addLog(
          companyId,
          assignedById,
          "member_assigned",
          "player_id=" .. tostring(targetId) .. ";role=" .. role
        )

        callback(true, nil)
      end
    )
  end)
end

function kcRP.Functions.RemoveCompanyMember(companyCode, targetPid, removedByPid, callback)
  local targetId = getPlayerAccountId(targetPid)

  if not targetId then
    callback(false, "Target account unavailable")
    return
  end

  local removedById = removedByPid and getPlayerAccountId(removedByPid) or nil

  getCompanyId(companyCode, function(companyId, companyErr)
    if companyErr then
      callback(false, companyErr)
      return
    end

    if not companyId then
      callback(false, "Company not found")
      return
    end

    db:Execute(
      [[
        UPDATE company_members
        SET active = 0
        WHERE company_id = :company_id
          AND player_id = :player_id
      ]],
      {
        company_id = companyId,
        player_id = targetId
      },
      function(_, _, err)
        if err then
          callback(false, err)
          return
        end

        addLog(
          companyId,
          removedById,
          "member_removed",
          "player_id=" .. tostring(targetId)
        )

        callback(true, nil)
      end
    )
  end)
end

local previousGameModeInit = OnGameModeInit

function OnGameModeInit()
  if previousGameModeInit then
    previousGameModeInit()
  end

  if not db then
    log("database unavailable; module not initialized")
    return
  end

  local _, _, companiesErr = db:ExecuteSync([[
    CREATE TABLE IF NOT EXISTS companies (
      id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
      code VARCHAR(64) NOT NULL UNIQUE,
      label VARCHAR(128) NOT NULL,
      job_name VARCHAR(64) NOT NULL,
      level_name VARCHAR(64) NOT NULL,
      door_key VARCHAR(255),
      stash_key VARCHAR(255),
      burglary_allowed TINYINT NOT NULL DEFAULT 1,
      created_at DATETIME NOT NULL
    )
  ]])

  if companiesErr then
    log("companies table failed: " .. tostring(companiesErr))
    return
  end

  local _, _, membersErr = db:ExecuteSync([[
    CREATE TABLE IF NOT EXISTS company_members (
      company_id INT NOT NULL,
      player_id INT NOT NULL,
      role VARCHAR(32) NOT NULL,
      active TINYINT NOT NULL DEFAULT 1,
      assigned_by INT NULL,
      joined_at DATETIME NOT NULL,
      PRIMARY KEY (company_id, player_id),
      INDEX company_members_player_idx (player_id),
      CONSTRAINT company_members_company_fk
        FOREIGN KEY (company_id)
        REFERENCES companies(id)
        ON DELETE CASCADE
    )
  ]])

  if membersErr then
    log("company_members table failed: " .. tostring(membersErr))
    return
  end

  local _, _, logsErr = db:ExecuteSync([[
    CREATE TABLE IF NOT EXISTS company_logs (
      id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
      company_id INT NOT NULL,
      player_id INT NULL,
      action VARCHAR(64) NOT NULL,
      details TEXT,
      created_at DATETIME NOT NULL,
      INDEX company_logs_company_idx (company_id),
      INDEX company_logs_player_idx (player_id),
      CONSTRAINT company_logs_company_fk
        FOREIGN KEY (company_id)
        REFERENCES companies(id)
        ON DELETE CASCADE
    )
  ]])

  if logsErr then
    log("company_logs table failed: " .. tostring(logsErr))
    return
  end

  ensureBlacksmithCompany()
end

Log("kcRP: companies module loaded")