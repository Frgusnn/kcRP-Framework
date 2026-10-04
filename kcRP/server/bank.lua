-- kcRP server bank
-- Cash = KCD:MP native purse.
-- Bank = kcRP persistent SQL account.

kcRP = kcRP or {}
kcRP.Functions = kcRP.Functions or {}
kcRP.Events = kcRP.Events or {}

local Bank = {}

local ACCOUNT_BANK = "bank"
local DEFAULT_BANK_BALANCE = 0
local MAX_TRANSACTION_AMOUNT = 1000000

local function getDatabase()
  return GetDatabase()
end

local function utcNow()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function isValidAmount(amount)
  amount = tonumber(amount)

  if not amount then
    return false
  end

  if amount <= 0 then
    return false
  end

  if amount > MAX_TRANSACTION_AMOUNT then
    return false
  end

  return true
end

local function roundMoney(amount)
  return math.floor((tonumber(amount) or 0) * 100 + 0.5) / 100
end

local function getPlayer(pid)
  return kcRP.Functions.GetPlayer(pid)
end

local function getCharacterId(player)
  return player and player.PlayerData and player.PlayerData.characterId or nil
end

function kcRP.Functions.SyncMoneyState(pid)
  local player = getPlayer(pid)

  if not player or not IsPlayerConnected(pid) then
    return false
  end

  local cash = GetPlayerMoney(pid) or 0
  local bank = player.PlayerData.money and player.PlayerData.money.bank or 0

  player.PlayerData.money = player.PlayerData.money or {}
  player.PlayerData.money.cash = cash
  player.PlayerData.money.bank = bank

  SetPlayerState(pid, "kcrp_cash", tostring(roundMoney(cash)))
  SetPlayerState(pid, "kcrp_bank", tostring(roundMoney(bank)))

  return true
end

function kcRP.Functions.GetMoney(pid, account)
  local player = getPlayer(pid)

  if not player then
    return nil
  end

  account = tostring(account or "cash"):lower()

  if account == "cash" then
    local cash = GetPlayerMoney(pid) or 0
    player.PlayerData.money.cash = cash
    return cash
  end

  if account == ACCOUNT_BANK then
    return player.PlayerData.money.bank or 0
  end

  return nil
end

function Bank.LogTransaction(characterId, account, amount, balanceAfter, reason, fromCharacterId, toCharacterId)
  local database = getDatabase()

  if not database or not characterId then
    return
  end

  database:Execute(
    [[
      INSERT INTO bank_transactions (
        character_id,
        account_name,
        amount,
        balance_after,
        reason,
        from_character_id,
        to_character_id,
        created_at
      )
      VALUES (@character_id, @account_name, @amount, @balance_after, @reason, @from_character_id, @to_character_id, @created_at)
    ]],
    {
      character_id = characterId,
      account_name = account,
      amount = roundMoney(amount),
      balance_after = roundMoney(balanceAfter),
      reason = tostring(reason or "unknown"),
      from_character_id = fromCharacterId,
      to_character_id = toCharacterId,
      created_at = utcNow()
    },
    function(_, _, err)
      if err then
        Log("kcRP: bank transaction log failed: " .. tostring(err))
      end
    end
  )
end

function kcRP.Functions.SaveBank(pid, reason, callback)
  local database = getDatabase()
  local player = getPlayer(pid)
  local characterId = getCharacterId(player)

  if not database or not player or not characterId then
    if callback then callback(false, "Database or character unavailable.") end
    return false
  end

  local balance = roundMoney(player.PlayerData.money.bank or 0)

  database:Execute(
    [[
      INSERT INTO player_accounts (
        player_id,
        account_name,
        balance,
        updated_at
      )
      VALUES (@player_id, @account_name, @balance, @updated_at)
      ON DUPLICATE KEY UPDATE
        balance = @balance,
        updated_at = @updated_at
    ]],
    {
      player_id = characterId,
      account_name = ACCOUNT_BANK,
      balance = balance,
      updated_at = utcNow()
    },
    function(_, _, err)
      if err then
        Log("kcRP: bank save failed for " .. player.PlayerData.name .. ": " .. tostring(err))

        if callback then callback(false, err) end
        return
      end

      if callback then callback(true) end
    end
  )

  return true
end

