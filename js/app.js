(() => {
  "use strict";

  const cfg = window.RIFA_CONFIG;
  const db = window.supabaseClient;
  const PENDING_KEY = "rifa_pagamento_pendente_v3";

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
    paid: $("paidCount"),
    progressBar: $("progressBar"),
    progressText: $("progressText"),
    selectedNumbers: $("selectedNumbers"),
    selectedTotal: $("selectedTotal"),
    selectedNumbersMain: $("selectedNumbersMain"),
    selectedTotalMain: $("selectedTotalMain"),
    clear: $("clearSelectionBtn"),
    openCheckout: $("openCheckoutBtn"),
    checkoutModal: $("checkoutModal"),
    checkoutClose: $("checkoutCloseBtn"),
    cancelChoiceModal: $("cancelChoiceModal"),
    keepCheckout: $("keepCheckoutBtn"),
    confirmCancelCheckout: $("confirmCancelCheckoutBtn"),
    form: $("purchaseForm"),
    name: $("nameInput"),
    phone: $("phoneInput"),
    purchaseButton: $("purchaseButton"),
    paymentHelp: $("paymentHelp"),
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
    receiptLink: $("receiptLink"),
    methodInfiniteCard: $("methodInfiniteCard"),
    methodPersonalCard: $("methodPersonalCard"),
    methodCashCard: $("methodCashCard"),
    cashPaymentFields: $("cashPaymentFields"),
    cashReceivedBy: $("cashReceivedByInput"),
    cashReceivedPhone: $("cashReceivedPhoneInput"),
    personalPixPanel: $("personalPixPanel"),
    personalPixKey: $("personalPixKey"),
    personalPixOwner: $("personalPixOwner"),
    personalPixAmount: $("personalPixAmount"),
    personalPixNumbers: $("personalPixNumbers"),
    copyPixKey: $("copyPixKeyBtn"),
    sendWhatsapp: $("sendWhatsappBtn")
  };

  function pad(n) { return String(n).padStart(3, "0"); }
  function digits(value) { return String(value || "").replace(/\D/g, ""); }

  const BRAZIL_DDDS = new Set([
    "11","12","13","14","15","16","17","18","19",
    "21","22","24","27","28",
    "31","32","33","34","35","37","38",
    "41","42","43","44","45","46","47","48","49",
    "51","53","54","55",
    "61","62","63","64","65","66","67","68","69",
    "71","73","74","75","77","79",
    "81","82","83","84","85","86","87","88","89",
    "91","92","93","94","95","96","97","98","99"
  ]);

  function normalizeBrazilPhone(value, { requireMobile = false } = {}) {
    const raw = String(value || "").trim();
    let d = digits(raw);

    if (!d) {
      return { ok: false, error: "Digite o telefone com DDD." };
    }

    if (d.startsWith("00")) d = d.slice(2);

    // Corrige country code 55 duplicado quando houver comprimento suficiente
    // para provar que há um +55 extra (ex.: 55 55 11 99999-9999).
    if (d.startsWith("5555") && (d.length === 14 || d.length === 15)) {
      d = d.slice(2);
    }

    // Se vier em E.164 brasileiro, converte para formato nacional.
    if (d.startsWith("55") && (d.length === 12 || d.length === 13)) {
      d = d.slice(2);
    }

    if (d.length !== 10 && d.length !== 11) {
      return {
        ok: false,
        error: "Telefone inválido. Use DDD + número, por exemplo: 11 99999-9999."
      };
    }

    const ddd = d.slice(0, 2);
    const subscriber = d.slice(2);

    if (!BRAZIL_DDDS.has(ddd)) {
      return { ok: false, error: `DDD ${ddd} inválido.` };
    }

    if (d.length === 11 && subscriber[0] !== "9") {
      return {
        ok: false,
        error: "Celular inválido: depois do DDD, o número deve começar com 9."
      };
    }

    if (d.length === 10 && requireMobile) {
      return {
        ok: false,
        error: "Para WhatsApp de celular, digite DDD + 9 dígitos."
      };
    }

    if (d.length === 10 && !/^[2-9]/.test(subscriber)) {
      return { ok: false, error: "Telefone fixo inválido." };
    }

    return {
      ok: true,
      national: d,
      e164: `55${d}`,
      ddd,
      subscriber
    };
  }

  function formatPhoneInput(value) {
    const raw = String(value || "");
    let d = digits(raw);

    const explicitCountry = /^\s*\+55\b/.test(raw) || (d.startsWith("55") && d.length > 11);
    if (explicitCountry && d.startsWith("55")) d = d.slice(2);

    d = d.slice(0, 11);

    if (d.length <= 2) return d;
    if (d.length <= 6) return `(${d.slice(0,2)}) ${d.slice(2)}`;

    if (d.length <= 10) {
      return `(${d.slice(0,2)}) ${d.slice(2,6)}-${d.slice(6)}`;
    }

    return `(${d.slice(0,2)}) ${d.slice(2,7)}-${d.slice(7)}`;
  }
  function money(cents) {
    return new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" })
      .format((Number(cents) || 0) / 100);
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

  function selectedMethod() {
    return document.querySelector('input[name="paymentMethod"]:checked')?.value || "infinitepay";
  }

  function showToast(message, kind = "normal") {
    el.toast.textContent = message;
    el.toast.dataset.kind = kind;
    el.toast.classList.add("toast--show");
    clearTimeout(showToast.timer);
    showToast.timer = setTimeout(() => el.toast.classList.remove("toast--show"), 3600);
  }

  function setConnection(text, ok = false) {
    if (!el.badge) return;
    el.badge.textContent = text;
    el.badge.classList.toggle("connection-badge--ok", ok);
  }

  function showSetupError() {
    el.setupWarning.classList.remove("hidden");
    setConnection("Banco não atualizado");
    el.loading.textContent = "O Supabase precisa receber a atualização desta versão.";
  }

  function showPaymentCard(type, title, text, options = {}) {
    el.paymentCard.classList.remove(
      "hidden", "payment-status-card--success",
      "payment-status-card--warning", "payment-status-card--error"
    );
    if (type) el.paymentCard.classList.add(`payment-status-card--${type}`);
    el.paymentTitle.textContent = title;
    el.paymentText.textContent = text;
    el.continuePayment.classList.toggle("hidden", !options.continuePayment);
    el.receiptLink.classList.toggle("hidden", !options.receiptUrl);
    if (options.receiptUrl) el.receiptLink.href = options.receiptUrl;
  }

  async function releaseExpired() {
    try {
      await db.rpc("release_expired_pending");
    } catch (error) {
      console.warn("Não foi possível liberar pagamentos expirados:", error);
    }
  }

  async function loadAll() {
    setConnection("Sincronizando...");
    await releaseExpired();

    const [numbersRes, stateRes] = await Promise.all([
      db.from("raffle_numbers").select("number,status").order("number"),
      db.from("raffle_public_state")
        .select("sales_closed,draw_at,instagram_handle,winner_number,drawn_at")
        .eq("id", 1)
        .single()
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

    state.channel = db.channel("rifa-public-live-v3")
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "raffle_numbers" }, payload => {
        const n = Number(payload.new.number);
        state.numbers.set(n, payload.new.status);
        if (payload.new.status !== "available") state.selected.delete(n);
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
    renderPublicWinner();
    renderSalesState();
    renderPaymentMethod();
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
        button.classList.add("number--unavailable");
        button.disabled = true;
        button.title = "Indisponível no momento";
      } else if (status === "paid") {
        button.classList.add("number--paid");
        button.disabled = true;
        button.title = "Pago";
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
    if (!el.available || !el.paid || !el.progressBar || !el.progressText) return;

    const values = [...state.numbers.values()];
    const available = values.filter(v => v === "available").length;
    const paid = values.filter(v => v === "paid").length;

    el.available.textContent = available;
    el.paid.textContent = paid;
    el.progressBar.style.width = `${(paid / cfg.totalNumbers) * 100}%`;
    el.progressText.textContent = `${paid} de ${cfg.totalNumbers} números pagos.`;
  }

  function renderSelected() {
    const values = [...state.selected].sort((a, b) => a - b);
    const numbersText = values.length ? values.map(pad).join(", ") : "Nenhum";
    const totalText = money(values.length * cfg.unitPriceCents);

    el.selectedNumbers.textContent = numbersText;
    el.selectedTotal.textContent = totalText;
    el.selectedNumbersMain.textContent = numbersText;
    el.selectedTotalMain.textContent = totalText;

    if (el.checkoutModal.classList.contains("checkout-modal--open") && values.length === 0) {
      closeCheckoutSilently();
      showToast("Os números selecionados ficaram indisponíveis. Escolha novamente.", "error");
    }
  }

  function renderPublicWinner() {
    const winner = Number(state.raffleState?.winner_number || 0);
    if (!winner) {
      el.winnerPublic.classList.add("hidden");
      return;
    }
    el.winnerPublicNumber.textContent = pad(winner);
    el.winnerPublic.classList.remove("hidden");
  }

  function renderPaymentMethod() {
    const method = selectedMethod();
    el.methodInfiniteCard.classList.toggle("payment-method--active", method === "infinitepay");
    el.methodPersonalCard.classList.toggle("payment-method--active", method === "personal_pix");
    el.methodCashCard.classList.toggle("payment-method--active", method === "cash");
    el.cashPaymentFields.classList.toggle("hidden", method !== "cash");

    if (method === "infinitepay") {
      el.paymentHelp.innerHTML =
        'Cada número custa <strong>R$ 10,00</strong>. Pela InfinitePay, o pagamento é identificado automaticamente.';
    } else if (method === "personal_pix") {
      el.paymentHelp.innerHTML =
        'Cada número custa <strong>R$ 10,00</strong>. No Pix pessoal, depois do pagamento toque em <strong>enviar meus números no WhatsApp</strong>.';
    } else {
      el.paymentHelp.innerHTML =
        'Cada número custa <strong>R$ 10,00</strong>. Em dinheiro, informe <strong>quem recebeu</strong> e o telefone dessa pessoa. O pagamento ficará pendente até conferência do organizador.';
    }
    renderSalesState();
  }

  function renderSalesState() {
    const closed = Boolean(state.raffleState?.sales_closed);
    const pastDraw = Date.now() >= new Date(cfg.drawAt).getTime();
    const count = state.selected.size;
    const blocked = closed || pastDraw;
    const method = selectedMethod();
    const total = money(count * cfg.unitPriceCents);

    el.openCheckout.disabled = blocked || count === 0;
    if (blocked) el.openCheckout.textContent = "Vendas encerradas";
    else if (!count) el.openCheckout.textContent = "Escolha seus números";
    else el.openCheckout.textContent = `Confirmar ${count === 1 ? "número" : "números"} • ${total}`;

    el.purchaseButton.disabled = blocked || count === 0;
    if (blocked) el.purchaseButton.textContent = "Vendas encerradas";
    else if (method === "personal_pix") el.purchaseButton.textContent = `Continuar para Pix • ${total}`;
    else if (method === "cash") el.purchaseButton.textContent = `Registrar em dinheiro • ${total}`;
    else el.purchaseButton.textContent = `Ir para InfinitePay • ${total}`;
  }

  function updateBodyModalState() {
    const anyOpen =
      el.checkoutModal.classList.contains("checkout-modal--open") ||
      el.cancelChoiceModal.classList.contains("checkout-modal--open");
    document.body.classList.toggle("modal-open", anyOpen);
  }

  function openCheckoutModal() {
    if (!state.selected.size) {
      showToast("Escolha pelo menos um número.", "error");
      return;
    }
    renderSelected();
    renderPaymentMethod();
    el.checkoutModal.classList.add("checkout-modal--open");
    el.checkoutModal.setAttribute("aria-hidden", "false");
    updateBodyModalState();
    setTimeout(() => el.name.focus(), 60);
  }

  function closeCheckoutSilently() {
    el.checkoutModal.classList.remove("checkout-modal--open");
    el.checkoutModal.setAttribute("aria-hidden", "true");
    el.cancelChoiceModal.classList.remove("checkout-modal--open");
    el.cancelChoiceModal.setAttribute("aria-hidden", "true");
    updateBodyModalState();
  }

  function requestCloseCheckout() {
    if (!el.checkoutModal.classList.contains("checkout-modal--open")) return;
    el.cancelChoiceModal.classList.add("checkout-modal--open");
    el.cancelChoiceModal.setAttribute("aria-hidden", "false");
    updateBodyModalState();
    setTimeout(() => el.keepCheckout.focus(), 40);
  }

  function keepCheckoutOpen() {
    el.cancelChoiceModal.classList.remove("checkout-modal--open");
    el.cancelChoiceModal.setAttribute("aria-hidden", "true");
    updateBodyModalState();
    setTimeout(() => el.name.focus(), 40);
  }

  function confirmCancelCheckout() {
    state.selected.clear();
    el.form.reset();
    const infinite = document.querySelector('input[name="paymentMethod"][value="infinitepay"]');
    if (infinite) infinite.checked = true;
    closeCheckoutSilently();
    renderAll();
    showToast("Escolha cancelada. Nenhum número ficou preso.", "normal");
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

    let data = {};
    try { data = await response.json(); } catch {}
    if (!response.ok) {
      throw new Error(data?.message || data?.error || `Erro ${response.status} no pagamento.`);
    }
    return data;
  }

  async function startInfinitePay(name, phone, numbers) {
    return callGateway({
      action: "create",
      name,
      whatsapp: phone,
      numbers,
      redirect_url: buildRedirectUrl()
    });
  }

  async function startPersonalPix(name, phone, numbers) {
    return callGateway({
      action: "create_personal_pix",
      name,
      whatsapp: phone,
      numbers
    });
  }

  async function startCashPayment(name, phone, numbers, receivedBy, receivedPhone) {
    return callGateway({
      action: "create_cash_payment",
      name,
      whatsapp: phone,
      numbers,
      cash_received_by: receivedBy,
      cash_received_phone: receivedPhone
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
      showPaymentCard(
        "success",
        "Pagamento confirmado!",
        `Seus números ${data.numbers.map(pad).join(", ")} estão confirmados para o sorteio.`,
        { receiptUrl: data.receipt_url }
      );
      el.personalPixPanel.classList.add("hidden");
      savePending(null);
      return data;
    }

    if (data.payment_status === "expired") {
      showPaymentCard(
        "error",
        "Prazo do pagamento encerrado",
        "Este pagamento expirou e os números voltaram a ficar disponíveis. Se você já pagou, fale com o organizador."
      );
      el.personalPixPanel.classList.add("hidden");
      savePending(null);
      return data;
    }

    return data;
  }

  async function handlePaymentReturn() {
    const params = new URLSearchParams(location.search);
    const orderNsu = params.get("order_nsu");
    const transactionNsu = params.get("transaction_nsu");
    const slug = params.get("slug");
    const receiptUrl = params.get("receipt_url");

    if (orderNsu && transactionNsu && slug) {
      showPaymentCard(
        "warning",
        "Confirmando seu pagamento...",
        "Recebemos o retorno da InfinitePay e estamos validando a transação."
      );

      try {
        await callGateway({
          action: "confirm",
          order_nsu: orderNsu,
          transaction_nsu: transactionNsu,
          slug,
          receipt_url: receiptUrl || null
        });
      } catch (error) {
        console.error(error);
      }

      for (let i = 0; i < 6; i++) {
        const status = await checkPaymentStatus(orderNsu, true);
        if (status?.payment_status === "paid") break;
        await new Promise(resolve => setTimeout(resolve, 1200));
      }

      const clean = new URL(location.href);
      clean.search = "";
      history.replaceState({}, "", clean.toString());
      return;
    }

    const pending = loadPending();
    if (!pending?.order_nsu) return;

    const status = await checkPaymentStatus(pending.order_nsu, true);
    if (!status || status.payment_status !== "pending") return;

    if (pending.provider === "personal_pix") {
      showPersonalPixPanel(pending);
    } else if (pending.provider === "cash") {
      showPaymentCard(
        "warning",
        "Pagamento em dinheiro pendente",
        `Seus números ${(pending.numbers || []).map(pad).join(", ")} estão aguardando a confirmação do organizador.`
      );
    } else if (pending.checkout_url) {
      showPaymentCard(
        "warning",
        "Pagamento ainda não concluído",
        `Seu pagamento de ${money(pending.amount_cents)} ainda está aberto.`,
        { continuePayment: true }
      );
    }
  }

  function showPersonalPixPanel(order) {
    el.personalPixKey.textContent = cfg.personalPix.key;
    el.personalPixOwner.textContent = cfg.personalPix.owner;
    el.personalPixAmount.textContent = money(order.amount_cents);
    el.personalPixNumbers.textContent = (order.numbers || []).map(pad).join(", ");
    el.personalPixPanel.classList.remove("hidden");
    el.personalPixPanel.scrollIntoView({ behavior: "smooth", block: "center" });
  }

  async function retryPendingPayment() {
    const pending = loadPending();
    if (!pending?.checkout_url) {
      showToast("Não encontrei um checkout aberto.", "error");
      return;
    }
    location.assign(pending.checkout_url);
  }

  async function copyText(value) {
    try {
      await navigator.clipboard.writeText(value);
      return true;
    } catch {
      const input = document.createElement("textarea");
      input.value = value;
      input.style.position = "fixed";
      input.style.opacity = "0";
      document.body.appendChild(input);
      input.select();
      const ok = document.execCommand("copy");
      input.remove();
      return ok;
    }
  }

  async function sendPersonalPixWhatsapp() {
    const pending = loadPending();

    if (!pending || pending.provider !== "personal_pix") {
      showToast("Não encontrei um pagamento Pix pessoal em andamento.", "error");
      return;
    }

    try {
      await callGateway({
        action: "personal_pix_contacted",
        order_nsu: pending.order_nsu
      });
    } catch (error) {
      console.warn(error);
    }

    const buyerName = pending.buyer_name || el.name.value.trim() || "Comprador";
    const nums = (pending.numbers || []).map(pad).join(", ");
    const total = money(pending.amount_cents);

    const message = [
      "Olá! Fiz o Pix da rifa beneficente.",
      "",
      `Nome: ${buyerName}`,
      `Números escolhidos: ${nums}`,
      `Total pago: ${total}`,
      `Pedido: ${pending.order_nsu}`,
      "",
      "Pode confirmar meus números, por favor?"
    ].join("\n");

    const url = `https://wa.me/${cfg.personalPix.whatsapp}?text=${encodeURIComponent(message)}`;
    window.open(url, "_blank", "noopener");
  }

  el.openCheckout.addEventListener("click", openCheckoutModal);
  el.checkoutClose.addEventListener("click", requestCloseCheckout);
  el.checkoutModal.querySelector("[data-checkout-close]").addEventListener("click", requestCloseCheckout);
  el.keepCheckout.addEventListener("click", keepCheckoutOpen);
  el.confirmCancelCheckout.addEventListener("click", confirmCancelCheckout);

  document.addEventListener("keydown", event => {
    if (event.key !== "Escape") return;

    if (el.cancelChoiceModal.classList.contains("checkout-modal--open")) {
      keepCheckoutOpen();
      return;
    }

    if (el.checkoutModal.classList.contains("checkout-modal--open")) {
      requestCloseCheckout();
    }
  });

  el.clear.addEventListener("click", () => {
    state.selected.clear();
    renderGrid();
    renderSelected();
    renderSalesState();
  });

  el.continuePayment.addEventListener("click", retryPendingPayment);

  document.querySelectorAll('input[name="paymentMethod"]').forEach(input => {
    input.addEventListener("change", renderPaymentMethod);
  });

  el.copyPixKey.addEventListener("click", async () => {
    const ok = await copyText(cfg.personalPix.key);
    showToast(ok ? "Chave Pix copiada." : "Não foi possível copiar automaticamente.", ok ? "success" : "error");
  });

  el.sendWhatsapp.addEventListener("click", sendPersonalPixWhatsapp);

  el.form.addEventListener("submit", async event => {
    event.preventDefault();
    if (!state.ready) return;

    const name = el.name.value.trim();
    const phoneCheck = normalizeBrazilPhone(el.phone.value, { requireMobile: true });
    const phone = phoneCheck.ok ? phoneCheck.national : "";
    const numbers = [...state.selected].sort((a, b) => a - b);
    const method = selectedMethod();
    const cashReceivedBy = el.cashReceivedBy.value.trim();
    const cashPhoneCheck = normalizeBrazilPhone(el.cashReceivedPhone.value, { requireMobile: false });
    const cashReceivedPhone = cashPhoneCheck.ok ? cashPhoneCheck.national : "";

    if (!numbers.length) return showToast("Escolha pelo menos um número.", "error");
    if (name.length < 2) return showToast("Digite um nome válido.", "error");
    if (!phoneCheck.ok) {
      return showToast(phoneCheck.error || "Digite um WhatsApp válido com DDD.", "error");
    }
    if (method === "cash") {
      if (cashReceivedBy.length < 2) return showToast("Informe para quem o dinheiro foi entregue.", "error");
      if (!cashPhoneCheck.ok) {
        return showToast(cashPhoneCheck.error || "Digite o telefone de quem recebeu o dinheiro.", "error");
      }
    }

    el.purchaseButton.disabled = true;
    el.purchaseButton.textContent = "Preparando pagamento...";

    try {
      if (method === "personal_pix") {
        const data = await startPersonalPix(name, phone, numbers);
        if (!data?.order_nsu) throw new Error("Não foi possível gerar o pagamento Pix.");

        const pending = {
          provider: "personal_pix",
          order_nsu: data.order_nsu,
          buyer_name: name,
          numbers: data.numbers || numbers,
          amount_cents: data.amount_cents || numbers.length * cfg.unitPriceCents
        };

        savePending(pending);
        state.selected.clear();
        closeCheckoutSilently();
        el.form.reset();
        renderAll();
        showPersonalPixPanel(pending);
        showToast("Pagamento Pix preparado. Faça o Pix e envie seus números pelo WhatsApp.", "success");
      } else if (method === "cash") {
        const data = await startCashPayment(name, phone, numbers, cashReceivedBy, cashReceivedPhone);
        if (!data?.order_nsu) throw new Error("Não foi possível registrar o pagamento em dinheiro.");

        const pending = {
          provider: "cash",
          order_nsu: data.order_nsu,
          buyer_name: name,
          numbers: data.numbers || numbers,
          amount_cents: data.amount_cents || numbers.length * cfg.unitPriceCents,
          cash_received_by: data.cash_received_by || cashReceivedBy,
          cash_received_phone: data.cash_received_phone || cashReceivedPhone
        };

        savePending(pending);
        state.selected.clear();
        closeCheckoutSilently();
        el.form.reset();
        renderAll();
        showPaymentCard(
          "warning",
          "Pagamento em dinheiro registrado",
          `Seus números ${pending.numbers.map(pad).join(", ")} estão Pendentes até o organizador confirmar o recebimento.`
        );
        showToast("Pagamento em dinheiro registrado para conferência.", "success");
      } else {
        const data = await startInfinitePay(name, phone, numbers);
        if (!data?.url || !data?.order_nsu) {
          throw new Error("A InfinitePay não retornou o checkout.");
        }

        savePending({
          provider: "infinitepay",
          order_nsu: data.order_nsu,
          buyer_name: name,
          numbers: data.numbers || numbers,
          amount_cents: data.amount_cents || numbers.length * cfg.unitPriceCents,
          checkout_url: data.url
        });

        state.selected.clear();
        closeCheckoutSilently();
        renderSelected();
        location.assign(data.url);
      }
    } catch (error) {
      console.error(error);
      showToast(error.message || "Não foi possível iniciar o pagamento.", "error");
      await loadAll();
      renderSalesState();
    }
  });

  el.phone.addEventListener("input", () => {
    el.phone.value = formatPhoneInput(el.phone.value);
  });

  el.cashReceivedPhone.addEventListener("input", () => {
    el.cashReceivedPhone.value = formatPhoneInput(el.cashReceivedPhone.value);
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

  updateCountdown();
  setInterval(updateCountdown, 1000);

  loadAll().then(handlePaymentReturn);

  setInterval(async () => {
    await releaseExpired();
  }, 15000);

  setInterval(async () => {
    const pending = loadPending();
    if (pending?.order_nsu && pending.provider === "personal_pix") {
      await checkPaymentStatus(pending.order_nsu, true);
    }
  }, 15000);

  window.addEventListener("beforeunload", () => {
    if (state.channel) db.removeChannel(state.channel);
  });
})();
