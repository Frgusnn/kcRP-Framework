// Demander le focus clavier + curseur
if (window.KcdMp) {
  KcdMp.focus({ cursor: true, keyboard: true });
}

const state = {
  cash: 0,
  bank: 0,
  total: 0
};

const elements = {
  cash: document.getElementById("player-cash"),
  bank: document.getElementById("player-bank"),
  total: document.getElementById("player-total"),
  depositAmount: document.getElementById("deposit-amount"),
  withdrawAmount: document.getElementById("withdraw-amount"),
  depositButton: document.getElementById("deposit-button"),
  withdrawButton: document.getElementById("withdraw-button"),
  closeButton: document.getElementById("close-button"),
  tabs: document.querySelectorAll(".tab"),
  tabContents: document.querySelectorAll(".tab-content")
};

function formatMoney(value) {
  return Number(value || 0).toLocaleString("fr-FR", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  });
}

function updateDisplay() {
  elements.cash.textContent = formatMoney(state.cash) + " G";
  elements.bank.textContent = formatMoney(state.bank) + " G";
  elements.total.textContent = formatMoney(state.cash + state.bank) + " G";
}

function requestClose() {
  console.log("=== Fermeture de la banque demandée ===");
  
  // Rendre le focus au jeu
  if (window.KcdMp && window.KcdMp.blur) {
    KcdMp.blur();
  }
  
  // Envoyer l'événement au serveur
  if (window.KcdMp) {
    KcdMp.emitServer("bank_close", { action: "close" });
  }
}

function deposit() {
  const amount = parseFloat(elements.depositAmount.value);
  
  if (!amount || amount <= 0) {
    console.log("Montant invalide pour dépôt");
    return;
  }
  
  if (amount > state.cash) {
    console.log("Fonds insuffisants en bourse");
    return;
  }
  
  console.log("Dépôt demandé:", amount);
  
  if (window.KcdMp) {
    KcdMp.emitServer("bank_deposit", { amount: amount });
  }
  
  elements.depositAmount.value = "";
}

function withdraw() {
  const amount = parseFloat(elements.withdrawAmount.value);
  
  if (!amount || amount <= 0) {
    console.log("Montant invalide pour retrait");
    return;
  }
  
  if (amount > state.bank) {
    console.log("Fonds insuffisants en banque");
    return;
  }
  
  console.log("Retrait demandé:", amount);
  
  if (window.KcdMp) {
    KcdMp.emitServer("bank_withdraw", { amount: amount });
  }
  
  elements.withdrawAmount.value = "";
}

function switchTab(tabName) {
  elements.tabs.forEach(tab => {
    tab.classList.toggle("active", tab.dataset.tab === tabName);
  });
  
  elements.tabContents.forEach(content => {
    content.classList.toggle("hidden", content.id !== "tab-" + tabName);
  });
}

// Initialisation avec KCD:MP
if (window.KcdMp) {
  console.log("KCD:MP SDK detected");
  
  // Recevoir les mises à jour du serveur
  window.KcdMp.onServer("bank_state", (data) => {
    console.log("Bank state update:", data);
    if (data && typeof data === "object") {
      state.cash = data.cash || 0;
      state.bank = data.bank || 0;
      updateDisplay();
    }
  });
}

// Event Listeners
elements.closeButton?.addEventListener("click", (event) => {
  event.preventDefault();
  event.stopPropagation();
  console.log("=== BOUTON X CLIQUÉ ===");
  requestClose();
});

elements.depositButton?.addEventListener("click", deposit);

elements.withdrawButton?.addEventListener("click", withdraw);

elements.tabs.forEach(tab => {
  tab.addEventListener("click", () => {
    switchTab(tab.dataset.tab);
  });
});

// Gestion des touches
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    event.preventDefault();
    requestClose();
  }
  
  if (event.key === "Enter") {
    const activeTab = document.querySelector(".tab.active");
    if (activeTab?.dataset.tab === "operations") {
      const focusedInput = document.activeElement;
      if (focusedInput === elements.depositAmount) {
        deposit();
      } else if (focusedInput === elements.withdrawAmount) {
        withdraw();
      }
    }
  }
});

console.log("Bank UI initialized");