function kcRP.Functions.SetMoney(pid, account, amount, reason, callback)
  local player = getPlayer(pid)

  if not player then
    if callback then callback(false, "Joueur introuvable.") end
    return false
  end

  account = tostring(account or ""):lower()
  amount = roundMoney(amount)

  if amount < 0 then
    if callback then callback(false, "Montant invalide.") end
    return false
  end

  player.PlayerData.money = player.PlayerData.money or {}

  if account == "cash" then
    local current = GetPlayerMoney(pid) or 0
    local delta = amount - current

    if not GivePlayerMoney(pid, delta) then
      if callback then callback(false, "Impossible de modifier le cash.") end
      return false
    end

    player.PlayerData.money.cash = GetPlayerMoney(pid) or amount
    kcRP.Functions.SyncMoneyState(pid)

    if callback then callback(true, player.PlayerData.money.cash) end
    return true
  end

  if account == ACCOUNT_BANK then
    player.PlayerData.money.bank = amount
    kcRP.Functions.SyncMoneyState(pid)

    kcRP.Functions.SaveBank(pid, reason, function(ok, err)
      if not ok then
        Log("kcRP: bank SetMoney persistence failed: " .. tostring(err))
      end

      if callback then callback(ok, player.PlayerData.money.bank, err) end
    end)

    return true
  end

  if callback then callback(false, "Compte inconnu.") end
  return false
end

function kcRP.Functions.AddMoney(pid, account, amount, reason, callback)
  if not isValidAmount(amount) then
    if callback then callback(false, "Montant invalide.") end
    return false
  end

  local current = kcRP.Functions.GetMoney(pid, account)

  if current == nil then
    if callback then callback(false, "Compte inconnu.") end
    return false
  end

  local player = getPlayer(pid)

  return kcRP.Functions.SetMoney(
    pid,
    account,
    current + amount,
    reason,
    function(ok, newBalance, err)
      if ok and account == ACCOUNT_BANK then
        Bank.LogTransaction(
          getCharacterId(player),
          ACCOUNT_BANK,
          amount,
          newBalance,
          reason or "credit",
          nil,
          getCharacterId(player)
        )
      end

      if callback then callback(ok, newBalance, err) end
    end
  )
end

function kcRP.Functions.RemoveMoney(pid, account, amount, reason, callback)
  if not isValidAmount(amount) then
    if callback then callback(false, "Montant invalide.") end
    return false
  end

  local current = kcRP.Functions.GetMoney(pid, account)

  if current == nil then
    if callback then callback(false, "Compte inconnu.") end
    return false
  end

  if current < amount then
    if callback then callback(false, "Solde insuffisant.") end
    return false
  end

  local player = getPlayer(pid)

  return kcRP.Functions.SetMoney(
    pid,
    account,
    current - amount,
    reason,
    function(ok, newBalance, err)
      if ok and account == ACCOUNT_BANK then
        Bank.LogTransaction(
          getCharacterId(player),
          ACCOUNT_BANK,
          -amount,
          newBalance,
          reason or "debit",
          getCharacterId(player),
          nil
        )
      end

      if callback then callback(ok, newBalance, err) end
    end
  )
end

function kcRP.Functions.LoadBank(pid, characterId)
  local database = getDatabase()
  local player = getPlayer(pid)

  if not database or not player or not characterId then
    Log("kcRP: bank load skipped for pid " .. tostring(pid))
    return
  end

  database:Query(
    "SELECT balance FROM player_accounts WHERE player_id = @player_id AND account_name = @account_name",
    {
      player_id = characterId,
      account_name = ACCOUNT_BANK
    },
    function(rows, err)
      if err then
        Log("kcRP: bank load failed for character " .. tostring(characterId) .. ": " .. tostring(err))
        return
      end

      if not IsPlayerConnected(pid) or getPlayer(pid) ~= player then
        return
      end

      player.PlayerData.money = player.PlayerData.money or {}

      local row = rows and rows[1]

      if not row then
        player.PlayerData.money.bank = DEFAULT_BANK_BALANCE
        kcRP.Functions.SyncMoneyState(pid)

        kcRP.Functions.SaveBank(pid, "first bank setup", function(ok, saveErr)
          if ok then
            Log("kcRP: default bank account created for " .. player.PlayerData.name)
          else
            Log("kcRP: default bank account failed for " .. player.PlayerData.name .. ": " .. tostring(saveErr))
          end
        end)

        return
      end

      player.PlayerData.money.bank = roundMoney(row.balance or 0)
      kcRP.Functions.SyncMoneyState(pid)

      Log(string.format(
        "kcRP: bank loaded for %s#%d: %.2f",
        player.PlayerData.name,
        pid,
        player.PlayerData.money.bank
      ))
    end
  )
end

