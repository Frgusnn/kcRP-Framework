const state = {
  sketches: [],
  selected: null,
  filter: "all",
  search: "",
  money: 0,
  rank: "Membre de la Forge",
  known: new Set()
};

const elements = {
  list: document.getElementById("sketch-list"),
  search: document.getElementById("search"),
  count: document.getElementById("catalogue-count"),
  money: document.getElementById("player-money"),
  rank: document.getElementById("player-rank"),
  knownCount: document.getElementById("known-count"),
  empty: document.getElementById("detail-empty"),
  detail: document.getElementById("detail-content"),
  tier: document.getElementById("detail-tier"),
  name: document.getElementById("detail-name"),
  price: document.getElementById("detail-price"),
  requiredRank: document.getElementById("detail-rank"),
  status: document.getElementById("detail-status"),
  buy: document.getElementById("buy-button")
};

const tierNames = {
  1: "Apprenti",
  2: "Compagnon",
  3: "Maître forgeron"
};

function formatMoney(value) {
  return Number(value || 0).toLocaleString("fr-FR", {
    minimumFractionDigits: 0,
    maximumFractionDigits: 1
  });
}

function getCategory(sketch) {
  const name = `${sketch.name || ""} ${sketch.label || ""}`.toLowerCase();

  if (name.includes("horseshoe")) return "horseshoe";
  if (name.includes("longsword")) return "longsword";
  if (name.includes("sword") || name.includes("sabre") || name.includes("falchion")) return "sword";
  if (name.includes("axe")) return "axe";

  return "all";
}

function getVisibleSketches() {
  const search = state.search.toLowerCase().trim();

  return state.sketches.filter((sketch) => {
    const category = getCategory(sketch);
    const matchesFilter = state.filter === "all" || category === state.filter;
    const haystack = `${sketch.label || ""} ${sketch.name || ""}`.toLowerCase();
    const matchesSearch = !search || haystack.includes(search);

    return matchesFilter && matchesSearch;
  });
}

function renderList() {
  const sketches = getVisibleSketches();

  elements.count.textContent = `${sketches.length} plan${sketches.length > 1 ? "s" : ""}`;

  if (!sketches.length) {
    elements.list.innerHTML = `
      <div class="empty-state">
        <span>⚒</span>
        <p>Aucun croquis ne correspond à cette recherche.</p>
      </div>
    `;
    return;
  }

  elements.list.innerHTML = "";

  for (const sketch of sketches) {
    const known = state.known.has(sketch.class);
    const selected = state.selected && state.selected.class === sketch.class;
    const locked = Number(sketch.tier || 1) > Number(state.playerTier || 1);

    const row = document.createElement("button");
    row.type = "button";
    row.className = `sketch-row${selected ? " selected" : ""}${known ? " known" : ""}${locked ? " locked" : ""}`;

    row.innerHTML = `
      <span class="sketch-icon">⚒</span>
      <span>
        <span class="sketch-name">${sketch.label || sketch.name}</span>
        <span class="sketch-meta">${tierNames[sketch.tier] || "Forgeron"}${known ? " · Acquis" : locked ? " · Rang insuffisant" : ""}</span>
      </span>
      <span class="sketch-price">${formatMoney(sketch.price)} G</span>
    `;

    row.addEventListener("click", () => {
      state.selected = sketch;
      renderList();
      renderDetail();
    });

    elements.list.appendChild(row);
  }
}

function renderDetail() {
  const sketch = state.selected;

  if (!sketch) {
    elements.empty.classList.remove("hidden");
    elements.detail.classList.add("hidden");
    return;
  }

  const known = state.known.has(sketch.class);
  const locked = Number(sketch.tier || 1) > Number(state.playerTier || 1);
  const canAfford = Number(state.money || 0) >= Number(sketch.price || 0);
  const canBuy = !known && !locked && canAfford;

  elements.empty.classList.add("hidden");
  elements.detail.classList.remove("hidden");

  elements.tier.textContent = tierNames[sketch.tier] || "Forgeron";
  elements.name.textContent = sketch.label || sketch.name;
  elements.price.textContent = formatMoney(sketch.price);
  elements.requiredRank.textContent = tierNames[sketch.tier] || "Forgeron";

  if (known) {
    elements.status.textContent = "Déjà acquis";
  } else if (locked) {
    elements.status.textContent = "Rang insuffisant";
  } else if (!canAfford) {
    elements.status.textContent = "Fonds insuffisants";
  } else {
    elements.status.textContent = "Disponible";
  }

  elements.buy.disabled = !canBuy;
  elements.buy.textContent = known
    ? "Croquis déjà acquis"
    : locked
      ? "Rang de guilde insuffisant"
      : !canAfford
        ? "Groschen insuffisants"
        : `Acheter — ${formatMoney(sketch.price)} G`;
}

function renderHeader() {
  elements.money.textContent = formatMoney(state.money);
  elements.rank.textContent = state.rank;
  elements.knownCount.textContent =
    `${state.known.size} croquis connu${state.known.size > 1 ? "s" : ""}`;
}

const closeButton = document.getElementById("close-button");

function requestClose() {
  document.body.classList.add("is-closing");

  console.log("Bouton de fermeture du registre cliqué");

  /*
    Diagnostic temporaire :
    la croix doit devenir inactive/transparente avec le CSS .is-closing.
    Ne pas appeler KcdMp.call("close") : aucune action "close"
    n'a encore été confirmée pour une frame Web personnalisée.
  */
}

closeButton?.addEventListener("click", (event) => {
  event.preventDefault();
  event.stopPropagation();

  requestClose();
});

function render() {
  renderHeader();
  renderList();
  renderDetail();
}

document.querySelectorAll(".filter").forEach((button) => {
  button.addEventListener("click", () => {
    state.filter = button.dataset.filter;

    document.querySelectorAll(".filter").forEach((item) => {
      item.classList.toggle("active", item === button);
    });

    renderList();
  });
});

elements.search.addEventListener("input", (event) => {
  state.search = event.target.value;
  renderList();
});

elements.buy.addEventListener("click", () => {
  if (!state.selected) return;

  // L'achat réel sera ajouté dans l'étape suivante.
  // Ici, la page confirme seulement que le bouton et l'état fonctionnent.
  elements.status.textContent = "Demande d'achat prête à être envoyée.";
});

/*
  Étape suivante :
  la page recevra le catalogue réel depuis le serveur et postera l'achat
  via l'API KcdMp. Pour tester la maquette maintenant, nous injectons
  volontairement trois faux croquis visuels.
*/
state.money = 839.1;
state.rank = "Maître forgeron";
state.playerTier = 3;
state.sketches = [
  {
    class: "preview_work_axe",
    name: "Sketch - Work Axe",
    label: "Croquis — Hache de travail",
    tier: 1,
    price: 100
  },
  {
    class: "preview_battle_longsword",
    name: "Sketch - Battle Longsword",
    label: "Croquis — Épée longue de combat",
    tier: 2,
    price: 100
  },
  {
    class: "preview_knight_horseshoes",
    name: "Sketch - Knight Horseshoes",
    label: "Croquis — Fers de chevalier",
    tier: 3,
    price: 100
  }
];

state.known.add("preview_work_axe");
render();

KcdMp.onPlayerCursor((shown) => {
  document.body.classList.toggle("clickable", shown);
  document.body.classList.toggle("web-focused", shown);

  KcdMp.focus({
    cursor: shown
  }).catch((error) => {
    console.error("Impossible de donner le focus à la frame :", error);
  });

  if (!shown) {
    elements.search?.blur();
  }
});

elements.search?.addEventListener("click", () => {
  elements.search.focus();
});
