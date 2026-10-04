-- =====================================================================
-- kcRP - Boutique de plans de forge (serveur)
-- Le maître forgeron vend des croquis NATIFS de KCD2 à 100 Groschen.
-- Le joueur lit le croquis ; la forge native du jeu s'occupe ensuite du craft.
--
--  * Catalogue construit au démarrage depuis le catalogue d'objets du serveur
--    (FindItems), avec filtres et paliers de rang - rien n'est codé en dur.
--  * Trois boutiques cumulatives : Apprenti (palier 1), Compagnon (2),
--    Maître / Propriétaire (3). Le joueur ouvre celle de son rang.
--  * Accès réservé aux membres de la compagnie (contrôlé à l'ouverture, puis
--    à l'ouverture de l'écran, puis à chaque achat).
--  * Un seul exemplaire par personnage (réglable) ; chaque achat est
--    journalisé en base et peut être crédité à la caisse de la compagnie.
-- Dépend de : companies.lua (IsCompanyMember, Forge), blacksmith.lua.
-- =====================================================================

kcRP = kcRP or {}

local ForgeShop = {}

-- ---------------------------------------------------------------------
-- Configuration - à adapter ici
-- ---------------------------------------------------------------------
local CONFIG = {
  basePrice = 100,            -- prix d'un croquis en Groschen
  filter = "sketch",          -- motif cherché dans le catalogue d'objets
  maxResults = 500,           -- nombre maximum d'objets lus
  exclude = {},               -- fragments (minuscules) de noms à ne PAS vendre, ex. { "armourer", "caster" }
  priceOverrides = {},        -- prix particuliers : [classe GUID en minuscules] = prix
  defaultTier = 2,            -- palier des croquis qu'aucune règle ci-dessous ne classe
  -- Règles de palier : le premier fragment trouvé dans le nom décide.
  tierRules = {
    { tier = 1, keywords = { "horseshoe", "work axe", "carpenter" } },
    { tier = 3, keywords = { "longsword", "falchion", "sabre", "shashka", "executioner" } }
  },
  oneCopyPerCharacter = true, -- true : un personnage n'achète un croquis qu'une fois
  creditCompany = true        -- true : l'argent des ventes est ajouté à la caisse de la compagnie
}

local Forge = (kcRP.Companies and kcRP.Companies.Forge) or {}
local COMPANY_CODE = Forge.code or "blacksmith_kuttenberg"

local TIER_TITLES = { "Plans de forge - Apprenti", "Plans de forge - Compagnon", "Plans de forge - Maître" }
local ROLE_TIER = { apprentice = 1, smith = 2, master = 3, owner = 3 }

local catalogue = {}         -- liste des croquis : { class, label, tier, price }
local byClass = {}           -- classe en minuscules -> entrée du catalogue
local shopsByTier = {}       -- palier -> id de boutique
local tierOfShop = {}        -- id de boutique -> palier
local purchased = {}         -- id de personnage -> { classe en minuscules = true }

-- ---------------------------------------------------------------------
-- Utilitaires
-- ---------------------------------------------------------------------

-- Handle de base de données du mode.
local function getDatabase()
  return GetDatabase()
end

-- Date UTC ISO 8601.
local function utcNow()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- Palier d'un rang de compagnie (0 si inconnu).
local function tierOfRole(role)
  return ROLE_TIER[role] or 0
end

-- Identifiant de personnage (players.id) d'un joueur connecté.
local function getCharacterId(pid)
  local getPlayer = kcRP.Functions and kcRP.Functions.GetPlayer
  local player = getPlayer and getPlayer(pid) or nil

  return player and player.PlayerData and player.PlayerData.characterId or nil
end

-- Vrai si le texte contient l'un des fragments donnés.
local function containsAny(text, fragments)
  for _, fragment in ipairs(fragments) do
    if text:find(fragment, 1, true) then
      return true
    end
  end

  return false
end

-- Palier d'un croquis d'après son nom.
local function tierOfName(text)
  for _, rule in ipairs(CONFIG.tierRules) do
    if containsAny(text, rule.keywords) then
      return rule.tier
    end
  end

  return CONFIG.defaultTier
end

-- ---------------------------------------------------------------------
-- Catalogue et boutiques
-- ---------------------------------------------------------------------