function Bank.InitDatabase()
  local database = getDatabase()

  if not database then
    Log("kcRP: bank disabled; no database available.")
    return false
  end

  Log("kcRP: creating/checking bank tables...")

  database:Execute([[
    CREATE TABLE IF NOT EXISTS player_accounts (
      player_id INT NOT NULL,
      account_name VARCHAR(32) NOT NULL,
      balance DOUBLE PRECISION NOT NULL DEFAULT 0,
      updated_at VARCHAR(32),
      PRIMARY KEY (player_id, account_name),
      FOREIGN KEY (player_id) REFERENCES players(id) ON DELETE CASCADE
    )
  ]], {}, function(_, _, accountsErr)
    if accountsErr then
      Log("kcRP: player_accounts table creation failed: " .. tostring(accountsErr))
      return
    end

    database:Execute([[
      CREATE TABLE IF NOT EXISTS bank_transactions (
        id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        character_id INT NOT NULL,
        account_name VARCHAR(32) NOT NULL,
        amount DOUBLE PRECISION NOT NULL,
        balance_after DOUBLE PRECISION NOT NULL,
        reason VARCHAR(128) NOT NULL,
        from_character_id INT NULL,
        to_character_id INT NULL,
        created_at VARCHAR(32),
        KEY bank_transactions_character (character_id),
        KEY bank_transactions_created (created_at),
        FOREIGN KEY (character_id) REFERENCES players(id) ON DELETE CASCADE
      )
    ]], {}, function(_, _, transactionsErr)
      if transactionsErr then
        Log("kcRP: bank_transactions table creation failed: " .. tostring(transactionsErr))
        return
      end

      Log("kcRP: bank database ready")
    end)
  end)

  return true
end

function Bank.OnPlayerLoggedIn(pid, characterId)
  local player = getPlayer(pid)

  if not player then
    return
  end

  player.PlayerData.characterId = characterId
  player.PlayerData.loggedIn = true
  player.PlayerData.money = player.PlayerData.money or {
    cash = 0,
    bank = 0
  }

  player.PlayerData.money.cash = GetPlayerMoney(pid) or 0

  kcRP.Functions.LoadBank(pid, characterId)
end

function Bank.OnPlayerDisconnect(pid)
  kcRP.Functions.SaveBank(pid, "player disconnect")
end

function Bank.HandleCommand(pid, cmd, args)
  local player = getPlayer(pid)

  if not player then
    return false
  end

  if cmd == "balance" or cmd == "bank" then
    local cash = kcRP.Functions.GetMoney(pid, "cash") or 0
    local bank = kcRP.Functions.GetMoney(pid, "bank") or 0

    SendClientMessage(
      pid,
      COLOR_GOLD,
      string.format("Bourse : %.2f Groschen | Banque : %.2f Groschen", cash, bank)
    )

    return true
  end

  if cmd == "deposit" then
    local amount = tonumber(args)

    if not isValidAmount(amount) then
      SendClientMessage(pid, COLOR_RED, "Usage : /deposit <montant positif>")
      return true
    end

    local cash = kcRP.Functions.GetMoney(pid, "cash") or 0

    if cash < amount then
      SendClientMessage(pid, COLOR_RED, "Vous n'avez pas assez de Groschen dans votre bourse.")
      return true
    end

    local removed = kcRP.Functions.RemoveMoney(pid, "cash", amount, "bank deposit")

    if not removed then
      SendClientMessage(pid, COLOR_RED, "Le dépôt a échoué.")
      return true
    end

    kcRP.Functions.AddMoney(pid, "bank", amount, "bank deposit", function(ok, balance)
      if not ok then
        kcRP.Functions.AddMoney(pid, "cash", amount, "bank deposit rollback")
        SendClientMessage(pid, COLOR_RED, "Le dépôt a échoué ; votre argent a été rendu.")
        return
      end

      SendClientMessage(
        pid,
        COLOR_GREEN,
        string.format("Dépôt de %.2f Groschen. Solde banque : %.2f.", amount, balance)
      )
    end)

    return true
  end

  if cmd == "withdraw" then
    local amount = tonumber(args)

    if not isValidAmount(amount) then
      SendClientMessage(pid, COLOR_RED, "Usage : /withdraw <montant positif>")
      return true
    end

    local bank = kcRP.Functions.GetMoney(pid, "bank") or 0

    if bank < amount then
      SendClientMessage(pid, COLOR_RED, "Solde bancaire insuffisant.")
      return true
    end

    local removed = kcRP.Functions.RemoveMoney(pid, "bank", amount, "bank withdrawal")

    if not removed then
      SendClientMessage(pid, COLOR_RED, "Le retrait a échoué.")
      return true
    end

    local added = kcRP.Functions.AddMoney(pid, "cash", amount, "bank withdrawal")

    if not added then
      kcRP.Functions.AddMoney(pid, "bank", amount, "bank withdrawal rollback")
      SendClientMessage(pid, COLOR_RED, "Le retrait a échoué ; votre argent a été recrédité.")
      return true
    end

    SendClientMessage(
      pid,
      COLOR_GREEN,
      string.format("Retrait de %.2f Groschen.", amount)
    )

    return true
  end

  if cmd == "pay" then
    local target, amount = sscanf(args, "uf")

    if target == false then
      SendClientMessage(pid, COLOR_RED, "Usage : /pay <joueur> <montant>")
      return true
    end

    if target == pid then
      SendClientMessage(pid, COLOR_RED, "Vous ne pouvez pas vous payer vous-même.")
      return true
    end

    if not isValidAmount(amount) then
      SendClientMessage(pid, COLOR_RED, "Le montant doit être positif.")
      return true
    end

    local bank = kcRP.Functions.GetMoney(pid, "bank") or 0

    if bank < amount then
      SendClientMessage(pid, COLOR_RED, "Solde bancaire insuffisant.")
      return true
    end

    local targetPlayer = getPlayer(target)

    if not targetPlayer then
      SendClientMessage(pid, COLOR_RED, "Joueur introuvable.")
      return true
    end

    local senderCharacterId = getCharacterId(player)
    local receiverCharacterId = getCharacterId(targetPlayer)

    if not senderCharacterId or not receiverCharacterId then
      SendClientMessage(pid, COLOR_RED, "Paiement indisponible : personnage non chargé.")
      return true
    end

    local removed = kcRP.Functions.RemoveMoney(pid, "bank", amount, "player payment")

    if not removed then
      SendClientMessage(pid, COLOR_RED, "Le paiement a échoué.")
      return true
    end

    kcRP.Functions.AddMoney(target, "bank", amount, "player payment", function(ok)
      if not ok then
        kcRP.Functions.AddMoney(pid, "bank", amount, "player payment rollback")
        SendClientMessage(pid, COLOR_RED, "Paiement échoué ; votre argent a été recrédité.")
        return
      end

      SendClientMessage(
        pid,
        COLOR_GREEN,
        string.format("Vous avez envoyé %.2f Groschen à %s.", amount, targetPlayer.PlayerData.name)
      )

      SendClientMessage(
        target,
        COLOR_GREEN,
        string.format("Vous avez reçu %.2f Groschen de %s.", amount, player.PlayerData.name)
      )
    end)

    return true
  end

  return false
