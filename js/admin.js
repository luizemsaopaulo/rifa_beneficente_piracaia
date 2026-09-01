(() => {
  "use strict";

  const cfg = window.RIFA_CONFIG;
  const db = window.supabaseClient;

  const state = {
    password: "",
    dashboard: null,
    channel: null
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
    officialDraw: $("officialDrawBtn")
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
    const method = r.capture_method === "pix" ? "Pix" : (r.capture_method ? r.capture_method : "InfinitePay");
    const receipt = r.receipt_url ? `<a href="${escapeHtml(r.receipt_url)}" target="_blank" rel="noopener noreferrer">Comprovante</a>` : "";
    return `<div><strong>${escapeHtml(method)}</strong>${receipt ? `<br><small>${receipt}</small>` : ""}</div>`;
  }

  async function rpc(name, args = {}) {
    const { data, error } = await db.rpc(name, { p_password: state.password, ...args });
    if (error) throw error;
    return data;
  }

  async function login(event) {
    event.preventDefault();
    const password = el.password.value;
    if (!password) return;

    state.password = password;

    try {
      await refreshDashboard();
      el.password.value = "";
      el.loginCard.classList.add("hidden");
      el.panel.classList.remove("hidden");
      subscribeAdminRealtime();
      showToast("Painel liberado.", "success");
    } catch (error) {
      console.error(error);
      state.password = "";
      if (/relation|function|schema cache|does not exist/i.test(error.message || "")) {
        el.setupWarning.classList.remove("hidden");
      }
      showToast(error.message || "Senha incorreta.", "error");
      el.password.select();
    }
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
    el.paid.textContent = stats.paid ?? 0;
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

  function statusBadge(status) {
    return status === "paid"
      ? '<span class="payment-badge payment-badge--paid">Pago</span>'
      : '<span class="payment-badge payment-badge--pending">Em pagamento</span>';
  }

  function actionsHtml(r) {
    const paid = r.payment_status === "paid";
    return `
      <div class="row-actions">
        <button class="mini-button ${paid ? "mini-button--soft" : "mini-button--success"}" data-payment="${r.id}" data-paid="${paid ? "false" : "true"}">
          ${paid ? "Voltar p/ em pagamento" : "Confirmar pagamento"}
        </button>
        <button class="mini-button mini-button--danger" data-cancel="${r.id}">Cancelar</button>
      </div>
    `;
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
        <td>${escapeHtml(formatPhone(r.whatsapp))}</td>
        <td><div class="table-numbers">${(r.numbers || []).map(n => `<span>${pad(n)}</span>`).join("")}</div></td>
        <td><strong>${money(r.expected_amount_cents)}</strong></td>
        <td>${statusBadge(r.payment_status)}</td>
        <td>${paymentInfo(r)}</td>
        <td>${escapeHtml(formatDate(r.created_at))}</td>
        <td>${actionsHtml(r)}</td>
      </tr>
    `).join("");

    el.cards.innerHTML = rows.map(r => `
      <article class="buyer-card">
        <div class="buyer-card__head">
          <div><strong>${escapeHtml(r.buyer_name)}</strong><small>${escapeHtml(formatPhone(r.whatsapp))}</small></div>
          ${statusBadge(r.payment_status)}
        </div>
        <div class="table-numbers">${(r.numbers || []).map(n => `<span>${pad(n)}</span>`).join("")}</div>
        <p><strong>${money(r.expected_amount_cents)}</strong> • InfinitePay</p>
        <small>Compra iniciada em ${escapeHtml(formatDate(r.created_at))}</small>
        ${actionsHtml(r)}
      </article>
    `).join("");

    bindRowActions();
  }

  function bindRowActions() {
    document.querySelectorAll("[data-payment]").forEach(btn => {
      btn.addEventListener("click", async () => {
        const id = btn.dataset.payment;
        const paid = btn.dataset.paid === "true";
        const action = paid ? "confirmar o pagamento" : "voltar este pedido para pagamento em andamento";
        if (!confirm(`Deseja ${action}?`)) return;

        try {
          await rpc("admin_set_payment", { p_reservation_id: id, p_paid: paid });
          await refreshDashboard();
          showToast(paid ? "Pagamento confirmado." : "Pagamento desmarcado.", "success");
        } catch (error) {
          showToast(error.message, "error");
        }
      });
    });

    document.querySelectorAll("[data-cancel]").forEach(btn => {
      btn.addEventListener("click", async () => {
        const id = btn.dataset.cancel;
        if (!confirm("Liberar os números deste pedido?")) return;

        try {
          await rpc("admin_cancel_reservation", { p_reservation_id: id });
          await refreshDashboard();
          showToast("Pedido cancelado e números liberados.", "success");
        } catch (error) {
          showToast(error.message, "error");
        }
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
        r.payment_status === "paid" ? "Pago" : "Em pagamento",
        r.order_nsu || "",
        r.transaction_nsu || "",
        r.capture_method || "InfinitePay",
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

  function logout() {
    state.password = "";
    state.dashboard = null;
    if (state.channel) db.removeChannel(state.channel);
    state.channel = null;
    el.panel.classList.add("hidden");
    el.loginCard.classList.remove("hidden");
    el.password.focus();
  }

  el.loginForm.addEventListener("submit", login);
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
})();
