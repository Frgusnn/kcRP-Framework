-- =====================================================================
-- kcRP.lua
--   * configuration et variables partagées
--   * outils SQL d'initialisation et de migration
--   * OnGameModeInit
--   * marchand du spawn
--   * noyau kcRP : registre des joueurs et permissions
-- Tous les noms utilisés par le reste du fichier sont conservés à
-- l'identique (execInit, insertId, itemName, setupDiscovery...) : la
-- suite peut être collée telle quelle après cette partie.
-- =====================================================================

SetGameModeText("kcRP")

-- Point d'apparition par défaut du serveur (server.toml), base de spawnSpot().
local spawnX, spawnY, spawnZ, spawnYaw = GetDefaultSpawn()

-- Handle de base de données (nil si aucune base n'est configurée).
local db = GetDatabase()

-- Registre BasicRP : pid -> { name = nom en minuscules, registered = un compte
-- existe, logged = identité prouvée durant cette session }.
local players = {}

-- ---------------------------------------------------------------------
-- Réglages
-- ---------------------------------------------------------------------
local CHAT_RANGE, SHOUT_RANGE = 20, 40          -- mètres : voix normale / cri
local COLOR_OOC = 0xB0B0B0FF                    -- gris des lignes hors-personnage
local COLOR_PARTY = 0x80C0FFFF                  -- bleu clair des lignes de groupe
local START_MONEY, START_ITEMS = 3000, { "torch_weapon" } -- kit d'un nouveau personnage
local CREATOR_WORLD = 1000                      -- + pid : monde où se crée un personnage
local MAX_TRIES = 5                             -- mots de passe faux avant expulsion

-- Caméra (appliquée à chaque connexion).
local CAMERA = {
  third_person = "allow", -- "off" : première personne ; "allow" : touche F3 ; "force" : toujours à la 3e personne
  in_fights = true,       -- false : première personne pendant un combat
  when_aiming = true,     -- false : première personne quand un arc / arbalète est bandé
  crosshair = true        -- false : pas de point de visée à la 3e personne
}

-- Administrateurs : false = seuls les noms de la variable d'environnement
-- KCDMP_ADMINS ("Henry,Hans") le sont, une fois leur identité prouvée.
local EVERYONE_ADMIN = false

local admins = {}

for name in (os.getenv("KCDMP_ADMINS") or ""):gmatch("[^,%s]+") do
  admins[name:lower()] = true
end

-- Propriétaires kcRP (noms en minuscules). Ajouter les suivants ici.
local KCRP_OWNERS = {
  ["frgusnn"] = true
}

-- Raccourci de string.format.
local function fmt(...)
  return string.format(...)
end

-- Envoie une ligne de chat "serveur" à un joueur.
local function say(pid, text)
  SendClientMessage(pid, COLOR_SERVER, text)
end

-- Déclarations anticipées : ces fonctions sont définies plus bas dans le fichier.
local register, login, savePlace, savePlaces, makeMerchant, promote, horse, party, help, openCreator, saveLook
local askPassword, stageCreator, leaveCreator, unstuck
local cartMaker, cartMakerEvent, closeCartMaker, dropCarts, despawnCart
local PROGRESS   -- règles de progression (section dédiée)
local DISCOVERY  -- règles de découverte (section dédiée)
local PULLDOWN   -- règles de "pull-down" (près des dés)
local pullReady, pullSafe = {}, {} -- pid tireur -> ms de nouvelle tentative ; pid cavalier -> ms de protection
local CARRY      -- règles de portage (près des pull-down)
local carryCommand
local PICKPOCKET -- règles de pickpocket (près du portage)
local pocketCommand, pocketRights

-- Position d'apparition d'un joueur : le point du serveur, décalé de 1,5 m par pid.
local function spawnSpot(pid)
  return spawnX + 1.5 * (pid % 16), spawnY + 1.5 * (pid // 16), spawnZ, spawnYaw
end

-- Accorde ou retire l'admin natif selon le rôle kcRP (les permissions kcRP
-- sont la seule autorité). Appelée à plusieurs endroits par BasicRP.
-- Retourne true si le joueur est admin natif.
function promote(pid)
  local p = players[pid]
  local role = kcRP and kcRP.Functions.GetPermission(pid) or "user"

  if kcRP and kcRP.Config.NativeAdminRoles[role] then
    if p then
      p.admin = true
    end

    kcRP.Functions.ApplyNativeAdmin(pid)
    say(pid, "kcRP permission: " .. role .. ". Native admin access granted.")
    return true
  end

  if p then
    p.admin = false
  end

  if IsPlayerConnected(pid) then
    SetPlayerAdmin(pid, false)
  end

  return false
end

-- Envoie une ligne à tous les joueurs du même monde dans un rayon donné
-- (l'émetteur compris) : le chat de proximité du jeu de rôle.
local function sayNearby(pid, range, color, text)
  local x, y, z = GetPlayerPos(pid)

  if not x then
    SendClientMessage(pid, color, text)
    return
  end

  for _, other in ipairs(GetPlayersInRange(x, y, z, range, GetPlayerVirtualWorld(pid))) do
    SendClientMessage(other, color, text)
  end
end

-- ---------------------------------------------------------------------
-- Les tables
-- players        : un compte par ligne (clé id, nom unique)
-- player_items   : une pile par ligne (porté ou équipé, worn = 1)
-- player_horses  : un cheval par ligne (race, robe ; active = celui de /horse)
-- horse_items    : une pile par ligne dans les sacoches (équipement worn = 1)
-- player_progress: niveau, XP et points de talent par stat / compétence
-- player_perks   : un talent par ligne
-- horse_stats    : une statistique donnée à un cheval par ligne
-- ---------------------------------------------------------------------

-- Colonnes ajoutées à "players" depuis sa première version.
local ADDED_COLUMNS = {
  { "money", "DOUBLE PRECISION" },        -- la bourse
  { "level", "VARCHAR(32)" },             -- niveau du lieu sauvegardé
  { "look", "TEXT" },                     -- apparence (LookToString)
  { "nourishment", "DOUBLE PRECISION" },  -- état de faim du jeu
  { "energy", "DOUBLE PRECISION" }        -- état de fatigue du jeu
}

-- Requête listant les colonnes d'une table selon le moteur (%s = la table).
local COLUMNS_SQL = {
  mysql = "SELECT column_name AS c FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = '%s'",
  postgres = "SELECT column_name::text AS c FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = '%s'",
  sqlite = "SELECT name AS c FROM pragma_table_info('%s')"
}

-- Colonnes ajoutées à "player_horses".
local HORSE_COLUMNS = {
  { "coat", "VARCHAR(16)" } -- robe (GetHorseCoats) : le cheval revient de la même couleur
}

-- Colonnes communes aux tables de piles d'objets.
local STACK_COLUMNS = [[slot SMALLINT NOT NULL, item VARCHAR(36) NOT NULL, item_name VARCHAR(64), amount INT NOT NULL,
      health SMALLINT NOT NULL DEFAULT 100, worn SMALLINT NOT NULL DEFAULT 0]]

-- Syntaxe de clé numérotée propre au moteur SQL.
local function autoId()
  if db.driver == "postgres" then
    return "id SERIAL PRIMARY KEY"
  end

  if db.driver == "sqlite" then
    return "id INTEGER PRIMARY KEY AUTOINCREMENT"
  end

  return "id INT NOT NULL AUTO_INCREMENT PRIMARY KEY"
end

-- Exécute une instruction SQL synchrone (démarrage uniquement).
-- Retourne true si elle a réussi ; journalise l'échec sinon.
local function execInit(sql, what)
  local _, _, err = db:ExecuteSync(sql)

  if err then
    Log("kcRP: " .. what .. " failed: " .. err)
  end

  return err == nil
end

-- Ajoute à une table les colonnes de "list" qui lui manquent.
-- Retourne l'ensemble des colonnes présentes (nom en minuscules -> true).
-- Si le moteur ne sait pas les lister, chaque ajout est tenté et les échecs
-- des colonnes déjà présentes sont ignorés.
local function addColumns(tableName, list)
  local have = {}
  local sql = string.format(COLUMNS_SQL[db.driver] or COLUMNS_SQL.mysql, tableName)

  for _, row in ipairs(db:QuerySync(sql) or {}) do
    if row.c then
      have[string.lower(row.c)] = true
    end
  end

  for _, column in ipairs(list) do
    if not have[column[1]] then
      local _, _, failed = db:ExecuteSync("ALTER TABLE " .. tableName .. " ADD COLUMN " .. column[1] .. " " .. column[2])

      if not failed then
        Log("kcRP: added the column '" .. column[1] .. "' to the " .. tableName .. " table")
        have[column[1]] = true
      end
    end
  end

  return have
end

-- Migration d'une table "players" d'avant le 2026-09-25 (clé = le nom) :
-- elle reçoit un id et le nom reste unique. MySQL / MariaDB et PostgreSQL
-- numérotent les lignes à l'ajout ; SQLite (les tests) recopie la table.
local function keyPlayersById(have)
  if db.driver == "mysql" then
    return execInit("ALTER TABLE players DROP PRIMARY KEY, ADD COLUMN id INT NOT NULL AUTO_INCREMENT PRIMARY KEY FIRST, " ..
      "ADD UNIQUE KEY players_name (name)", "keying the players table by id")
  elseif db.driver == "postgres" then
    return execInit("ALTER TABLE players DROP CONSTRAINT IF EXISTS players_pkey", "dropping the name key")
      and execInit("ALTER TABLE players ADD COLUMN id SERIAL PRIMARY KEY", "keying the players table by id")
      and execInit("ALTER TABLE players ADD CONSTRAINT players_name_key UNIQUE (name)", "keeping the names unique")
  end

  local columns = {}

  for _, c in ipairs({ "name", "password", "visits", "x", "y", "z", "yaw", "money", "level", "inventory", "look", "horse",
    "last_seen", "nourishment", "energy" }) do
    if have[c] then
      columns[#columns + 1] = c
    end
  end

  local list = table.concat(columns, ", ")

  return execInit([[CREATE TABLE players_new (id INTEGER PRIMARY KEY AUTOINCREMENT, name VARCHAR(24) NOT NULL UNIQUE,
      password VARCHAR(200) NOT NULL, visits INTEGER NOT NULL DEFAULT 0, x DOUBLE PRECISION, y DOUBLE PRECISION,
      z DOUBLE PRECISION, yaw DOUBLE PRECISION, money DOUBLE PRECISION, level VARCHAR(32), inventory TEXT, look TEXT, horse TEXT,
      last_seen VARCHAR(32), nourishment DOUBLE PRECISION, energy DOUBLE PRECISION)]], "copying the players table")
    and execInit("INSERT INTO players_new (" .. list .. ") SELECT " .. list .. " FROM players", "copying the players")
    and execInit("DROP TABLE players", "dropping the old players table")
    and execInit("ALTER TABLE players_new RENAME TO players", "renaming the players table")
end

-- Insère une ligne et retourne son nouvel id (version synchrone, démarrage).
-- MySQL / MariaDB renvoient l'id ; PostgreSQL et SQLite répondent RETURNING.
local function insertIdSync(sql, params)
  if db.driver == "mysql" then
    local _, id, err = db:ExecuteSync(sql, params)
    return not err and id or nil, err
  end

  local rows, err = db:QuerySync(sql .. " RETURNING id", params)
  return rows and rows[1] and rows[1].id, err
end

-- Même chose en asynchrone : cb(id, err). Fonction globale, utilisée plus bas.
function insertId(sql, params, cb)
  if db.driver == "mysql" then
    db:Execute(sql, params, function(_, id, err)
      cb(not err and id or nil, err)
    end)
  else
    db:Scalar(sql .. " RETURNING id", params, cb)
  end
end

-- Anciennes sauvegardes (avant les tables) : sacs au format
-- "classe:quantité[:porté];..." convertis en liste de piles.
local function oldBags(packed)
  local items = {}

  for entry in (packed or ""):gmatch("[^;]+") do
    local class, amount, worn = entry:match("^([^:]+):(%d+):?(%d*)$")
    amount, worn = tonumber(amount), tonumber(worn) or 0

    if class and amount and amount > 0 then
      for _ = 1, math.min(worn, amount) do
        items[#items + 1] = { class = class, amount = 1, health = 100, worn = true }
      end

      if amount > worn then
        items[#items + 1] = { class = class, amount = amount - worn, health = 100 }
      end
    end
  end

  return items
end

-- Ancien cheval "race|équipement,...|classe:quantité:santé;..." converti en
-- (race, liste de piles). Retourne nil si le format est invalide.
local function oldHorse(line)
  local breed, gear, bags = (line or ""):match("^([^|]*)|([^|]*)|(.*)$")

  if not breed then
    return nil
  end

  local items = {}

  for class in gear:gmatch("[^,]+") do
    items[#items + 1] = { class = class, amount = 1, health = 100, worn = true }
  end

  for class, amount, health in bags:gmatch("([^:;]+):(%d+):(%d+)") do
    items[#items + 1] = { class = class, amount = tonumber(amount), health = tonumber(health) }
  end

  return breed, items
end

-- Premier démarrage après la création des tables : les sauvegardes texte de
-- chaque compte deviennent des lignes, puis les anciennes colonnes sont vidées.
local function moveOldSaves(have)
  if not (have.inventory or have.horse) then
    return
  end

  local cols = (have.inventory and "inventory" or "NULL AS inventory") .. ", " .. (have.horse and "horse" or "NULL AS horse")
  local where = {}

  if have.inventory then
    where[#where + 1] = "(inventory IS NOT NULL AND inventory <> '')"
  end

  if have.horse then
    where[#where + 1] = "(horse IS NOT NULL AND horse <> '')"
  end

  local rows, err = db:QuerySync("SELECT id, " .. cols .. " FROM players WHERE " .. table.concat(where, " OR "))

  if err then
    Log("kcRP: the old saves could not be read: " .. err)
    return
  end

  local moved = 0

  for _, row in ipairs(rows or {}) do
    for slot, it in ipairs(oldBags(row.inventory)) do
      db:ExecuteSync("INSERT INTO player_items (player_id, slot, item, item_name, amount, health, worn) VALUES (@p, @s, @i, @n, @a, @h, @w)",
        { p = row.id, s = slot, i = it.class, n = itemName(it.class), a = it.amount, h = it.health, w = it.worn and 1 or 0 })
    end

    local breed, items = oldHorse(row.horse)

    if breed then
      local horseId = insertIdSync("INSERT INTO player_horses (player_id, soul, active, created_at) VALUES (@p, @s, 1, @t)",
        { p = row.id, s = breed ~= "" and breed or DB_NULL, t = os.date("!%Y-%m-%dT%H:%M:%SZ") })

      for slot, it in ipairs(horseId and items or {}) do
        db:ExecuteSync("INSERT INTO horse_items (horse_id, slot, item, item_name, amount, health, worn) VALUES (@hid, @s, @i, @n, @a, @h, @w)",
          { hid = horseId, s = slot, i = it.class, n = itemName(it.class), a = it.amount, h = it.health, w = it.worn and 1 or 0 })
      end
    end

    local sets = {}

    if have.inventory then
      sets[#sets + 1] = "inventory = NULL"
    end

    if have.horse then
      sets[#sets + 1] = "horse = NULL"
    end

    db:ExecuteSync("UPDATE players SET " .. table.concat(sets, ", ") .. " WHERE id = @p", { p = row.id })
    moved = moved + 1
  end

  if moved > 0 then
    Log(fmt("kcRP: %d account(s)' saved bags and horses moved into the tables", moved))
  end
end

-- Démarrage du mode : réglages du serveur, création / migration des tables,
-- initialisation des modules jobs et banque, sauvegarde périodique.
function OnGameModeInit()
  Log(fmt("kcRP on %s: spawn %.1f %.1f %.1f, %d slots", GetLevel(), spawnX, spawnY, spawnZ, GetMaxPlayers()))

  SetStoryQuests(false) -- les quêtes du jeu restent endormies (elles peuvent prendre les affaires d'un joueur)
  SetXPRate(PROGRESS.xp_rate)
  SetCarrying(CARRY.enabled, CARRY)
  SetPickpocketing(PICKPOCKET.enabled, PICKPOCKET)

  if not db then
    Log("kcRP: no [gamemode.database] in server.toml - accounts are off until the owner connects one")
    return
  end

  -- Les clients masquent le mot de passe pendant la saisie et gardent la ligne hors de l'historique.
  SetSecretCommand("register")
  SetSecretCommand("login")

  local _, _, err = db:ExecuteSync("CREATE TABLE IF NOT EXISTS players (" .. autoId() .. [[,
      name VARCHAR(24) NOT NULL UNIQUE,
      password VARCHAR(200) NOT NULL,
      visits INTEGER NOT NULL DEFAULT 0,
      x DOUBLE PRECISION, y DOUBLE PRECISION, z DOUBLE PRECISION, yaw DOUBLE PRECISION,
      money DOUBLE PRECISION,
      level VARCHAR(32),
      look TEXT,
      nourishment DOUBLE PRECISION,
      energy DOUBLE PRECISION,
      last_seen VARCHAR(32))]])

  if err then
    Log("kcRP: the players table could not be made: " .. err)
    db = nil
    return
  end

  local have = addColumns("players", ADDED_COLUMNS)

  if next(have) and not have.id then
    if not keyPlayersById(have) then
      db = nil
      return
    end

    Log("kcRP: the players table is keyed by id now (the names stay unique)")
  end

  -- MySQL / MariaDB indexent dans CREATE TABLE ; les autres moteurs après.
  -- Les clés étrangères sont en fin de table : MySQL ignore celle écrite sur la colonne.
  local inline = db.driver == "mysql"

  local ok = execInit("CREATE TABLE IF NOT EXISTS player_items (player_id INT NOT NULL, " .. STACK_COLUMNS ..
      ", PRIMARY KEY (player_id, slot)" .. (inline and ", KEY player_items_item (item)" or "") ..
      ", FOREIGN KEY (player_id) REFERENCES players(id) ON DELETE CASCADE)", "the player_items table")
    and execInit("CREATE TABLE IF NOT EXISTS player_horses (" .. autoId() .. ", player_id INT NOT NULL, soul VARCHAR(64), " ..
      "active SMALLINT NOT NULL DEFAULT 0, created_at VARCHAR(32), coat VARCHAR(16), " ..
      "FOREIGN KEY (player_id) REFERENCES players(id) ON DELETE CASCADE)", "the player_horses table")
    and execInit("CREATE TABLE IF NOT EXISTS horse_items (horse_id INT NOT NULL, " .. STACK_COLUMNS ..
      ", PRIMARY KEY (horse_id, slot)" .. (inline and ", KEY horse_items_item (item)" or "") ..
      ", FOREIGN KEY (horse_id) REFERENCES player_horses(id) ON DELETE CASCADE)", "the horse_items table")
    and execInit("CREATE TABLE IF NOT EXISTS player_progress (player_id INT NOT NULL, kind VARCHAR(8) NOT NULL, name VARCHAR(32) NOT NULL, " ..
      "level SMALLINT NOT NULL, xp DOUBLE PRECISION NOT NULL, points SMALLINT NOT NULL DEFAULT 0, PRIMARY KEY (player_id, kind, name)" ..
      (inline and ", KEY player_progress_name (name)" or "") ..
      ", FOREIGN KEY (player_id) REFERENCES players(id) ON DELETE CASCADE)", "the player_progress table")
    and execInit("CREATE TABLE IF NOT EXISTS player_perks (player_id INT NOT NULL, perk VARCHAR(36) NOT NULL, PRIMARY KEY (player_id, perk)" ..
      (inline and ", KEY player_perks_perk (perk)" or "") ..
      ", FOREIGN KEY (player_id) REFERENCES players(id) ON DELETE CASCADE)", "the player_perks table")
    and execInit("CREATE TABLE IF NOT EXISTS horse_stats (horse_id INT NOT NULL, stat VARCHAR(16) NOT NULL, level SMALLINT NOT NULL, " ..
      "PRIMARY KEY (horse_id, stat), FOREIGN KEY (horse_id) REFERENCES player_horses(id) ON DELETE CASCADE)", "the horse_stats table")

  if ok and not inline then
    execInit("CREATE INDEX IF NOT EXISTS player_items_item ON player_items (item)", "the player_items index")
    execInit("CREATE INDEX IF NOT EXISTS player_horses_player ON player_horses (player_id)", "the player_horses index")
    execInit("CREATE INDEX IF NOT EXISTS horse_items_item ON horse_items (item)", "the horse_items index")
    execInit("CREATE INDEX IF NOT EXISTS player_progress_name ON player_progress (name)", "the player_progress index")
    execInit("CREATE INDEX IF NOT EXISTS player_perks_perk ON player_perks (perk)", "the player_perks index")
  end

  if not ok then
    db = nil
    return
  end

  addColumns("player_horses", HORSE_COLUMNS) -- table créée avant la robe
  moveOldSaves(have)
  setupDiscovery()                           -- table de découverte, seulement si une règle DISCOVERY est active

  -- La table "players" existe déjà (création synchrone ci-dessus) : les
  -- modules peuvent démarrer tout de suite, sans minuteur arbitraire.
  -- pcall : une erreur d'un module n'empêche pas le reste du démarrage.
  if kcRP.Jobs then
    local okJobs, errJobs = pcall(kcRP.Jobs.InitDatabase)

    if not okJobs then
      Log("kcRP: jobs database init failed: " .. tostring(errJobs))
    end
  else
    Log("kcRP: jobs module missing at database initialization")
  end

  if kcRP.Bank then
    local okBank, errBank = pcall(kcRP.Bank.InitDatabase)

    if not okBank then
      Log("kcRP: bank database init failed: " .. tostring(errBank))
    end
  else
    Log("kcRP: bank module missing at database initialization")
  end

  Log("kcRP: accounts on (" .. db.driver .. ")")

  -- Chaque minute : un serveur qui s'arrête garde la position de chacun.
  SetTimer(savePlaces, 60000, true)
end

-- ---------------------------------------------------------------------
-- Le marchand du spawn
-- Un vendeur (CreateVendor : PNJ invulnérable avec une boutique) ; la touche
-- d'utilisation ouvre l'écran d'échange du jeu. La boutique vend quelques
-- objets utiles, rachète tout (sauf les papiers) à moitié prix et dispose
-- de 500 Groschen.
-- ---------------------------------------------------------------------
local merchant, store

-- Emplacement par niveau (z négatif = au sol, trouvé par le serveur).
local MERCHANT_SPOT = { klaster = { 1278.1, 1088.8, 26.0 }, kutnohorsko = { 749.0, 3349.0, -1 } }

-- Crée la boutique et le marchand. Les anciens acteurs nommés situés à moins
-- de 3 m de l'emplacement sont détruits d'abord : un /reload relance Lua sans
-- supprimer les acteurs, ce qui les empilait.
function makeMerchant()
  store = CreateShop("General store", 0.5, 500)

  if not store then
    Log("kcRP: no shop could be made")
    return
  end

  SetShopItem(store, "torch_weapon", 5)                 -- illimité
  SetShopItem(store, "arrow_normal", 0.5, 200)
  SetShopItem(store, "bandage_classic", 12, 20)
  SetShopItem(store, "shortswordBroad", 90, 3)
  SetShopItem(store, "GambesonLong01_m01_C3", 60, 2)
  SetShopBuyCategories(store, { "-Document" })          -- jamais de papiers

  local spot = MERCHANT_SPOT[GetLevel()] or { spawnX + 4, spawnY + 4, -1 }
  local mx, my, mz = spot[1], spot[2], spot[3]

  -- Le marchand regarde le point d'apparition.
  local yaw = math.deg(math.atan(-(spawnX - mx), spawnY - my)) % 360

  for _, id in ipairs(GetEntities() or {}) do
    local ex, ey = GetEntityPos(id)

    if ex and (GetEntityName(id) or "") ~= ""
      and math.sqrt((ex - mx) ^ 2 + (ey - my) ^ 2) <= 3.0 then
      DestroyEntity(id)
    end
  end

  merchant = CreateVendor(store, nil, mx, my, mz, yaw, "Merchant")

  if not merchant then
    Log("kcRP: no merchant could be made")
    return
  end

  SetEntityData(merchant, "role", "merchant")
  Log(fmt("kcRP: the merchant stands at %.1f %.1f %.1f with shop %d", mx, my, mz, store))
end

makeMerchant()

-- Interaction avec un acteur : le marchand salue. Retourner true laisse la
-- boutique s'ouvrir (les modules suivants se chaînent sur cette fonction).
function OnPlayerInteractActor(pid, id)
  if GetEntityData(id, "role") == "merchant" then
    SendClientMessage(pid, COLOR_PURPLE, fmt("* %s greets %s.", GetEntityName(id), GetPlayerName(pid)))
  end

  return true
end

-- Achat : journalisé, toujours accepté.
function OnPlayerBuy(pid, shop, class, amount, price)
  local info = GetItemInfo(class)
  Log(fmt("kcRP: %s buys %d x %s at %.1f", GetPlayerName(pid), amount, info and info.display or class, price))
  return true
end

-- Transaction complète : journalisée seulement si le joueur achète et vend.
function OnPlayerShopDeal(pid, shop, deal)
  if deal.cost > 0 and deal.proceeds > 0 then
    Log(fmt("kcRP: %s trades - pays %.1f, gets %.1f", GetPlayerName(pid), deal.cost, deal.proceeds))
  end

  return true
end

-- Fermeture de la boutique : le marchand salue un joueur qui s'éloigne.
function OnPlayerCloseShop(pid, shop, reason)
  if reason == "you walked away" then
    say(pid, "The merchant waves you goodbye.")
  end
end

-- =====================================================================
-- Noyau kcRP v0.1.1
-- Registre des joueurs : une couche AU-DESSUS de la table "players" de
-- BasicRP (qui continue son travail). Tout vit dans la table globale
-- "kcRP" et dans ce bloc do...end : le script ne gagne aucune variable
-- locale de premier niveau (Lua en autorise 200 par chunk et BasicRP
-- en utilise beaucoup).
-- Le bloc reste OUVERT : il est refermé plus loin dans le fichier.
-- =====================================================================
do
kcRP = {
  Version = "0.1.1",
  Players = {},
  Functions = {},
  Events = {},
  Config = {
    -- Niveau numérique de chaque rôle.
    Permissions = {
      user = 0,
      moderator = 50,
      admin = 75,
      owner = 100
    },

    -- Rôles qui reçoivent aussi l'admin natif KCD:MP (/give, /tp, /kick, /time...).
    NativeAdminRoles = {
      admin = true,
      owner = true
    }
  }
}

-- Abonnés aux événements internes : nom -> liste de fonctions.
local handlers = {}

-- ---------------------------------------------------------------------
-- Événements internes
-- ---------------------------------------------------------------------

-- Abonne une fonction à un événement. Retourne la fonction (pour Off).
function kcRP.Events.On(name, fn)
  handlers[name] = handlers[name] or {}
  table.insert(handlers[name], fn)
  return fn
end

-- Désabonne une fonction. Retourne true si elle était abonnée.
function kcRP.Events.Off(name, fn)
  local list = handlers[name]

  if not list then
    return false
  end

  for i, f in ipairs(list) do
    if f == fn then
      table.remove(list, i)
      return true
    end
  end

  return false
end

-- Déclenche un événement. Chaque abonné est protégé par pcall : l'erreur de
-- l'un n'empêche pas les autres.
function kcRP.Events.Emit(name, ...)
  for _, fn in ipairs(handlers[name] or {}) do
    local ok, err = pcall(fn, ...)

    if not ok then
      Log("kcRP: handler of '" .. name .. "' failed: " .. tostring(err))
    end
  end
end

-- ---------------------------------------------------------------------
-- L'objet joueur
-- ---------------------------------------------------------------------

-- Construit l'objet joueur kcRP (PlayerData + Functions) pour un pid.
local function build(pid)
  local p = { source = pid, Functions = {} }

  p.PlayerData = {
    source = pid,
    name = GetPlayerName(pid) or "",
    characterId = nil,        -- players.id de BasicRP une fois connecté
    loggedIn = false,
    permission = "user",      -- renseigné par l'étape des permissions
    money = { cash = 0, bank = 0 },
    job = {
      name = "unemployed",
      label = "Sans emploi",
      grade = {
        level = 0,
        name = "citizen",
        label = "Habitant",   -- aligné sur shared/jobs.lua
        payment = 0,          -- nombre (l'ancien code mettait la chaîne "0")
        isBoss = false
      },
      onduty = true
    },
    metadata = {},
    connectedAt = GetServerTime()
  }

  local f = p.Functions

  -- Relit les valeurs vivantes de BasicRP / KCD:MP : le jeu reste la source de vérité.
  function f.Refresh()
    local d, s = p.PlayerData, players[pid]
    d.loggedIn = (s and s.logged) and true or false
    d.characterId = s and s.id or nil
    d.money.cash = GetPlayerMoney(pid) or d.money.cash
    return d
  end

  -- Nom du joueur.
  function f.GetName()
    return p.PlayerData.name
  end

  -- Espèces actuelles (bourse native).
  function f.GetCash()
    return GetPlayerMoney(pid) or 0
  end

  -- Le joueur est-il connecté à un compte ?
  function f.IsLoggedIn()
    return f.Refresh().loggedIn
  end

  -- Le joueur est-il dans le monde (apparu) ?
  function f.IsInWorld()
    return IsPlayerInWorld(pid)
  end

  -- Lecture / écriture d'une métadonnée libre.
  function f.GetMetadata(key)
    return p.PlayerData.metadata[key]
  end

  function f.SetMetadata(key, value)
    p.PlayerData.metadata[key] = value
  end

  return p
end

-- ---------------------------------------------------------------------
-- Le registre
-- ---------------------------------------------------------------------

-- Enregistre un joueur qui se connecte et lui attribue sa permission.
function kcRP.Functions.AddPlayer(pid)
  local old = kcRP.Players[pid]

  if old then
    kcRP.Events.Emit("player:disconnected", old, "replaced") -- pid réutilisé
  end

  local p = build(pid)
  kcRP.Players[pid] = p

  local playerName = (p.PlayerData.name or ""):lower()

  if KCRP_OWNERS and KCRP_OWNERS[playerName] then
    -- Propriétaire configuré : reçoit aussi l'admin natif.
    kcRP.Functions.SetPermission(pid, "owner", "configured owner")
  elseif admins and admins[playerName] then
    -- Compatibilité : KCDMP_ADMINS devient le rôle kcRP "admin".
    kcRP.Functions.SetPermission(pid, "admin", "KCDMP_ADMINS")
  else
    -- Tous les autres restent "user", sans commande admin native.
    kcRP.Functions.ApplyNativeAdmin(pid)
  end

  Log(string.format(
    "kcRP: player %d (%s) registered as %s, %d in the registry",
    pid, p.PlayerData.name, p.PlayerData.permission, kcRP.Functions.GetPlayerCount()
  ))

  kcRP.Events.Emit("player:connected", p)

  return p
end

-- Retire un joueur du registre (déconnexion).
function kcRP.Functions.RemovePlayer(pid, reason)
  local p = kcRP.Players[pid]

  if not p then
    return
  end

  kcRP.Events.Emit("player:disconnected", p, reason)
  kcRP.Players[pid] = nil

  Log(string.format("kcRP: player %d (%s) removed (%s)", pid, p.PlayerData.name, tostring(reason)))
end

-- Objet joueur, ou nil si le pid n'est pas connecté (un pid est réutilisé).
function kcRP.Functions.GetPlayer(pid)
  if pid == nil or not IsPlayerConnected(pid) then
    return nil
  end

  return kcRP.Players[pid]
end

-- Objet joueur à partir d'un nom ou d'un fragment de nom.
function kcRP.Functions.GetPlayerByName(text)
  local pid = GetPlayerId(text)
  return pid and kcRP.Functions.GetPlayer(pid) or nil
end

-- Liste des joueurs connectés, triée par pid.
function kcRP.Functions.GetPlayers()
  local list = {}

  for pid, p in pairs(kcRP.Players) do
    if IsPlayerConnected(pid) then
      list[#list + 1] = p
    end
  end

  table.sort(list, function(a, b)
    return a.source < b.source
  end)

  return list
end

-- Nombre de joueurs dans le registre.
function kcRP.Functions.GetPlayerCount()
  local n = 0

  for _ in pairs(kcRP.Players) do
    n = n + 1
  end

  return n
end

-- ---------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------

-- Ramène un rôle inconnu à "user".
function kcRP.Functions.NormalizePermission(role)
  role = tostring(role or "user"):lower()

  if kcRP.Config.Permissions[role] == nil then
    return "user"
  end

  return role
end

-- Niveau numérique d'un rôle.
function kcRP.Functions.GetPermissionLevel(role)
  role = kcRP.Functions.NormalizePermission(role)
  return kcRP.Config.Permissions[role] or 0
end

-- Rôle d'un joueur ("user" s'il est absent).
function kcRP.Functions.GetPermission(pid)
  local player = kcRP.Functions.GetPlayer(pid)

  if not player then
    return "user"
  end

  return kcRP.Functions.NormalizePermission(player.PlayerData.permission)
end

-- Le joueur a-t-il au moins le rôle demandé ?
function kcRP.Functions.HasPermission(pid, requiredRole)
  local player = kcRP.Functions.GetPlayer(pid)

  if not player then
    return false
  end

  local currentLevel = kcRP.Functions.GetPermissionLevel(player.PlayerData.permission)
  local requiredLevel = kcRP.Functions.GetPermissionLevel(requiredRole)

  return currentLevel >= requiredLevel
end

-- Aligne l'admin natif KCD:MP sur le rôle kcRP. Retourne true s'il est admin.
function kcRP.Functions.ApplyNativeAdmin(pid)
  local player = kcRP.Functions.GetPlayer(pid)

  if not player or not IsPlayerConnected(pid) then
    return false
  end

  local role = kcRP.Functions.NormalizePermission(player.PlayerData.permission)
  local shouldBeAdmin = kcRP.Config.NativeAdminRoles[role] == true

  SetPlayerAdmin(pid, shouldBeAdmin)

  return shouldBeAdmin
end

-- Change le rôle kcRP d'un joueur et aligne son admin natif.
-- Retourne (true, estAdminNatif) ou (false, message).
function kcRP.Functions.SetPermission(pid, role, reason)
  local player = kcRP.Functions.GetPlayer(pid)

  if not player then
    return false, "Player not found."
  end

  role = kcRP.Functions.NormalizePermission(role)

  local oldRole = player.PlayerData.permission
  player.PlayerData.permission = role

  local nativeAdmin = kcRP.Functions.ApplyNativeAdmin(pid)

  Log(string.format(
    "kcRP: permission of %s#%d changed %s -> %s (%s)",
    player.PlayerData.name, pid, oldRole, role, tostring(reason or "no reason")
  ))

  kcRP.Events.Emit("player:permissionChanged", player, oldRole, role, reason)

  return true, nativeAdmin
end

-- Le joueur est-il admin natif KCD:MP ?
function kcRP.Functions.IsNativeAdmin(pid)
  return IsPlayerAdmin(pid)
end

-- ---------------------------------------------------------------------
-- /kcrp : commande de test du noyau
--   /kcrp perm     : ma permission
--   /kcrp players  : joueurs du registre
--   /kcrp          : informations sur moi
-- Retourne toujours true (la commande est traitée).
-- ---------------------------------------------------------------------
function kcRP.Functions.Command(pid, args)
  local sub = ((args or ""):match("^(%S*)") or ""):lower()

  -- Envoie une ligne à l'appelant.
  local function reply(color, text)
    SendClientMessage(pid, color, text)
  end

  if sub == "perm" then
    local player = kcRP.Functions.GetPlayer(pid)

    if not player then
      reply(COLOR_RED, "kcRP: player registry unavailable.")
      return true
    end

    local role = player.PlayerData.permission
    local level = kcRP.Functions.GetPermissionLevel(role)

    reply(COLOR_GOLD, string.format(
      "kcRP permission: %s (level %d), native admin: %s", role, level, tostring(IsPlayerAdmin(pid))
    ))

    return true
  end

  if sub == "players" then
    reply(COLOR_SERVER, string.format("kcRP: %d player(s) in the registry", kcRP.Functions.GetPlayerCount()))

    for _, player in ipairs(kcRP.Functions.GetPlayers()) do
      local data = player.Functions.Refresh()

      reply(COLOR_WHITE, string.format(
        " [%d] %s - role: %s, logged: %s, cash: %s",
        data.source, data.name, data.permission, tostring(data.loggedIn), tostring(data.money.cash)
      ))
    end

    return true
  end

  -- /kcrp seul (ou sous-commande inconnue) : informations sur le joueur.
  local player = kcRP.Functions.GetPlayer(pid)

  if not player then
    reply(COLOR_RED, "kcRP: you are not in the registry.")
    return true
  end

  local data = player.Functions.Refresh()

  reply(COLOR_GOLD, "---- kcRP core v" .. kcRP.Version .. " ----")
  reply(COLOR_WHITE, string.format(" pid %d, name %s, logged in: %s", data.source, data.name, tostring(data.loggedIn)))
  reply(COLOR_WHITE, string.format(
    " character id: %s, cash: %s, bank: %s",
    tostring(data.characterId), tostring(data.money.cash), tostring(data.money.bank)
  ))
  reply(COLOR_WHITE, string.format(" job: %s, permission: %s", data.job.label, data.permission))
  reply(COLOR_OOC, " /kcrp perm - show your kcRP permission")
  reply(COLOR_OOC, " /kcrp players - list players in the kcRP registry")

  return true
end

-- ====================================================================== fin du noyau kcRP
end

-- ---------------------------------------------------------------------
-- Modules kcRP. Ordre obligatoire : définitions partagées, métiers,
-- banque, compagnies, puis la forge (qui dépend des compagnies).
-- Les fichiers du dossier client/ ne se chargent PAS ici : le serveur
-- les envoie lui-même aux joueurs.
-- ---------------------------------------------------------------------
dofile("gamemodes/kcRP/server/notifications.lua")
dofile("gamemodes/kcRP/shared/jobs.lua")
dofile("gamemodes/kcRP/server/jobs.lua")
dofile("gamemodes/kcRP/server/bank.lua")
dofile("gamemodes/kcRP/server/companies.lua")
dofile("gamemodes/kcRP/server/blacksmith.lua")
dofile("gamemodes/kcRP/server/forge_shop.lua")
-- ---------------------------------------------------------------------
-- Les joueurs
-- ---------------------------------------------------------------------

-- Connexion : enregistre le joueur dans kcRP, règle sa caméra, l'accueille,
-- puis vérifie en base si son nom a un compte (le formulaire de mot de passe
-- s'ouvre ensuite).
function OnPlayerConnect(pid)
  -- Le registre kcRP ne doit jamais bloquer BasicRP : l'erreur est seulement journalisée.
  local registered, registerErr = pcall(kcRP.Functions.AddPlayer, pid)

  if not registered then
    Log("kcRP: AddPlayer failed for pid " .. tostring(pid) .. ": " .. tostring(registerErr))
  end

  local name = GetPlayerName(pid) or ""

  SetPlayerThirdPerson(pid, CAMERA.third_person, CAMERA.in_fights, CAMERA.when_aiming, CAMERA.crosshair)
  say(pid, fmt("Welcome to kcRP on %s, %s. %d player(s) online.", GetLevelName(), name, GetPlayerCount()))
  SendClientMessageToAll(COLOR_SERVER, name .. " joined")

  -- Sans base de données : pas de comptes, le nom suffit.
  if not db then
    say(pid, "This server has no database: accounts are off.")
    players[pid] = { name = name:lower(), registered = false, logged = false }
    promote(pid)
    return
  end

  players[pid] = { name = name:lower(), registered = false, logged = false, tries = 0 }

  if EVERYONE_ADMIN then
    promote(pid) -- dès la porte, connecté ou non
  end

  db:Query("SELECT visits FROM players WHERE name = @n", { n = name:lower() }, function(rows, err)
    if err then
      Log("kcRP: " .. err)
      return
    end

    local p = players[pid]

    if not p or not IsPlayerConnected(pid) then
      return
    end

    p.registered = #rows > 0
    p.known = true -- le formulaire s'ouvre quand la moitié client est prête (OnClientEvent "auth_ready")

    say(pid, p.registered and "This name has an account: log in with its password."
      or "This name has no account yet: choose a password to make it yours.")

    askPassword(pid)
  end)
end

-- Demande d'apparition : le joueur apparaît à sa place du point de spawn.
function OnPlayerRequestSpawn(pid)
  SetSpawnInfo(pid, spawnSpot(pid))
  return true
end

-- Apparition : droits de pull-down et de pickpocket, puis kit de départ
-- (une fois par session) : bourse et torche. La bourse sauvegardée d'un
-- joueur connecté remplace l'argent de départ. À 1,5 s, l'argent et le métier
-- sont publiés dans les state bags pour le HUD.
function OnPlayerSpawn(pid)
  local p = players[pid]

  if not p then
    p = { name = (GetPlayerName(pid) or ""):lower(), registered = false, logged = false }
    players[pid] = p
  end

  SetPlayerPullDown(pid, PULLDOWN.enabled) -- droit de faire tomber un cavalier (désactivé par défaut)
  pocketRights(pid)                        -- poches volables : celles de tous, sauf celles d'un admin si la table l'interdit

  if p.outfitted then
    return
  end

  p.outfitted = true

  for _, item in ipairs(START_ITEMS) do
    GivePlayerItem(pid, item)
  end

  if p.savedMoney then
    GivePlayerMoney(pid, p.savedMoney - GetPlayerMoney(pid)) -- connecté avant l'apparition : la bourse sauvegardée
  else
    GivePlayerMoney(pid, START_MONEY)
  end

  if p.savedItems then
    -- Connecté avant l'apparition : les sacs sont restaurés une fois que le
    -- client a rapporté ce que l'équipement et le kit ont donné.
    local items = p.savedItems

    SetTimer(function()
      if IsPlayerInWorld(pid) and players[pid] == p then
        restoreInventory(pid, items)
      end
    end, 4000)
  end

  SetTimer(function()
    if not IsPlayerConnected(pid) then
      return
    end

    if kcRP.Functions and kcRP.Functions.SyncMoneyState then
      kcRP.Functions.SyncMoneyState(pid)
    end

    if kcRP.Functions and kcRP.Functions.SyncJobState then
      kcRP.Functions.SyncJobState(pid)
    end
  end, 1500)
end

-- Déconnexion : sauvegardes (métier, banque, découvertes, position), retrait
-- du registre, nettoyage des charrettes et des chevaux, puis des minuteurs
-- de pull-down du pid (qui sera réutilisé).
function OnPlayerDisconnect(pid, reason)
  if kcRP.Jobs then
    kcRP.Jobs.OnPlayerDisconnect(pid)
  end

  if kcRP.Bank then
    kcRP.Bank.OnPlayerDisconnect(pid)
  end

  pcall(kcRP.Functions.RemovePlayer, pid, reason) -- registre kcRP

  SendClientMessageToAll(COLOR_SERVER, fmt("%s left (%s)", GetPlayerName(pid), reason))

  markDiscovery(pid) -- ce qu'ils ont trouvé dans leurs derniers instants est sauvegardé avec le reste
  savePlace(pid)
  dropCarts(pid)     -- leur charrette (et celle en cours de fabrication) part avec eux

  -- Leur cheval part avec eux (sauvegardé plus haut pour un compte ; /horse le
  -- ramène) : laissé derrière, il n'appartiendrait à personne, ses sacoches à tous.
  for _, ownedHorse in ipairs(GetPlayerHorses(pid)) do
    DestroyEntity(ownedHorse)
  end

  players[pid] = nil
  pullReady[pid], pullSafe[pid] = nil, nil
end

-- ---------------------------------------------------------------------
-- Le chat de jeu de rôle
-- ---------------------------------------------------------------------

-- Une ligne simple est PARLÉE : ceux à moins de 20 m lisent "Nom says: ...".
-- La ligne passe aussi au-dessus de la tête (bulle de chat).
-- Retourner false retire la diffusion native du serveur.
function OnPlayerText(pid, text)
  sayNearby(pid, CHAT_RANGE, COLOR_WHITE, fmt("%s says: %s", GetPlayerName(pid), text))
  SetPlayerChatBubble(pid, text, COLOR_WHITE, CHAT_RANGE)
  return false
end

-- Affiche l'usage d'une commande à son appelant. Retourne true (commande traitée).
local function usage(pid, line)
  SendClientMessage(pid, COLOR_RED, "Usage: " .. line)
  return true
end

-- Un joueur assommé ou porté ne fait que parler : aucune commande qui le
-- libérerait (/putdown, /unstuck), le déplacerait (/horse, /look, /createcart)
-- ou mettrait quelque chose sous lui.
--   DOWN_OK      : commandes qui restent permises
--   DOWN_BLOCKED : commandes du mode qui libèrent ou déplacent, interdites à tous
-- Un admin garde ses outils (ceux du serveur et ceux du mode), sauf ceux de DOWN_BLOCKED.
local DOWN_OK = {
  register = true, login = true, me = true, ["do"] = true, ame = true, s = true, shout = true,
  b = true, ooc = true, p = true, help = true, skills = true
}

local DOWN_BLOCKED = {
  horse = true, unstuck = true, seat = true, createcart = true, despawncart = true,
  look = true, dice = true, carry = true, putdown = true
}


-- =====================================================================
-- Gestion des messages web (forge-register + bank)
-- =====================================================================

function OnWebMessage(frame, data)
  -- Gérer forge-register
  if frame == "forge-register" then
    Log("Forge-register message received:", data)
    
    if type(data) == "table" and data.action == "close" then
      -- Trouver le joueur (via une table)
      if kcRP.forgeFrames then
        for pid, _ in pairs(kcRP.forgeFrames) do
          if IsPlayerConnected(pid) then
            SetPlayerWebFocus(pid, frame, false)
            HidePlayerWebFrame(pid, frame)
            kcRP.forgeFrames[pid] = nil
            Log("Forge frame closed for player", pid)
            break
          end
        end
      end
    end
    return
  end
  
  -- Gérer bank
  if frame == "bank" then
    Log("Bank message received:", data)
    
    if type(data) == "table" and data.action == "close" then
      -- Trouver le joueur (via une table)
      if kcRP.bankFrames then
        for pid, _ in pairs(kcRP.bankFrames) do
          if IsPlayerConnected(pid) then
            SetPlayerWebFocus(pid, frame, false)
            HidePlayerWebFrame(pid, frame)
            kcRP.bankFrames[pid] = nil
            Log("Bank frame closed for player", pid)
            break
          end
        end
      end
    end
    return
  end
end

-- =====================================================================
-- Tables pour suivre les frames ouvertes
-- =====================================================================

kcRP.bankFrames = kcRP.bankFrames or {}
kcRP.forgeFrames = kcRP.forgeFrames or {}

-- =====================================================================
-- Les commandes
-- =====================================================================

function OnPlayerCommandText(pid, cmd, args)
  cmd = cmd:lower()
  args = args or ""

  -- /job : affiche le HUD du métier.
  if cmd == "job" then
    SendClientEvent(pid, "kcrp_hud_show_job", "8000")
    return true
  end

  if cmd == "kcrp" then
    return kcRP.Functions.Command(pid, args)
  end

  if cmd == "forgeregister" then
    -- Vérifier si déjà ouvert
    if kcRP.forgeFrames and kcRP.forgeFrames[pid] then
      SendClientMessage(pid, COLOR_RED, "Le registre est déjà ouvert.")
      return true
    end
    
    local opened = ShowPlayerWebFrame(pid, "forge-register")

    if not opened then 
      SendClientMessage(
        pid,
        COLOR_RED,
        "Impossible d'ouvrir le Registre de la forge."
      )
      return true
    end

    SetPlayerCursor(pid, true)
    
    -- Stocker le pid
    kcRP.forgeFrames = kcRP.forgeFrames or {}
    kcRP.forgeFrames[pid] = true

    return true
  end

  if cmd == "bank" then
    -- Vérifier si la frame est déjà ouverte
    if kcRP.bankFrames and kcRP.bankFrames[pid] then
      kcRP.Functions.Notify(pid, "La banque est déjà ouverte.", "warning", 3000)
      return true
    end
    
    local opened = ShowPlayerWebFrame(pid, "bank")

    if not opened then
      kcRP.Functions.Notify(pid, "Impossible d'ouvrir l'interface de la banque.", "error", 4000)
      return true
    end

    SetPlayerCursor(pid, true)

    -- Stocker le pid dans la table bankFrames
    kcRP.bankFrames = kcRP.bankFrames or {}
    kcRP.bankFrames[pid] = true

    kcRP.Functions.Notify(pid, "Vérifions le contenu de votre coffre.", "info", 2000)

    return true
  end

  -- ... (le reste de tes commandes)

  return party(pid, cmd, args)
end

-- =====================================================================
-- Nettoyage à la déconnexion
-- =====================================================================

function OnPlayerDisconnect(pid)
  -- Nettoyer la table bankFrames
  if kcRP.bankFrames then
    kcRP.bankFrames[pid] = nil
  end
  
  -- Nettoyer la table forgeFrames
  if kcRP.forgeFrames then
    kcRP.forgeFrames[pid] = nil
  end
end
-- ---------------------------------------------------------------------
-- Pull-down : faire tomber un cavalier
-- Le mouvement natif de prise : un joueur à pied, arme tirée (ou mains nues),
-- près du cheval d'un cavalier voit le prompt "Pull down" ; les deux jeux
-- jouent la scène. Pas de commande. DÉSACTIVÉ tant que enabled = false.
-- Le serveur contrôle la portée, l'allure du cheval, le pvp, les équipes et
-- les groupes ; les règles ci-dessous sont celles du mode.
-- ---------------------------------------------------------------------
PULLDOWN = {
  enabled = true,     -- true : les joueurs peuvent faire tomber un cavalier ; false : personne
  chance = 0.7,           -- 0..1 : chance de réussite (sinon la scène d'échec est jouée)
  cooldown = 20,          -- secondes entre deux tentatives d'un joueur
  protect_seconds = 30,   -- secondes pendant lesquelles un cavalier tombé ne peut plus l'être
  damage = 0              -- santé retirée par la chute (0 = aucune ; jamais sous 1)
}

-- Demande d'un joueur à pied (le serveur a vérifié portée, allure et pvp) :
-- applique le délai, la protection et la chance.
-- Retourne false (refus) ou la chance de réussite.
function OnPlayerPullDown(pid, victim, id)
  if not PULLDOWN.enabled then
    return false
  end

  local now = GetServerTime()

  if (pullReady[pid] or 0) > now then
    say(pid, fmt("You cannot pull anyone down for another %d seconds.", math.ceil((pullReady[pid] - now) / 1000)))
    return false
  end

  if (pullSafe[victim] or 0) > now then
    say(pid, fmt("%s was pulled off a horse a moment ago and cannot be again yet.", GetPlayerName(victim)))
    return false
  end

  pullReady[pid] = now + PULLDOWN.cooldown * 1000
  return PULLDOWN.chance
end

-- Fin d'un pull-down : cavalier tombé (protégé un moment, blessé si les
-- règles le disent) ou tentative ratée.
function OnPlayerPulledDown(pid, victim, id, success)
  if not success then
    say(pid, fmt("%s stayed in the saddle.", GetPlayerName(victim)))
    return
  end

  pullSafe[victim] = GetServerTime() + PULLDOWN.protect_seconds * 1000

  if PULLDOWN.damage > 0 then
    local health = GetPlayerHealth(victim)

    if health then
      SetPlayerHealth(victim, math.max(1, health - PULLDOWN.damage))
    end
  end

  say(victim, fmt("%s pulled you off your horse!", GetPlayerName(pid)))
end

-- ---------------------------------------------------------------------
-- Portage
-- La prise native, le portage sur l'épaule et la dépose, vus par tous : le
-- prompt de prise sur un corps allongé (mort, joueur ou PNJ assommé), ou
-- /carry <nom> sur un joueur assommé ; /putdown dépose. DÉSACTIVÉ tant que
-- enabled = false. Le serveur contrôle la portée et que personne d'autre ne
-- porte le corps. /ko assomme un joueur, /wake le réveille, /carrying
-- on|off règle la prise, et le /carry d'un admin prend n'importe qui.
-- ---------------------------------------------------------------------
CARRY = {
  enabled = false,   -- true : prompt de prise actif et /carry pour tous ; false : seul un admin porte
  range = 3,         -- mètres entre le joueur et le corps quand il le saisit
  speed = 2.4,       -- mètres par seconde du porteur (4 au maximum)
  corpses = true,    -- les corps des morts (PNJ ou joueur, selon [combat] corpse_seconds)
  players = true,    -- ... un joueur assommé
  actors = true,     -- ... un PNJ assommé
  ko_seconds = 120   -- durée du /ko d'un admin sans durée précisée (0 = jusqu'à /wake)
}

-- Commandes de portage :
--   /carry <nom>, /putdown                       (joueurs, selon CARRY)
--   /carrying on|off, /ko [nom] [sec], /wake [nom]  (admins)
function carryCommand(pid, cmd, args)
  local admin = IsPlayerAdmin(pid)

  if cmd == "carry" then
    if not CARRY.enabled and not admin then
      say(pid, "Carrying is not allowed here.")
      return true
    end

    local target = sscanf(args, "u")

    if target == false then
      return usage(pid, "/carry <name>")
    end

    if not admin then
      -- Les règles de portée et de type s'appliquent à la commande comme au
      -- prompt. Une seule réponse pour "pas au sol" et "pas à portée", afin
      -- que la commande ne révèle ni la position d'un joueur ni s'il est assommé hors de vue.
      local x, y, z = GetPlayerPos(pid)
      local tx, ty, tz = GetPlayerPos(target)
      local near = x and tx and (x - tx) ^ 2 + (y - ty) ^ 2 + (z - tz) ^ 2 <= (CARRY.range + 1) ^ 2

      if not (CARRY.players and near and IsPlayerKnockedOut(target)) then
        say(pid, fmt("%s cannot be carried.", GetPlayerName(target)))
        return true
      end
    end

    local ok, why = CarryPlayer(pid, target, CARRY.speed)

    if not ok then
      say(pid, admin and why or fmt("You cannot carry %s now.", GetPlayerName(target)))
    end

    return true
  end

  if cmd == "putdown" then
    if not CARRY.enabled and not admin then
      say(pid, "Carrying is not allowed here.")
      return true
    end

    -- StopCarry prend l'un ou l'autre des deux joueurs : seul le porteur dépose,
    -- le joueur porté ne met pas fin à son propre portage.
    if not IsPlayerCarrying(pid) or not StopCarry(pid) then
      say(pid, "You carry nobody.")
    end

    return true
  end

  if not admin then
    say(pid, "/" .. cmd .. " is for admins")
    return true
  end

  if cmd == "carrying" then
    local word = args:match("^%s*(%a+)%s*$")

    if word == "on" or word == "off" then
      CARRY.enabled = word == "on"
      SetCarrying(CARRY.enabled, CARRY)
    end

    say(pid, fmt("carrying is %s - /carrying on|off", CARRY.enabled and "on" or "off"))
    return true
  end

  if cmd == "ko" then
    local first, second = args:match("^%s*(%S*)%s*(%S*)")
    local target, seconds = pid, tonumber(second) or CARRY.ko_seconds

    if first ~= "" then
      local who = GetPlayerId(first)

      if who then
        target = who
      elseif tonumber(first) and second == "" then
        seconds = tonumber(first)
      else
        return usage(pid, "/ko [name] [seconds]")
      end
    end

    local ok, why = SetPlayerKnockedOut(target, true, seconds)

    say(pid, ok
      and fmt("%s is knocked out%s.", GetPlayerName(target), seconds > 0 and fmt(" for %g seconds", seconds) or "")
      or fmt("%s: %s", GetPlayerName(target), why))

    return true
  end

  -- /wake [nom]
  local target = sscanf(args, "u?")

  if target == false then
    return usage(pid, "/wake [name]")
  end

  target = target or pid
  SetPlayerKnockedOut(target, false)
  say(pid, fmt("%s is awake.", GetPlayerName(target)))

  return true
end

-- Joueur assommé : il en est informé.
function OnPlayerKnockedOut(pid)
  say(pid, "You were knocked out.")
end

-- Joueur réveillé (par le temps ou par le mode) : il en est informé.
function OnPlayerWake(pid, reason)
  if reason == "woke" or reason == "mode" then
    say(pid, "You come to.")
  end
end

-- ---------------------------------------------------------------------
-- Pickpocket
-- Le "Rob" natif sur le corps d'un autre joueur : maintenir E au prompt, puis
-- la charge et le jeu de tuiles, joués sur l'écran du voleur, sur quelques
-- objets que la victime porte sans les porter sur elle ; le serveur déplace
-- ce que le mini-jeu prend. Pas de commande pour voler. DÉSACTIVÉ tant que
-- enabled = false (ou /pickpocket on). Un admin n'est pas volable sauf
-- admins_robbable : avec EVERYONE_ADMIN, tout le monde l'est.
-- ---------------------------------------------------------------------
PICKPOCKET = {
  enabled = false,          -- true : le prompt Rob apparaît sur les autres joueurs ; false : personne ne vole
  range = 3,                -- mètres maximum entre le voleur et le corps
  cooldown = 30,            -- secondes avant que le même voleur vole la même victime
  max_items = 8,            -- piles offertes au plus (la roue du jeu en montre 11)
  max_stack = 5,            -- maximum d'un même objet offert
  behind_only = true,       -- true : seulement par derrière
  money = false,            -- true : un dixième de la bourse (jusqu'à 100 Groschen) est aussi dans les poches
  admins_robbable = false,  -- true : les poches d'un admin sont volables
  on_robbed = "none",       -- victime volée : "notify" la prévient, "none" la laisse découvrir
  on_caught = "notify"      -- voleur repéré : "notify" prévient les deux, "fight" lance en plus un combat (pvp), "none" ne dit rien
}

-- Qui peut être volé : tout le monde, sauf un admin si la table l'interdit.
-- Publié aux clients comme un état : le prompt n'apparaît que sur un corps volable.
function pocketRights(pid)
  SetPlayerPickpocketable(pid, PICKPOCKET.admins_robbable or not IsPlayerAdmin(pid))
end

-- /pickpocket on|off|status et /pickpocket admins on|off : l'interrupteur et
-- le droit de voler les admins. Réservé aux admins.
function pocketCommand(pid, args)
  if not IsPlayerAdmin(pid) then
    say(pid, "/pickpocket is for admins")
    return true
  end

  local first, second = (args or ""):match("^%s*(%a*)%s*(%a*)")

  if first == "on" or first == "off" then
    PICKPOCKET.enabled = first == "on"
    SetPickpocketing(PICKPOCKET.enabled, PICKPOCKET)
  elseif first == "admins" and (second == "on" or second == "off") then
    PICKPOCKET.admins_robbable = second == "on"

    for _, id in ipairs(GetPlayers()) do
      pocketRights(id)
    end
  end

  say(pid, fmt("pickpocketing is %s%s - /pickpocket on|off, /pickpocket admins on|off",
    PICKPOCKET.enabled and "on" or "off",
    PICKPOCKET.admins_robbable and ", admins can be robbed too" or ""))

  return true
end

-- Fin d'un vol : la victime est prévenue (volée ou voleur repéré), et un
-- combat démarre si la table le dit. Poches d'un PNJ (victim < 0) : personne à prévenir.
function OnPlayerPickpocketEnd(pid, victim, actor, outcome, reason, taken)
  if victim < 0 then
    return
  end

  if outcome == "took" then
    if PICKPOCKET.on_robbed == "notify" then
      say(victim, "Your pockets feel lighter - someone has been at them.")
    end
  elseif outcome == "caught" and (reason == "detected" or reason == "seen") and PICKPOCKET.on_caught ~= "none" then
    say(victim, fmt("You catch %s with a hand in your pocket!", GetPlayerName(pid)))
    say(pid, fmt("%s caught you!", GetPlayerName(victim)))

    if PICKPOCKET.on_caught == "fight" then
      StartFight(pid, victim)
    end
  end
end

-- ---------------------------------------------------------------------
-- Dés
-- Le jeu de dés natif entre deux joueurs côte à côte à une table de dés (les
-- tavernes en ont) : chacun joue sur son écran contre un double au visage de
-- l'autre ; le serveur tire chaque lancer et garde les mises ; gains et pertes
-- sont dans la bourse aussitôt. /dice <nom> [mise] défie, /dice accept ou
-- /dice decline répond dans la minute, /dice quit abandonne (Échap aussi).
-- ---------------------------------------------------------------------
local DICE = {
  enabled = true,     -- false : /dice répond que les dés sont désactivés
  game_type = 0,      -- objectif : 0 mendiant (1500 pts), 1 charretier (2000), 5 artisan (3000), 9 courtisan (4000)
  turn_timeout = 90,  -- secondes par coup avant de perdre (5 à 3600)
  range = 4           -- mètres entre les deux joueurs au départ (0,5 à 8)
}

local dice_invites = {}  -- joueur défié -> { from, name, bet, at }
local DICE_INVITE_MS = 60000

-- Libellés des fins de partie.
local DICE_REASONS = {
  goal = "reached the goal",
  ["gave up"] = "the other gave up",
  left = "the other left",
  timeout = "a move took too long",
  died = "a player died",
  ["out of step"] = "the two games parted ways",
  failed = "no dice table here - stand at one together",
  ["the mode"] = "the game was ended",
  ["a fight"] = "a fight broke out",
  ["walked away"] = "a player walked away"
}

-- Commande /dice : défi, acceptation, refus, abandon.
function dice(pid, args)
  args = args or ""

  local word, rest = args:match("^(%S*)%s*(.-)$")
  word = (word or ""):lower()

  if word == "" then
    return usage(pid, "/dice <name> [bet], /dice accept, /dice decline, /dice quit")
  end

  if not DICE.enabled and word ~= "quit" then
    SendClientMessage(pid, COLOR_RED, "Dice are off on this server.")

  elseif word == "accept" then
    local invite = dice_invites[pid]
    dice_invites[pid] = nil

    -- Le nom du défieur est vérifié : un pid réutilisé par un autre joueur
    -- ne doit pas pouvoir accepter une invitation qui ne lui était pas destinée.
    if not invite
      or GetServerTime() - invite.at > DICE_INVITE_MS
      or GetPlayerName(invite.from) ~= invite.name then
      say(pid, "Nobody challenged you to dice.")
      return true
    end

    local id, why = StartDiceMatch(invite.from, pid, invite.bet, DICE.game_type, DICE.turn_timeout, DICE.range)

    if not id then
      SendClientMessage(pid, COLOR_RED, why)
      SendClientMessage(invite.from, COLOR_RED, why)
    end

  elseif word == "decline" then
    local invite = dice_invites[pid]
    dice_invites[pid] = nil

    if not invite then
      say(pid, "Nobody challenged you to dice.")
      return true
    end

    if GetPlayerName(invite.from) == invite.name then
      say(invite.from, GetPlayerName(pid) .. " declined your game of dice.")
    end

  elseif word == "quit" then
    local info = GetDiceMatchInfo(GetPlayerDiceMatch(pid) or 0)

    if not info then
      say(pid, "You are not playing dice.")
      return true
    end

    EndDiceMatch(info.id, info.challenger == pid and info.opponent or info.challenger)

  else
    local target = GetPlayerId(word)
    local bet = math.floor(tonumber(rest) or 0)

    if not target then
      SendClientMessage(pid, COLOR_RED, "No such player.")
      return true
    end

    if target == pid then
      SendClientMessage(pid, COLOR_RED, "Not against yourself.")
      return true
    end

    if bet < 0 then
      SendClientMessage(pid, COLOR_RED, "The bet must be 0 or more Groschen.")
      return true
    end

    if GetPlayerDiceMatch(target) then
      say(pid, GetPlayerName(target) .. " is playing dice already.")
      return true
    end

    dice_invites[target] = { from = pid, name = GetPlayerName(pid), bet = bet, at = GetServerTime() }

    local stake = bet > 0 and fmt(" for %d Groschen", bet) or ""

    say(target, fmt("%s challenges you to dice%s - /dice accept or /dice decline.", GetPlayerName(pid), stake))
    say(pid, fmt("You challenged %s to dice%s.", GetPlayerName(target), stake))
  end

  return true
end


-- ---------------------------------------------------------------------
-- Dés : début et fin d'une partie
-- ---------------------------------------------------------------------

-- Une partie démarre : les deux joueurs sont informés de l'objectif et de la mise.
function OnDiceMatchStart(id, challenger, opponent, bet, goal)
  local text = fmt("Dice: %s against %s, to %d points%s. %s throws first.",
    GetPlayerName(challenger), GetPlayerName(opponent), goal,
    bet > 0 and fmt(", %d Groschen each", bet) or "", GetPlayerName(challenger))

  say(challenger, text)
  say(opponent, text)
end

-- Une partie se termine (victoire, abandon, départ, combat...). winner < 0
-- signifie partie annulée : les mises sont rendues.
function OnDiceMatchEnd(id, challenger, opponent, winner, reason, bet)
  local why = DICE_REASONS[reason] or reason

  local text = winner >= 0
    and fmt("%s won the game of dice%s (%s).", GetPlayerName(winner),
      bet > 0 and fmt(" and %d Groschen", 2 * bet) or "", why)
    or fmt("The game of dice is off: %s%s.", why, bet > 0 and " - the stakes went back" or "")

  for _, p in ipairs({ challenger, opponent }) do
    if GetPlayerName(p) then -- un joueur qui part est encore un joueur ici ; un autre peut avoir disparu
      say(p, text)
    end
  end
end

-- ---------------------------------------------------------------------
-- /anim <nom> : une émote pour tous les alentours
-- La roue de la touche G (et T, le geste de pointer) les joue sans commande.
-- /anim seul les liste, /anim stop arrête une danse. Les règles du serveur
-- répondent via la raison de PlayPlayerEmote ("Stand still first." ...).
-- ---------------------------------------------------------------------
function anim(pid, args)
  local name = (args or ""):match("^(%S+)")

  if not name then
    say(pid, "Animations: " .. table.concat(GetEmotes(), ", ") .. " - /anim <name>, /anim stop")
  elseif name:lower() == "stop" then
    if not StopPlayerEmote(pid) then
      say(pid, "No animation is playing.")
    end
  else
    local ok, why = PlayPlayerEmote(pid, name)

    if not ok then
      SendClientMessage(pid, COLOR_RED, why)
    end
  end

  return true
end

-- ---------------------------------------------------------------------
-- /seat : qui est assis où dans la charrette du joueur
-- /seat <n> le déplace : 0 = les rênes (d'une charrette libre), puis pour un
-- chariot 1 à côté et 2-5 à l'arrière ; pour une charrette à deux roues 1-2
-- les ridelles. Entre le banc et l'arrière, le joueur descend et remonte :
-- la charrette doit être à l'arrêt ; une place verrouillée par le mode n'est
-- pas à prendre.
-- ---------------------------------------------------------------------
local SEAT_NAMES = {
  wagon = { [0] = "the reins", "the bench", "back right", "back left", "middle right", "middle left" },
  cart = { [0] = "the reins", "right side", "left side" }
}

function seat(pid, args)
  local cart, mine = GetPlayerCart(pid)

  if not cart then
    say(pid, "You sit in no cart.")
    return true
  end

  local want = tonumber((args or ""):match("^(%d+)"))

  if not want then
    -- Sans numéro : liste des places.
    local seats, names = {}, SEAT_NAMES[GetEntityTemplate(cart)] or {}

    for s = 0, GetCartSeatCount(cart) - 1 do
      local who = GetCartSeatPlayer(cart, s)

      seats[#seats + 1] = fmt("%d %s: %s", s, names[s] or "",
        who and GetPlayerName(who) or IsCartSeatLocked(cart, s) and "kept" or "free")
    end

    say(pid, table.concat(seats, ", ") .. " - /seat <n> moves you")
  elseif want ~= mine then
    if GetCartSeatPlayer(cart, want) then
      say(pid, "Someone sits there.")
    elseif IsCartSeatLocked(cart, want) or not SetPlayerCartSeat(pid, want) then
      say(pid, "Not that seat now - the reins of a wagoner's cart are his, and nobody climbs about a moving cart.")
    end
  end

  return true
end

-- ---------------------------------------------------------------------
-- /horse : le cheval du joueur devant lui, puis en selle
-- La commande native du même nom est un outil d'admin ; la traiter ici
-- répond pour tout le monde avant d'atteindre la commande native. Un cheval
-- que le joueur possède déjà est amené au lieu d'en créer un second.
-- ---------------------------------------------------------------------
function horse(pid)
  if GetPlayerMount(pid) then
    say(pid, "You are in the saddle already - X gets you off.")
    return true
  end

  local x, y, z = GetPlayerPos(pid)

  if not x then
    return true
  end

  local yaw = GetPlayerYaw(pid) or 0
  local rad = math.rad(yaw)
  local hx, hy = x - math.sin(rad) * 2.5, y + math.cos(rad) * 2.5 -- 2,5 m devant, comme la commande native
  local mount = ownHorse(pid) -- le sien seulement : un cheval libre que le joueur simule est à quelqu'un d'autre

  if mount then
    SetEntityPos(mount, hx, hy, z, yaw)
  else
    local p = players[pid]
    local saved = p and p.savedHorse

    mount = CreateHorse(hx, hy, z, yaw, pid, nil, saved and saved.breed, saved and saved.coat)

    if not mount and saved and saved.coat then
      -- Une robe que ce serveur ne connaît pas (ligne modifiée) : une robe au hasard.
      mount = CreateHorse(hx, hy, z, yaw, pid, nil, saved.breed)
      saved.coat = nil
    end

    if mount and saved then
      -- Cheval d'une sauvegarde d'avant la robe : celle qu'il montre maintenant est
      -- conservée, pour qu'il ne change plus jamais.
      if not saved.coat and db then
        saved.coat = GetHorseCoat(mount)

        db:Execute("UPDATE player_horses SET coat = @c WHERE id = @h", { c = saved.coat, h = saved.dbId }, function(_, _, err)
          if err then
            Log("kcRP: the horse's coat was not saved: " .. tostring(err))
          end
        end)
      end

      -- Le cheval qu'ils ont quitté : l'id de sa ligne reste sur lui, il est
      -- équipé d'abord, puis ses sacoches sont remplies (elles partent avec son
      -- apparition vers le jeu du propriétaire).
      local gear, items = {}, {}

      for _, it in ipairs(saved.stacks) do
        if it.worn then
          gear[#gear + 1] = it.class
        else
          items[#items + 1] = it
        end
      end

      SetEntityData(mount, "db_id", saved.dbId)

      if #gear > 0 then
        SetHorseGear(mount, gear)
      end

      SetHorseItems(mount, items)

      -- Les statistiques qu'un admin lui avait données.
      for stat, level in pairs(p.horseStats and p.horseStats[saved.dbId] or {}) do
        SetHorseStat(mount, stat, level)
      end

      p.horseKeys = p.horseKeys or {}
      p.horseKeys[saved.dbId] = stacksKey(saved.stacks)

      Log(fmt("kcRP: %s's horse back (%d pieces of gear, %d stacks in the saddlebags)", GetPlayerName(pid), #gear, #items))

    elseif mount and db and p and p.logged and p.id then
      -- Un premier cheval : sa ligne d'abord, puis son équipement et ses sacs tels
      -- que le jeu du propriétaire les rapporte (OnHorseItemsChange).
      local breed, coat = GetEntityTemplate(mount), GetHorseCoat(mount) -- la robe affichée est sa robe pour de bon

      insertId("INSERT INTO player_horses (player_id, soul, active, created_at, coat) VALUES (@p, @s, 1, @t, @c)",
        { p = p.id, s = breed or DB_NULL, t = os.date("!%Y-%m-%dT%H:%M:%SZ"), c = coat or DB_NULL },
        function(id, err)
          if not id then
            Log("kcRP: the horse of " .. p.name .. " was not saved: " .. tostring(err))
            return
          end

          p.savedHorse = { dbId = tonumber(id), breed = breed, coat = coat, stacks = {} }

          if GetHorseOwner(mount) == pid then
            SetEntityData(mount, "db_id", tonumber(id))

            local batch = {}
            saveHorse(pid, mount, batch)
            flush(batch, "the horse of " .. p.name)
          end
        end)
    end
  end

  if not mount then
    say(pid, "There is no room for another horse here.")
    return true
  end

  if not MountPlayer(pid, mount) then
    say(pid, "That horse will not have you.")
  end

  return true
end

-- ---------------------------------------------------------------------
-- /unstuck : retour au spawn d'un joueur coincé
-- Pour un joueur coincé quelque part d'où il ne peut pas sortir à pied (une
-- étable, un rocher) : retour au spawn - sur kutnohorsko, la cour de la
-- forteresse de Suchdol. Pas pendant un combat (ce n'est pas une sortie), pas
-- dans une charrette, pas mort ni en création de personnage ; une fois toutes
-- les UNSTUCK_COOLDOWN secondes. La position est sauvegardée comme les autres.
-- ---------------------------------------------------------------------
local UNSTUCK_COOLDOWN = 300

function unstuck(pid)
  local p = players[pid]

  if not p or p.staged or not IsPlayerInWorld(pid) then
    return true
  end

  if IsPlayerDead(pid) then
    say(pid, "Not while you are dead.")
    return true
  end

  if (p.fights or 0) > 0 then
    SendClientMessage(pid, COLOR_RED, "Not in a fight.")
    return true
  end

  if GetPlayerCart(pid) then
    say(pid, "Get off the cart first.")
    return true
  end

  local now = GetServerTime()

  if p.unstuckAt and now - p.unstuckAt < UNSTUCK_COOLDOWN * 1000 then
    say(pid, fmt("You can use /unstuck again in %d s.", math.ceil((UNSTUCK_COOLDOWN * 1000 - (now - p.unstuckAt)) / 1000)))
    return true
  end

  p.unstuckAt = now

  local x, y = GetPlayerPos(pid)

  SetPlayerPos(pid, spawnSpot(pid))
  say(pid, "Back at the spawn.")
  Log(fmt("kcRP: %s unstuck from %.1f %.1f", GetPlayerName(pid), x or 0, y or 0))

  return true
end

-- Nombre de combats de chaque joueur (pour /unstuck) : le serveur les démarre
-- et les termine, le mode ne fait que compter.
function OnFightStart(a, b)
  for _, id in ipairs({ a, b }) do
    local p = players[id]

    if p then
      p.fights = (p.fights or 0) + 1
    end
  end
end

function OnFightEnd(a, b)
  for _, id in ipairs({ a, b }) do
    local p = players[id]

    if p then
      p.fights = math.max(0, (p.fights or 0) - 1)
    end
  end
end

-- ---------------------------------------------------------------------
-- Fabrication de charrettes (/createcart)
-- Une charrette personnelle, faite dans une fenêtre de la moitié client du
-- mode (gamemodes/kcRP/client/cartmaker.lua). Le joueur passe dans un monde
-- à lui (CART_WORLD + son id : personne ne regarde fabriquer) avec une vraie
-- charrette devant lui ; chaque choix de la fenêtre - chariot ou deux roues,
-- caisse, roues, chargement, robes des chevaux, rotation - est appliqué
-- aussitôt sur cette charrette. Espace la ramène dans le monde partagé avec
-- le joueur ; Échap l'enlève. Un joueur a une charrette : la nouvelle prend la
-- place de l'ancienne (la fenêtre repart d'elle), et elle quitte le monde
-- avec lui comme son cheval.
-- Événements du client : "cartmaker_shown", "cartmaker_kind" "<type>;<pièces>",
-- "cartmaker_set" "<pièces>", "cartmaker_turn" "<degrés>", "cartmaker_done"
-- ou "cartmaker_cancel" ; les pièces vont sous la forme "emplacement=pièce,...".
-- ---------------------------------------------------------------------
local CART_WORLD = 2000                      -- + id du joueur : monde où se fabrique la charrette
local CART_KINDS = { "wagon", "cart" }       -- ordre de la fenêtre
local CART_AHEAD = { wagon = 9, cart = 6 }   -- mètres entre le joueur et le milieu de la charrette : tout est visible
local CART_MIDDLE = { wagon = 0, cart = 1 }  -- mètres du point de la charrette (essieu avant / cheval) à son milieu
local CART_REACH = 4.6                       -- mètres du milieu d'un chariot à ses extrémités : la place pour tourner
local CART_TURN = 65                         -- degrés : de côté, l'arrière un peu tourné vers le joueur
local cartCatalogue                          -- contenu de "cartmaker_parts", construit une fois

-- Altitude du sol sous un point (collision, sinon relief, sinon z donné).
local function groundAt(x, y, z)
  return GetGroundZ(x, y, z + 3) or GetTerrainHeight(x, y) or z
end

-- Catalogue de chaque type : "wagon:body=a,b,...;axle=b,b_covered;...|cart:..."
-- (la pièce par défaut de chaque emplacement d'abord).
local function buildCartCatalogue()
  local kinds = {}

  for _, kind in ipairs(CART_KINDS) do
    local slots = {}

    for _, slot in ipairs(GetCartPartSlots(kind)) do
      slots[#slots + 1] = slot .. "=" .. table.concat(GetCartPartNames(slot, kind), ",")
    end

    if #slots > 0 then
      kinds[#kinds + 1] = kind .. ":" .. table.concat(slots, ";")
    end
  end

  return table.concat(kinds, "|")
end

-- Table de pièces -> "emplacement=pièce,..." (triée, donc stable).
local function partsText(parts)
  local out = {}

  for slot, part in pairs(parts) do
    out[#out + 1] = slot .. "=" .. part
  end

  table.sort(out)

  return table.concat(out, ",")
end

-- "emplacement=pièce,..." -> table de pièces.
local function partsFrom(text)
  local parts = {}

  for slot, part in (text or ""):gmatch("([%w_]+)=([%w_]+)") do
    parts[slot] = part
  end

  return parts
end

-- La charrette du joueur, tant qu'elle est à lui (la commande admin /cart remove
-- peut la retirer, et l'id peut être celui d'un autre depuis).
local function ownCart(p, pid)
  local id = p and p.cart

  if id and GetEntityKind(id) == ENTITY_CART and tonumber(GetEntityData(id, "cart_owner")) == pid then
    return id
  end

  return nil
end

-- Milieu de la charrette, devant le joueur.
local function cartMiddle(m)
  local r = math.rad(m.yaw)
  local d = CART_AHEAD[m.kind]
  local x, y = m.x - math.sin(r) * d, m.y + math.cos(r) * d

  return x, y, groundAt(x, y, m.z)
end

-- Point de la charrette et sa direction : tournée autour de son milieu par la rotation de la fenêtre.
local function cartPoint(m)
  local mx, my = cartMiddle(m)
  local yaw = (m.yaw + CART_TURN + m.turn) % 360
  local r = math.rad(yaw)
  local x, y = mx - math.sin(r) * CART_MIDDLE[m.kind], my + math.cos(r) * CART_MIDDLE[m.kind]

  return x, y, groundAt(x, y, m.z), yaw
end

-- Rien du niveau en travers (mur, arbre - avec l'export de collision ; sans
-- lui toujours vrai) : des yeux au milieu du chariot, de ses extrémités de
-- chaque côté et au-delà, où une rotation pourrait l'emmener.
local function roomForCart(m)
  local r = math.rad(m.yaw)
  local fx, fy, rx, ry = -math.sin(r), math.cos(r), math.cos(r), math.sin(r)
  local mx, my = m.x + fx * CART_AHEAD.wagon, m.y + fy * CART_AHEAD.wagon

  for _, o in ipairs({ { 0, 0 }, { rx, ry }, { -rx, -ry }, { fx, fy } }) do
    local x, y = mx + o[1] * CART_REACH, my + o[2] * CART_REACH

    if not IsLineOfSight(m.x, m.y, m.z + 1.6, x, y, groundAt(x, y, m.z) + 1) then
      return false
    end
  end

  return true
end

-- (Re)crée la charrette de la fenêtre. Retourne true si elle existe.
local function makePreview(pid, m)
  if m.cart then
    DestroyEntity(m.cart)
    m.cart = nil
  end

  local x, y, z, yaw = cartPoint(m)
  m.cart = CreateCart(m.kind, x, y, z, yaw, CART_WORLD + pid, m.parts[m.kind])

  return m.cart ~= nil
end

-- Envoie au client le catalogue puis l'ordre d'ouvrir la fenêtre.
local function sendCartMaker(pid, m)
  local x, y, z = cartMiddle(m)

  SendClientEvent(pid, "cartmaker_parts", cartCatalogue) -- à chaque fois : un /reload des scripts l'oublie
  SendClientEvent(pid, "cartmaker", fmt("open;%s;%s;%.2f;%.2f;%.2f", m.kind, partsText(GetCartParts(m.cart)), x, y, z))
end

-- /createcart : ouvre la fenêtre de fabrication.
function cartMaker(pid)
  local p = players[pid]

  if not p or not IsPlayerInWorld(pid) then
    return true
  end

  if db and not p.logged then
    say(pid, "Log in first.")
    return true
  end

  if p.staged or p.creating then
    say(pid, "Finish your character first.")
    return true
  end

  -- La fenêtre a disparu (scripts rechargés) : on la rouvre sur la même charrette.
  if p.maker then
    sendCartMaker(pid, p.maker)
    return true
  end

  if GetPlayerMount(pid) then
    say(pid, "Get off your horse first - X.")
    return true
  end

  if GetPlayerCart(pid) then
    say(pid, "Get down from the cart first.")
    return true
  end

  if GetPlayerDiceMatch(pid) then
    say(pid, "Finish your game of dice first.")
    return true
  end

  local x, y, z = GetPlayerPos(pid)

  if not x then
    return true
  end

  local m = { x = x, y = y, z = z, yaw = GetPlayerYaw(pid) or 0, turn = 0, kind = CART_KINDS[1], parts = {} }
  local old = ownCart(p, pid)

  if old and CART_AHEAD[GetEntityTemplate(old)] then -- la fenêtre repart de la charrette qu'ils ont
    m.kind = GetEntityTemplate(old)
    m.parts[m.kind] = GetCartParts(old)
  end

  if not roomForCart(m) then
    SendClientMessage(pid, COLOR_RED, "There is no room for a cart here - stand facing open ground.")
    return true
  end

  cartCatalogue = cartCatalogue or buildCartCatalogue()
  SetPlayerVirtualWorld(pid, CART_WORLD + pid)

  if cartCatalogue == "" or not makePreview(pid, m) then
    SetPlayerVirtualWorld(pid, 0)
    SendClientMessage(pid, COLOR_RED, "Carts are off on this server.")
    return true
  end

  p.maker = m
  sendCartMaker(pid, m)

  -- La fenêtre confirme qu'elle est ouverte ; un jeu sans les scripts du mode ne le
  -- fait jamais, et le joueur ne reste pas dans un monde à lui seul.
  SetTimer(function()
    if players[pid] == p and p.maker == m and not m.shown then
      closeCartMaker(pid)
      SendClientMessage(pid, COLOR_RED, "Your game did not open the cart window - join the server again to get its scripts.")
    end
  end, 6000)

  return true
end

-- Sortie de la fenêtre, retour dans le monde partagé : la charrette est gardée
-- (là, avec eux, à eux - l'ancienne détruite) ou enlevée. Retourne true si une
-- charrette a été gardée.
function closeCartMaker(pid, keep)
  local p = players[pid]
  local m = p and p.maker

  if not m then
    return false
  end

  p.maker = nil

  local kept = m.cart and keep

  if kept then
    local old = ownCart(p, pid)

    if old then
      DestroyEntity(old)
    end

    SetEntityData(m.cart, "cart_owner", pid)
    SetEntityVirtualWorld(m.cart, 0)
    p.cart = m.cart

    Log(fmt("kcRP: %s made a %s (%s)", GetPlayerName(pid), m.kind, partsText(GetCartParts(m.cart))))
  elseif m.cart then
    DestroyEntity(m.cart)
  end

  SetPlayerVirtualWorld(pid, 0)
  SendClientEvent(pid, "cartmaker", "close")

  return kept == true
end

-- Événements envoyés par la fenêtre client (voir l'en-tête de la section).
function cartMakerEvent(pid, p, name, payload)
  local m = p.maker

  if not m then
    return
  end

  payload = payload or ""

  if name == "cartmaker_shown" then
    m.shown = true

  elseif name == "cartmaker_kind" then
    local kind, parts = payload:match("^([%w_]+);?(.*)$")

    if kind and CART_AHEAD[kind] and kind ~= m.kind then
      m.kind = kind
      m.parts[kind] = partsFrom(parts)

      if makePreview(pid, m) then
        -- La nouvelle charrette telle qu'elle est, emplacements jamais choisis compris
        -- (la paire de chevaux d'une charrette) : la fenêtre les affiche.
        SendClientEvent(pid, "cartmaker", "parts;" .. kind .. ";" .. partsText(GetCartParts(m.cart)))
      else
        closeCartMaker(pid)
        SendClientMessage(pid, COLOR_RED, "No cart could be made here.")
      end
    end

  elseif name == "cartmaker_set" and m.cart then
    local parts = m.parts[m.kind] or {}

    for slot, part in pairs(partsFrom(payload)) do
      if SetCartPart(m.cart, slot, part) then
        parts[slot] = part
      end
    end

    m.parts[m.kind] = parts

  elseif name == "cartmaker_turn" and m.cart then
    local by = tonumber(payload)

    if by then
      m.turn = (m.turn + math.max(-90, math.min(90, by))) % 360
      SetEntityPos(m.cart, cartPoint(m))
    end

  elseif name == "cartmaker_done" then
    if closeCartMaker(pid, true) then
      say(pid, "Your cart stands in front of you - take the reins at its bench with the use key. /createcart builds another in its place.")
    end

  elseif name == "cartmaker_cancel" then
    closeCartMaker(pid)
  end
end

-- La fenêtre se ferme à la mort du joueur : il ne reste pas dans un monde à lui seul.
-- (À vérifier : OnPlayerDeath ne doit être défini qu'une fois dans tout le fichier.)
function OnPlayerDeath(pid, killer)
  if players[pid] and players[pid].maker then
    closeCartMaker(pid)
  end
end

-- Retire la charrette du joueur et celle en cours de fabrication (déconnexion).
function dropCarts(pid)
  local p = players[pid]

  if not p then
    return
  end

  if p.maker and p.maker.cart then
    DestroyEntity(p.maker.cart)
  end

  p.maker = nil

  local cart = ownCart(p, pid)

  if cart then
    DestroyEntity(cart)
  end
end

-- /despawncart : la seule charrette du joueur est retirée, où qu'elle soit
-- (ceux qui sont dedans descendent d'abord).
function despawnCart(pid)
  local p = players[pid]
  local cart = ownCart(p, pid)

  if not cart then
    say(pid, "You have no cart - /createcart builds one.")
    return true
  end

  DestroyEntity(cart)
  p.cart = nil
  say(pid, "Your cart is gone. /createcart builds a new one.")

  return true
end

-- ---------------------------------------------------------------------
-- Groupes (party)
-- Le serveur tient le groupe, l'invitation avec son avis et les cadres à
-- l'écran ; les commandes et les règles sont celles du mode, les mêmes que
-- freeroam : tout membre invite, le chef retire un membre, passe la main ou
-- dissout. Retourne false si la commande n'en est pas une (les commandes
-- natives du serveur répondent ensuite).
-- ---------------------------------------------------------------------
function party(pid, cmd, args)
  if cmd == "invite" then
    if #args == 0 then
      return usage(pid, "/invite <name>")
    end

    local target = GetPlayerId(args)

    if not target then
      SendClientMessage(pid, COLOR_RED, "No such player.")
      return true
    end

    local ok, reason = InviteToParty(pid, target)

    if ok then
      say(pid, "Invited " .. GetPlayerName(target) .. ".")
    else
      SendClientMessage(pid, COLOR_RED, "Cannot invite: " .. reason .. ".")
    end

    return true

  elseif cmd == "accept" then
    if not AcceptPartyInvite(pid) then
      SendClientMessage(pid, COLOR_RED, "Nobody invited you.")
    end

    return true

  elseif cmd == "decline" then
    if not DeclinePartyInvite(pid) then
      SendClientMessage(pid, COLOR_RED, "Nobody invited you.")
    end

    return true

  elseif cmd == "leave" then
    if not RemovePlayerFromParty(pid, "left") then
      SendClientMessage(pid, COLOR_RED, "You are in no party.")
    end

    return true

  elseif cmd == "pkick" or cmd == "leader" then
    if #args == 0 then
      return usage(pid, "/" .. cmd .. " <name>")
    end

    local group, target = GetPlayerParty(pid), GetPlayerId(args)

    if not group or GetPartyLeader(group) ~= pid then
      SendClientMessage(pid, COLOR_RED, "You lead no party.")
      return true
    end

    if not target or GetPlayerParty(target) ~= group then
      SendClientMessage(pid, COLOR_RED, "Not in your party.")
      return true
    end

    if cmd == "pkick" then
      RemovePlayerFromParty(target, "kicked")
    else
      SetPartyLeader(group, target)
    end

    return true

  elseif cmd == "disband" then
    local group = GetPlayerParty(pid)

    if not group or GetPartyLeader(group) ~= pid then
      SendClientMessage(pid, COLOR_RED, "You lead no party.")
      return true
    end

    DisbandParty(group)

    return true

  elseif cmd == "p" then -- /p Meet at the gate. : la ligne au groupe seul, où qu'ils soient
    local group = GetPlayerParty(pid)

    if not group then
      SendClientMessage(pid, COLOR_RED, "You are in no party.")
      return true
    end

    if #args == 0 then
      return usage(pid, "/p <text>")
    end

    SendPartyMessage(group, COLOR_PARTY, "[Party] " .. GetPlayerName(pid) .. ": " .. args)

    return true
  end

  return false
end

-- Invitation reçue : l'invité est prévenu.
function OnPartyInvite(from, target)
  SendClientMessage(target, COLOR_SERVER, GetPlayerName(from) .. " invites you to a party - /accept or /decline.")
end

-- Réponse à une invitation : l'inviteur est prévenu si elle n'est pas acceptée.
function OnPartyInviteResponse(from, target, answer)
  if answer ~= "accepted" then
    say(from, GetPlayerName(target) .. " " .. answer .. " the party invitation.")
  end
end

-- Un joueur rejoint le groupe.
function OnPlayerJoinParty(group, pid, reason)
  SendPartyMessage(group, COLOR_SERVER, GetPlayerName(pid) .. " joined the party.")
end

-- Un joueur quitte le groupe (sauf dissolution : le groupe est fini).
function OnPlayerLeaveParty(group, pid, reason)
  if reason ~= "disband" then
    SendPartyMessage(group, COLOR_SERVER, GetPlayerName(pid) .. " left the party (" .. reason .. ").")
  end
end

-- Changement de chef.
function OnPartyLeaderChange(group, pid, previous)
  SendPartyMessage(group, COLOR_SERVER, GetPlayerName(pid) .. " leads the party now.")
end

-- ---------------------------------------------------------------------
-- /help : ce que le mode offre, et rien d'autre
-- Un titre par sujet, les commandes dessous, pour qu'un nouveau joueur lise
-- le tout dans les cinq lignes que le chat garde à l'écran.
-- ---------------------------------------------------------------------
function help(pid)
  -- Une ligne d'aide dans une couleur.
  local function line(color, text)
    SendClientMessage(pid, color, text)
  end

  line(COLOR_GOLD, "---- kcRP ----")

  if db then
    line(COLOR_SERVER, "Your name:")
    line(COLOR_WHITE, "  a box asks for its password when you join (Esc there leaves the game)")
    line(COLOR_WHITE, "  /register <password>   /login <password>   the same from the chat")
  end

  line(COLOR_WHITE, "  /look                  your character's face, hair, beard and skin")
  line(COLOR_SERVER, "Speaking (heard within " .. CHAT_RANGE .. " m):")
  line(COLOR_WHITE, "  /me <action>           * Henry draws his sword")
  line(COLOR_WHITE, "  /do <description>      The door is barred. ((Henry))")
  line(COLOR_WHITE, "  /ame <action>          the same, over your head alone")
  line(COLOR_WHITE, "  /s <text>              shout, heard across " .. SHOUT_RANGE .. " m")
  line(COLOR_WHITE, "  /b <text>              out of character, in grey")
  line(COLOR_SERVER, "Gestures:")
  line(COLOR_WHITE, "  hold G                 the wheel: wave, bow, dance ...; T points")
  line(COLOR_WHITE, "  /anim <name>           the same by name (/anim lists them, /anim stop)")
  line(COLOR_SERVER, "Getting about:")
  line(COLOR_WHITE, "  /horse                 a horse in front of you; X gets you off")
  line(COLOR_WHITE, "  /unstuck               stuck somewhere? back to the spawn (every " .. UNSTUCK_COOLDOWN // 60 .. " minutes)")
  line(COLOR_WHITE, "  /createcart            build a cart of your own - it stands in front of you")
  line(COLOR_WHITE, "  /despawncart           your cart taken away")
  line(COLOR_WHITE, "  /seat [n]              in a cart: who sits where, or another seat")

  if PULLDOWN.enabled then
    line(COLOR_WHITE, "  on foot beside a rider's horse, the game's Pull down prompt takes them off it (every " .. PULLDOWN.cooldown .. " seconds at most)")
  end

  if CARRY.enabled then
    line(COLOR_WHITE, "  at a body that lies down, the game's grab prompt carries it; /carry <name> a knocked-out player, /putdown puts it down")
  end

  if PICKPOCKET.enabled then
    line(COLOR_WHITE, "  at another player's back" .. (PICKPOCKET.behind_only and "" or " (or front, at a risk)")
      .. ", hold E at the game's Rob prompt to pick their pockets (once per " .. PICKPOCKET.cooldown .. " seconds per person)")
  end

  line(COLOR_WHITE, "  the merchant at the spawn trades - walk up and use him")
  line(COLOR_SERVER, "Skills:")
  line(COLOR_WHITE, "  /skills [name]         your stats and skills, or one of them with its XP")
  line(COLOR_SERVER, "Dice (at a dice table, together):")
  line(COLOR_WHITE, "  /dice <name> [bet]     challenge   /dice accept  /dice decline  /dice quit")
  line(COLOR_SERVER, "Party:")
  line(COLOR_WHITE, "  /invite <name>  /accept  /decline  /leave")
  line(COLOR_WHITE, "  /p <text>              to your party, wherever they are")
  line(COLOR_WHITE, "  the leader: /pkick <name>  /leader <name>  /disband")

  if IsPlayerAdmin(pid) then
    line(COLOR_OOC, "  (admin: the server's own tools answer too - /give, /tp, /time, /kick ...)")
    line(COLOR_OOC, "  (admin: /setlevel <name> <skill> <level> [xp]  /givexp <name> <skill> <xp>  /perk <name> add|remove <perk>)")
    line(COLOR_OOC, "  (admin: /perkpoints <name> <skill> <points>  /xprate <rate>  /horsestat <stat> <level>  /horsecoat <coat>)")
    line(COLOR_OOC, "  (admin: /carrying on|off  /ko [name] [seconds]  /wake [name]  /carry <name> carries anyone)")
    line(COLOR_OOC, "  (admin: /pickpocket on|off|status  /pickpocket admins on|off - whether an admin can be robbed too)")
  end
end

-- ---------------------------------------------------------------------
-- La boîte de mot de passe
-- La moitié client du mode (gamemodes/kcRP/client/account.lua) dessine une
-- boîte de mot de passe et garde le clavier tant qu'elle est ouverte :
-- "auth" "register;<ligne>" demande un mot de passe à un nom sans compte,
-- "login;<ligne>" le demande pour se connecter, "close" la retire ; la ligne
-- dessous dit ce qui n'a pas marché. La boîte envoie "auth_register" /
-- "auth_login" avec le mot de passe (il ne va nulle part ailleurs : jamais
-- dans un journal, jamais dans le chat) ; Échap la ferme et quitte le jeu.
-- ---------------------------------------------------------------------

-- Envoie un ordre à la boîte : type ("register" / "login" / "close") et ligne.
local function box(pid, kind, line)
  SendClientEvent(pid, "auth", kind .. ";" .. (line or ""))
end

-- La boîte s'ouvre quand deux choses sont connues : si le nom a un compte
-- (réponse de la base) et que la moitié client est prête à la dessiner (son
-- "auth_ready", renvoyé après chaque /reload des scripts).
function askPassword(pid, line)
  local p = players[pid]

  if not db or not p or p.logged or not p.known or not p.ready then
    return
  end

  box(pid, p.registered and "login" or "register", line)
end

-- /register <mot de passe> (ou la boîte, fromBox = true). Les réponses vont là
-- d'où le mot de passe est venu : la boîte, ou le chat.
function register(pid, password, fromBox)
  password = password or ""

  if not db then
    say(pid, "This server keeps no accounts.")
    return true
  end

  local p = players[pid]

  if not p or p.logged then
    return true
  end

  -- Répond dans la boîte ou dans le chat selon l'origine de la demande.
  local function answer(kind, text, chatText)
    if fromBox then
      box(pid, kind, text)
    else
      say(pid, chatText or text)
    end
  end

  if p.registered then
    answer("login", "This name has an account already - log in with its password.",
      "This name is registered already: /login <password>.")
    return true
  end

  local length = utf8.len(password) or #password -- des caractères, pas des octets (un tréma en fait deux)

  if length < 4 or length > 32 or password:find("%s") then
    answer("register", "A password is 4 to 32 characters, without spaces.",
      "Usage: /register <password> (4 to 32 characters, no spaces).")
    return true
  end

  p.registered = true -- avant le retour de la réponse : une seconde demande entre-temps est refusée

  db:Execute("INSERT INTO players (name, password, visits) VALUES (@n, @p, 0)",
    { n = p.name, p = HashPassword(password) },
    function(_, _, err)
      if not IsPlayerConnected(pid) or players[pid] ~= p then
        return
      end

      if err then
        p.registered = false
        Log("kcRP: register failed for " .. p.name .. ": " .. err)
        answer("register", "The account could not be made - try again in a moment.",
          "The registration failed; try again in a moment.")
        return
      end

      Log("kcRP: " .. p.name .. " registered")
      answer("login", "Your account is made. Now log in with the password you chose.",
        "Registered: this name is yours now. Now /login <password>.")
    end)

  return true
end

-- /login <mot de passe> (ou la boîte, fromBox = true).
-- Après succès : modules (métier, banque, compagnies), sacs et cheval,
-- progression, découvertes, puis place sauvegardée ou création du personnage.
function login(pid, password, fromBox)
  password = password or ""

  if not db then
    say(pid, "This server keeps no accounts.")
    return true
  end

  local p = players[pid]

  if not p then
    return true
  end

  if p.logged then
    if not fromBox then
      say(pid, "You are logged in already.")
    end

    return true
  end

  -- Répond dans la boîte ou dans le chat selon l'origine de la demande.
  local function answer(kind, text, chatText)
    if fromBox then
      box(pid, kind, text)
    else
      say(pid, chatText or text)
    end
  end

  if not p.registered then
    answer("register", "This name has no account yet - choose a password to make it yours.",
      "This name is not registered: /register <password> makes it yours.")
    return true
  end

  if #password == 0 then
    answer("login", "Type your password first.", "Usage: /login <password>")
    return true
  end

  if p.checking then
    return true -- une vérification à la fois : la base répond à la première
  end

  p.checking = true

  db:Query("SELECT id, password, x, y, z, yaw, money, level, look, nourishment, energy FROM players WHERE name = @n",
    { n = p.name },
    function(rows, err)
      p.checking = false

      if err then
        Log("kcRP: " .. err)
        return
      end

      if not IsPlayerConnected(pid) or players[pid] ~= p then
        return
      end

      if #rows == 0 or not VerifyPassword(password, rows[1].password) then
        p.tries = (p.tries or 0) + 1

        if p.tries >= MAX_TRIES then
          Log("kcRP: " .. p.name .. " kicked after " .. p.tries .. " wrong passwords")
          Kick(pid, "Too many wrong passwords.")
          return
        end

        answer("login", fmt("Wrong password - %d of %d tries left.", MAX_TRIES - p.tries, MAX_TRIES), "Wrong password.")
        return
      end

      p.logged = true
      SendClientEvent(pid, "auth", "close") -- la boîte disparaît, d'où que le mot de passe soit venu

      local row = rows[1]

      db:Execute("UPDATE players SET visits = visits + 1 WHERE name = @n", { n = p.name })

      -- Une ligne qui n'a jamais sauvegardé de bourse (compte d'avant, ou jamais joué) garde le kit.
      if row.money and row.money > 0 then
        p.savedMoney = row.money

        if p.outfitted then
          GivePlayerMoney(pid, row.money - GetPlayerMoney(pid)) -- la bourse telle qu'ils l'ont laissée (les 3000 du kit remplacés)
        end
      end

      p.id = row.id

      -- Modules kcRP. Le métier se charge de façon asynchrone ; la compagnie
      -- attribue son premier propriétaire quand le métier est chargé (événement
      -- "player:jobChanged" de companies.lua).
      if kcRP.Jobs then
        kcRP.Jobs.OnPlayerLoggedIn(pid, row.id)
      end

      if kcRP.Bank then
        kcRP.Bank.OnPlayerLoggedIn(pid, row.id)
      end

      if kcRP.Companies and kcRP.Companies.OnPlayerLoggedIn then
        kcRP.Companies.OnPlayerLoggedIn(pid)
      end

      loadSaves(pid, p)         -- les sacs et le cheval, depuis leurs tables
      loadProgress(pid, p, row) -- stats, compétences, talents et états du personnage
      loadDiscovery(pid, p)     -- lieux et livres découverts (si une règle DISCOVERY les garde)
      promote(pid)

      -- Le lieu sauvegardé, sur ce niveau.
      local place = row.x and row.level == GetLevel() and { row.x, row.y, row.z, row.yaw } or nil

      -- L'apparence sauvegardée ; un compte sans apparence (première connexion, compte
      -- d'avant les apparences, pièce supprimée par une mise à jour) fait d'abord son
      -- personnage, dans un monde à lui au spawn.
      if row.look and row.look ~= "" and SetPlayerLook(pid, row.look) then
        if place and IsPlayerInWorld(pid) then
          SetPlayerPos(pid, place[1], place[2], place[3], place[4]) -- là où ils étaient
          say(pid, fmt("Logged in. Welcome back, %s - you are where you left.", GetPlayerName(pid)))
        else
          say(pid, fmt("Logged in. Welcome, %s.", GetPlayerName(pid)))
        end
      else
        say(pid, fmt("Logged in. Welcome, %s.", GetPlayerName(pid)))
        stageCreator(pid, place)
      end
    end)

  return true
end

-- ---------------------------------------------------------------------
-- L'apparence du personnage
-- Le créateur est la moitié client du mode (gamemodes/kcRP/client/creator.lua) :
-- le mode envoie les éléments offerts - visages simples, chaque coiffure avec ses
-- couleurs (coupes de barbier comprises), barbes, peaux, et la même chose pour
-- une femme (visages, cheveux et peaux ; pas de barbe) - et l'ouvre avec
-- l'apparence du joueur ; il choisit un homme ou une femme, tourne l'aperçu,
-- choisit, et le client demande l'apparence. OnPlayerLookChange ne l'accepte
-- que créateur ouvert, et la sauvegarde avec le compte. Le créateur d'un nouveau
-- personnage n'a pas d'annulation. Qui devient femme (ou redevient homme) doit
-- redémarrer son jeu une fois : le corps se charge avec le niveau.
-- ---------------------------------------------------------------------
local creatorParts -- contenu de "creator_parts", construit une fois depuis les listes du jeu

-- Coiffures d'un corps : "style:couleur,couleur;style:..." - les couleurs de
-- chaque modèle de cheveux (pas ceux d'un personnage nommé : m_hair_005_mIstvan)
-- et les coupes de barbier (une couleur chacune).
local function hairStyles(gender)
  local hair, order = {}, {}

  for _, part in ipairs(GetLookParts("hair", "", gender)) do
    if part.style ~= "" and part.generic and not part.name:find("%u") then
      if not hair[part.style] then
        hair[part.style] = {}
        order[#order + 1] = part.style
      end

      table.insert(hair[part.style], part.name)
    elseif part.name:find("^m_hair_barber_") then
      hair[part.name] = { part.name }
      order[#order + 1] = part.name
    end
  end

  local styles = {}

  for _, style in ipairs(order) do
    styles[#styles + 1] = style .. ":" .. table.concat(hair[style], ",")
  end

  return table.concat(styles, ";")
end

-- Visages simples (pas leurs variantes) et teintes de peau d'un corps (les noms
-- qui commencent par l'une des "tones", pas leurs groupes).
local function facesAndSkins(gender, tones)
  local faces, skins = {}, {}

  for _, part in ipairs(GetLookParts("head", "generic", gender)) do
    if part.style == "" then
      faces[#faces + 1] = part.name
    end
  end

  for _, part in ipairs(GetLookParts("body", "generic", gender)) do
    for _, tone in ipairs(tones) do
      if part.name:sub(1, #tone) == tone then
        skins[#skins + 1] = part.name
        break
      end
    end
  end

  return faces, skins
end

-- Construit tout ce que le créateur propose. Retourne nil sans export des
-- tables (rien à offrir).
local function buildCreatorParts()
  local faces, skins = facesAndSkins("", { "m_body_" })
  local herFaces, herSkins = facesAndSkins("female", { "f_body_", "f_roma_" })
  local beards = { "m_beard_00" }

  for _, part in ipairs(GetLookParts("beard")) do
    if (part.generic and part.name:find("^m_beard_") and part.name ~= "m_beard_00")
      or part.name:find("^UC_beard_barber_") then
      beards[#beards + 1] = part.name
    end
  end

  if #faces == 0 then
    return nil
  end

  local payload = "faces=" .. table.concat(faces, ",") .. "|hair=" .. hairStyles("")
    .. "|beards=" .. table.concat(beards, ",") .. "|skins=" .. table.concat(skins, ",")

  if #herFaces > 0 then
    payload = payload .. "|ffaces=" .. table.concat(herFaces, ",") .. "|fhair=" .. hairStyles("female")
      .. "|fskins=" .. table.concat(herSkins, ",")
  end

  return payload
end

-- Ouvre le créateur chez le joueur. Retourne true s'il s'est ouvert.
function openCreator(pid, first)
  local p = players[pid]

  if not p or not IsPlayerInWorld(pid) then
    return false
  end

  creatorParts = creatorParts or buildCreatorParts()

  if not creatorParts then
    -- Un nouveau personnage garde l'apparence du jeu sans un mot ; /look explique pourquoi.
    if not first then
      say(pid, "This server has no list of faces and hair to choose from (the tables export is missing).")
    end

    return false
  end

  if not p.partsSent then
    SendClientEvent(pid, "creator_parts", creatorParts)
    p.partsSent = true
  end

  p.creating = true
  p.firstLook = first

  SendClientEvent(pid, "creator", (first and "new" or "edit") .. ";" .. LookToString(GetPlayerLook(pid) or {}))

  if first then
    say(pid, "Make your character: the face, the hair, the beard, the skin.")
  end

  return true
end

-- Première connexion d'un compte sans apparence : le joueur passe dans un monde à
-- lui (CREATOR_WORLD + son id : personne ne voit un personnage à moitié fait, et
-- deux nouveaux joueurs ne se tiennent pas l'un dans l'autre) au point d'apparition
-- de la carte ; le créateur s'ouvre un instant plus tard (le déplacement est
-- arrivé : l'aperçu se tient là où ils regardent), et son "terminé"
-- (leaveCreator) les ramène dans le monde partagé - au spawn, ou au lieu qu'un
-- compte d'avant les apparences avait sauvegardé.
function stageCreator(pid, place)
  local p = players[pid]

  if not p or not IsPlayerInWorld(pid) then
    return
  end

  p.staged = place or { spawnSpot(pid) } -- où le monde partagé les emmène ensuite

  SetPlayerVirtualWorld(pid, CREATOR_WORLD + pid)
  SetPlayerPos(pid, spawnX, spawnY, spawnZ, spawnYaw)
  TogglePlayerControllable(pid, false) -- personne ne part avant l'ouverture du créateur (il tourne la vue sur le corps)

  Log(fmt("kcRP: %s makes a character in world %d", GetPlayerName(pid), CREATOR_WORLD + pid))

  SetTimer(function()
    if not IsPlayerConnected(pid) or players[pid] ~= p or not p.staged then
      return
    end

    if not openCreator(pid, true) then
      leaveCreator(pid) -- rien à choisir (pas d'export des tables) : directement dans le monde
    end
  end, 1500)
end

-- Sort le joueur du monde de création vers le monde partagé.
function leaveCreator(pid)
  local p = players[pid]

  if not p or not p.staged then
    return
  end

  local to = p.staged
  p.staged = nil

  SetPlayerVirtualWorld(pid, 0)
  SetPlayerPos(pid, to[1], to[2], to[3], to[4])
  TogglePlayerControllable(pid, true)

  Log(fmt("kcRP: %s joins the shared world at %.1f %.1f", GetPlayerName(pid), to[1], to[2]))
end

-- Sauvegarde l'apparence dans le compte.
function saveLook(pid, look)
  local p = players[pid]

  if not db or not p or not p.logged then
    return
  end

  db:Execute("UPDATE players SET look = @l WHERE name = @n", { l = LookToString(look), n = p.name }, function(_, _, err)
    if err then
      Log("kcRP: the look of " .. p.name .. " was not saved: " .. err)
    end
  end)
end

-- "Terminé" du créateur : l'apparence est celle du joueur tant que le créateur
-- est ouvert, et elle est sauvegardée avec le compte. Retourner true l'accepte.
function OnPlayerLookChange(pid, look)
  local p = players[pid]

  if not p or not p.creating then
    return false
  end

  p.creating = false
  saveLook(pid, look)
  SendClientEvent(pid, "creator", "close")
  say(pid, p.firstLook and "Your character is made. /look changes it later." or "Your new look suits you.")
  leaveCreator(pid) -- nouveau personnage : hors de son monde à lui, dans le monde partagé (l'apparence suit)

  return true
end

-- =====================================================================
-- Gestion des messages web (forge-register + bank)
-- =====================================================================

-- Tables pour suivre les frames ouvertes
kcRP.bankFrames = kcRP.bankFrames or {}
kcRP.forgeFrames = kcRP.forgeFrames or {}

function OnWebMessage(frame, data)
  Log("=== OnWebMessage called ===", frame, data)
  
  -- Gérer bank
  if frame == "bank" then
    if type(data) == "table" and data.action == "close" then
      Log("Bank close action detected")
      
      -- Trouver et fermer la frame pour TOUS les joueurs qui l'ont ouverte
      for pid, _ in pairs(kcRP.bankFrames) do
        if IsPlayerConnected(pid) then
          Log("Closing bank for player", pid)
          SetPlayerWebFocus(pid, "bank", false, false)
          HidePlayerWebFrame(pid, "bank")
          SetPlayerCursor(pid, false)
          kcRP.bankFrames[pid] = nil
        end
      end
    end
    return
  end
  
  -- Gérer forge-register
  if frame == "forge-register" then
    if type(data) == "table" and data.action == "close" then
      Log("Forge close action detected")
      
      for pid, _ in pairs(kcRP.forgeFrames) do
        if IsPlayerConnected(pid) then
          Log("Closing forge for player", pid)
          SetPlayerWebFocus(pid, "forge-register", false, false)
          HidePlayerWebFrame(pid, "forge-register")
          SetPlayerCursor(pid, false)
          kcRP.forgeFrames[pid] = nil
        end
      end
    end
    return
  end
end

-- ---------------------------------------------------------------------
-- Les sacs et le cheval qu'un joueur garde
-- Ce que le joueur porte, ce sont des lignes de player_items (l'argent à part :
-- la bourse est players.money), remises au prochain login avec
-- SetPlayerInventory - le manquant donné, le surplus retiré, ce qu'ils portaient
-- remis sur eux - si bien que l'équipement du spawn et le kit deviennent les sacs
-- sauvegardés sans doublon. Leur cheval est une ligne de player_horses (la race)
-- avec son équipement et ses sacoches en lignes de horse_items. Le serveur oublie
-- tous les chevaux à l'arrêt, et le cheval quitte le monde avec son propriétaire
-- (laissé derrière, il serait à personne, ses sacs à tous) : /horse le refait,
-- tel qu'il était. Une liste n'est écrite que si elle a changé depuis la dernière
-- sauvegarde, ses anciennes lignes supprimées et les nouvelles insérées dans une
-- seule transaction.
-- ---------------------------------------------------------------------
local MONEY_CLASS = "5ef63059-322e-4e1b-abe8-926e100c770e" -- classe de l'objet "argent" du jeu

-- Nom du catalogue à côté du GUID, pour qui lit les lignes (DB_NULL si inconnu).
function itemName(class)
  local name = GetItemName(class)
  return name ~= "" and name or DB_NULL
end

-- Une liste de piles sous forme de texte, pour savoir si elle a changé.
function stacksKey(stacks)
  local parts = {}

  for _, it in ipairs(stacks) do
    parts[#parts + 1] = fmt("%s:%d:%d:%d", it.class, it.amount, it.health or 100, it.worn and 1 or 0)
  end

  return table.concat(parts, ";")
end

-- Les lignes d'une liste dans un lot : les anciennes supprimées, les nouvelles insérées.
local function stackStatements(batch, tbl, column, id, stacks)
  batch[#batch + 1] = { "DELETE FROM " .. tbl .. " WHERE " .. column .. " = @id", { id = id } }

  for slot, it in ipairs(stacks) do
    batch[#batch + 1] = {
      "INSERT INTO " .. tbl .. " (" .. column .. ", slot, item, item_name, amount, health, worn) " ..
        "VALUES (@id, @s, @i, @n, @a, @h, @w)",
      { id = id, s = slot, i = it.class, n = itemName(it.class), a = it.amount, h = it.health or 100, w = it.worn and 1 or 0 }
    }
  end
end

-- Exécute un lot d'instructions en une transaction ; journalise l'échec ("what" = ce qui était sauvegardé).
function flush(batch, what)
  if not db or #batch == 0 then
    return
  end

  db:Batch(batch, function(ok, err)
    if not ok then
      Log("kcRP: " .. what .. " not saved: " .. tostring(err))
    end
  end)
end

-- Lignes de la base -> liste de piles.
local function readStacks(rows)
  local stacks = {}

  for _, r in ipairs(rows or {}) do
    if r.item then
      stacks[#stacks + 1] = {
        class = r.item,
        amount = tonumber(r.amount) or 1,
        health = tonumber(r.health) or 100,
        worn = tonumber(r.worn) == 1
      }
    end
  end

  return stacks
end

local BAGS_WAIT = 120000 -- ms : le temps laissé au jeu pour rapporter les sacs restaurés avant que le mode cesse d'attendre

-- Compare ce que le jeu du joueur a rapporté en dernier à ce que la restauration
-- a commandé. Retourne : classes tenues en entier (au moins la quantité
-- sauvegardée), nombre de classes commandées, noms des classes manquantes.
local function bagsHeld(pid, want)
  local have, need = {}, {}

  for _, it in ipairs(GetPlayerInventory(pid)) do
    local class = it.class:lower()
    have[class] = (have[class] or 0) + it.amount
  end

  for _, it in ipairs(want) do
    local class = it.class:lower()
    need[class] = (need[class] or 0) + it.amount
  end

  local held, total, missing = 0, 0, {}

  for class, amount in pairs(need) do
    total = total + 1

    if (have[class] or 0) >= amount then
      held = held + 1
    else
      local name = GetItemName(class)
      missing[#missing + 1] = (name and name ~= "") and name or class
    end
  end

  return held, total, missing
end

-- Vrai quand les sacs rapportés par le jeu contiennent chaque pile commandée par la restauration.
local function bagsConfirmed(pid, want)
  local held, total = bagsHeld(pid, want)
  return held == total
end

-- Remet les sacs sauvegardés au joueur (SetPlayerInventory), puis attend que
-- son jeu les rapporte avant de recommencer à les sauvegarder.
function restoreInventory(pid, items)
  local p = players[pid]

  SetPlayerInventory(pid, items)

  if p then
    p.bagsKey = stacksKey(items)

    -- Sauvegardé de nouveau une fois que le jeu a rapporté la restauration
    -- (bagsConfirmed, à chaque changement) : une sauvegarde avant écrirait les sacs
    -- qu'elle a remplacés. Un jeu qui ne les rapporte jamais laisse les sacs
    -- sauvegardés tels quels - pas un démarrage lent qu'un minuteur devine, ce qui
    -- écrivait les sacs d'un arrivant par-dessus ceux d'un personnage quand la
    -- restauration était en retard.
    p.bagsWant = items
    p.bagsReady = false

    SetTimer(function()
      if players[pid] ~= p or p.bagsReady or not p.bagsWant then
        return
      end

      -- Toujours pas tout : un objet sauvegardé que le jeu ne donne plus (retiré par
      -- une mise à jour) empêcherait de sauvegarder tout changement de la session.
      -- Des sacs qui tiennent au moins la moitié des piles montrent que la restauration
      -- a abouti : sauvegardés désormais, sans les manquants ; moins que cela, la
      -- restauration n'est jamais arrivée - rien n'est sauvegardé.
      local held, total, missing = bagsHeld(pid, p.bagsWant)
      p.bagsWant = nil

      if held * 2 >= total then
        p.bagsReady = true

        if #missing > 0 then
          Log(fmt("kcRP: %s's bags came back without %s - saved from here on as the game holds them",
            GetPlayerName(pid), table.concat(missing, ", ")))
        end

        saveCarried(pid)
      else
        -- Les classes manquantes sont ajoutées au message : sans elles on ne peut pas
        -- savoir quel objet sauvegardé le jeu ne rapporte pas.
        Log(fmt("kcRP: %s's bags were not reported back within %d s (%d of %d stacks; missing: %s) - they are not saved this session, the saved ones stay",
          GetPlayerName(pid), BAGS_WAIT // 1000, held, total, table.concat(missing, ", ")))
      end
    end, BAGS_WAIT)
  end

  Log(fmt("kcRP: %s's bags restored (%d stacks)", GetPlayerName(pid), #items))
end

-- Les sacs du joueur dans le lot, quand ils ont changé.
function saveBags(pid, p, batch)
  if not p.bagsReady then
    return
  end

  local stacks = {}

  for _, it in ipairs(GetPlayerInventory(pid)) do
    if it.class ~= MONEY_CLASS then
      stacks[#stacks + 1] = it
    end
  end

  local key = stacksKey(stacks)

  if key == p.bagsKey then
    return
  end

  p.bagsKey = key
  stackStatements(batch, "player_items", "player_id", p.id, stacks)
end

-- Le cheval le plus récent du joueur (ce mode lui en donne un).
function ownHorse(pid)
  local owned = GetPlayerHorses(pid)
  return owned[#owned]
end

-- Les lignes d'un cheval : son équipement d'abord (porté), puis le contenu de ses sacoches.
local function horseStacks(mount)
  local stacks = {}

  for _, class in ipairs(GetHorseGear(mount) or {}) do
    stacks[#stacks + 1] = { class = class, amount = 1, health = 100, worn = true }
  end

  for _, it in ipairs(GetHorseItems(mount) or {}) do
    stacks[#stacks + 1] = it
  end

  return stacks
end

-- Un cheval du joueur dans le lot, quand il a changé.
function saveHorse(pid, mount, batch)
  local p = players[pid]
  local id = mount and tonumber(GetEntityData(mount, "db_id"))

  -- La ligne d'un premier cheval est encore en cours de création : son callback le sauvegarde.
  if not (db and p and p.logged and id) then
    return
  end

  local stacks = horseStacks(mount)
  local key = stacksKey(stacks)

  p.horseKeys = p.horseKeys or {}

  if key == p.horseKeys[id] then
    return
  end

  p.horseKeys[id] = key

  if mount == ownHorse(pid) then
    p.savedHorse = { dbId = id, breed = GetEntityTemplate(mount), coat = GetHorseCoat(mount), stacks = stacks }
  end

  stackStatements(batch, "horse_items", "horse_id", id, stacks)
end

-- La bourse dans le lot, quand elle a changé.
local function savePurse(pid, p, batch)
  local money = GetPlayerMoney(pid)

  if money == p.purseKey then
    return
  end

  p.purseKey = money
  batch[#batch + 1] = { "UPDATE players SET money = @m WHERE id = @id", { m = money, id = p.id } }
end

-- Ce que le joueur porte - les sacs, la bourse, ses chevaux - sauvegardé en une
-- transaction, seulement ce qui a changé : un objet qui passe de l'un à l'autre
-- (dans les sacoches, vendu contre de l'argent) n'est qu'à un endroit dans la
-- base, jamais à deux. Appelée dès que le serveur apprend un changement
-- (OnPlayerInventoryChange, OnHorseItemsChange) : ce qu'un joueur donne à un coffre,
-- au sol ou à une boutique - au serveur aussitôt - disparaît de ses sacs
-- sauvegardés dans la seconde ; un plantage ne peut plus le rendre.
function saveCarried(pid)
  local p = players[pid]

  if not (db and p and p.logged and p.id) or p.staged then
    return
  end

  local batch = {}

  saveBags(pid, p, batch)
  savePurse(pid, p, batch)

  for _, mount in ipairs(GetPlayerHorses(pid)) do
    saveHorse(pid, mount, batch)
  end

  flush(batch, "the things of " .. p.name)
end

-- Le serveur a appris un changement de ce que le joueur porte (ou de sa bourse).
function OnPlayerInventoryChange(pid)
  if not IsPlayerInWorld(pid) then
    return
  end

  local p = players[pid]

  if p and not p.bagsReady and p.bagsWant and bagsConfirmed(pid, p.bagsWant) then
    p.bagsReady = true -- le jeu tient ce que la restauration a commandé : ce qu'il rapporte désormais est celui du personnage
    p.bagsWant = nil
  end

  saveCarried(pid)
end

-- Le contenu ou l'équipement d'un cheval a changé : on sauvegarde chez son propriétaire.
function OnHorseItemsChange(id)
  local owner = GetHorseOwner(id)

  if owner then
    saveCarried(owner)
  end
end

-- À la connexion : les sacs sauvegardés (remis maintenant, ou à l'apparition), le
-- cheval actif (pour /horse) et les statistiques que des admins ont données à leurs chevaux.
function loadSaves(pid, p)
  db:Query("SELECT item, amount, health, worn FROM player_items WHERE player_id = @p ORDER BY slot", { p = p.id }, function(rows, err)
    if err then
      Log("kcRP: the bags of " .. p.name .. " could not be read: " .. err)
      return
    end

    if players[pid] ~= p then
      return
    end

    local items = readStacks(rows)

    if #items == 0 then
      p.bagsReady = true -- rien de sauvegardé (nouveau compte) : le kit reste, et est sauvegardé dès maintenant
      return
    end

    p.savedItems = items

    if p.outfitted then
      restoreInventory(pid, items) -- déjà apparu ; sinon OnPlayerSpawn les remet
    end
  end)

  db:Query("SELECT h.id AS hid, h.soul, h.coat, i.item, i.amount, i.health, i.worn FROM player_horses h LEFT JOIN horse_items i ON i.horse_id = h.id " ..
    "WHERE h.player_id = @p AND h.active = 1 ORDER BY h.id DESC, i.slot", { p = p.id }, function(rows, err)
    if err then
      Log("kcRP: the horse of " .. p.name .. " could not be read: " .. err)
      return
    end

    if players[pid] ~= p or #rows == 0 then
      return
    end

    local first, mine = rows[1].hid, {}

    for _, r in ipairs(rows) do
      if r.hid == first then
        mine[#mine + 1] = r
      end
    end

    local coat = rows[1].coat

    p.savedHorse = { dbId = first, breed = rows[1].soul, coat = coat ~= "" and coat or nil, stacks = readStacks(mine) }
  end)

  -- Statistiques données à leurs chevaux (appliquées quand /horse refait le cheval).
  db:Query("SELECT s.horse_id, s.stat, s.level FROM horse_stats s JOIN player_horses h ON h.id = s.horse_id WHERE h.player_id = @p",
    { p = p.id }, function(rows, err)
      if err then
        Log("kcRP: the horse stats of " .. p.name .. " could not be read: " .. err)
        return
      end

      if players[pid] ~= p then
        return
      end

      p.horseStats = p.horseStats or {}

      for _, r in ipairs(rows) do
        local stats = p.horseStats[r.horse_id] or {}
        stats[r.stat] = tonumber(r.level)
        p.horseStats[r.horse_id] = stats
      end
    end)
end

-- ---------------------------------------------------------------------
-- La progression qu'un personnage garde
-- Les statistiques, compétences, talents, le niveau principal, et ce qu'un
-- personnage a mangé et dormi sont l'âme dans le jeu du joueur, qui les
-- rapporte au serveur quelques secondes après l'apparition et à chaque
-- changement ; le serveur les remet au mode (GetPlayerProgress). Ils sont
-- sauvegardés avec le personnage - player_progress (une ligne par stat et
-- compétence : niveau, XP vers le suivant, points de talent non dépensés),
-- player_perks (une ligne par talent), nourriture et énergie dans la ligne
-- players - dès qu'un niveau ou un talent change et chaque minute avec le lieu,
-- et remis au prochain login avec SetPlayerProgress. Le niveau principal
-- ("mainlevel") est une ligne comme les autres, mais le jeu calcule lui-même
-- son niveau : il est sauvegardé pour l'œil, et seuls ses points de talent
-- sont remis (SetPlayerPerkPoints). Un personnage n'est sauvegardé qu'après
-- que sa progression sauvegardée a été remise (p.progressReady) : un jeu
-- planté, ou qui rapporte en retard, ne doit pas écrire son âme neuve par-dessus
-- le personnage - la leçon des sacs. Les règles - à changer ici :
-- ---------------------------------------------------------------------
PROGRESS = {
  xp_rate = 1 -- chaque XP que le jeu accorde (un kill, un coup, un livre, une distance) compte autant de fois : 0 aucun, 1 comme le jeu le donne
}

-- Ce qu'un personnage a trouvé du monde, gardé avec lui. Le jeu du joueur rapporte
-- les lieux nommés et points d'intérêt, et les livres lus ; le serveur les
-- enregistre (ils ne font que croître), ce mode sauvegarde l'enregistrement dans
-- player_discovery (une ligne par niveau et par type ; les livres sont les mêmes
-- à tous les niveaux) et le remet au prochain login. Tout désactivé : le comportement
-- natif de la carte - toute la carte montrée dès le départ - et rien de sauvegardé ;
-- aucune table n'est créée et le jeu d'aucun joueur n'est sollicité.
DISCOVERY = {
  places = false,     -- lieux nommés (villages, villes, camps) et points d'intérêt trouvés - ils s'affichent sur la carte avec leur nom
  reading = false,    -- livres lus et degré d'étude de chacun : relire un livre après une reconnexion ne fait plus farmer son XP
  explorer = "keep"   -- "strip" : le talent Explorateur, qui révèle tout le niveau dès qu'on le possède, est écarté des talents remis au login
}

local EXPLORER_PERK = "34e03c47-de53-482f-b3f5-555e7e36d70c" -- le talent Explorateur du jeu

-- Les noms que les menus du jeu montrent pour les stats et compétences dont le nom diffère.
local LABELS = {
  mainlevel = "main level", storyprogress = "story progress", horse_riding = "horsemanship", fencing = "warfare",
  weapon_sword = "swords", weapon_large = "polearms", weapon_unarmed = "unarmed", weapon_shield = "shield",
  weapon_dagger = "dagger"
}

local STAT_ORDER = { "strength", "agility", "vitality", "speech" } -- ligne des stats de /skills ; le niveau principal a la sienne

-- Nom affiché d'une stat ou compétence.
local function label(name)
  return LABELS[name] or (name:gsub("_", " "))
end

-- "2 perk points" pour des points au-dessus de 0, sinon nil.
local function perkPoints(points)
  points = tonumber(points) or 0

  if points <= 0 then
    return nil
  end

  return fmt("%d perk point%s", points, points == 1 and "" or "s")
end

-- Noms que l'admin peut taper pour le niveau principal (le jeu le calcule : aucune commande ne le fixe).
local MAIN_LEVEL_NAMES = { mainlevel = true, main_level = true, main = true, level = true }

local function isMainLevel(name)
  return MAIN_LEVEL_NAMES[(name:lower():gsub("[%s%-]", "_"))] == true
end

-- Warfare (l'escrime du jeu) se calcule aussi à partir des compétences d'armes :
-- on fixe ou on donne de l'XP à celles-ci à la place.
local WARFARE_NAMES = { warfare = true, fencing = true }

local function isWarfare(name)
  return WARFARE_NAMES[(name:lower():gsub("[%s%-]", "_"))] == true
end

local WARFARE_REFUSAL = "Warfare follows the weapon skills (swords, heavy weapons, polearms, unarmed, marksmanship) - set those. /perkpoints sets its points."

-- Arguments de commande qui n'ont pas pu être lus : joueur inconnu, ou l'usage.
local function badArgs(pid, reason, line)
  SendClientMessage(pid, COLOR_RED, tostring(reason):find("^no player") and "No such player." or "Usage: " .. line)
  return true
end

-- "warfare 8 (2 perk points)" pour une stat ou compétence de GetPlayerProgress.
local function progressEntry(name, v)
  local points = perkPoints(v.points)
  return fmt("%s %d", label(name), v.level) .. (points and " (" .. points .. ")" or "")
end

-- /skills : le niveau principal d'abord, puis les stats et compétences du joueur
-- telles que son jeu les a rapportées en dernier, avec les points de talent non
-- dépensés à côté de celles qui en ont ; /skills <nom> en montre une avec son XP.
local function showSkills(pid, name)
  if name ~= "" then
    local level, xp, need = GetPlayerStat(pid, name), nil, nil

    if level > 0 then
      xp, need = GetPlayerStatXP(pid, name)
    else
      level = GetPlayerSkill(pid, name)

      if level > 0 then
        xp, need = GetPlayerSkillXP(pid, name)
      end
    end

    local points = perkPoints(GetPlayerPerkPoints(pid, name))

    if level == 0 then
      SendClientMessage(pid, COLOR_RED, "No stat or skill of that name, or your game has not reported it yet: " .. name)
    elseif (need or 0) > 0 then
      say(pid, fmt("%s: level %d, %.0f of %.0f XP to the next", name, level, xp, need) .. (points and ", " .. points or ""))
    else
      say(pid, fmt("%s: level %d", name, level) .. (points and ", " .. points or ""))
    end

    return
  end

  local progress = GetPlayerProgress(pid)
  local main, stats, skills, names = progress and progress.stats.mainlevel, {}, {}, {}

  for _, stat in ipairs(STAT_ORDER) do
    local v = progress and progress.stats[stat]

    if v then
      stats[#stats + 1] = progressEntry(stat, v)
    end
  end

  for skill in pairs(progress and progress.skills or {}) do
    names[#names + 1] = skill
  end

  table.sort(names, function(a, b)
    return label(a) < label(b)
  end)

  for _, skill in ipairs(names) do
    skills[#skills + 1] = progressEntry(skill, progress.skills[skill])
  end

  if not main and #stats == 0 and #skills == 0 then
    say(pid, "Your game has not reported your skills yet - it does a few seconds after you spawn.")
    return
  end

  if main then
    local points = perkPoints(main.points)
    say(pid, fmt("Main level: %d", main.level) .. (points and " (" .. points .. ")" or ""))
  end

  if #stats > 0 then
    say(pid, "Stats: " .. table.concat(stats, ", "))
  end

  for i = 1, #skills, 10 do -- dix par ligne : la largeur du chat
    SendClientMessage(pid, COLOR_WHITE, (i == 1 and "Skills: " or "  ") .. table.concat(skills, ", ", i, math.min(i + 9, #skills)))
  end
end

-- /skills pour tous ; pour les admins : /setlevel <joueur> <stat|compétence> <niveau> [xp]
-- (niveau et XP fixés tels quels, en baisse aussi ; le niveau principal est
-- calculé par le jeu et refusé), /givexp <joueur> <stat|compétence> <xp> (à la
-- manière du jeu : avis de niveau, points de talent), /perk <joueur> add|remove
-- <talent> (un GUID, ou un nom de la liste des talents de la doc), /perkpoints
-- <joueur> <stat|compétence|mainlevel> <n> (points de talent non dépensés) et
-- /xprate [taux]. Le serveur résout les noms (warfare pour fencing ...).
-- Retourne true si la commande est une des siennes.
function progressCommand(pid, cmd, args)
  args = args or ""

  if cmd == "skills" then
    showSkills(pid, args:match("^%s*(.-)%s*$"))
    return true
  end

  if cmd ~= "setlevel" and cmd ~= "givexp" and cmd ~= "perk" and cmd ~= "perkpoints" and cmd ~= "xprate" then
    return false
  end

  if not IsPlayerAdmin(pid) then
    SendClientMessage(pid, COLOR_RED, "/" .. cmd .. " is for admins.")
    return true
  end

  if cmd == "setlevel" then
    local target, name, level, xp = sscanf(args, "usdf?")

    if target == false then
      return badArgs(pid, name, "/setlevel <player> <stat|skill> <level> [xp]")
    end

    if isMainLevel(name) then
      SendClientMessage(pid, COLOR_RED, "The main level cannot be set - the game works it out from the stats and skills. Set those, or use /perkpoints for its points.")
      return true
    end

    if isWarfare(name) then
      SendClientMessage(pid, COLOR_RED, WARFARE_REFUSAL)
      return true
    end

    if not (SetPlayerStat(target, name, level, xp) or SetPlayerSkill(target, name, level, xp)) then
      SendClientMessage(pid, COLOR_RED, "Not a stat or skill, or not a level from 0 to 30 - /skills lists the names.")
      return true
    end

    say(pid, fmt("%s: %s is level %d now.", GetPlayerName(target), name, level))

    if target ~= pid then
      say(target, fmt("%s set your %s to level %d.", GetPlayerName(pid), name, level))
    end

  elseif cmd == "givexp" then
    local target, name, xp = sscanf(args, "usf")

    if target == false then
      return badArgs(pid, name, "/givexp <player> <stat|skill> <xp>")
    end

    if isMainLevel(name) then
      SendClientMessage(pid, COLOR_RED, "The main level takes no XP of its own - give XP to a stat or a skill.")
      return true
    end

    if isWarfare(name) then
      SendClientMessage(pid, COLOR_RED, WARFARE_REFUSAL)
      return true
    end

    if xp <= 0 or xp > 100000 or not (AddPlayerStatXP(target, name, xp) or AddPlayerSkillXP(target, name, xp)) then
      SendClientMessage(pid, COLOR_RED, "Not a stat or skill, or not an XP amount above 0 and up to 100000 - /skills lists the names.")
      return true
    end

    say(pid, fmt("%s: %g XP in %s.", GetPlayerName(target), xp, name))

  elseif cmd == "perk" then
    local target, how, perk = sscanf(args, "usz")

    if target == false then
      return badArgs(pid, how, "/perk <player> add|remove <perk>")
    end

    how = how:lower()

    if how ~= "add" and how ~= "remove" then
      return badArgs(pid, "", "/perk <player> add|remove <perk>")
    end

    local ok

    if how == "add" then
      ok = AddPlayerPerk(target, perk)
    else
      ok = RemovePlayerPerk(target, perk)
    end

    if not ok then
      SendClientMessage(pid, COLOR_RED, "No such perk: " .. perk .. " - a GUID, or a name from the list at docs.kcd-mp.com/reference/perks/")
      return true
    end

    say(pid, fmt("%s: %s %s.", GetPlayerName(target), GetPerkName(perk) or perk, how == "add" and "added" or "taken away"))

  elseif cmd == "perkpoints" then
    local target, name, points = sscanf(args, "usd")

    if target == false then
      return badArgs(pid, name, "/perkpoints <player> <stat|skill|mainlevel> <points>")
    end

    if points < 0 or not SetPlayerPerkPoints(target, name, points) then
      SendClientMessage(pid, COLOR_RED, "Not a stat, a skill or mainlevel, or not a number of perk points the game takes (0 or more) - /skills lists the names.")
      return true
    end

    say(pid, fmt("%s: %s has %d perk point%s now.", GetPlayerName(target), name, points, points == 1 and "" or "s"))

    if target ~= pid then
      say(target, fmt("%s set your %s perk points to %d.", GetPlayerName(pid), name, points))
    end

  else -- /xprate [taux]
    local rate, why = sscanf(args, "f?")

    if rate == false then
      return badArgs(pid, why, "/xprate [rate from 0 to 100]")
    end

    if rate == nil then
      say(pid, fmt("The XP rate is %g - /xprate <rate from 0 to 100> changes it.", GetXPRate()))
      return true
    end

    if rate < 0 or rate > 100 then
      SendClientMessage(pid, COLOR_RED, "The XP rate is from 0 to 100.")
      return true
    end

    SetXPRate(rate)
    Log(fmt("kcRP: %s set the XP rate to %g", GetPlayerName(pid), rate))
    say(pid, fmt("The XP rate is %g now.", rate))
  end

  return true
end


-- ---------------------------------------------------------------------
-- /horsestat [stat niveau]
-- Le cheval que l'admin monte, sinon le sien : force, agilité, vitalité ou
-- courage (niveau 1 à 30 ; /horsestat seul les liste). Sauvegardé dans
-- horse_stats et remis quand /horse ramène le cheval.
-- ---------------------------------------------------------------------
local HORSE_STATS = { "strength", "agility", "vitality", "courage" }

function horseStat(pid, args)
  args = args or ""

  if not IsPlayerAdmin(pid) then
    SendClientMessage(pid, COLOR_RED, "/horsestat is for admins.")
    return true
  end

  local p = players[pid]
  local mount = GetPlayerMount(pid)
  local target = mount and GetEntityKind(mount) == ENTITY_HORSE and mount or ownHorse(pid)

  if not target then
    say(pid, "You have no horse - /horse brings one.")
    return true
  end

  -- Sans argument : liste des statistiques.
  if args == "" then
    local parts = {}

    for _, stat in ipairs(HORSE_STATS) do
      local level = GetHorseStat(target, stat)
      parts[#parts + 1] = fmt("%s %s", stat, level > 0 and fmt("%d", level) or "as bred")
    end

    say(pid, "The horse: " .. table.concat(parts, ", ") .. " - /horsestat <stat> <level>")
    return true
  end

  local stat, level = sscanf(args, "sd")

  if stat == false then
    return badArgs(pid, level, "/horsestat <strength|agility|vitality|courage> <level from 1 to 30>")
  end

  stat = stat:lower()

  local known = false

  for _, s in ipairs(HORSE_STATS) do
    known = known or s == stat
  end

  if not known or level < 1 or level > 30 then
    SendClientMessage(pid, COLOR_RED, "A horse has strength, agility, vitality and courage, each from level 1 to 30.")
    return true
  end

  local id = tonumber(GetEntityData(target, "db_id"))

  -- Son premier cheval : sa ligne est encore en cours de création.
  if not id and db and p and p.logged and target == ownHorse(pid) then
    say(pid, "Your horse is not in the books yet - try again in a moment.")
    return true
  end

  if not SetHorseStat(target, stat, level) then
    SendClientMessage(pid, COLOR_RED, "That horse will not take it.")
    return true
  end

  -- Un cheval qui a une ligne : la statistique est gardée pour la prochaine fois.
  if id and db then
    db:Batch({
      { "DELETE FROM horse_stats WHERE horse_id = @h AND stat = @s", { h = id, s = stat } },
      { "INSERT INTO horse_stats (horse_id, stat, level) VALUES (@h, @s, @l)", { h = id, s = stat, l = level } }
    }, function(ok, err)
      if not ok then
        Log("kcRP: the horse stat was not saved: " .. tostring(err))
      end
    end)

    local owner = players[GetHorseOwner(target) or -1]

    if owner then
      owner.horseStats = owner.horseStats or {}
      owner.horseStats[id] = owner.horseStats[id] or {}
      owner.horseStats[id][stat] = level
    end
  end

  say(pid, fmt("The horse's %s is level %d now.", stat, level))

  return true
end

-- ---------------------------------------------------------------------
-- /horsecoat [robe]
-- Le cheval que l'admin monte, sinon le sien : sa robe, une de GetHorseCoats()
-- (/horsecoat seul les liste). Sauvegardée dans player_horses et remise quand
-- /horse ramène le cheval.
-- ---------------------------------------------------------------------
function horseCoat(pid, args)
  args = args or ""

  if not IsPlayerAdmin(pid) then
    SendClientMessage(pid, COLOR_RED, "/horsecoat is for admins.")
    return true
  end

  local mount = GetPlayerMount(pid)
  local target = mount and GetEntityKind(mount) == ENTITY_HORSE and mount or ownHorse(pid)

  if not target then
    say(pid, "You have no horse - /horse brings one.")
    return true
  end

  local coat = args:lower():match("^%s*(%S+)")

  -- Sans argument : robe actuelle et liste des robes.
  if not coat then
    say(pid, fmt("The horse is %s - /horsecoat <%s>", GetHorseCoat(target) or "?", table.concat(GetHorseCoats(), "|")))
    return true
  end

  local id = tonumber(GetEntityData(target, "db_id"))
  local p = players[pid]

  -- Son premier cheval : sa ligne est encore en cours de création.
  if not id and db and p and p.logged and target == ownHorse(pid) then
    say(pid, "Your horse is not in the books yet - try again in a moment.")
    return true
  end

  if not SetHorseCoat(target, coat) then
    SendClientMessage(pid, COLOR_RED, "The coats: " .. table.concat(GetHorseCoats(), ", "))
    return true
  end

  coat = GetHorseCoat(target)

  -- Un cheval qui a une ligne : la robe est gardée pour la prochaine fois.
  if id and db then
    db:Execute("UPDATE player_horses SET coat = @c WHERE id = @h", { c = coat, h = id }, function(_, _, err)
      if err then
        Log("kcRP: the horse's coat was not saved: " .. tostring(err))
      end
    end)

    local owner = players[GetHorseOwner(target) or -1]

    if owner and owner.savedHorse and owner.savedHorse.dbId == id then
      owner.savedHorse.coat = coat
    end
  end

  say(pid, fmt("The horse is %s now.", coat))

  return true
end

-- ---------------------------------------------------------------------
-- Progression : lecture à la connexion
-- La progression sauvegardée est remise avec SetPlayerProgress. Une lecture
-- unique : les stats et compétences comme lignes de leur type, les talents
-- comme lignes du type "perk", et la nourriture et l'énergie depuis la ligne
-- players (row). Chaque stat et compétence revient avec niveau, XP et points
-- de talent non dépensés ; le niveau principal ("mainlevel") seulement avec ses
-- points, remis par SetPlayerPerkPoints - son niveau est celui que le jeu
-- calcule, jamais ordonné. Un personnage sans sauvegarde reste tel que le jeu
-- l'a fait et est sauvegardé dès son premier changement. Si la lecture
-- échoue, rien n'est sauvegardé par-dessus le personnage cette session.
-- ---------------------------------------------------------------------
function loadProgress(pid, p, row)
  db:Query("SELECT kind, name, level, xp, points FROM player_progress WHERE player_id = @p " ..
    "UNION ALL SELECT 'perk', perk, 0, 0, 0 FROM player_perks WHERE player_id = @q",
    { p = p.id, q = p.id },
    function(rows, err)
      if err then
        Log("kcRP: the progress of " .. p.name .. " could not be read: " .. err)
        return
      end

      if players[pid] ~= p then
        return
      end

      local progress = { stats = {}, skills = {}, perks = {}, nourishment = row.nourishment, energy = row.energy }
      local keys, perks, levels, mainPoints = {}, {}, 0, nil

      for _, r in ipairs(rows) do
        if r.kind == "perk" then
          if DISCOVERY.explorer == "strip" and r.name:lower() == EXPLORER_PERK then
            p.explorerSaved = true -- écarté de ce qui est remis ; sa ligne reste (saveProgress la garde)
          else
            progress.perks[#progress.perks + 1] = r.name
          end

          perks[r.name:lower()] = true
        elseif r.kind == "stat" or r.kind == "skill" then
          local level, xp, points = tonumber(r.level) or 0, tonumber(r.xp) or 0, tonumber(r.points) or 0

          if r.kind == "stat" and r.name == "mainlevel" then
            mainPoints = points -- la réserve seulement : le niveau découle des stats et compétences
          else
            progress[r.kind == "stat" and "stats" or "skills"][r.name] = { level = level, xp = xp, points = points }
          end

          keys[r.kind .. ":" .. r.name] = fmt("%d:%.1f:%d", level, xp, points)
          levels = levels + 1
        end
      end

      p.progressRows, p.perkSet = keys, perks -- ce que les tables contiennent : une sauvegarde écrit la différence
      p.vitalsKey = row.nourishment and row.energy and fmt("%.1f:%.1f", row.nourishment, row.energy) or nil

      if levels == 0 then
        -- Rien de sauvegardé (nouveau compte, ou d'avant la progression) : le départ du jeu est la première sauvegarde.
        p.progressFresh = true
        return
      end

      SetPlayerProgress(pid, progress)

      if mainPoints then
        SetPlayerPerkPoints(pid, "mainlevel", mainPoints)
      end

      p.progressReady = true

      Log(fmt("kcRP: %s's progress restored (%d stats and skills, %d perks)", GetPlayerName(pid), levels, #progress.perks))
    end)
end

-- Vrai quand la progression du personnage peut être sauvegardée : la sauvegarde
-- a été remise, ou il n'en avait pas et le jeu a rapporté la sienne.
local function progressReady(pid, p)
  if p.progressReady then
    return true
  end

  if not p.progressFresh then
    return false
  end

  local now = GetPlayerProgress(pid)

  if now and next(now.skills or {}) then
    p.progressReady = true
  end

  return p.progressReady == true
end

-- La progression en une transaction, seulement ce qui diffère de la dernière
-- sauvegarde : ligne de stat ou compétence dont le niveau, l'XP ou les points
-- ont changé (celle du niveau principal aussi), talents ajoutés ou retirés,
-- nourriture et énergie. Les valeurs sont lues maintenant, sur le tick ; les
-- écritures partent plus tard.
function saveProgress(pid)
  local p = players[pid]

  if not (db and p and p.logged and p.id) or p.staged or not progressReady(pid, p) then
    return
  end

  local now = GetPlayerProgress(pid)
  local stats, skills = now and now.stats or {}, now and now.skills or {}

  if next(stats) == nil and next(skills) == nil then
    return -- le jeu n'a encore rien rapporté
  end

  local batch, keys = {}, p.progressRows

  for _, group in ipairs({ { "stat", stats }, { "skill", skills } }) do
    for name, v in pairs(group[2]) do
      local points = v.points or 0
      local key = fmt("%d:%.1f:%d", v.level, v.xp or 0, points)
      local id = group[1] .. ":" .. name

      if keys[id] ~= key then
        keys[id] = key
        batch[#batch + 1] = {
          "DELETE FROM player_progress WHERE player_id = @id AND kind = @k AND name = @n",
          { id = p.id, k = group[1], n = name }
        }
        batch[#batch + 1] = {
          "INSERT INTO player_progress (player_id, kind, name, level, xp, points) VALUES (@id, @k, @n, @l, @x, @pt)",
          { id = p.id, k = group[1], n = name, l = math.floor(v.level), x = v.xp or 0, pt = math.floor(points) }
        }
      end
    end
  end

  local perks = {}

  for _, guid in ipairs(now.perks or {}) do
    perks[guid:lower()] = true
  end

  if p.explorerSaved and DISCOVERY.explorer == "strip" then
    perks[EXPLORER_PERK] = true -- écarté de la restauration, jamais retiré du personnage
  end

  local was = p.perkSet

  if was == nil then
    -- Après une sauvegarde ratée : les lignes sont réécrites en entier.
    batch[#batch + 1] = { "DELETE FROM player_perks WHERE player_id = @id", { id = p.id } }

    for guid in pairs(perks) do
      batch[#batch + 1] = { "INSERT INTO player_perks (player_id, perk) VALUES (@id, @g)", { id = p.id, g = guid } }
    end
  else
    for guid in pairs(perks) do
      if not was[guid] then
        batch[#batch + 1] = { "INSERT INTO player_perks (player_id, perk) VALUES (@id, @g)", { id = p.id, g = guid } }
      end
    end

    for guid in pairs(was) do
      if not perks[guid] then
        batch[#batch + 1] = { "DELETE FROM player_perks WHERE player_id = @id AND perk = @g", { id = p.id, g = guid } }
      end
    end
  end

  p.perkSet = perks

  if now.nourishment and now.energy then
    local key = fmt("%.1f:%.1f", now.nourishment, now.energy)

    if key ~= p.vitalsKey then
      p.vitalsKey = key
      batch[#batch + 1] = {
        "UPDATE players SET nourishment = @n, energy = @e WHERE id = @id",
        { n = now.nourishment, e = now.energy, id = p.id }
      }
    end
  end

  if #batch == 0 then
    return
  end

  db:Batch(batch, function(ok, err)
    if ok then
      return
    end

    Log("kcRP: the progress of " .. p.name .. " not saved: " .. tostring(err))
    p.progressRows, p.perkSet, p.vitalsKey = {}, nil, nil -- la prochaine sauvegarde réécrit tout
  end)
end

-- Le serveur a appris un changement de l'âme : un niveau ou un talent est
-- sauvegardé aussitôt, l'XP et la faim avec la ronde de la minute.
function OnPlayerProgressChange(pid, levels)
  local p = players[pid]

  if not (db and p and p.logged and p.id) then
    return
  end

  if p.progressFresh then
    p.progressReady = true -- rien n'était sauvegardé : le départ du jeu est leur première sauvegarde
  end

  if levels then
    saveProgress(pid)
  end
end

-- ---------------------------------------------------------------------
-- Ce qu'un personnage a trouvé
-- Les règles sont la table DISCOVERY plus haut. Le serveur enregistre ce que le
-- jeu d'un joueur rapporte (GetPlayerDiscovery : un bloc par type, des données
-- en base64 dans un format fixe et versionné) et ce mode le garde dans
-- player_discovery - une ligne par joueur, niveau et type, les livres sous le
-- niveau vide car le jeu les garde une fois pour tout - sauvegardé par la ronde
-- de la minute et au départ du joueur, seulement les types qui ont crû
-- (OnPlayerDiscoveryChange) et seulement si le texte diffère de la dernière
-- sauvegarde. À la connexion, les lignes sauvegardées sont remises avec
-- SetPlayerDiscovery, qui les ajoute à ce que le jeu du joueur tient (le
-- registre ne fait que croître). Rien n'est sauvegardé avant que les lignes
-- sauvegardées aient été remises (p.discoveryReady), ou - pour un personnage
-- sans lignes - avant que le jeu ait rapporté la sienne : un registre vide
-- seulement parce que le jeu n'a pas rapporté ne doit jamais remplacer un
-- sauvegardé, et une lecture ratée ne sauvegarde rien cette session.
-- ---------------------------------------------------------------------
local DISCOVERY_KINDS = { "places", "reading" } -- les types qu'une règle peut garder (épingle et légende ne le sont pas ici)
local discoveryOn = false                      -- une règle est active et sa table existe

-- Une règle garde-t-elle ce type ? (un nom qui n'est pas un type, "explorer"
-- compris, ne l'est pas.) Un seul test pour tous les usages d'une règle : une
-- valeur autre que true (un 1, par exemple) l'active pour la demande, la table,
-- la restauration et la sauvegarde.
local function kept(kind)
  for _, k in ipairs(DISCOVERY_KINDS) do
    if k == kind then
      return DISCOVERY[k] and true or false
    end
  end

  return false
end

-- Liste des types gardés par les règles actives.
local function discoveryKinds()
  local kinds = {}

  for _, kind in ipairs(DISCOVERY_KINDS) do
    if kept(kind) then
      kinds[#kinds + 1] = kind
    end
  end

  return kinds
end

-- Le jeu a-t-il rapporté un bloc entier d'un type gardé ? Le registre tient alors
-- son propre état et pas une supposition vide.
local function gameReported(pid)
  for _, kind in ipairs(discoveryKinds()) do
    if IsPlayerDiscoveryKnown(pid, kind) then
      return true
    end
  end

  return false
end

-- Marque les types d'un personnage pour la prochaine sauvegarde, chacun sur son
-- niveau (les livres n'en ont pas) : le registre du serveur peut tenir ce
-- qu'aucun appel de changement n'a annoncé - ce que le jeu a rapporté avant le
-- login, l'union d'une restauration, un changement encore dans sa fenêtre au
-- départ du joueur - donc le login, l'au revoir et l'arrêt les marquent tous ;
-- une ligne n'est écrite que si son texte diffère de la dernière sauvegarde.
function markDiscovery(pid)
  local p = players[pid]

  if not (discoveryOn and p) then
    return
  end

  local level = GetLevel():lower()
  p.discoveryDirty = p.discoveryDirty or {}

  for _, kind in ipairs(discoveryKinds()) do
    p.discoveryDirty[kind] = kind == "reading" and "" or level
  end

  -- Un personnage sans sauvegarde : le premier rapport de son jeu.
  if p.discoveryFresh and not p.discoveryReady and gameReported(pid) then
    p.discoveryReady = true
  end
end

-- Au démarrage, seulement si une règle est active : la table (pas de règle, pas
-- de table - une installation par défaut ne change rien et n'a besoin d'aucun
-- SQL) et les types demandés aux jeux des joueurs.
function setupDiscovery()
  local kinds = discoveryKinds()

  if #kinds == 0 then
    return
  end

  if not execInit("CREATE TABLE IF NOT EXISTS player_discovery (player_id INT NOT NULL, level VARCHAR(32) NOT NULL, kind VARCHAR(12) NOT NULL, " ..
      "format SMALLINT NOT NULL, data TEXT NOT NULL, updated VARCHAR(32), PRIMARY KEY (player_id, level, kind), " ..
      "FOREIGN KEY (player_id) REFERENCES players(id) ON DELETE CASCADE)", "the player_discovery table") then
    Log("kcRP: what characters find is not kept - the player_discovery table could not be made")
    return
  end

  discoveryOn = true
  SetDiscoveryTracking(kinds)
  Log("kcRP: keeping what characters find (" .. table.concat(kinds, ", ") .. ")")
end

-- À la connexion, après la progression : ce que le personnage a trouvé, remis.
-- Une lecture des lignes de ce niveau et des livres ; un personnage sans ligne
-- reste tel que le jeu l'a fait et est sauvegardé dès son premier rapport. Une
-- lecture qui échoue, ou une ligne que le serveur ne sait pas lire, ne
-- sauvegarde rien par-dessus le personnage cette session.
function loadDiscovery(pid, p)
  if not discoveryOn then
    return
  end

  local level = GetLevel():lower()

  db:Query("SELECT kind, level, format, data, updated FROM player_discovery WHERE player_id = @p AND (level = @l OR level = '')",
    { p = p.id, l = level },
    function(rows, err)
      if err then
        Log("kcRP: what " .. p.name .. " found could not be read: " .. err)
        return
      end

      if players[pid] ~= p then
        return
      end

      local record, saved, count = { level = level }, {}, 0

      for _, r in ipairs(rows) do
        if kept(r.kind) and r.data and r.data ~= "" then
          record[r.kind] = { format = tonumber(r.format) or 1, data = r.data }
          saved[r.kind .. "|" .. r.level] = r.data -- ce que la table tient maintenant : une sauvegarde écrit la différence
          count = count + 1
        end
      end

      p.discoveryRows = saved

      if count == 0 then
        p.discoveryFresh = true -- rien de sauvegardé : le premier rapport du jeu est la première sauvegarde

        -- Le jeu a rapporté avant la réponse de la lecture : aucun de nos appels de changement
        -- ne l'a entendu (le login n'était pas fait).
        if gameReported(pid) then
          p.discoveryReady = true
          markDiscovery(pid)
        end

        return
      end

      if SetPlayerDiscovery(pid, record) then
        p.discoveryReady = true
        markDiscovery(pid) -- le registre est maintenant l'union des lignes sauvegardées et de ce que le jeu tenait : une sauvegarde écrit la différence
        Log(fmt("kcRP: %s's places and books restored (%d kinds)", GetPlayerName(pid), count))
      else
        Log("kcRP: part of what " .. p.name .. " found could not be put back - nothing of it is saved this session")
      end
    end)
end

-- Le serveur a appris plus de choses : le type est marqué et écrit par la ronde de la minute et au départ du joueur.
function OnPlayerDiscoveryChange(pid, kind, level)
  local p = players[pid]

  if not (discoveryOn and db and p and p.logged and p.id) or not kept(kind) then
    return
  end

  if p.discoveryFresh then
    p.discoveryReady = true -- rien n'était sauvegardé : le premier rapport du jeu est la première sauvegarde
  end

  p.discoveryDirty = p.discoveryDirty or {}
  p.discoveryDirty[kind] = level
end

-- Réponse du jeu d'un joueur à une restauration : seul l'échec est journalisé.
function OnPlayerDiscoveryRestore(pid, kind, ok)
  if not ok then
    Log("kcRP: " .. (GetPlayerName(pid) or "a player") .. "'s game could not put back the " .. kind)
  end
end

-- Les types marqués sales dans une transaction, une ligne seulement si son texte
-- diffère de la dernière sauvegarde. Les valeurs sont lues maintenant, sur le
-- tick ; les écritures partent plus tard.
function saveDiscovery(pid)
  local p = players[pid]

  if not (discoveryOn and db and p and p.logged and p.id) or p.staged or not p.discoveryReady or not p.discoveryDirty then
    return
  end

  local dirty = p.discoveryDirty
  p.discoveryDirty = nil

  local record = GetPlayerDiscovery(pid)

  if not record then
    return
  end

  local batch, rows = {}, p.discoveryRows or {}
  p.discoveryRows = rows

  for kind, level in pairs(dirty) do
    local block, key = record[kind], kind .. "|" .. level

    if block and block.data ~= "" and rows[key] ~= block.data then
      rows[key] = block.data

      -- "updated" peut être un horodatage numérique ou déjà un texte : os.date n'accepte que le premier.
      local updated = type(block.updated) == "number" and block.updated or nil

      batch[#batch + 1] = {
        "DELETE FROM player_discovery WHERE player_id = @id AND level = @l AND kind = @k",
        { id = p.id, l = level, k = kind }
      }
      batch[#batch + 1] = {
        "INSERT INTO player_discovery (player_id, level, kind, format, data, updated) VALUES (@id, @l, @k, @f, @d, @u)",
        { id = p.id, l = level, k = kind, f = block.format, d = block.data, u = os.date("!%Y-%m-%dT%H:%M:%SZ", updated) }
      }
    end
  end

  if #batch == 0 then
    return
  end

  db:Batch(batch, function(ok, err)
    if ok then
      return
    end

    Log("kcRP: what " .. p.name .. " found was not saved: " .. tostring(err))

    p.discoveryRows = {} -- la prochaine sauvegarde réécrit tout
    p.discoveryDirty = p.discoveryDirty or {}

    for kind, level in pairs(dirty) do
      p.discoveryDirty[kind] = level
    end
  end)
end

-- ---------------------------------------------------------------------
-- Le lieu qu'un joueur a quitté
-- Les valeurs sont lues maintenant, sur le tick ; les écritures partent plus
-- tard sur un autre fil.
-- ---------------------------------------------------------------------
function savePlace(pid)
  local p = players[pid]

  -- Pas pendant qu'un nouveau personnage se crée dans son monde à lui : un
  -- compte plus ancien garde le lieu qu'il avait.
  if not db or not p or not p.logged or not p.id or p.staged or not IsPlayerInWorld(pid) then
    return
  end

  local x, y, z = GetPlayerPos(pid)

  db:Execute("UPDATE players SET x = @x, y = @y, z = @z, yaw = @yaw, level = @l, last_seen = @t WHERE id = @id",
    { x = x, y = y, z = z, yaw = GetPlayerYaw(pid), l = GetLevel(), t = os.date("!%Y-%m-%dT%H:%M:%SZ"), id = p.id },
    function(_, _, err)
      if err then
        Log("kcRP: the place of " .. p.name .. " was not saved: " .. err)
      end
    end)

  saveCarried(pid)   -- rien si rien n'a changé depuis la dernière sauvegarde
  saveProgress(pid)  -- idem pour stats, compétences, talents et états (XP et faim sont gardés ici, avec la minute)
  saveDiscovery(pid) -- et pour les lieux et livres trouvés
end

-- Sauvegarde le lieu de tous les joueurs (minuteur d'une minute).
function savePlaces()
  for pid in pairs(players) do
    savePlace(pid)
  end
end

-- Arrêt ou rechargement du mode : dernières sauvegardes, puis nettoyage des
-- acteurs créés par le mode (le marchand et, via son module, la forge).
-- Cette fonction est définie ICI, après le chargement des modules : un module
-- qui chaînerait OnGameModeExit sur son propre chargement serait écrasé.
-- C'est pourquoi la forge expose kcRP.Blacksmith.Shutdown, appelée ci-dessous.
function OnGameModeExit()
  for pid in pairs(players) do
    markDiscovery(pid) -- ce que les joueurs ont trouvé depuis leur dernière sauvegarde, annoncé ou non
  end

  savePlaces() -- au mieux : l'arrêt peut survenir avant les écritures, le minuteur de la minute couvre le reste

  if kcRP.Blacksmith and kcRP.Blacksmith.Shutdown then
    pcall(kcRP.Blacksmith.Shutdown)
  end

  if merchant then
    DestroyEntity(merchant)
    merchant = nil
  end

  if store then
    DestroyShop(store)
    store = nil
  end
end