end

kcRP.Bank = Bank

-- =====================================================================
-- Interface Web de la Banque
-- =====================================================================

-- Envoyer les soldes au client
local function sendBankState(pid)
  local player = getPlayer(pid)
  
  if not player then
    return
  end
  
  local cash = kcRP.Functions.GetMoney(pid, "cash") or 0
  local bank = kcRP.Functions.GetMoney(pid, "bank") or 0
  
  -- Envoyer via un événement client
  SendClientEvent(pid, "bank_state", string.format("%.2f;%.2f", cash, bank))
end

-- Gérer les événements web
local previousWebMessage = OnWebMessage

-- Gérer les événements web
local previousWebMessage = OnWebMessage

-- Gérer les événements web
local previousWebMessage = OnWebMessage

function OnWebMessage(frame, data)
  -- Vérifier si c'est la frame bank
  if frame ~= "bank" then
    if previousWebMessage then
      return previousWebMessage(frame, data)
    end
    return
  end
  
  -- Récupérer le joueur qui a envoyé le message
  local pid = GetPlayerFromWebFrame(frame)
  
  if not pid then
    Log("Bank: Impossible de trouver le joueur pour la frame", frame)
    return
  end
  
  Log("Bank Web message from player", pid, ":", data)
  
  if data and data.action then
    if data.action == "close" then
      -- Fermer la frame et cacher le curseur
      HidePlayerWebFrame(pid, "bank")
      SetPlayerCursor(pid, false)
      Log("Bank frame closed for player", pid)
      
    elseif data.action == "deposit" then
      -- Dépôt
      local amount = tonumber(data.amount)
      if amount and amount > 0 then
        Log("Deposit requested by player", pid, ":", amount)
        -- Traiter le dépôt
      end
      
    elseif data.action == "withdraw" then
      -- Retrait
      local amount = tonumber(data.amount)
      if amount and amount > 0 then
        Log("Withdrawal requested by player", pid, ":", amount)
        -- Traiter le retrait
      end
    end
  end
  
  if previousWebMessage then
    return previousWebMessage(frame, data)
  end
end

-- Commande de test pour mettre à jour l'UI
function kcRP.Functions.UpdateBankUI(pid)
  sendBankState(pid)
end

Log("kcRP: server bank module loaded")
