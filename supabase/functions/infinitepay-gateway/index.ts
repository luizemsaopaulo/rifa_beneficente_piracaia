import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
});

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const HANDLE = "luizwl";
const UNIT_PRICE = 1000;

async function getReservation(orderNsu: string) {
  const { data, error } = await db
    .from("reservations")
    .select("id,numbers,payment_status,expected_amount_cents,checkout_url,order_nsu")
    .eq("order_nsu", orderNsu)
    .single();
  if (error || !data) throw new Error("Pedido não encontrado.");
  return data;
}

async function verifyAndConfirm(payload: {
  order_nsu: string;
  transaction_nsu: string;
  slug: string;
  receipt_url?: string | null;
}) {
  if (!payload.order_nsu || !payload.transaction_nsu || !payload.slug) {
    throw new Error("Dados do pagamento incompletos.");
  }

  const reservation = await getReservation(payload.order_nsu);
  if (reservation.payment_status === "paid") return { ok: true, paid: true, already_paid: true };

  const checkResponse = await fetch("https://api.checkout.infinitepay.io/payment_check", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      handle: HANDLE,
      order_nsu: payload.order_nsu,
      transaction_nsu: payload.transaction_nsu,
      slug: payload.slug,
    }),
  });

  if (!checkResponse.ok) throw new Error("Não foi possível validar o pagamento na InfinitePay.");
  const check = await checkResponse.json();
  if (!check?.success || !check?.paid) return { ok: true, paid: false };

  const expected = Number(reservation.expected_amount_cents);
  const received = Number(check.amount);
  if (!Number.isFinite(received) || received !== expected) {
    throw new Error(`Valor divergente. Esperado ${expected}, recebido ${received}.`);
  }

  const { data, error } = await db.rpc("confirm_infinitepay_payment", {
    p_order_nsu: payload.order_nsu,
    p_transaction_nsu: payload.transaction_nsu,
    p_receipt_url: payload.receipt_url || null,
    p_capture_method: check.capture_method || null,
    p_amount_cents: received,
  });
  if (error) throw error;
  return { ok: true, paid: true, data };
}

async function createCheckout(body: any) {
  const orderNsu = String(body.order_nsu || "");
  const redirectUrl = String(body.redirect_url || "");
  if (!orderNsu) throw new Error("order_nsu não informado.");

  let redirect: URL;
  try { redirect = new URL(redirectUrl); }
  catch { throw new Error("redirect_url inválida."); }
  if (!["http:", "https:"].includes(redirect.protocol)) throw new Error("redirect_url inválida.");

  const reservation = await getReservation(orderNsu);
  if (reservation.payment_status === "paid") return { paid: true, order_nsu: orderNsu };
  if (reservation.checkout_url) return { url: reservation.checkout_url, reused: true };

  const numbers = Array.isArray(reservation.numbers) ? reservation.numbers : [];
  if (!numbers.length) throw new Error("Reserva sem números.");
  const expected = numbers.length * UNIT_PRICE;
  if (Number(reservation.expected_amount_cents) !== expected) throw new Error("Valor interno da reserva está incorreto.");

  const webhookUrl = `${SUPABASE_URL}/functions/v1/infinitepay-gateway`;
  const response = await fetch("https://api.checkout.infinitepay.io/links", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      handle: HANDLE,
      redirect_url: redirect.toString(),
      webhook_url: webhookUrl,
      order_nsu: orderNsu,
      items: [{
        quantity: numbers.length,
        price: UNIT_PRICE,
        description: `Rifa Beneficente - ${numbers.length} número(s)`,
      }],
    }),
  });

  const result = await response.json().catch(() => ({}));
  if (!response.ok || !result?.url) throw new Error(result?.message || "A InfinitePay não gerou o checkout.");

  await db.from("reservations").update({
    checkout_url: result.url,
    checkout_created_at: new Date().toISOString(),
  }).eq("id", reservation.id);

  return { url: result.url, order_nsu: orderNsu, amount_cents: expected };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ success: false, message: "Método não permitido." }, 405);

  try {
    const body = await req.json();

    if (body?.action === "create") {
      return json(await createCheckout(body));
    }

    if (body?.action === "confirm") {
      const result = await verifyAndConfirm({
        order_nsu: String(body.order_nsu || ""),
        transaction_nsu: String(body.transaction_nsu || ""),
        slug: String(body.slug || ""),
        receipt_url: body.receipt_url || null,
      });
      return json(result);
    }

    // Webhook da InfinitePay
    const task = verifyAndConfirm({
      order_nsu: String(body.order_nsu || ""),
      transaction_nsu: String(body.transaction_nsu || ""),
      slug: String(body.invoice_slug || body.slug || ""),
      receipt_url: body.receipt_url || null,
    });

    const runtime = (globalThis as any).EdgeRuntime;
    if (runtime?.waitUntil) {
      runtime.waitUntil(task.catch((error: unknown) => console.error("Webhook InfinitePay:", error)));
      return json({ success: true, message: null });
    }

    await task;
    return json({ success: true, message: null });
  } catch (error) {
    console.error(error);
    return json({ success: false, message: error instanceof Error ? error.message : "Erro interno." }, 400);
  }
});