-- Lit le catalogue d'objets du serveur et en tire la liste des croquis.
local function buildCatalogue()
  catalogue, byClass = {}, {}

  for _, entry in ipairs(FindItems(CONFIG.filter, CONFIG.maxResults) or {}) do
    local class = entry.class and entry.class:lower() or nil
    local label = (entry.display and entry.display ~= "") and entry.display or (entry.name or "")
    local lowered = (label .. " " .. (entry.name or "")):lower()

    -- Seuls les vrais croquis : le motif de FindItems cherche aussi dans la catégorie.
    if class and not byClass[class] and lowered:find("sketch", 1, true)
      and not containsAny(lowered, CONFIG.exclude) then

      local item = {
        class = entry.class,
        label = label,
        tier = tierOfName(lowered),
        price = CONFIG.priceOverrides[class] or CONFIG.basePrice
      }

      catalogue[#catalogue + 1] = item
      byClass[class] = item
    end
  end

  table.sort(catalogue, function(a, b)
    if a.tier ~= b.tier then
      return a.tier < b.tier
    end

    return a.label < b.label
  end)
end

-- (Re)crée les trois boutiques cumulatives à partir du catalogue.
local function createShops()
  for _, shop in pairs(shopsByTier) do
    DestroyShop(shop)
  end

  shopsByTier, tierOfShop = {}, {}

  for tier = 1, 3 do
    -- sellFactor 0 : la boutique ne rachète rien ; bourse illimitée.
    local shop = CreateShop(TIER_TITLES[tier], 0)

    if shop then
      for _, item in ipairs(catalogue) do
        if item.tier <= tier then
          SetShopItem(shop, item.class, item.price)
        end
      end

      shopsByTier[tier] = shop
      tierOfShop[shop] = tier
    else
      Log("kcRP: forge shop tier " .. tier .. " could not be created")
    end
  end

  Log(string.format("kcRP: forge shops ready (%d sketches)", #catalogue))
end

-- Reconstruit catalogue et boutiques (démarrage et /forgeshop reload).
function ForgeShop.Rebuild()
  buildCatalogue()
  createShops()
end

-- ---------------------------------------------------------------------
-- Base de données : journal des achats
-- ---------------------------------------------------------------------

-- Crée la table forge_sketch_purchases si nécessaire.
local function createTable()
  local database = getDatabase()

  if not database then
    return
  end

  database:Execute([[
    CREATE TABLE IF NOT EXISTS forge_sketch_purchases (
      id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
      character_id INT NOT NULL,
      item_class VARCHAR(64) NOT NULL,
      item_label VARCHAR(128),
      price DOUBLE PRECISION NOT NULL,
      created_at VARCHAR(32),
      KEY forge_sketch_purchases_character (character_id),
      FOREIGN KEY (character_id) REFERENCES players(id) ON DELETE CASCADE
    )
  ]], {}, function(_, _, err)
    if err then
      Log("kcRP: forge_sketch_purchases table creation failed: " .. tostring(err))
    end
  end)
end

-- Charge en mémoire les croquis déjà achetés par un personnage. callback() à la fin.
local function loadPurchases(characterId, callback)
  if purchased[characterId] then
    callback()
    return
  end

  local database = getDatabase()

  if not database then
    purchased[characterId] = {}
    callback()
    return
  end

  database:Query(
    "SELECT item_class FROM forge_sketch_purchases WHERE character_id = @character_id",
    { character_id = characterId },
    function(rows, err)
      if err then
        Log("kcRP: forge purchases load failed: " .. tostring(err))
      end

      local set = {}

      for _, row in ipairs(rows or {}) do
        set[tostring(row.item_class):lower()] = true
      end

      purchased[characterId] = set
      callback()
    end
  )
end

-- Enregistre un achat et crédite la caisse de la compagnie.
local function recordPurchase(characterId, item, price)
  local database = getDatabase()

  purchased[characterId] = purchased[characterId] or {}
  purchased[characterId][item.class:lower()] = true

  if not database then
    return
  end

  database:Execute(
    [[
      INSERT INTO forge_sketch_purchases (character_id, item_class, item_label, price, created_at)
      VALUES (@character_id, @item_class, @item_label, @price, @created_at)
    ]],
    {
      character_id = characterId,
      item_class = item.class,
      item_label = item.label,
      price = price,
      created_at = utcNow()
    },
    function(_, _, err)
      if err then
        Log("kcRP: forge purchase log failed: " .. tostring(err))
      end
    end
  )

  if CONFIG.creditCompany then
    database:Execute(
      "UPDATE companies SET bank_balance = bank_balance + @amount, updated_at = @updated_at WHERE code = @code",
      { amount = price, updated_at = utcNow(), code = COMPANY_CODE },
      function(_, _, err)
        if err then
          Log("kcRP: forge company credit failed: " .. tostring(err))
        end
      end
    )
  end
end

local WATCH_MS = 1000       -- intervalle de contrôle de la distance
local MAX_DISTANCE = 4.0    -- mètres entre le joueur et le PNJ avant fermeture

-- Ferme l'écran de boutique quand le joueur s'éloigne du maître forgeron.
-- Un minuteur à usage unique est reprogrammé tant que l'écran est ouvert.
local function watchShopDistance(pid)
  SetTimer(function()
    if not IsPlayerConnected(pid) then
      return
    end

    local shop = GetPlayerShop(pid)

    if not shop or not tierOfShop[shop] then
      return -- l'écran est fermé : on arrête de surveiller
    end

    local npcId = kcRP.Blacksmith and kcRP.Blacksmith.GetNpcId and kcRP.Blacksmith.GetNpcId() or nil
    local nx, ny

    if npcId then
      nx, ny = GetEntityPos(npcId)
    end

    local x, y = GetPlayerPos(pid)

    if not nx or not x or math.sqrt((nx - x) ^ 2 + (ny - y) ^ 2) > MAX_DISTANCE then
      CloseShop(pid)
      return
    end

    watchShopDistance(pid)
  end, WATCH_MS, false)
end

-- ---------------------------------------------------------------------
-- Ouverture de la boutique (appelée par le menu du PNJ)
-- ---------------------------------------------------------------------

-- Vérifie le rang du joueur, charge ses achats, puis ouvre la boutique de son palier.
function ForgeShop.Open(pid)
  if not (kcRP.Functions and kcRP.Functions.IsCompanyMember) then
    SendClientMessage(pid, COLOR_RED, "Le système d'entreprise n'est pas disponible.")
    return
  end

  local characterId = getCharacterId(pid)

  if not characterId then
    SendClientMessage(pid, COLOR_RED, "Personnage non chargé.")
    return
  end

  kcRP.Functions.IsCompanyMember(pid, COMPANY_CODE, function(isMember, role, err)
    if not IsPlayerConnected(pid) then
      return
    end

    if err or not isMember then
      SendClientMessage(pid, COLOR_RED, "Cette boutique est réservée aux membres de la Forge de Kuttenberg.")
      return
    end

    local tier = tierOfRole(role)
    local shop = shopsByTier[tier]

    if not shop or #catalogue == 0 then
      SendClientMessage(pid, COLOR_RED, "La boutique de plans est vide pour le moment.")
      return
    end

    loadPurchases(characterId, function()
      if not IsPlayerConnected(pid) then
        return
      end

      -- Le palier est mémorisé : OnPlayerOpenShop et OnPlayerBuy le revérifient de façon synchrone.
      SetPlayerData(pid, "kcrp_forge_tier", tier)

      if OpenShop(pid, shop) then
        watchShopDistance(pid)
      end
    end)
  end)
end

-- ---------------------------------------------------------------------
-- Callbacks de boutique (chaînés avec ceux de kcRP.lua : marchand du spawn)
-- ---------------------------------------------------------------------

-- Ouverture d'un écran de boutique : une boutique de plans ne s'ouvre que pour un joueur autorisé.
local previousOpenShop = OnPlayerOpenShop

function OnPlayerOpenShop(pid, shop, vendor)
  local tier = tierOfShop[shop]

  if tier then
    if (GetPlayerData(pid, "kcrp_forge_tier") or 0) < tier then
      SendClientMessage(pid, COLOR_RED, "Vous n'avez pas accès à cette boutique.")
      return false
    end

    return true
  end

  if previousOpenShop then
    return previousOpenShop(pid, shop, vendor)
  end
end

-- Achat d'une ligne : un seul exemplaire, palier suffisant, pas de doublon.
local previousBuy = OnPlayerBuy

function OnPlayerBuy(pid, shop, class, amount, price)
  local tier = tierOfShop[shop]

  if not tier then
    if previousBuy then
      return previousBuy(pid, shop, class, amount, price)
    end

    return true
  end

  local item = byClass[tostring(class):lower()]

  if not item or (GetPlayerData(pid, "kcrp_forge_tier") or 0) < item.tier then
    SendClientMessage(pid, COLOR_RED, "Ce plan est réservé à un rang supérieur.")
    return false
  end

  if amount ~= 1 then
    SendClientMessage(pid, COLOR_RED, "Un seul exemplaire de chaque plan à la fois.")
    return false
  end

  local characterId = getCharacterId(pid)

  if CONFIG.oneCopyPerCharacter and characterId
    and purchased[characterId] and purchased[characterId][item.class:lower()] then
    SendClientMessage(pid, COLOR_RED, "Vous avez déjà acheté ce plan.")
    return false
  end

  return true
end

-- Transaction acceptée : journalisation des achats (appelée après toutes les vérifications).
local previousShopDeal = OnPlayerShopDeal

function OnPlayerShopDeal(pid, shop, deal)
  if not tierOfShop[shop] then
    if previousShopDeal then
      return previousShopDeal(pid, shop, deal)
    end

    return true
  end

  local characterId = getCharacterId(pid)

  if characterId then
    for _, line in ipairs(deal.lines or {}) do
      local item = line.buy and byClass[tostring(line.class):lower()] or nil

      if item then
        recordPurchase(characterId, item, line.price * (line.amount or 1))

        Log(string.format("kcRP: %s bought the sketch '%s' for %s Groschen",
          GetPlayerName(pid), item.label, tostring(line.price)))
      end
    end
  end

  return true
end

-- ---------------------------------------------------------------------
-- Commande administrateur : /forgeshop list | reload
-- Retourne true si la commande a été traitée (appelée par kcRP.lua).
-- ---------------------------------------------------------------------
function ForgeShop.HandleCommand(pid, cmd, args)
  if cmd ~= "forgeshop" then
    return false
  end

  if not IsPlayerAdmin(pid) then
    SendClientMessage(pid, COLOR_RED, "/forgeshop est réservé aux administrateurs.")
    return true
  end

  local word = ((args or ""):match("^%s*(%S*)") or ""):lower()

  if word == "reload" then
    ForgeShop.Rebuild()
    SendClientMessage(pid, COLOR_GREEN, string.format("Boutique de plans reconstruite : %d plans.", #catalogue))
    return true
  end

  if word == "list" then
    SendClientMessage(pid, COLOR_GOLD, string.format("----- %d plans (détail dans server.log) -----", #catalogue))

    for index, item in ipairs(catalogue) do
      Log(string.format("kcRP: forge sketch #%d | tier %d | %s G | %s | %s",
        index, item.tier, tostring(item.price), item.label, item.class))

      if index <= 12 then
        SendClientMessage(pid, COLOR_WHITE, string.format("[%d] %s - %s G", item.tier, item.label, tostring(item.price)))
      end
    end

    return true
  end

  SendClientMessage(pid, COLOR_GOLD, "Usage : /forgeshop list | /forgeshop reload")

  return true
end

-- ---------------------------------------------------------------------
-- Démarrage
-- ---------------------------------------------------------------------
local previousGameModeInit = OnGameModeInit

function OnGameModeInit()
  if previousGameModeInit then
    previousGameModeInit()
  end

  createTable()
  ForgeShop.Rebuild()
end

kcRP.ForgeShop = ForgeShop

local previousCommandText = OnPlayerCommandText

function OnPlayerCommandText(pid, cmd, args)
  if cmd == "forgeregister" then
    local ok = ShowPlayerWebFrame(pid, "forge-register")

    if not ok then
      SendClientMessage(
        pid,
        COLOR_RED,
        "Impossible d'ouvrir le Registre de la Forge."
      )
    end

    return true
  end

  if previousCommandText then
    return previousCommandText(pid, cmd, args)
  end

  return false
end

Log("kcRP: forge shop module loaded")
