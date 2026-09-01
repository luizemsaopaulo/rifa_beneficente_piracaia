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
    clear: $("clearSelectionBtn"),
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
    el.selectedNumbers.textContent = values.length ? values.map(pad).join(", ") : "Nenhum";
    el.selectedTotal.textContent = money(values.length * cfg.unitPriceCents);
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

    if (method === "infinitepay") {
      el.paymentHelp.innerHTML =
        'Cada número custa <strong>R$ 10,00</strong>. Pela InfinitePay, o pagamento é identificado automaticamente.';
    } else {
      el.paymentHelp.innerHTML =
        'Cada número custa <strong>R$ 10,00</strong>. No Pix pessoal, depois do pagamento toque em <strong>enviar meus números no WhatsApp</strong>.';
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

    el.purchaseButton.disabled = blocked || count === 0;

    if (blocked) el.purchaseButton.textContent = "Vendas encerradas";
    else if (!count) el.purchaseButton.textContent = "Escolha seus números";
    else if (method === "personal_pix") el.purchaseButton.textContent = `Pagar ${total} por Pix pessoal`;
    else el.purchaseButton.textContent = `Pagar ${total} pela InfinitePay`;
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
    const phone = digits(el.phone.value);
    const numbers = [...state.selected].sort((a, b) => a - b);
    const method = selectedMethod();

    if (!numbers.length) return showToast("Escolha pelo menos um número.", "error");
    if (name.length < 2) return showToast("Digite um nome válido.", "error");
    if (phone.length < 10 || phone.length > 15) {
      return showToast("Digite um WhatsApp válido com DDD.", "error");
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
        renderAll();
        showPersonalPixPanel(pending);
        showToast("Pagamento Pix preparado. Faça o Pix e envie seus números pelo WhatsApp.", "success");
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
    const d = digits(el.phone.value).slice(0, 11);
    if (d.length <= 2) el.phone.value = d;
    else if (d.length <= 7) el.phone.value = `(${d.slice(0,2)}) ${d.slice(2)}`;
    else el.phone.value = `(${d.slice(0,2)}) ${d.slice(2,7)}-${d.slice(7)}`;
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
  }, 60000);

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
