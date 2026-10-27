// Fausse API en mémoire pour tester le site sans Supabase.
// Utilisateurs : reader / r (Read), writer / w (Write), admin / a (Admin). Les données sont perdues au rechargement.
// Reproduit les règles de supabase/schema.sql (rôles, fenêtre de dates, doublons, aliment utilisé).
(() => {
  try { localStorage.removeItem("food_session"); sessionStorage.removeItem("food_session"); } catch {}

  const classes = [
    { id: 1, name: "Protéines", part_name: "protéine" },
    { id: 2, name: "Féculents", part_name: "féculent" },
    { id: 3, name: "Légumes", part_name: "légume" },
    { id: 4, name: "Laitages", part_name: "laitage" },
    { id: 5, name: "Fruits", part_name: "fruit" },
  ];
  const seed = {
    1: ["poulet", "poisson", "oeuf", "boeuf haché", "jambon"],
    2: ["riz", "pâtes", "pomme de terre", "polenta", "quinoa"],
    3: ["brocoli", "carotte", "courgette", "épinards", "haricots verts"],
    4: ["yaourt", "fromage blanc", "emmental"],
    5: ["pomme", "banane", "poire", "orange"],
  };
  let nextId = 1;
  let foods = [];
  for (const cid in seed) for (const name of seed[cid]) foods.push({ id: nextId++, name, class_id: Number(cid) });
  const byName = (n) => foods.find((f) => f.name === n).id;

  const meals = new Map(); // "date|slot" -> [food ids]
  const users = { reader: ["r", "read"], writer: ["w", "write"], admin: ["a", "admin"] };

  const zurichToday = () => new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Zurich" }).format(new Date());
  const addDays = (ds, n) => {
    const [y, m, d] = ds.split("-").map(Number);
    return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10);
  };
  const t = zurichToday();
  const put = (offset, slot, names) => meals.set(`${addDays(t, offset)}|${slot}`, names.map(byName));
  put(-2, "midi", ["poulet", "riz", "brocoli", "pomme"]);
  put(-2, "soir", ["oeuf", "pomme de terre", "carotte", "yaourt"]);
  put(-1, "soir", ["poisson", "quinoa", "courgette"]);
  put(0, "midi", ["poulet", "riz", "brocoli", "carotte", "pomme"]);
  put(1, "midi", ["boeuf haché", "pâtes", "épinards", "fromage blanc", "banane"]);
  put(2, "soir", ["jambon", "polenta", "haricots verts"]);

  const fail = (message, details) => ({ ok: false, status: 400, json: async () => ({ message, details }) });
  const ok = (body) => ({ ok: true, json: async () => body });
  const inWindow = (d) => d >= addDays(zurichToday(), -15) && d <= addDays(zurichToday(), 30);
  const clean = (n) => String(n || "").trim().toLowerCase();

  window.fetch = async (url, opts) => {
    await new Promise((r) => setTimeout(r, 150)); // latence réseau simulée
    const fn = String(url).split("/rpc/")[1];
    const a = JSON.parse(opts.body);
    const user = users[clean(a.u)];
    const role = user && user[0] === a.p ? user[1] : null;
    if (fn === "login") return ok(role);
    if (!role) return fail("invalid_password");

    switch (fn) {
      case "get_catalog":
        return ok({ classes, foods: [...foods].sort((x, y) => x.name.localeCompare(y.name)) });

      case "get_meals": {
        const rows = [];
        for (const [key, ids] of meals) {
          const [d, s] = key.split("|");
          if (d < a.d_from || d > a.d_to) continue;
          for (const id of ids) {
            const f = foods.find((x) => x.id === id);
            rows.push({ meal_date: d, slot: s, food_id: id, food_name: f.name, class_id: f.class_id });
          }
        }
        return ok(rows);
      }

      case "set_meal": {
        if (role !== "write") return fail("forbidden");
        if (!["midi", "soir"].includes(a.s)) return fail("invalid_slot");
        if (!inWindow(a.d)) return fail("out_of_window");
        const ids = [...new Set(a.food_ids)];
        if (ids.some((id) => !foods.some((f) => f.id === id))) return fail("unknown_food");
        if (ids.length) meals.set(`${a.d}|${a.s}`, ids);
        else meals.delete(`${a.d}|${a.s}`);
        return ok(null);
      }

      case "add_food": {
        if (role !== "admin") return fail("forbidden");
        const name = clean(a.n);
        if (!name || name.length > 60) return fail("invalid_name");
        const dup = foods.find((f) => f.name === name);
        if (dup) return fail(dup.class_id === a.cid ? "food_exists" : "food_exists_other_class");
        foods.push({ id: nextId++, name, class_id: a.cid });
        return ok(nextId - 1);
      }

      case "update_food": {
        if (role !== "admin") return fail("forbidden");
        const name = clean(a.n);
        const f = foods.find((x) => x.id === a.fid);
        if (!name || name.length > 60) return fail("invalid_name");
        if (!f) return fail("unknown_food");
        const dup = foods.find((x) => x.name === name && x.id !== a.fid);
        if (dup) return fail(dup.class_id === a.cid ? "food_exists" : "food_exists_other_class");
        const used = [...meals.values()].some((ids) => ids.includes(a.fid));
        if (a.cid !== f.class_id && used) return fail("food_in_use_class");
        f.name = name;
        f.class_id = a.cid;
        return ok(null);
      }

      case "delete_food": {
        if (role !== "admin") return fail("forbidden");
        const n = [...meals.values()].filter((ids) => ids.includes(a.fid)).length;
        if (n) return fail("food_in_use", String(n));
        foods = foods.filter((f) => f.id !== a.fid);
        return ok(null);
      }
    }
    return fail("unknown_function");
  };

  const banner = document.createElement("div");
  banner.textContent = "MODE TEST : données fictives en mémoire, rien n'est envoyé à Supabase. Identifiant / mot de passe : reader / r, writer / w, admin / a.";
  banner.style.cssText = "background:#fff3cd;color:#664d03;font:13px system-ui;padding:6px 12px;text-align:center;position:relative;z-index:10";
  document.addEventListener("DOMContentLoaded", () => document.body.prepend(banner));
})();
