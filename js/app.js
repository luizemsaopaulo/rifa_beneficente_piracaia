(() => {
  "use strict";

  const cfg = window.RIFA_CONFIG;
  const db = window.supabaseClient;

  const state = {
    selected: new Set(),
    numbers: new Map(),
    raffleState: null,
    ready: false,
    channel: null
  };

  const $ = (id) => document.getElementById(id);
  const el = {
    grid: $("numberGrid"),
    loading: $("loadingNumbers"),
    available: $("availableCount"),
    reserved: $("reservedCount"),
    paid: $("paidCount"),
    progressBar: $("progressBar"),
    progressText: $("progressText"),
    selectedNumbers: $("selectedNumbers"),
    clear: $("clearSelectionBtn"),
    form: $("reserveForm"),
    name: $("nameInput"),
    phone: $("phoneInput"),
    reserveButton: $("reserveButton"),
    unavailableList: $("unavailableList"),
    badge: $("connectionBadge"),
    setupWarning: $("setupWarning"),
    toast: $("toast"),
    winnerPublic: $("winnerPublic"),
    winnerPublicNumber: $("winnerPublicNumber"),
    countDays: $("countDays"),
    countHours: $("countHours"),
    countMinutes: $("countMinutes"),
    countSeconds: $("countSeconds")
  };

  function pad(n) {
    return String(n).padStart(3, "0");
  }

  function digits(value) {
    return String(value || "").replace(/\D/g, "");
  }

  function showToast(message, kind = "normal") {
    el.toast.textContent = message;
    el.toast.dataset.kind = kind;
    el.toast.classList.add("toast--show");
    clearTimeout(showToast.timer);
    showToast.timer = setTimeout(() => el.toast.classList.remove("toast--show"), 3300);
  }

  function setConnection(text, ok = false) {
    el.badge.textContent = text;
    el.badge.classList.toggle("connection-badge--ok", ok);
  }

  function showSetupError() {
    el.setupWarning.classList.remove("hidden");
    setConnection("Banco não instalado");
    el.loading.textContent = "O banco do Supabase ainda precisa ser instalado.";
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

      if (status === "reserved") {
        button.classList.add("number--reserved");
        button.disabled = true;
        button.title = "Reservado";
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
        });
      }

      fragment.appendChild(button);
    }

    el.grid.replaceChildren(fragment);
  }

  function renderStats() {
    const values = [...state.numbers.values()];
    const available = values.filter(v => v === "available").length;
    const reserved = values.filter(v => v === "reserved").length;
    const paid = values.filter(v => v === "paid").length;
    const chosen = reserved + paid;
    const percent = (chosen / cfg.totalNumbers) * 100;

    el.available.textContent = available;
    el.reserved.textContent = reserved;
    el.paid.textContent = paid;
    el.progressBar.style.width = `${percent}%`;
    el.progressText.textContent = `${chosen} de ${cfg.totalNumbers} números já escolhidos.`;
  }

  function renderSelected() {
    const values = [...state.selected].sort((a, b) => a - b);
    el.selectedNumbers.textContent = values.length ? values.map(pad).join(", ") : "Nenhum";
  }

  function renderUnavailable() {
    const unavailable = [...state.numbers.entries()]
      .filter(([, status]) => status !== "available")
      .sort((a, b) => a[0] - b[0]);

    if (!unavailable.length) {
      el.unavailableList.innerHTML = '<span class="muted">Nenhum número escolhido ainda.</span>';
      return;
    }

    el.unavailableList.innerHTML = unavailable.map(([n, status]) =>
      `<span class="status-chip status-chip--${status}">${pad(n)} • ${status === "paid" ? "Pago" : "Reservado"}</span>`
    ).join("");
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

  function renderSalesState() {
    const closed = Boolean(state.raffleState?.sales_closed);
    const pastDraw = Date.now() >= new Date(cfg.drawAt).getTime();
    el.reserveButton.disabled = closed || pastDraw;
    el.reserveButton.textContent = (closed || pastDraw) ? "Reservas encerradas" : "Confirmar reserva";
  }

  el.clear.addEventListener("click", () => {
    state.selected.clear();
    renderGrid();
    renderSelected();
  });

  el.form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!state.ready) return;

    const name = el.name.value.trim();
    const phone = digits(el.phone.value);
    const numbers = [...state.selected].sort((a, b) => a - b);

    if (numbers.length === 0) return showToast("Escolha pelo menos um número.", "error");
    if (name.length < 2) return showToast("Digite um nome válido.", "error");
    if (phone.length < 10 || phone.length > 15) return showToast("Digite um WhatsApp válido com DDD.", "error");

    el.reserveButton.disabled = true;
    el.reserveButton.textContent = "Registrando...";

    const { data, error } = await db.rpc("reserve_numbers", {
      p_name: name,
      p_whatsapp: phone,
      p_numbers: numbers
    });

    if (error) {
      console.error(error);
      showToast(error.message || "Não foi possível reservar.", "error");
      await loadAll();
      return;
    }

    state.selected.clear();
    el.form.reset();
    showToast(`Reserva confirmada: ${numbers.map(pad).join(", ")}`, "success");
    await loadAll();
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
    const days = Math.floor(sec / 86400);
    const hours = Math.floor((sec % 86400) / 3600);
    const minutes = Math.floor((sec % 3600) / 60);
    const seconds = sec % 60;

    el.countDays.textContent = String(days);
    el.countHours.textContent = String(hours).padStart(2, "0");
    el.countMinutes.textContent = String(minutes).padStart(2, "0");
    el.countSeconds.textContent = String(seconds).padStart(2, "0");
  }

  el.phone.addEventListener("input", () => {
    let v = digits(el.phone.value).slice(0, 11);
    if (v.length > 2) v = `(${v.slice(0,2)}) ${v.slice(2)}`;
    if (v.length > 10) v = `${v.slice(0,10)}-${v.slice(10)}`;
    el.phone.value = v;
  });

  updateCountdown();
  setInterval(updateCountdown, 1000);
  loadAll();

  window.addEventListener("beforeunload", () => {
    if (state.channel) db.removeChannel(state.channel);
  });
})();
