// Demander le focus clavier + curseur
KcdMp.onServer("bank.state", (value) => {
  state.cash = Number(value.cash) || 0;
  state.bank = Number(value.bank) || 0;
  updateDisplay();
});

const state = {
  cash: 0,
  bank: 0
};

const $ = (id) => document.getElementById(id);

const elements = {
  cash: [$("cashSummary")],
  bank: [$("bankSummary")],
  total: [$("totalBalance")],
  depositAmount: $("depositAmount"),
  withdrawAmount: $("withdrawAmount"),
  depositButton: $("depositButton"),
  withdrawButton: $("withdrawButton"),
  closeButton: $("closeButton"),
  subtitle: document.querySelector(".subtitle"),
  tabs: document.querySelectorAll(".tab"),
  tabContents: document.querySelectorAll(".tab-content")
};

const DEFAULT_SUBTITLE = elements.subtitle ? elements.subtitle.textContent : "";
let statusTimer = null;

/* ---------- Affichage ---------- */

function formatMoney(value) {
  return Number(value || 0).toLocaleString("fr-FR", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  });
}

function setAll(nodes, text) {
  nodes.forEach((node) => {
    if (node) node.textContent = text;
  });
}

function updateDisplay() {
  setAll(elements.cash, formatMoney(state.cash));
  setAll(elements.bank, formatMoney(state.bank));
  setAll(elements.total, formatMoney(state.cash + state.bank));
}

function setStatus(text) {
  if (!elements.subtitle) return;
  elements.subtitle.textContent = text;
  clearTimeout(statusTimer);
  statusTimer = setTimeout(() => {
    elements.subtitle.textContent = DEFAULT_SUBTITLE;
  }, 3000);
}

/* ---------- Clavier dans les champs ---------- */

function takeKeyboard() {
  KcdMp.focus({ cursor: true, keyboard: true })
    .catch((e) => console.error("focus clavier refusé :", e));
}

function releaseKeyboard() {
  KcdMp.focus({ cursor: true, keyboard: false })
    .catch((e) => console.error("focus clavier :", e));
}

[elements.depositAmount, elements.withdrawAmount].forEach((input) => {
  input?.addEventListener("click", takeKeyboard);
  input?.addEventListener("focus", takeKeyboard);
  input?.addEventListener("blur", releaseKeyboard);
});

/* ---------- Actions ---------- */

function requestClose() {
  try {
    const result = KcdMp.emitServer("bank.close", {});
    if (result && typeof result.catch === "function") {
      result.catch((e) => console.error("bank.close refusé :", e));
    }
  } catch (e) {
    console.error("bank.close erreur :", e);
  }
}

function readAmount(input) {
  const amount = parseFloat(input.value);
  if (!amount || amount <= 0) {
    setStatus("Montant invalide.");
    return null;
  }
  return amount;
}

function deposit() {
  const amount = readAmount(elements.depositAmount);
  if (amount === null) return;
  KcdMp.emitServer("bank.deposit", { amount });
  elements.depositAmount.value = "";
}

function withdraw() {
  const amount = readAmount(elements.withdrawAmount);
  if (amount === null) return;
  KcdMp.emitServer("bank.withdraw", { amount });
  elements.withdrawAmount.value = "";
}

function switchTab(tabName) {
  elements.tabs.forEach((tab) => {
    tab.classList.toggle("active", tab.dataset.tab === tabName);
  });
  elements.tabContents.forEach((content) => {
    content.classList.toggle("hidden", content.id !== "tab-" + tabName);
  });
}

/* ---------- Données du serveur ---------- */

function applyState(data) {
  if (!data || typeof data !== "object") return;
  state.cash = Number(data.cash) || 0;
  state.bank = Number(data.bank) || 0;
  updateDisplay();
}

if (window.KcdMp) {
  console.log("KCD:MP SDK detected");
  KcdMp.onServer("bank.state", applyState);
  KcdMp.onServer("bank_state", applyState);
}

/* ---------- Événements ---------- */

elements.closeButton?.addEventListener("click", (event) => {
  event.preventDefault();
  event.stopPropagation();
  requestClose();
});

elements.depositButton?.addEventListener("click", deposit);
elements.withdrawButton?.addEventListener("click", withdraw);

elements.tabs.forEach((tab) => {
  tab.addEventListener("click", () => switchTab(tab.dataset.tab));
});

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    requestClose();
    return;
  }

  if (event.key === "Enter") {
    if (document.activeElement === elements.depositAmount) deposit();
    else if (document.activeElement === elements.withdrawAmount) withdraw();
  }
});

updateDisplay();
console.log("Bank UI initialized");