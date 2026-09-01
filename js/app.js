(() => {
  "use strict";

  const cfg = window.RIFA_CONFIG;
  const db = window.supabaseClient;
  const PENDING_KEY = "rifa_infinitepay_pending_v2";

  const state = {
    selected: new Set(),
    numbers: new Map(),
    raffleState: null,
    ready: false,
    channel: null,
    pending: loadPending()
  };

  const $ = (id) => document.getElementById(id);
  const el = {
    grid: $("numberGrid"),
    loading: $("loadingNumbers"),
    available: $("availableCount"),
    pendingCount: $("pendingCount"),
    paid: $("paidCount"),
    progressBar: $("progressBar"),
    progressText: $("progressText"),
    selectedNumbers: $("selectedNumbers"),
    selectedTotal: $("selectedTotal"),
    clear: $("clearSelectionBtn"),
    form: $("purchaseForm"),
    name: $("nameInput"),
    phone: $("phoneInput"),
    purchaseButton: $("purchaseButton"),
    unavailableList: $("unavailableList"),
    badge: $("connectionBadge"),
    setupWarning: $("setupWarning"),
    toast: $("toast"),
    winnerPublic: $("winnerPublic"),
    winnerPublicNumber: $("winnerPublicNumber"),
    countDays: $("countDays"),
    countHours: $("countHours"),
    countMinutes: $("countMinutes"),
    countSeconds: $("countSeconds"),
    paymentCard: $("paymentStatusCard"),
    paymentTitle: $("paymentStatusTitle"),
    paymentText: $("paymentStatusText"),
    continuePayment: $("continuePaymentBtn"),
    receiptLink: $("receiptLink")
  };

  function pad(n) { return String(n).padStart(3, "0"); }
  function digits(value) { return String(value || "").replace(/\D/g, ""); }
  function money(cents) {
    return new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" }).format((Number(cents) || 0) / 100);
  }

  function loadPending() {
    try { return JSON.parse(localStorage.getItem(PENDING_KEY) || "null"); }
    catch { return null; }
  }

  function savePending(value) {
    state.pending = value;
    if (value) localStorage.setItem(PENDING_KEY, JSON.stringify(value));
    else localStorage.removeItem(PENDING_KEY);
  }

  function showToast(message, kind = "normal") {
    el.toast.textContent = message;
    el.toast.dataset.kind = kind;
    el.toast.classList.add("toast--show");
    clearTimeout(showToast.timer);
    showToast.timer = setTimeout(() => el.toast.classList.remove("toast--show"), 3600);
  }

  function setConnection(text, ok = false) {
    el.badge.textContent = text;
    el.badge.classList.toggle("connection-badge--ok", ok);
  }

  function showSetupError() {
    el.setupWarning.classList.remove("hidden");
    setConnection("Banco não instalado");
    el.loading.textContent = "O banco do Supabase ainda precisa ser atualizado.";
  }

  function showPaymentCard(type, title, text, options = {}) {
    el.paymentCard.classList.remove("hidden", "payment-status-card--success", "payment-status-card--warning", "payment-status-card--error");
    if (type) el.paymentCard.classList.add(`payment-status-card--${type}`);
    el.paymentTitle.textContent = title;
    el.paymentText.textContent = text;
    el.continuePayment.classList.toggle("hidden", !options.continuePayment);
    el.receiptLink.classList.toggle("hidden", !options.receiptUrl);
    if (options.receiptUrl) el.receiptLink.href = options.receiptUrl;
  }

  async function loadAll() {
    setConnection("Sincronizando...");
    const [numbersRes, stateRes] = await Promise.all([
      db.from("raffle_numbers").select("number,status").order("number"),
      db.from("raffle_public_state").select("sales_closed,draw_at,instagram_handle,winner_number,drawn_at").eq("id", 1).single()
    ]);

    if (numbersRes.error || stateRes.error) {
      console.error(numbersRes.error || stateRes.error);
      showSetupError();
      return;
    }

    state.numbers = new Map(numbersRes.data.map(row => [Number(row.number), row.status]));
    state.raffleState = stateRes.data;
    state.ready = true;
    el.loading.classList.add("hidden");
    el.grid.classList.remove("hidden");
    setConnection("Ao vivo", true);
    renderAll();
    subscribeRealtime();
  }

  function subscribeRealtime() {
    if (state.channel) db.removeChannel(state.channel);
    state.channel = db.channel("rifa-public-live")
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "raffle_numbers" }, payload => {
        state.numbers.set(Number(payload.new.number), payload.new.status);
        if (payload.new.status !== "available") state.selected.delete(Number(payload.new.number));
        renderAll();
      })
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "raffle_public_state" }, payload => {
        if (Number(payload.new.id) === 1) {
          state.raffleState = payload.new;
          renderAll();
        }
      })
      .subscribe(status => {
        if (status === "SUBSCRIBED") setConnection("Ao vivo", true);
      });
  }

  function renderAll() {
    renderGrid();
    renderStats();
    renderSelected();
    renderUnavailable();
    renderPublicWinner();
    renderSalesState();
  }

  function renderGrid() {
    const fragment = document.createDocumentFragment();
    for (let n = 1; n <= cfg.totalNumbers; n++) {
      const status = state.numbers.get(n) || "available";
      const button = document.createElement("button");
      button.type = "button";
      button.className = "number";
      button.textContent = pad(n);
      button.dataset.number = String(n);

      if (status === "pending") {
        button.classList.add("number--pending");
        button.disabled = true;
        button.title = "Pagamento em andamento";
      } else if (status === "paid") {
        button.classList.add("number--paid");
        button.disabled = true;
        button.title = "Pagamento confirmado";
      } else if (state.selected.has(n)) {
        button.classList.add("number--selected");
        button.setAttribute("aria-pressed", "true");
      } else {
        button.setAttribute("aria-pressed", "false");
      }

      if (!button.disabled) {
        button.addEventListener("click", () => {
          if (state.selected.has(n)) state.selected.delete(n);
          else state.selected.add(n);
          renderGrid();
          renderSelected();
          renderSalesState();
        });
      }
      fragment.appendChild(button);
    }
    el.grid.replaceChildren(fragment);
  }

  function renderStats() {
    const values = [...state.numbers.values()];
    const available = values.filter(v => v === "available").length;
    const pending = values.filter(v => v === "pending").length;
    const paid = values.filter(v => v === "paid").length;
    const unavailable = pending + paid;
    el.available.textContent = available;
    el.pendingCount.textContent = pending;
    el.paid.textContent = paid;
    el.progressBar.style.width = `${(unavailable / cfg.totalNumbers) * 100}%`;
    el.progressText.textContent = `${paid} pagos • ${pending} com pagamento em andamento.`;
  }

  function renderSelected() {
    const values = [...state.selected].sort((a, b) => a - b);
    el.selectedNumbers.textContent = values.length ? values.map(pad).join(", ") : "Nenhum";
    el.selectedTotal.textContent = money(values.length * cfg.unitPriceCents);
  }

  function renderUnavailable() {
    const unavailable = [...state.numbers.entries()].filter(([, status]) => status !== "available").sort((a, b) => a[0] - b[0]);
    if (!unavailable.length) {
      el.unavailableList.innerHTML = '<span class="muted">Todos os números estão disponíveis.</span>';
      return;
    }
    el.unavailableList.innerHTML = unavailable.map(([n, status]) =>
      `<span class="status-chip status-chip--${status}">${pad(n)} • ${status === "paid" ? "Pago" : "Em pagamento"}</span>`
    ).join("");
  }

  function renderPublicWinner() {
    const winner = Number(state.raffleState?.winner_number || 0);
    if (!winner) return el.winnerPublic.classList.add("hidden");
    el.winnerPublicNumber.textContent = pad(winner);
    el.winnerPublic.classList.remove("hidden");
  }

  function renderSalesState() {
    const closed = Boolean(state.raffleState?.sales_closed);
    const pastDraw = Date.now() >= new Date(cfg.drawAt).getTime();
    const count = state.selected.size;
    const blocked = closed || pastDraw;
    el.purchaseButton.disabled = blocked || count === 0;
    if (blocked) el.purchaseButton.textContent = "Vendas encerradas";
    else if (!count) el.purchaseButton.textContent = "Escolha seus números";
    else el.purchaseButton.textContent = `Comprar ${money(count * cfg.unitPriceCents)}`;
  }

  function buildRedirectUrl() {
    if (location.protocol === "file:") return "http://localhost:8080/index.html";
    const url = new URL(location.href);
    url.search = "";
    url.hash = "";
    return url.toString();
  }

  async function callGateway(payload) {
    const response = await fetch(cfg.infinitePay.gatewayUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "apikey": cfg.supabase.publishableKey
      },
      body: JSON.stringify(payload)
    });
    let data = null;
    try { data = await response.json(); } catch { data = {}; }
    if (!response.ok) throw new Error(data?.message || data?.error || `Erro ${response.status} no pagamento.`);
    return data;
  }

  async function startPurchase(name, phone, numbers) {
    return callGateway({
      action: "create",
      name,
      whatsapp: phone,
      numbers,
      redirect_url: buildRedirectUrl()
    });
  }

  async function checkPaymentStatus(orderNsu, quiet = false) {
    const { data, error } = await db.rpc("payment_status", { p_order_nsu: orderNsu });
    if (error) {
      if (!quiet) console.error(error);
      return null;
    }
    if (!data?.found) return null;

    if (data.payment_status === "paid") {
      showPaymentCard("success", "Pagamento confirmado!", `Seus números ${data.numbers.map(pad).join(", ")} estão confirmados para o sorteio.`, { receiptUrl: data.receipt_url });
      savePending(null);
      return data;
    }

    const pending = loadPending();
    showPaymentCard("warning", "Pagamento ainda não confirmado", `Os números ${data.numbers.map(pad).join(", ")} estão com pagamento em andamento no valor de ${money(data.expected_amount_cents)}.`, { continuePayment: Boolean(pending?.checkout_url), receiptUrl: data.receipt_url });
    if (pending) state.pending = pending;
    return data;
  }

  async function handlePaymentReturn() {
    const params = new URLSearchParams(location.search);
    const orderNsu = params.get("order_nsu");
    const transactionNsu = params.get("transaction_nsu");
    const slug = params.get("slug");
    const receiptUrl = params.get("receipt_url");

    if (orderNsu && transactionNsu && slug) {
      showPaymentCard("warning", "Confirmando seu pagamento...", "Recebemos o retorno da InfinitePay e estamos validando a transação.");
      try {
        await callGateway({ action: "confirm", order_nsu: orderNsu, transaction_nsu: transactionNsu, slug, receipt_url: receiptUrl || null });
      } catch (error) { console.error(error); }
      for (let i = 0; i < 5; i++) {
        const status = await checkPaymentStatus(orderNsu, true);
        if (status?.payment_status === "paid") break;
        await new Promise(resolve => setTimeout(resolve, 1200));
      }
      const clean = new URL(location.href);
      clean.search = "";
      history.replaceState({}, "", clean.toString());
      return;
    }

    if (state.pending?.order_nsu) await checkPaymentStatus(state.pending.order_nsu, true);
  }

  async function retryPendingPayment() {
    const pending = loadPending();
    if (!pending?.checkout_url) return showToast("Não encontrei um checkout em andamento.", "error");
    location.assign(pending.checkout_url);
  }

  el.clear.addEventListener("click", () => {
    state.selected.clear();
    renderGrid();
    renderSelected();
    renderSalesState();
  });

  el.continuePayment.addEventListener("click", retryPendingPayment);

  el.form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!state.ready) return;

    const name = el.name.value.trim();
    const phone = digits(el.phone.value);
    const numbers = [...state.selected].sort((a, b) => a - b);

    if (!numbers.length) return showToast("Escolha pelo menos um número.", "error");
    if (name.length < 2) return showToast("Digite um nome válido.", "error");
    if (phone.length < 10 || phone.length > 15) return showToast("Digite um WhatsApp válido com DDD.", "error");

    el.purchaseButton.disabled = true;
    el.purchaseButton.textContent = "Abrindo pagamento...";

    try {
      const data = await startPurchase(name, phone, numbers);
      if (!data?.url || !data?.order_nsu) throw new Error("A InfinitePay não retornou o checkout.");

      savePending({
        order_nsu: data.order_nsu,
        numbers: data.numbers || numbers,
        amount_cents: data.amount_cents || numbers.length * cfg.unitPriceCents,
        checkout_url: data.url
      });

      state.selected.clear();
      renderSelected();
      location.assign(data.url);
    } catch (error) {
      console.error(error);
      showToast(error.message || "Não foi possível iniciar a compra.", "error");
      await loadAll();
      renderSalesState();
    }
  });

  function updateCountdown() {
    const diff = new Date(cfg.drawAt).getTime() - Date.now();
    if (diff <= 0) {
      el.countDays.textContent = "0";
      el.countHours.textContent = "00";
      el.countMinutes.textContent = "00";
      el.countSeconds.textContent = "00";
      return;
    }
    const sec = Math.floor(diff / 1000);
    el.countDays.textContent = String(Math.floor(sec / 86400));
    el.countHours.textContent = String(Math.floor((sec % 86400) / 3600)).padStart(2, "0");
    el.countMinutes.textContent = String(Math.floor((sec % 3600) / 60)).padStart(2, "0");
    el.countSeconds.textContent = String(sec % 60).padStart(2, "0");
  }

  el.phone.addEventListener("input", () => {
    const d = digits(el.phone.value).slice(0, 11);
    if (d.length <= 2) el.phone.value = d;
    else if (d.length <= 7) el.phone.value = `(${d.slice(0,2)}) ${d.slice(2)}`;
    else el.phone.value = `(${d.slice(0,2)}) ${d.slice(2,7)}-${d.slice(7)}`;
  });

  updateCountdown();
  setInterval(updateCountdown, 1000);
  loadAll().then(handlePaymentReturn);

  window.addEventListener("beforeunload", () => {
    if (state.channel) db.removeChannel(state.channel);
  });
})();
