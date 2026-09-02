(() => {
  "use strict";

  const cfg = window.RIFA_CONFIG;
  const db = window.supabaseClient;

  const SESSION_KEY = "rifa_admin_session_v1";

  const state = {
    sessionToken: localStorage.getItem(SESSION_KEY) || "",
    dashboard: null,
    channel: null,
    deferredInstallPrompt: null,
    confirmResolver: null
  };

  const $ = (id) => document.getElementById(id);
  const el = {
    loginCard: $("loginCard"),
    loginForm: $("adminLoginForm"),
    password: $("adminPassword"),
    panel: $("adminPanel"),
    setupWarning: $("adminSetupWarning"),
    toast: $("toast"),
    refresh: $("refreshAdminBtn"),
    logout: $("logoutBtn"),
    available: $("adminAvailable"),
    pending: $("adminPending"),
    paid: $("adminPaid"),
    buyers: $("adminBuyers"),
    salesTitle: $("salesStatusTitle"),
    salesText: $("salesStatusText"),
    toggleSales: $("toggleSalesBtn"),
    availableHeadline: $("availableHeadline"),
    availableList: $("availableNumbersList"),
    numberGrid: $("adminNumberGrid"),
    search: $("buyerSearch"),
    filter: $("buyerFilter"),
    tbody: $("buyerTableBody"),
    cards: $("buyerCards"),
    exportCsv: $("exportCsvBtn"),
    officialWinner: $("officialWinner"),
    officialWinnerNumber: $("officialWinnerNumber"),
    officialWinnerName: $("officialWinnerName"),
    officialWinnerPhone: $("officialWinnerPhone"),
    officialWinnerDate: $("officialWinnerDate"),
    drawControls: $("drawControls"),
    simulate: $("simulateDrawBtn"),
    simulationResult: $("simulationResult"),
    drawConfirm: $("drawConfirmInput"),
    officialDraw: $("officialDrawBtn"),
    installApp: $("installAdminAppBtn"),
    confirmModal: $("adminConfirmModal"),
    confirmIcon: $("adminConfirmIcon"),
    confirmTitle: $("adminConfirmTitle"),
    confirmMessage: $("adminConfirmMessage"),
    confirmDetails: $("adminConfirmDetails"),
    confirmCancel: $("adminConfirmCancelBtn"),
    confirmOk: $("adminConfirmOkBtn")
  };

  const pad = (n) => String(n).padStart(3, "0");
  const escapeHtml = (value) => String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");

  function showToast(message, kind = "normal") {
    el.toast.textContent = message;
    el.toast.dataset.kind = kind;
    el.toast.classList.add("toast--show");
    clearTimeout(showToast.timer);
    showToast.timer = setTimeout(() => el.toast.classList.remove("toast--show"), 3300);
  }

  function formatPhone(phone) {
    const d = String(phone || "").replace(/\D/g, "");
    if (d.length === 11) return `(${d.slice(0,2)}) ${d.slice(2,7)}-${d.slice(7)}`;
    if (d.length === 10) return `(${d.slice(0,2)}) ${d.slice(2,6)}-${d.slice(6)}`;
    return phone || "";
  }

  function formatDate(value) {
    if (!value) return "—";
    return new Date(value).toLocaleString("pt-BR");
  }

  function money(cents) {
    return new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" }).format((Number(cents) || 0) / 100);
  }

  function paymentInfo(r) {
    if (r.payment_provider === "personal_pix") {
      return '<div><strong>Pix pessoal</strong><br><small>Confirmação manual</small></div>';
    }
    const method = r.capture_method === "pix" ? "Pix" : (r.capture_method ? r.capture_method : "Checkout");
    const receipt = r.receipt_url
      ? `<a href="${escapeHtml(r.receipt_url)}" target="_blank" rel="noopener noreferrer">Comprovante</a>`
      : "";
    return `<div><strong>InfinitePay • ${escapeHtml(method)}</strong>${receipt ? `<br><small>${receipt}</small>` : ""}</div>`;
  }

  async function rpc(name, args = {}) {
    if (!state.sessionToken) throw new Error("Sessão administrativa não encontrada.");
    const { data, error } = await db.rpc(`${name}_session`, { p_session_token: state.sessionToken, ...args });
    if (error) throw error;
    return data;
  }

  function showPanel() { el.loginCard.classList.add("hidden"); el.panel.classList.remove("hidden"); }
  function showLogin() { el.panel.classList.add("hidden"); el.loginCard.classList.remove("hidden"); }
  function clearSession() { state.sessionToken = ""; localStorage.removeItem(SESSION_KEY); }
  function reservationById(id) { return (state.dashboard?.reservations || []).find(r => String(r.id) === String(id)); }
  function reservationDetails(r) {
    if (!r) return "";
    const nums = (r.numbers || []).map(pad).join(", ");
    return `<strong>${escapeHtml(r.buyer_name || "")}</strong><br>Números: <strong>${escapeHtml(nums)}</strong><br>Valor: <strong>${escapeHtml(money(r.expected_amount_cents))}</strong>`;
  }

  function whatsappTarget(phone) {
    const d = String(phone || "").replace(/\D/g, "");
    if (!d) return "";
    if (d.startsWith("55") && (d.length === 12 || d.length === 13)) return d;
    if (d.length === 10 || d.length === 11) return `55${d}`;
    return d;
  }

  function confirmationMessage(r) {
    const name = String(r?.buyer_name || "").trim();
    const numbers = (r?.numbers || []).map(pad).join(", ");
    return [
      `Olá${name ? `, ${name}` : ""}! ✅`,
      "",
      "Seu pagamento da Rifa Beneficente foi confirmado.",
      `🎟️ Seus números: ${numbers}`,
      "",
      "🍀 Boa sorte!",
      "Muito obrigado pela participação. Que Deus abençoe! 🙏"
    ].join("\n");
  }

  function whatsappPhoneHtml(r) {
    const phone = escapeHtml(formatPhone(r.whatsapp));
    if (r.payment_status !== "paid") {
      return `<span class="admin-phone admin-phone--plain">${phone}</span>`;
    }

    const sent = Boolean(r.confirmation_whatsapp_sent_at);
    const title = sent
      ? `Mensagem de confirmação já enviada em ${escapeHtml(formatDate(r.confirmation_whatsapp_sent_at))}`
      : "Clique para enviar a confirmação pelo WhatsApp";

    return `
      <button
        type="button"
        class="admin-phone admin-phone--whatsapp ${sent ? "admin-phone--sent" : ""}"
        data-whatsapp-confirmation="${escapeHtml(r.id)}"
        title="${title}">
        ${phone}${sent ? ' <span aria-hidden="true">✓</span>' : ""}
      </button>
    `;
  }

  async function handleConfirmationWhatsapp(r) {
    if (!r) return;

    if (r.payment_status !== "paid") {
      showToast("Confirme o pagamento antes de enviar a mensagem.", "error");
      return;
    }

    if (r.confirmation_whatsapp_sent_at) {
      await confirmAction({
        title: "Mensagem já enviada",
        message: `A confirmação para ${r.buyer_name || "este comprador"} já foi enviada em ${formatDate(r.confirmation_whatsapp_sent_at)}.`,
        details: reservationDetails(r),
        confirmText: "OK",
        icon: "✓",
        single: true
      });
      return;
    }

    const ok = await confirmAction({
      title: "Enviar confirmação pelo WhatsApp?",
      message: "Ao confirmar, o WhatsApp será aberto com a mensagem pronta. Esta confirmação só poderá ser usada uma vez para este pedido.",
      details: `${reservationDetails(r)}<br>WhatsApp: <strong>${escapeHtml(formatPhone(r.whatsapp))}</strong>`,
      confirmText: "Sim, abrir WhatsApp",
      icon: "💬"
    });

    if (!ok) return;

    try {
      const result = await rpc("admin_mark_confirmation_whatsapp_sent", {
        p_reservation_id: r.id
      });

      if (result?.already_sent) {
        await refreshDashboard();
        await confirmAction({
          title: "Mensagem já enviada",
          message: `Esta confirmação já tinha sido registrada em ${formatDate(result.sent_at)}.`,
          details: reservationDetails(r),
          confirmText: "OK",
          icon: "✓",
          single: true
        });
        return;
      }

      const messageData = {
        ...r,
        buyer_name: result?.buyer_name || r.buyer_name,
        whatsapp: result?.whatsapp || r.whatsapp,
        numbers: result?.numbers || r.numbers
      };

      const target = whatsappTarget(messageData.whatsapp);
      if (!target) throw new Error("WhatsApp do comprador inválido.");

      const url = `https://wa.me/${target}?text=${encodeURIComponent(confirmationMessage(messageData))}`;

      await refreshDashboard();

      const opened = window.open(url, "_blank", "noopener,noreferrer");
      if (!opened) {
        window.location.href = url;
      }

      showToast("Confirmação registrada. WhatsApp aberto.", "success");
    } catch (error) {
      showToast(error.message || "Não foi possível abrir a confirmação no WhatsApp.", "error");
    }
  }
  function confirmAction({ title="Confirmar ação", message="", details="", confirmText="Confirmar", icon="?", danger=false, single=false } = {}) {
    return new Promise(resolve => {
      state.confirmResolver=resolve; el.confirmIcon.textContent=icon; el.confirmTitle.textContent=title; el.confirmMessage.textContent=message;
      el.confirmOk.textContent=confirmText; el.confirmOk.classList.toggle("button--danger",danger); el.confirmOk.classList.toggle("button--primary",!danger);
      el.confirmCancel.classList.toggle("hidden", Boolean(single));
      if(details){ el.confirmDetails.innerHTML=details; el.confirmDetails.classList.remove("hidden"); } else { el.confirmDetails.innerHTML=""; el.confirmDetails.classList.add("hidden"); }
      el.confirmModal.classList.remove("hidden"); el.confirmModal.setAttribute("aria-hidden","false"); setTimeout(() => (single ? el.confirmOk : el.confirmCancel).focus(),20);
    });
  }
  function closeConfirmModal(result) {
    el.confirmModal.classList.add("hidden"); el.confirmModal.setAttribute("aria-hidden","true");
    el.confirmCancel.classList.remove("hidden");
    const resolver=state.confirmResolver; state.confirmResolver=null; if(resolver) resolver(Boolean(result));
  }
  async function restoreSession() {
    if(!state.sessionToken) return;
    try { await refreshDashboard(); showPanel(); subscribeAdminRealtime(); showToast("Sessão restaurada neste aparelho.","success"); }
    catch(error){ console.warn("Sessão salva inválida:",error); clearSession(); showLogin(); }
  }

  async function login(event) {
    event.preventDefault();
    const password=el.password.value; if(!password) return;
    try {
      const {data,error}=await db.rpc("admin_login_session",{p_password:password}); if(error) throw error;
      if(!data?.session_token) throw new Error("Não foi possível criar a sessão administrativa.");
      state.sessionToken=data.session_token; localStorage.setItem(SESSION_KEY,state.sessionToken);
      await refreshDashboard(); el.password.value=""; showPanel(); subscribeAdminRealtime();
      showToast("Painel liberado e sessão salva neste aparelho.","success");
    } catch(error){ console.error(error); clearSession(); if(/relation|function|schema cache|does not exist/i.test(error.message||"")) el.setupWarning.classList.remove("hidden"); showToast(error.message||"Senha incorreta.","error"); el.password.select(); }
  }

  async function refreshDashboard() {
    state.dashboard = await rpc("admin_dashboard");
    renderDashboard();
  }

  function renderDashboard() {
    const data = state.dashboard;
    if (!data) return;

    const stats = data.stats || {};
    el.available.textContent = stats.available ?? 0;
    el.pending.textContent = stats.pending ?? 0;
    const totalRaisedCents = (data.reservations || [])
      .filter(r => r.payment_status === "paid")
      .reduce((total, r) => total + Number(r.expected_amount_cents || 0), 0);
    el.paid.textContent = money(totalRaisedCents);
    el.buyers.textContent = stats.buyers ?? 0;

    renderSales(data.state || {});
    renderAvailable(data.numbers || []);
    renderNumberGrid(data.numbers || []);
    renderBuyers();
    renderWinner(data.state || {});
  }

  function renderSales(s) {
    const closed = Boolean(s.sales_closed);
    el.salesTitle.textContent = closed ? "Vendas fechadas" : "Vendas abertas";
    el.salesText.textContent = closed
      ? "Novas compras estão bloqueadas."
      : "O público ainda pode comprar números.";
    el.toggleSales.textContent = closed ? "Reabrir vendas" : "Fechar vendas";
    el.toggleSales.classList.toggle("button--danger", !closed);
    el.toggleSales.classList.toggle("button--success", closed);
  }

  function renderAvailable(numbers) {
    const available = numbers.filter(n => n.status === "available").map(n => Number(n.number));
    el.availableHeadline.textContent = `${available.length} disponíveis`;

    if (!available.length) {
      el.availableList.innerHTML = '<span class="muted">Todos os números já foram escolhidos.</span>';
      return;
    }

    el.availableList.innerHTML = available
      .map(n => `<span class="status-chip status-chip--available">${pad(n)}</span>`)
      .join("");
  }

  function renderNumberGrid(numbers) {
    const map = new Map(numbers.map(n => [Number(n.number), n.status]));
    el.numberGrid.innerHTML = Array.from({ length: cfg.totalNumbers }, (_, i) => {
      const n = i + 1;
      const status = map.get(n) || "available";
      return `<span class="number admin-number number--${status}" title="${status}">${pad(n)}</span>`;
    }).join("");
  }

  function filteredReservations() {
    const query = el.search.value.trim().toLowerCase();
    const filter = el.filter.value;

    return (state.dashboard?.reservations || []).filter(r => {
      if (filter !== "all" && r.payment_status !== filter) return false;
      if (!query) return true;
      const haystack = [
        r.buyer_name,
        r.whatsapp,
        r.order_nsu,
        r.transaction_nsu,
        ...(r.numbers || []).map(pad),
        ...(r.numbers || []).map(String)
      ].join(" ").toLowerCase();
      return haystack.includes(query);
    });
  }

  function statusBadge(status, provider = "") {
    if (status === "paid") return '<span class="payment-badge payment-badge--paid">Pago</span>';
    if (status === "expired") return '<span class="payment-badge payment-badge--expired">Expirado</span>';
    if (provider === "personal_pix") return '<span class="payment-badge payment-badge--pending">Pendente</span>';
    return '<span class="payment-badge payment-badge--pending">Em pagamento</span>';
  }

  function actionsHtml(r) {
    const paid = r.payment_status === "paid";
    const personalPix = r.payment_provider === "personal_pix";

    if (personalPix && !paid) {
      return `
        <div class="row-actions">
          <button class="mini-button mini-button--success" data-payment="${r.id}" data-paid="true">Confirmar pagamento</button>
          <button class="mini-button mini-button--danger" data-cancel="${r.id}" data-not-paid="true">Não pagou • liberar</button>
        </div>`;
    }

    return `
      <div class="row-actions">
        <button class="mini-button ${paid ? "mini-button--soft" : "mini-button--success"}" data-payment="${r.id}" data-paid="${paid ? "false" : "true"}">
          ${paid ? (personalPix ? "Voltar p/ pendente" : "Voltar p/ em pagamento") : "Confirmar pagamento"}
        </button>
        <button class="mini-button mini-button--danger" data-cancel="${r.id}">Cancelar</button>
      </div>`;
  }

  function renderBuyers() {
    const rows = filteredReservations();

    if (!rows.length) {
      el.tbody.innerHTML = '<tr><td colspan="8" class="empty-cell">Nenhum pedido encontrado.</td></tr>';
      el.cards.innerHTML = '<p class="muted">Nenhum pedido encontrado.</p>';
      return;
    }

    el.tbody.innerHTML = rows.map(r => `
      <tr>
        <td><strong>${escapeHtml(r.buyer_name)}</strong></td>
        <td>${whatsappPhoneHtml(r)}</td>
        <td><div class="table-numbers">${(r.numbers || []).map(n => `<span>${pad(n)}</span>`).join("")}</div></td>
        <td><strong>${money(r.expected_amount_cents)}</strong></td>
        <td>${statusBadge(r.payment_status, r.payment_provider)}</td>
        <td>${paymentInfo(r)}</td>
        <td>${escapeHtml(formatDate(r.created_at))}</td>
        <td>${actionsHtml(r)}</td>
      </tr>
    `).join("");

    el.cards.innerHTML = rows.map(r => `
      <article class="buyer-card">
        <div class="buyer-card__head">
          <div><strong>${escapeHtml(r.buyer_name)}</strong><small>${whatsappPhoneHtml(r)}</small></div>
          ${statusBadge(r.payment_status, r.payment_provider)}
        </div>
        <div class="table-numbers">${(r.numbers || []).map(n => `<span>${pad(n)}</span>`).join("")}</div>
        <p><strong>${money(r.expected_amount_cents)}</strong> • ${r.payment_provider === "personal_pix" ? "Pix pessoal" : "InfinitePay"}</p>
        <small>Compra iniciada em ${escapeHtml(formatDate(r.created_at))}</small>
        ${actionsHtml(r)}
      </article>
    `).join("");

    bindRowActions();
  }

  function bindRowActions() {
    document.querySelectorAll("[data-whatsapp-confirmation]").forEach(btn => {
      btn.addEventListener("click", async () => {
        const r = reservationById(btn.dataset.whatsappConfirmation);
        await handleConfirmationWhatsapp(r);
      });
    });

    document.querySelectorAll("[data-payment]").forEach(btn => {
      btn.addEventListener("click", async () => {
        const id = btn.dataset.payment;
        const paid = btn.dataset.paid === "true";
        const r = reservationById(id);
        const personalPix = r?.payment_provider === "personal_pix";
        const ok = await confirmAction({
          title: paid ? "Confirmar pagamento?" : (personalPix ? "Voltar para pendente?" : "Desmarcar pagamento?"),
          message: paid
            ? "Confirme somente se você verificou que o pagamento realmente foi recebido."
            : (personalPix ? "Os números voltarão a ficar Pendentes e continuarão bloqueados até uma nova decisão sua." : "O pedido voltará para o status Em pagamento."),
          details: reservationDetails(r),
          confirmText: paid ? "Sim, confirmar pagamento" : (personalPix ? "Sim, voltar para pendente" : "Sim, voltar para em pagamento"),
          icon: paid ? "✓" : "↩",
          danger: !paid
        });
        if (!ok) return;
        try {
          await rpc("admin_set_payment", { p_reservation_id: id, p_paid: paid });
          await refreshDashboard();
          showToast(paid ? "Pagamento confirmado." : (personalPix ? "Pedido voltou para Pendente." : "Pagamento desmarcado."), "success");
        } catch (error) { showToast(error.message, "error"); }
      });
    });

    document.querySelectorAll("[data-cancel]").forEach(btn => {
      btn.addEventListener("click", async () => {
        const id = btn.dataset.cancel;
        const r = reservationById(id);
        const notPaid = btn.dataset.notPaid === "true";
        const personalPix = r?.payment_provider === "personal_pix";
        const ok = await confirmAction({
          title: notPaid ? "Confirmar que não pagou?" : "Cancelar este pedido?",
          message: notPaid ? "Os números serão liberados imediatamente e poderão ser escolhidos por outra pessoa." : "Os números deste pedido serão liberados.",
          details: reservationDetails(r),
          confirmText: notPaid ? "Sim, não pagou • liberar" : "Sim, cancelar pedido",
          icon: "!",
          danger: true
        });
        if (!ok) return;
        try {
          await rpc("admin_cancel_reservation", { p_reservation_id: id });
          await refreshDashboard();
          showToast(personalPix && notPaid ? "Marcado como não pago. Números liberados." : "Pedido cancelado e números liberados.", "success");
        } catch (error) { showToast(error.message, "error"); }
      });
    });
  }

  function renderWinner(s) {
    if (!s.winner_number) {
      el.officialWinner.classList.add("hidden");
      el.drawControls.classList.remove("hidden");
      return;
    }

    el.officialWinnerNumber.textContent = pad(s.winner_number);
    el.officialWinnerName.textContent = s.winner_name || "";
    el.officialWinnerPhone.textContent = formatPhone(s.winner_whatsapp);
    el.officialWinnerDate.textContent = `Sorteado em ${formatDate(s.drawn_at)}`;
    el.officialWinner.classList.remove("hidden");
    el.drawControls.classList.add("hidden");
  }

  async function toggleSales() {
    const closed = Boolean(state.dashboard?.state?.sales_closed);
    const verb = closed ? "reabrir" : "fechar";
    if (!confirm(`Deseja ${verb} as vendas?`)) return;

    try {
      await rpc("admin_set_sales_closed", { p_closed: !closed });
      await refreshDashboard();
      showToast(closed ? "Vendas reabertas." : "Vendas fechadas.", "success");
    } catch (error) {
      showToast(error.message, "error");
    }
  }

  function simulateDraw() {
    const paidNumbers = (state.dashboard?.numbers || [])
      .filter(n => n.status === "paid")
      .map(n => Number(n.number));

    if (!paidNumbers.length) return showToast("Ainda não há números pagos.", "error");

    let ticks = 0;
    el.simulationResult.classList.remove("hidden");
    const timer = setInterval(() => {
      const n = paidNumbers[Math.floor(Math.random() * paidNumbers.length)];
      el.simulationResult.textContent = `SIMULAÇÃO: ${pad(n)}`;
      ticks++;
      if (ticks >= 18) {
        clearInterval(timer);
        el.simulationResult.textContent += " • NÃO SALVO";
      }
    }, 70);
  }

  async function officialDraw() {
    if (el.drawConfirm.value.trim().toUpperCase() !== "SORTEAR") return;
    if (!confirm("ATENÇÃO: este é o sorteio OFICIAL e o resultado será gravado definitivamente. Continuar?")) return;

    try {
      el.officialDraw.disabled = true;
      el.officialDraw.textContent = "Sorteando...";
      const result = await rpc("admin_draw_winner");
      await refreshDashboard();
      showToast(`Vencedor: número ${pad(result.number)}`, "success");
    } catch (error) {
      showToast(error.message, "error");
    } finally {
      el.officialDraw.textContent = "🎉 Realizar sorteio oficial";
      el.officialDraw.disabled = el.drawConfirm.value.trim().toUpperCase() !== "SORTEAR";
    }
  }

  function exportCsv() {
    const reservations = state.dashboard?.reservations || [];
    if (!reservations.length) return showToast("Não há dados para exportar.", "error");

    const rows = [
      ["Comprador", "WhatsApp", "Números", "Valor", "Status", "Pedido", "Transação", "Método", "Compra iniciada em", "Pago em", "Comprovante"],
      ...reservations.map(r => [
        r.buyer_name,
        r.whatsapp,
        (r.numbers || []).map(pad).join(" "),
        money(r.expected_amount_cents),
        r.payment_status === "paid" ? "Pago" : (r.payment_status === "expired" ? "Expirado" : "Em pagamento"),
        r.order_nsu || "",
        r.transaction_nsu || "",
        r.payment_provider === "personal_pix" ? "Pix pessoal" : (r.capture_method || "InfinitePay"),
        formatDate(r.created_at),
        formatDate(r.paid_at),
        r.receipt_url || ""
      ])
    ];

    const csv = rows.map(row =>
      row.map(value => `"${String(value ?? "").replaceAll('"', '""')}"`).join(";")
    ).join("\r\n");

    const blob = new Blob(["\ufeff" + csv], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `rifa-compradores-${new Date().toISOString().slice(0,10)}.csv`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
  }

  function subscribeAdminRealtime() {
    if (state.channel) db.removeChannel(state.channel);
    state.channel = db.channel("rifa-admin-live")
      .on("postgres_changes", { event: "*", schema: "public", table: "raffle_numbers" }, () => refreshDashboard())
      .on("postgres_changes", { event: "*", schema: "public", table: "raffle_public_state" }, () => refreshDashboard())
      .subscribe();
  }

  async function logout() {
    const token=state.sessionToken; clearSession(); state.dashboard=null;
    if(state.channel) db.removeChannel(state.channel); state.channel=null;
    if(token){ try { await db.rpc("admin_logout_session",{p_session_token:token}); } catch(error){ console.warn("Falha ao invalidar sessão:",error); } }
    showLogin(); el.password.focus(); showToast("Sessão encerrada neste aparelho.","normal");
  }

  function isStandalone(){ return window.matchMedia("(display-mode: standalone)").matches || window.navigator.standalone === true; }
  async function installAdminApp(){
    const promptEvent=state.deferredInstallPrompt; if(!promptEvent){ showToast("A opção de instalação ainda não está disponível neste navegador.","normal"); return; }
    promptEvent.prompt(); await promptEvent.userChoice; state.deferredInstallPrompt=null; el.installApp.classList.add("hidden");
  }
  function setupPwa(){
    if("serviceWorker" in navigator && /^https?:$/.test(location.protocol)) navigator.serviceWorker.register("./admin-sw.js",{scope:"./"}).catch(error=>console.warn("Service Worker não registrado:",error));
    if(isStandalone()){ el.installApp.classList.add("hidden"); return; }
    window.addEventListener("beforeinstallprompt",event=>{ event.preventDefault(); state.deferredInstallPrompt=event; el.installApp.classList.remove("hidden"); });
    window.addEventListener("appinstalled",()=>{ state.deferredInstallPrompt=null; el.installApp.classList.add("hidden"); showToast("Painel Admin instalado.","success"); });
  }

  el.loginForm.addEventListener("submit", login);
  el.installApp.addEventListener("click", installAdminApp);
  el.confirmCancel.addEventListener("click", () => closeConfirmModal(false));
  el.confirmOk.addEventListener("click", () => closeConfirmModal(true));
  el.confirmModal.querySelector(".admin-confirm-modal__backdrop").addEventListener("click", () => closeConfirmModal(false));
  el.refresh.addEventListener("click", () => refreshDashboard().catch(e => showToast(e.message, "error")));
  el.logout.addEventListener("click", logout);
  el.toggleSales.addEventListener("click", toggleSales);
  el.search.addEventListener("input", renderBuyers);
  el.filter.addEventListener("change", renderBuyers);
  el.exportCsv.addEventListener("click", exportCsv);
  el.simulate.addEventListener("click", simulateDraw);
  el.drawConfirm.addEventListener("input", () => {
    el.officialDraw.disabled = el.drawConfirm.value.trim().toUpperCase() !== "SORTEAR";
  });
  el.officialDraw.addEventListener("click", officialDraw);
  document.addEventListener("keydown", event => { if(event.key === "Escape" && !el.confirmModal.classList.contains("hidden")) closeConfirmModal(false); });
  setupPwa();
  restoreSession();
})();
