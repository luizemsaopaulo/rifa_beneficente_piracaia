window.RIFA_CONFIG = {
  totalNumbers: 200,
  unitPriceCents: 1000,
  unitPriceText: "R$ 10,00",
  prizeText: "R$ 200 no Pix",
  drawAt: "2026-10-18T20:00:00-03:00",
  drawDateText: "18/10/2026",
  drawTimeText: "20h",
  instagramHandle: "@TUDODEHELENA",
  instagramUrl: "https://www.instagram.com/TUDODEHELENA/",
  reports: {
    g1: "https://g1.globo.com/sp/vale-do-paraiba-regiao/noticia/2026/09/01/temporal-com-granizo-gigante-destelha-mais-de-400-casas-e-destroi-carros-em-piracaia-sp.ghtml",
    youtube: "https://www.youtube.com/watch?v=E1zrlKCCSYE"
  },
  infinitePay: {
    handle: "luizwl",
    gatewayUrl: "https://qzpezwscmwfznzzbrxpb.supabase.co/functions/v1/infinitepay-gateway"
  },
  personalPix: {
    key: "11947406124",
    owner: "Waldemar Jose Luiz",
    whatsapp: "5511947406124"
  },
  supabase: {
    url: "https://qzpezwscmwfznzzbrxpb.supabase.co",
    publishableKey: "sb_publishable_ZlViveYUmVgzUASUU7ETeg_AIRsZSbf"
  }
};

window.supabaseClient = window.supabase.createClient(
  window.RIFA_CONFIG.supabase.url,
  window.RIFA_CONFIG.supabase.publishableKey
);
