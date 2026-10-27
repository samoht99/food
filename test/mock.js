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
    { id: 5, name: "Autres", part_name: "divers" },
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
  for (const cid in seed) for (const name of seed[cid]) foods.push({ id: nextId++, name, class_ids: [Number(cid)] });
  foods.push({ id: nextId++, name: "sandwich jambon-salade", class_ids: [1, 2, 3] });
  foods.push({ id: nextId++, name: "pizza", class_ids: [1, 2, 4] });
  const byName = (n) => foods.find((f) => f.name === n).id;

  const meals = new Map(); // "date|slot" -> [food ids]
  let nextConId = 1;
  let constraints = ["Télétravail", "Repas au bureau", "Invités", "Sans viande"].map((name) => ({ id: nextConId++, name }));
  const dayCons = new Map(); // "date" -> [ids de contraintes]
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
  put(1, "soir", ["sandwich jambon-salade", "pomme"]);
  dayCons.set(addDays(t, 0), [1]);
  dayCons.set(addDays(t, 1), [3, 4]);
  dayCons.set(addDays(t, -20), [2]); // hors des 15 jours affichés
  put(-20, "midi", ["poisson", "riz", "courgette", "yaourt"]); // hors des 15 jours affichés, encore en base

  const fail = (message, details) => ({ ok: false, status: 400, json: async () => ({ message, details }) });
  const ok = (body) => ({ ok: true, status: 200, text: async () => JSON.stringify(body), json: async () => body });
  // Fonction PostgreSQL qui renvoie void : PostgREST répond 204 avec un corps vide (res.json() échoue).
  const voidOk = () => ({
    ok: true, status: 204, text: async () => "",
    json: async () => { throw new SyntaxError("Unexpected end of JSON input"); },
  });
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
            rows.push({ meal_date: d, slot: s, food_id: id, food_name: f.name, class_ids: [...f.class_ids].sort((x, y) => x - y) });
          }
        }
        return ok(rows);
      }

      case "get_constraints":
        return ok([...constraints]
          .sort((x, y) => x.name.localeCompare(y.name, "fr"))
          .map((k) => ({ id: k.id, name: k.name, uses: [...dayCons.values()].filter((ids) => ids.includes(k.id)).length })));

      case "get_day_constraints": {
        const rows = [];
        for (const [d, ids] of [...dayCons].sort()) {
          if (d < a.d_from || d > a.d_to) continue;
          for (const id of [...ids].sort((x, y) => x - y)) rows.push({ day_date: d, constraint_id: id });
        }
        return ok(rows);
      }

      case "set_day_constraints": {
        if (role !== "write" && role !== "admin") return fail("forbidden");
        if (!inWindow(a.d)) return fail("out_of_window");
        const ids = [...new Set(a.cids || [])];
        if (ids.some((id) => !constraints.some((k) => k.id === id))) return fail("unknown_constraint");
        if (ids.length) dayCons.set(a.d, ids);
        else dayCons.delete(a.d);
        return voidOk();
      }

      case "add_constraint": {
        if (role !== "admin") return fail("forbidden");
        const name = String(a.n || "").trim();
        if (!name || name.length > 60) return fail("invalid_name");
        if (constraints.some((k) => k.name.toLowerCase() === name.toLowerCase())) return fail("constraint_exists");
        constraints.push({ id: nextConId++, name });
        return ok(nextConId - 1);
      }

      case "update_constraint": {
        if (role !== "admin") return fail("forbidden");
        const name = String(a.n || "").trim();
        const k = constraints.find((x) => x.id === a.cid);
        if (!name || name.length > 60) return fail("invalid_name");
        if (!k) return fail("unknown_constraint");
        if (constraints.some((x) => x.id !== a.cid && x.name.toLowerCase() === name.toLowerCase())) return fail("constraint_exists");
        k.name = name;
        return voidOk();
      }

      case "delete_constraint": {
        if (role !== "admin") return fail("forbidden");
        const n = [...dayCons.values()].filter((ids) => ids.includes(a.cid)).length;
        if (n) return fail("constraint_in_use", String(n));
        constraints = constraints.filter((k) => k.id !== a.cid);
        return voidOk();
      }

      case "set_meal": {
        if (role !== "write" && role !== "admin") return fail("forbidden");
        if (!["midi", "soir"].includes(a.s)) return fail("invalid_slot");
        if (!inWindow(a.d)) return fail("out_of_window");
        const ids = [...new Set(a.food_ids)];
        if (ids.some((id) => !foods.some((f) => f.id === id))) return fail("unknown_food");
        if (ids.length) meals.set(`${a.d}|${a.s}`, ids);
        else meals.delete(`${a.d}|${a.s}`);
        return voidOk();
      }

      case "add_food": {
        if (role !== "admin") return fail("forbidden");
        const name = clean(a.n);
        if (!name || name.length > 60) return fail("invalid_name");
        const cids = [...new Set(a.cids || [])].sort((x, y) => x - y);
        if (!cids.length) return fail("invalid_classes");
        if (cids.some((c) => !classes.some((k) => k.id === c))) return fail("unknown_class");
        if (foods.some((f) => f.name === name)) return fail("food_exists");
        foods.push({ id: nextId++, name, class_ids: cids });
        return ok(nextId - 1);
      }

      case "update_food": {
        if (role !== "admin") return fail("forbidden");
        const name = clean(a.n);
        const f = foods.find((x) => x.id === a.fid);
        if (!name || name.length > 60) return fail("invalid_name");
        if (!f) return fail("unknown_food");
        const cids = [...new Set(a.cids || [])].sort((x, y) => x - y);
        if (!cids.length) return fail("invalid_classes");
        if (cids.some((c) => !classes.some((k) => k.id === c))) return fail("unknown_class");
        if (foods.some((x) => x.name === name && x.id !== a.fid)) return fail("food_exists");
        const used = [...meals.values()].some((ids) => ids.includes(a.fid));
        // On peut ajouter des classes à un aliment utilisé, pas en retirer.
        if (used && f.class_ids.some((c) => !cids.includes(c))) return fail("food_in_use_class");
        f.name = name;
        f.class_ids = cids;
        return voidOk();
      }

      case "delete_food": {
        if (role !== "admin") return fail("forbidden");
        const n = [...meals.values()].filter((ids) => ids.includes(a.fid)).length;
        if (n) return fail("food_in_use", String(n));
        foods = foods.filter((f) => f.id !== a.fid);
        return voidOk();
      }
    }
    return fail("unknown_function");
  };

  const banner = document.createElement("div");
  banner.textContent = "MODE TEST : données fictives en mémoire, rien n'est envoyé à Supabase. Identifiant / mot de passe : reader / r, writer / w, admin / a.";
  banner.style.cssText = "background:#fff3cd;color:#664d03;font:13px system-ui;padding:6px 12px;text-align:center;position:relative;z-index:10";
  document.addEventListener("DOMContentLoaded", () => document.body.prepend(banner));
})();
