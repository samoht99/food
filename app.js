// Ces deux valeurs sont publiques par conception (la sécurité repose sur la base).
const SUPABASE_URL = "https://bwcizhvhtwkjfjadurcj.supabase.co";
const SUPABASE_KEY = "sb_publishable_KLQZ-MuQKYbV1_GUvOFk9Q_nfumGtNc";

const SUPABASE_SCHEMA = "food";

// Read et Write : mot de passe gardé dans le navigateur (session persistante).
// Admin : gardé uniquement le temps de l'onglet (révoqué à sa fermeture).
const STORAGE_KEY = "food_session"; // JSON { u: identifiant, p: mot de passe }

const DAYS_BEFORE = 15;
const DAYS_AFTER = 30;
const SLOTS = ["midi", "soir"];

const $ = (id) => document.getElementById(id);
const gate = $("gate");
const gateForm = $("gate-form");
const gateError = $("gate-error");
const userInput = $("user-id");
const passwordInput = $("password");
const app = $("app");
const todayBtn = $("today-btn");

// Message d'erreur : bandeau fixe en haut de l'écran (visible quel que soit le défilement),
// qui disparaît seul ou au clic. Écrire dans statusEl.textContent l'affiche ; "" le masque.
const toast = $("status");
let toastTimer = 0;
const statusEl = {
  set textContent(msg) {
    clearTimeout(toastTimer);
    toast.textContent = msg;
    toast.hidden = !msg;
    if (msg) toastTimer = setTimeout(() => { toast.hidden = true; }, 8000);
  },
};
toast.addEventListener("click", () => { statusEl.textContent = ""; });

// Ferme une boîte de dialogue quand on clique en dehors de sa zone visible (sur le fond).
// On compare avec les coordonnées : un clic sur le bord intérieur de la boîte ne la ferme pas,
// et il faut que l'appui ET le relâchement soient en dehors (un clic qui commence dans la boîte
// et finit dehors, par exemple si la boîte change de taille, ne la ferme pas).
function closeOnBackdrop(dialog, value) {
  const outside = (e) => {
    const r = dialog.getBoundingClientRect();
    return e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom;
  };
  let pressedOutside = false;
  dialog.addEventListener("pointerdown", (e) => { pressedOutside = outside(e); });
  dialog.addEventListener("click", (e) => {
    if (pressedOutside && outside(e)) dialog.close(value);
    pressedOutside = false;
  });
}

let userId = "";
let password = "";
// Identifiants envoyés à chaque appel : la base revérifie le mot de passe et le rôle à chaque fois.
const auth = () => ({ u: userId, p: password });
let role = "";
let classes = [];
let foods = [];
// foods : [{ id, name, class_ids }] ; un aliment peut avoir plusieurs classes (ex. un sandwich).
let meals = new Map(); // "2026-10-27|midi" -> [{ id, name, class_ids }]
// Contraintes de jour : texte informatif affiché sur un jour, sans effet sur le comportement du site.
let constraints = []; // [{ id, name, uses }] : liste des contraintes possibles (gérée par l'admin)
let dayConstraints = new Map(); // "2026-10-27" -> [ids de contraintes]
let units = []; // [{ id, name, plural }] : unités possibles d'un ingrédient (liste fixe, gérée en SQL)
let effects = []; // [{ id, name, description, blocked_slot }] : effets possibles d'une contrainte (liste fixe, gérée en SQL)
let ingredients = []; // [{ id, name, uses }] : liste des ingrédients (admin uniquement)
let adminSection = "foods"; // onglet Admin : "foods" | "ingredients" | "constraints"
let currentTab = "home";
let today = "";
let adminClassId = null;
let adminSearch = "";
let adminUsage = "all"; // filtre d'utilisation des listes Admin : "all" | "used" | "unused"

// ------------------------------------------------------------------ Réseau
async function rpc(name, args) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: SUPABASE_KEY,
      "Content-Profile": SUPABASE_SCHEMA, // schéma PostgreSQL où vivent les fonctions
    },
    body: JSON.stringify(args),
  });
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    const err = new Error(body.message || `Erreur ${res.status}`);
    err.code = body.message;
    err.details = body.details;
    err.invalidPassword = body.message === "invalid_password";
    throw err;
  }
  // Une fonction qui ne renvoie rien (set_meal, update_food, delete_food) répond avec un corps vide :
  // on ne lit donc pas la réponse comme du JSON sans vérifier qu'il y en a une.
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

// Quand la suppression d'un aliment, d'un ingrédient ou d'une contrainte est refusée parce qu'il est
// utilisé, la base renvoie en détail { n: nombre, items: [ce qui l'utilise] } (en texte JSON).
function usageOf(e) {
  try {
    const d = JSON.parse(e.details);
    return { n: Number(d.n) || 0, slot: d.slot || "", items: Array.isArray(d.items) ? d.items : [] };
  } catch {
    return { n: 0, slot: "", items: [] };
  }
}

function errorText(e) {
  switch (e.code) {
    case "food_exists": return "Cet aliment existe déjà.";
    case "food_in_use":
      return `Cet aliment est utilisé dans ${usageOf(e).n || "plusieurs"} repas. Retirez-le de ces repas avant de le supprimer.`;
    case "food_in_use_class":
      return "Cet aliment est utilisé dans des repas : vous pouvez lui ajouter des classes, mais pas en retirer.";
    case "invalid_classes": return "Choisissez au moins une classe.";
    case "class_component_required": return "Choisissez au moins une classe d'aliment autre que Recettes.";
    case "ingredients_required": return "Une recette doit avoir au moins un ingrédient.";
    case "ingredient_exists": return "Cet ingrédient existe déjà.";
    case "ingredient_in_use":
      return `Cet ingrédient est utilisé par ${usageOf(e).n || "plusieurs"} aliment(s). Retirez-le de ces aliments avant de le supprimer.`;
    case "ingredient_of_simple_food": return "Cet ingrédient est celui d'un aliment simple : renommez plutôt l'aliment.";
    case "unknown_ingredient": return "Un ingrédient sélectionné n'existe plus. Rechargez la page.";
    case "invalid_portions": return "Le nombre de portions doit être supérieur à 0 (99 au plus, 2 décimales au plus).";
    case "invalid_quantity": return "La quantité doit être un nombre supérieur à 0 (laissez vide si elle n'est pas définie).";
    case "unknown_unit": return "Une unité sélectionnée n'existe plus. Rechargez la page.";
    case "slot_blocked": return "Ce repas est bloqué par une contrainte du jour : retirez-la pour pouvoir le remplir.";
    case "meal_in_blocked_slot":
      return `Le repas du ${e.details || "créneau bloqué"} de ce jour est rempli : videz-le avant d'attribuer cette contrainte.`;
    case "effect_conflict": return "Cet effet bloquerait des repas déjà remplis. Videz-les d'abord.";
    case "unknown_effect": return "Un effet sélectionné n'existe plus. Rechargez la page.";
    case "unknown_class": return "Une classe sélectionnée n'existe plus. Rechargez la page.";
    case "invalid_name": return "Le nom est invalide (1 à 60 caractères).";
    case "constraint_exists": return "Cette contrainte existe déjà.";
    case "constraint_in_use":
      return `Cette contrainte est attribuée à ${usageOf(e).n || "plusieurs"} jour(s). Retirez-la de ces jours avant de la supprimer.`;
    case "unknown_constraint": return "Une contrainte sélectionnée n'existe plus. Rechargez la page.";
    case "out_of_window": return "Ce jour n'est pas modifiable.";
    case "unknown_food": return "Un aliment sélectionné n'existe plus. Rechargez la page.";
    case "forbidden": return "Action non autorisée avec ce mot de passe.";
    default: return "Une erreur est survenue. Réessayez plus tard.";
  }
}

// Affiche l'erreur dans la zone voulue ; renvoie true si la session a expiré.
function fail(e, target = statusEl) {
  if (e.invalidPassword) { lock(); return true; }
  target.textContent = errorText(e);
  return false;
}

// --------------------------------------------------------- Quantités et unités
const numberFormat = new Intl.NumberFormat("fr-FR", { maximumFractionDigits: 2 });
const fmtNum = (n) => numberFormat.format(n);
const round2 = (n) => Math.round(n * 100) / 100;
const unitOf = (id) => units.find((u) => u.id === id) || { name: "", plural: "" };
// « 375 g », « 1,5 pièce », « 2 pièces » (pluriel à partir de 2).
const fmtQty = (q, unitId) => {
  const u = unitOf(unitId);
  return `${fmtNum(q)} ${q >= 2 ? u.plural : u.name}`.trim();
};

// ------------------------------------------------------------------- Dates
function zurichToday() {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Zurich" }).format(new Date());
}

function addDays(ds, n) {
  const [y, m, d] = ds.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10);
}

function fmtDay(ds) {
  const [y, m, d] = ds.split("-").map(Number);
  const s = new Date(Date.UTC(y, m - 1, d)).toLocaleDateString("fr-FR", {
    weekday: "long", day: "numeric", month: "long", timeZone: "UTC",
  });
  return s[0].toUpperCase() + s.slice(1);
}

// -------------------------------------------------------------------- Données
async function loadCatalog() {
  const cat = await rpc("get_catalog", auth());
  classes = cat.classes;
  units = cat.units || [];
  foods = cat.foods;
  if (!classes.some((c) => c.id === adminClassId)) adminClassId = classes[0] ? classes[0].id : null;
}

// Les contraintes de jour sont accessoires : si leur chargement échoue (sauf mot de passe refusé),
// on affiche quand même les repas, sans contraintes.
const optional = (promise) => promise.catch((e) => {
  if (e.invalidPassword) throw e;
  return [];
});

async function loadConstraints() {
  constraints = await optional(rpc("get_constraints", auth()));
}

// Les effets des contraintes sont accessoires aussi : sans eux (base pas encore à jour), aucun créneau n'est bloqué.
async function loadEffects() {
  effects = await optional(rpc("get_effects", auth()));
}

const effectOf = (k) => effects.find((e) => e.id === k.effect_id) || null;

// Créneaux bloqués un jour donné par les effets des contraintes de ce jour :
// Map "midi" | "soir" -> nom de la contrainte qui le bloque.
function blockedSlots(date) {
  const slots = new Map();
  for (const id of dayConstraints.get(date) || []) {
    const k = constraints.find((c) => c.id === id);
    const e = k && effectOf(k);
    if (e && e.blocked_slot) slots.set(e.blocked_slot, k.name);
  }
  return slots;
}

// Les ingrédients ne concernent que l'admin (liste de l'onglet Admin, suggestions des recettes).
async function loadIngredients() {
  ingredients = role === "admin" ? await optional(rpc("get_ingredients", auth())) : [];
}

// Aliments et ingrédients vont ensemble : une recette crée des ingrédients, un aliment simple aussi.
const loadFoodsAndIngredients = () => Promise.all([loadCatalog(), loadIngredients()]);

async function loadMeals() {
  today = zurichToday();
  const range = { d_from: addDays(today, -DAYS_BEFORE), d_to: addDays(today, DAYS_AFTER) };
  const [rows, dayRows] = await Promise.all([
    rpc("get_meals", { ...auth(), ...range }),
    optional(rpc("get_day_constraints", { ...auth(), ...range })),
  ]);
  dayConstraints = new Map();
  for (const r of dayRows) {
    if (!dayConstraints.has(r.day_date)) dayConstraints.set(r.day_date, []);
    dayConstraints.get(r.day_date).push(r.constraint_id);
  }
  meals = new Map();
  for (const r of rows) {
    const key = `${r.meal_date}|${r.slot}`;
    if (!meals.has(key)) meals.set(key, []);
    meals.get(key).push({ id: r.food_id, name: r.food_name, class_ids: r.class_ids || [], portions: Number(r.portions) || 1 });
  }
}

async function loadAll() {
  try {
    await Promise.all([loadCatalog(), loadConstraints(), loadMeals(), loadIngredients(), loadEffects()]);
    statusEl.textContent = "";
    render();
  } catch (e) {
    if (!fail(e)) statusEl.textContent = "Impossible de charger les données. Réessayez plus tard.";
  }
}

async function reloadMeals() {
  // L'indication d'utilisation de l'onglet Admin (aliments, contraintes) dépend des repas et des jours.
  await Promise.all([loadMeals(), role === "admin" ? Promise.all([loadCatalog(), loadConstraints()]) : null]);
  const y = window.scrollY;
  renderHome();
  renderMeals();
  renderAdmin();
  window.scrollTo(0, y);
  updateTodayBtn();
}

// ------------------------------------------------------------------ Rendu
function el(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined) n.textContent = text;
  return n;
}

function button(cls, text, onClick) {
  const b = el("button", cls, text);
  b.type = "button";
  b.addEventListener("click", onClick);
  return b;
}

function mealBlock(date, slot, editable) {
  const items = meals.get(`${date}|${slot}`) || [];
  // Créneau bloqué par une contrainte du jour (effet) : pas de génération possible ; pour pouvoir le
  // remplir à nouveau il faut retirer la contrainte du jour.
  const blocked = blockedSlots(date).has(slot);
  const box = el("div", "meal");
  const head = el("div", "meal-head");
  head.append(el("span", "meal-name", slot));

  if (editable) {
    const btns = el("div", "meal-btns");
    if (items.length) {
      // Un repas déjà rempli sur un créneau bloqué (antérieur à la règle) ne peut plus qu'être vidé.
      if (!blocked) btns.append(button("btn-sm", "Modifier", () => openMeal(date, slot)));
      btns.append(button("btn-sm danger", "Vider", () => clearMeal(date, slot)));
    } else if (!blocked) {
      btns.append(button("btn-sm", "Générer repas manuel", () => openMeal(date, slot)));
    }
    if (btns.children.length) head.append(btns);
  }
  box.append(head);

  if (!items.length) {
    box.append(el("p", "meal-empty", blocked ? "pas de repas" : "vide"));
    return box;
  }
  // Les aliments qui ont exactement les mêmes classes sont regroupés sur une ligne
  // ("poulet, jambon · Protéines") ; un aliment multi-classes apparaît une seule fois
  // avec toutes ses classes ("sandwich · Protéines, Féculents, Légumes").
  const pos = (id) => classes.findIndex((c) => c.id === id);
  const groups = new Map();
  for (const f of items) {
    const key = f.class_ids.join(",");
    if (!groups.has(key)) groups.set(key, { ids: f.class_ids, names: [] });
    // Un nombre de portions différent de 1 est indiqué à côté du nom (« poulet ×1,5 »).
    groups.get(key).names.push(f.portions === 1 ? f.name : `${f.name} ×${fmtNum(f.portions)}`);
  }
  const ordered = [...groups.values()].sort(
    (a, b) => Math.min(...a.ids.map(pos)) - Math.min(...b.ids.map(pos)) || a.ids.length - b.ids.length
  );
  for (const g of ordered) {
    const line = el("p", "meal-line", g.names.join(", "));
    const label = g.ids.map((id) => (classes[pos(id)] || {}).name).filter(Boolean).join(", ");
    line.append(el("span", "cls", label));
    box.append(line);
  }
  // Bouton « Ingrédients » : déplie les ingrédients de chaque aliment du repas avec leur quantité.
  const detail = mealIngredients(items);
  detail.hidden = true;
  const toggle = button("link-btn meal-ing-toggle", "Ingrédients ▾", () => {
    detail.hidden = !detail.hidden;
    toggle.textContent = detail.hidden ? "Ingrédients ▾" : "Ingrédients ▴";
  });
  box.append(toggle, detail);
  return box;
}

// Détail des ingrédients d'un repas : pour chaque aliment, ses ingrédients avec la quantité du repas
// (quantité pour 1 portion × nombre de portions de l'aliment dans ce repas).
function mealIngredients(items) {
  const box = el("div", "meal-detail");
  for (const it of [...items].sort((a, b) => a.name.localeCompare(b.name, "fr"))) {
    const food = foods.find((f) => f.id === it.id);
    const head = el("p", "md-food", it.name);
    if (it.portions !== 1) head.append(el("span", "md-portions", ` ×${fmtNum(it.portions)}`));
    box.append(head);
    const list = el("ul", "md-list");
    for (const ing of (food && food.ingredients) || []) {
      const li = el("li");
      li.append(el("span", "md-name", ing.name));
      li.append(el("span", ing.quantity == null ? "md-qty none" : "md-qty",
        ing.quantity == null ? "quantité non définie" : fmtQty(round2(ing.quantity * it.portions), ing.unit_id)));
      list.append(li);
    }
    if (!list.children.length) list.append(el("li", "md-none", "aucun ingrédient"));
    box.append(list);
  }
  return box;
}

function dayCard(date, editable) {
  const card = el("article", "day" + (date === today ? " today" : ""));
  card.dataset.date = date;
  const head = el("div", "day-head");
  const title = el("h3", "day-title", fmtDay(date));
  if (date === today) title.append(el("small", "", "aujourd'hui"));
  else if (date === addDays(today, 1)) title.append(el("small", "", "demain"));
  head.append(title);
  // Contraintes du jour, en haut à droite. Seul le mode write peut les modifier (clic dessus).
  const names = (dayConstraints.get(date) || [])
    .map((id) => constraints.find((k) => k.id === id))
    .filter(Boolean)
    .sort((a, b) => a.name.localeCompare(b.name, "fr"))
    .map((k) => k.name);
  const chips = () => names.map((n) => el("span", "day-chip", n));
  if (editable) {
    const b = el("button", "day-constraints editable");
    b.type = "button";
    b.setAttribute("aria-label", `Contraintes du ${fmtDay(date)}`);
    if (names.length) b.append(...chips());
    else b.append(el("span", "day-chip empty", "+ Contrainte"));
    b.addEventListener("click", () => openDayConstraints(date));
    head.append(b);
  } else if (names.length) {
    const box = el("div", "day-constraints");
    box.append(...chips());
    head.append(box);
  }
  card.append(head);
  for (const slot of SLOTS) card.append(mealBlock(date, slot, editable));
  return card;
}

function renderHome() {
  const root = $("tab-home");
  root.replaceChildren(el("h2", "section-title", "Aujourd'hui et demain"));
  root.append(dayCard(today, false), dayCard(addDays(today, 1), false));
  const more = el("p", "empty");
  more.append(button("btn-primary", "Voir tous les repas", () => switchTab("meals")));
  root.append(more);
}

function renderMeals() {
  const root = $("tab-meals");
  root.replaceChildren();
  const editable = role === "write" || role === "admin"; // l'admin a aussi les droits d'écriture sur les repas et les contraintes de jour
  for (let i = -DAYS_BEFORE; i <= DAYS_AFTER; i++) root.append(dayCard(addDays(today, i), editable));
}

function render() {
  renderHome();
  renderMeals();
  renderAdmin();
}

// ------------------------------------------------------------------ Onglets
function switchTab(name) {
  currentTab = name;
  for (const t of ["home", "meals", "admin"]) $(`tab-${t}`).hidden = t !== name;
  for (const b of $("tabs").querySelectorAll("button")) b.classList.toggle("on", b.dataset.tab === name);
  if (name === "meals") scrollToToday();
  else window.scrollTo(0, 0);
  updateTodayBtn();
}

function todayCard() {
  return $("tab-meals").querySelector(".day.today");
}

function scrollToToday() {
  const t = todayCard();
  if (t) t.scrollIntoView({ block: "start" });
}

// Bouton « Aujourd'hui » flottant : visible seulement sur l'onglet Repas quand le jour
// d'aujourd'hui n'est pas à l'écran, avec une flèche vers sa position (haut ou bas).
function updateTodayBtn() {
  const t = currentTab === "meals" ? todayCard() : null;
  if (!t) { todayBtn.hidden = true; return; }
  const r = t.getBoundingClientRect();
  const navTop = $("tabs").getBoundingClientRect().top;
  const visible = r.bottom > 0 && r.top < navTop;
  todayBtn.hidden = visible;
  todayBtn.textContent = (r.top < 0 ? "↑ " : "↓ ") + "Aujourd'hui";
}

todayBtn.addEventListener("click", scrollToToday);
window.addEventListener("scroll", updateTodayBtn, { passive: true });
window.addEventListener("resize", updateTodayBtn);

$("tabs").addEventListener("click", (e) => {
  const b = e.target.closest("button[data-tab]");
  if (b) switchTab(b.dataset.tab);
});

// ------------------------------------------------------------ Confirmation
const confirmDialog = $("confirm");
closeOnBackdrop(confirmDialog, "no");
$("confirm-no").addEventListener("click", () => confirmDialog.close("no"));
$("confirm-yes").addEventListener("click", () => confirmDialog.close("yes"));

function confirmAction(title, detail = "") {
  return new Promise((resolve) => {
    $("confirm-title").textContent = title;
    $("confirm-detail").textContent = detail;
    confirmDialog.returnValue = "no";
    confirmDialog.addEventListener("close", () => resolve(confirmDialog.returnValue === "yes"), { once: true });
    confirmDialog.showModal();
  });
}

// ---------------------------------------------------------- Choix d'aliments
// Champ multi-sélection : cadres avec croix + liste déroulante filtrée (« contient »).
// `chosen` (Map id -> aliment) est partagé entre tous les champs du popup : un aliment multi-classes
// choisi dans un champ apparaît aussi dans ses autres classes, et l'enlever l'enlève partout.
// `onChange` rafraîchit tous les champs.
// Avec `allowNew` (ingrédients d'une recette), on peut aussi saisir un nom qui n'est pas dans la liste
// (« Créer « nom » ») : `chosen` est alors indexé par le nom, et sert de source des cadres affichés.
// Avec `tags: false`, les choix ne s'affichent pas en cadres (le champ ne sert qu'à ajouter : les lignes
// d'ingrédients d'un aliment sont affichées à part).
function createPicker(options, chosen, onChange, {
  allowNew = false, tags = true, placeholder = "Choisir…",
  none = "Aucun aliment", empty = "Aucun aliment dans cette classe",
} = {}) {
  const root = el("div", "picker");
  const field = el("div", "picker-field");
  const input = el("input");
  input.type = "text";
  input.autocomplete = "off";
  input.placeholder = placeholder;
  const list = el("ul", "picker-list");
  list.hidden = true;
  let active = -1;
  let shown = [];

  const current = () => (allowNew ? [...chosen.values()] : options.filter((f) => chosen.has(f.id)));

  function renderTags() {
    if (!tags) return;
    field.querySelectorAll(".tag").forEach((t) => t.remove());
    const mine = current();
    for (const f of mine) {
      const tag = el("span", "tag", f.name);
      const x = button("", "×", () => { chosen.delete(f.id); onChange(); });
      x.setAttribute("aria-label", `Retirer ${f.name}`);
      tag.append(x);
      field.insertBefore(tag, input);
    }
    input.placeholder = mine.length ? "" : placeholder;
  }

  function renderList() {
    const q = input.value.trim().toLowerCase();
    shown = options.filter((o) => !chosen.has(o.id) && o.name.includes(q));
    if (allowNew && q && q.length <= 60 && !chosen.has(q) && !options.some((o) => o.id === q)) {
      shown.push({ id: q, name: q, isNew: true });
    }
    // Avec saisie libre, le nom tapé tel quel (existant ou à créer) est présélectionné.
    active = shown.length && q ? (allowNew ? shown.findIndex((o) => o.id === q) : 0) : -1;
    list.replaceChildren();
    if (!shown.length) {
      list.append(el("li", "none", options.length ? none : empty));
      return;
    }
    shown.forEach((o, i) => {
      const li = el("li", i === active ? "act" : "", o.isNew ? `Créer « ${o.name} »` : o.name);
      li.addEventListener("pointerdown", (e) => e.preventDefault()); // garde le focus dans le champ
      li.addEventListener("click", () => pick(o));
      list.append(li);
    });
  }

  function pick(o) {
    chosen.set(o.id, o);
    input.value = "";
    onChange();
    input.focus();
  }

  function move(delta) {
    if (!shown.length) return;
    active = (active + delta + shown.length) % shown.length;
    [...list.children].forEach((li, i) => li.classList.toggle("act", i === active));
    list.children[active].scrollIntoView({ block: "nearest" });
  }

  field.addEventListener("click", (e) => { if (e.target === field) input.focus(); });
  input.addEventListener("focus", () => { renderList(); list.hidden = false; });
  input.addEventListener("blur", () => { list.hidden = true; });
  input.addEventListener("input", () => { renderList(); list.hidden = false; });
  input.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown") { e.preventDefault(); move(1); }
    else if (e.key === "ArrowUp") { e.preventDefault(); move(-1); }
    else if (e.key === "Enter") { e.preventDefault(); if (shown[active]) pick(shown[active]); }
    else if (tags && e.key === "Backspace" && !input.value) {
      const mine = current();
      if (mine.length) { chosen.delete(mine[mine.length - 1].id); onChange(); }
    }
  });

  field.append(input);
  root.append(field, list);
  renderTags();
  return {
    el: root,
    refresh() { renderTags(); renderList(); },
    // Texte tapé mais pas encore validé (pour ne pas le perdre si on clique directement sur « Enregistrer »).
    pending() { return input.value.trim().toLowerCase(); },
    clear() { input.value = ""; },
  };
}

// Lignes d'ingrédients d'un aliment (ajout et modification) : nom, quantité pour 1 portion et unité.
// - Aliment simple : une seule ligne « automatique » = l'ingrédient de même nom que l'aliment (nom non
//   modifiable, ligne non supprimable) ; seule sa quantité se saisit.
// - Dès qu'on ajoute un 2e ingrédient, l'aliment devient une recette : onChange() laisse le formulaire
//   cocher (et verrouiller) la case Recettes.
// - Recette : au moins 1 ligne. Un ingrédient inconnu est créé à la volée (on choisit alors son unité) ;
//   pour un ingrédient existant, l'unité est celle de l'ingrédient (elle se change dans l'onglet Ingrédients).
// editor.payload() renvoie [{ name, quantity, unit_id }] ; editor.error() un code d'erreur ou null.
function ingredientEditor({ initial, recipe, foodName, onChange }) {
  const defaultUnit = (units[0] || {}).id;
  const state = {
    recipe,
    rows: initial.map((r) => ({
      auto: !!r.auto,
      name: r.name || "",
      quantity: r.quantity === null || r.quantity === undefined ? "" : String(r.quantity),
      unit_id: r.unit_id === undefined ? defaultUnit : r.unit_id,
    })),
  };
  const known = (name) => ingredients.find((i) => i.name === name);
  const autoName = () => foodName().trim().toLowerCase();
  const nameOf = (row) => (row.auto ? autoName() : row.name);
  const chosen = new Map(state.rows.filter((r) => !r.auto).map((r) => [r.name, { id: r.name, name: r.name }]));

  const root = el("div", "ing-editor");
  const list = el("div", "ing-rows");
  const picker = createPicker(ingredients.map((i) => ({ id: i.name, name: i.name })), chosen, () => onPick(), {
    allowNew: true, tags: false, placeholder: "Ajouter un ingrédient…",
    none: "Aucun ingrédient", empty: "Tapez le nom d'un ingrédient",
  });

  function changed() {
    picker.refresh();
    renderRows();
    onChange();
  }

  function onPick() {
    for (const name of [...chosen.keys()]) {
      if (state.rows.some((r) => !r.auto && r.name === name)) continue;
      if (name === autoName()) { chosen.delete(name); continue; } // déjà présent : l'ingrédient de même nom que l'aliment
      const k = known(name);
      state.rows.push({ auto: false, name, quantity: "", unit_id: k ? k.unit_id : defaultUnit });
    }
    if (state.rows.length >= 2) state.recipe = true;
    changed();
  }

  function remove(row) {
    state.rows = state.rows.filter((r) => r !== row);
    if (!row.auto) chosen.delete(row.name);
    changed();
  }

  function renderRows() {
    list.replaceChildren();
    for (const row of state.rows) {
      const line = el("div", "ing-row");
      const name = el("span", "ing-name");
      const qty = el("input", "ing-qty");
      qty.type = "number";
      qty.min = "0";
      qty.step = "any";
      qty.inputMode = "decimal";
      qty.placeholder = "quantité";
      qty.value = row.quantity;
      qty.setAttribute("aria-label", "Quantité pour 1 portion");
      qty.addEventListener("input", () => { row.quantity = qty.value; });
      const unitBox = el("span", "ing-unit");
      // Le nom (et donc l'unité connue) de la ligne automatique suit le nom de l'aliment en cours de saisie.
      row.refresh = () => {
        const nm = nameOf(row);
        name.textContent = nm || "(nom de l'aliment)";
        name.classList.toggle("muted", !nm);
        const k = known(nm);
        unitBox.replaceChildren();
        if (k) {
          unitBox.append(unitOf(k.unit_id).name);
        } else {
          const sel = el("select");
          for (const u of units) sel.append(new Option(u.name, u.id, false, u.id === row.unit_id));
          sel.setAttribute("aria-label", "Unité du nouvel ingrédient");
          sel.addEventListener("change", () => { row.unit_id = Number(sel.value); });
          unitBox.append(sel);
        }
      };
      row.refresh();
      line.append(name, qty, unitBox);
      if (state.recipe || !row.auto) {
        const del = button("ing-del", "✕", () => remove(row));
        del.setAttribute("aria-label", "Retirer cet ingrédient");
        line.append(del);
      }
      list.append(line);
    }
  }

  root.append(el("small", "ing-hint", "Quantité pour 1 portion"), list, picker.el);
  renderRows();

  root.count = () => state.rows.length;
  root.refreshAuto = () => state.rows.forEach((r) => r.auto && r.refresh && r.refresh());
  // Appelé quand on coche ou décoche la case Recettes.
  root.setRecipe = (on) => {
    state.recipe = on;
    const onlyAuto = state.rows.length === 1 && state.rows[0].auto;
    if (on) {
      // Aliment simple devenu recette : sa ligne automatique disparaît, sauf si une quantité y est saisie.
      if (onlyAuto && state.rows[0].quantity === "") state.rows = [];
    } else if (!onlyAuto) {
      // Recette redevenue aliment simple : une seule ligne automatique.
      state.rows = [{ auto: true, name: "", quantity: "", unit_id: defaultUnit }];
      chosen.clear();
    }
    picker.refresh();
    renderRows();
  };
  // Texte tapé dans le champ d'ajout mais pas encore validé : on l'ajoute pour ne pas le perdre.
  root.flushPending = () => {
    const typed = picker.pending();
    if (typed && typed.length <= 60 && typed !== autoName() && !state.rows.some((r) => !r.auto && r.name === typed)) {
      chosen.set(typed, { id: typed, name: typed });
      onPick();
    }
    picker.clear();
  };
  root.payload = () => state.rows.map((r) => ({
    name: nameOf(r),
    quantity: r.quantity === "" ? null : Number(String(r.quantity).replace(",", ".")),
    unit_id: r.unit_id,
  }));
  root.error = () => (state.rows.some((r) => r.quantity !== "" && !(Number(r.quantity) > 0 && Number(r.quantity) <= 99999))
    ? "invalid_quantity" : null);
  return root;
}

// Case Recettes d'un jeu de cases à cocher de classes (null s'il n'y a pas de classe de type combo).
const recipeCheckbox = (checks) => {
  const combo = classes.find((c) => c.type === "combo");
  return combo ? checks.querySelector(`input[value="${combo.id}"]`) : null;
};

// À partir de 2 ingrédients, l'aliment est une recette : la case Recettes est cochée et verrouillée.
function syncRecipeBox(checks, editor) {
  const cb = recipeCheckbox(checks);
  if (!cb) return;
  if (editor.count() >= 2) { cb.checked = true; cb.disabled = true; } else cb.disabled = false;
}

// ------------------------------------------------------------ Édition repas
const mealDialog = $("meal-dialog");
const mealError = $("meal-error");
const mealSave = $("meal-save");
let mealTarget = null; // { date, slot, chosen, portions, existing }

// Section « Portions » du popup : pour chaque aliment choisi (une seule fois, même s'il a plusieurs classes),
// un multiplicateur (1 par défaut ; 0,5 ou 0,75 possibles) appliqué aux quantités de ses ingrédients.
function renderPortions() {
  const { chosen, portions } = mealTarget;
  for (const id of [...portions.keys()]) if (!chosen.has(id)) portions.delete(id);
  for (const id of chosen.keys()) if (!portions.has(id)) portions.set(id, 1);
  const box = $("meal-portions");
  box.replaceChildren();
  if (!chosen.size) return;
  box.append(el("h3", "portions-title", "Portions"));
  const names = [...chosen.values()].sort((a, b) => a.name.localeCompare(b.name, "fr"));
  for (const f of names) {
    const row = el("div", "portion-row");
    const input = el("input", "portion-input");
    input.type = "number";
    input.min = "0.25";
    input.max = "99";
    input.step = "0.25";
    input.inputMode = "decimal";
    input.setAttribute("aria-label", `Portions de ${f.name}`);
    input.value = portions.get(f.id);
    // Valeur brute : la validation (> 0, 99 au plus, 2 décimales) est faite à l'enregistrement.
    input.addEventListener("input", () => portions.set(f.id, input.value === "" ? NaN : Number(input.value)));
    const step = (delta) => () => {
      const cur = portions.get(f.id);
      const v = round2((cur > 0 ? cur : 1) + delta);
      if (v > 0 && v <= 99) { portions.set(f.id, v); input.value = v; }
    };
    row.append(el("span", "portion-name", f.name), button("btn-step", "−", step(-0.25)), input, button("btn-step", "+", step(0.25)));
    box.append(row);
  }
}

function openMeal(date, slot) {
  const existing = meals.get(`${date}|${slot}`) || [];
  const chosen = new Map(existing.map((f) => [f.id, f]));
  const portions = new Map(existing.map((f) => [f.id, f.portions]));
  const rows = $("meal-rows");
  rows.replaceChildren();
  const pickers = [];
  const refreshAll = () => { pickers.forEach((p) => p.refresh()); renderPortions(); };
  // Seules les classes de type composante ont une partie de repas (pas les classes combo, comme Recettes).
  for (const c of classes.filter((k) => k.type === "composante")) {
    const options = foods.filter((f) => f.class_ids.includes(c.id));
    const picker = createPicker(options, chosen, refreshAll);
    pickers.push(picker);
    const label = el("div", "part-label", c.part_name);
    rows.append(label, picker.el);
  }
  mealTarget = { date, slot, chosen, portions, existing };
  renderPortions();
  fillCopyChoices(mealTarget, refreshAll);
  $("meal-title").textContent = `${fmtDay(date)} · ${slot}`;
  mealError.textContent = "";
  mealSave.disabled = false;
  mealDialog.showModal();
  // Sans ça, le navigateur met le focus dans le 1er champ et ouvre sa liste déroulante d'office.
  $("meal-title").tabIndex = -1;
  $("meal-title").focus();
}

// Copie d'un repas existant : la liste propose tous les repas non vides présents en base
// (y compris ceux qui ne sont plus affichés dans les 15 derniers jours), sauf le repas en cours
// de modification. Choisir un repas remplace la sélection du popup par ses aliments ; rien
// n'est enregistré tant qu'on n'a pas cliqué sur « Enregistrer ».
const copySelect = $("meal-copy");

async function fillCopyChoices(target, refreshAll) {
  copySelect.disabled = true;
  copySelect.replaceChildren(new Option("Chargement…", ""));
  let rows;
  try {
    rows = await rpc("get_meals", { ...auth(), d_from: "1970-01-01", d_to: "2999-12-31" });
  } catch (e) {
    if (mealTarget === target) {
      copySelect.replaceChildren(new Option("Liste indisponible", ""));
      fail(e, mealError);
    }
    return;
  }
  if (mealTarget !== target || !mealDialog.open) return; // la fenêtre a changé entre-temps

  const sources = new Map(); // "2026-10-27|midi" -> [{ id, name, class_ids }]
  for (const r of rows) {
    const key = `${r.meal_date}|${r.slot}`;
    if (key === `${target.date}|${target.slot}`) continue;
    if (!sources.has(key)) sources.set(key, []);
    sources.get(key).push({ id: r.food_id, name: r.food_name, class_ids: r.class_ids || [], portions: Number(r.portions) || 1 });
  }

  copySelect.replaceChildren(new Option(sources.size ? "Choisir un repas…" : "Aucun repas à copier", ""));
  const days = [...new Set([...sources.keys()].map((k) => k.split("|")[0]))].sort().reverse();
  for (const day of days) {
    const group = document.createElement("optgroup");
    group.label = fmtDay(day);
    for (const slot of SLOTS) {
      const items = sources.get(`${day}|${slot}`);
      if (!items) continue;
      const text = `${slot} · ${items.map((f) => f.name).join(", ")}`;
      group.append(new Option(text.length > 70 ? `${text.slice(0, 69)}…` : text, `${day}|${slot}`));
    }
    copySelect.append(group);
  }
  copySelect.disabled = !sources.size;

  copySelect.onchange = () => {
    const items = sources.get(copySelect.value);
    if (!items) return;
    target.chosen.clear();
    target.portions.clear();
    for (const f of items) {
      target.chosen.set(f.id, foods.find((x) => x.id === f.id) || f);
      target.portions.set(f.id, f.portions); // le repas copié garde ses nombres de portions
    }
    refreshAll();
  };
}

$("meal-cancel").addEventListener("click", () => mealDialog.close());
closeOnBackdrop(mealDialog);

mealSave.addEventListener("click", async () => {
  const { date, slot, chosen, portions, existing } = mealTarget;
  const ids = [...chosen.keys()];
  const ps = ids.map((id) => (portions.has(id) ? portions.get(id) : 1));
  if (ps.some((p) => !(p > 0 && p <= 99 && round2(p) === p))) { mealError.textContent = errorText({ code: "invalid_portions" }); return; }
  // Le repas ne change pas si ni les aliments ni leurs portions ne changent.
  const signature = (pairs) => pairs.map(([id, p]) => `${id}:${p}`).sort().join();
  if (signature(ids.map((id, i) => [id, ps[i]])) === signature(existing.map((f) => [f.id, f.portions]))) { mealDialog.close(); return; }

  if (existing.length) {
    const ok = await confirmAction(
      ids.length ? "Êtes-vous sûr de vouloir modifier ce repas ?" : "Êtes-vous sûr de vouloir vider ce repas ?",
      `${fmtDay(date)} · ${slot}`
    );
    if (!ok) return;
  }
  await saveMeal(date, slot, ids, ps, mealError, mealSave);
});

// portions : tableau parallèle à ids (nombre de portions de chaque aliment dans le repas).
async function saveMeal(date, slot, ids, portions, errorTarget, btn) {
  if (btn) btn.disabled = true;
  try {
    await rpc("set_meal", { ...auth(), d: date, s: slot, food_ids: ids, portions });
    if (mealDialog.open) mealDialog.close();
    statusEl.textContent = "";
    await reloadMeals();
  } catch (e) {
    fail(e, errorTarget);
  }
  if (btn) btn.disabled = false;
}

async function clearMeal(date, slot) {
  const ok = await confirmAction("Êtes-vous sûr de vouloir vider ce repas ?", `${fmtDay(date)} · ${slot}`);
  if (ok) await saveMeal(date, slot, [], [], statusEl, null);
}

// ------------------------------------------------- Contraintes d'un jour (mode write)
const dayDialog = $("day-dialog");
const dayChecks = $("day-checks");
const dayError = $("day-error");
const daySave = $("day-save");
let dayTarget = null; // { date, before, box }

function openDayConstraints(date) {
  const before = dayConstraints.get(date) || [];
  $("day-title").textContent = fmtDay(date);
  dayError.textContent = "";
  daySave.disabled = false;
  let box = null;
  if (constraints.length) {
    // Une contrainte qui a un effet l'indique à côté de son nom.
    box = checkBoxes(constraints.map((k) => ({ id: k.id, name: k.name, meta: (effectOf(k) || {}).name })), new Set(before));
    dayChecks.replaceChildren(box);
  } else {
    dayChecks.replaceChildren(el("p", "empty", "Aucune contrainte n'est définie. Un admin peut en créer dans l'onglet Admin."));
  }
  dayTarget = { date, before, box };
  dayDialog.showModal();
}

$("day-cancel").addEventListener("click", () => dayDialog.close());
closeOnBackdrop(dayDialog);

daySave.addEventListener("click", async () => {
  const { date, before, box } = dayTarget;
  if (!box) { dayDialog.close(); return; }
  const ids = box.values();
  if (ids.length === before.length && ids.every((id) => before.includes(id))) { dayDialog.close(); return; }
  // Retirer toutes les contraintes d'un jour est une suppression : avec confirmation.
  if (!ids.length) {
    const ok = await confirmAction("Êtes-vous sûr de vouloir retirer toutes les contraintes de ce jour ?", fmtDay(date));
    if (!ok) return;
  }
  daySave.disabled = true;
  try {
    await rpc("set_day_constraints", { ...auth(), d: date, cids: ids });
    dayDialog.close();
    statusEl.textContent = "";
    await reloadMeals();
  } catch (e) {
    fail(e, dayError);
  }
  daySave.disabled = false;
});

// ------------------------------------------------------------------- Admin
// Cases à cocher : items = [{ id, name }] ; box.values() renvoie les identifiants cochés.
function checkBoxes(items, selected) {
  const box = el("div", "class-checks");
  for (const it of items) {
    const label = el("label", "class-check");
    const cb = el("input");
    cb.type = "checkbox";
    cb.value = it.id;
    cb.checked = selected.has(it.id);
    label.append(cb, document.createTextNode(it.name));
    if (it.meta) label.append(el("small", "check-meta", it.meta));
    box.append(label);
  }
  box.values = () => [...box.querySelectorAll("input:checked")].map((i) => Number(i.value));
  return box;
}

// Cases à cocher des classes d'un aliment.
function classChecks(selected) {
  return checkBoxes(classes, selected);
}

// Une recette est un aliment qui a une classe de type combo (Recettes).
const isRecipe = (cids) => cids.some((id) => (classes.find((c) => c.id === id) || {}).type === "combo");

// Contrôle fait avant l'envoi (la base refait les mêmes contrôles) : renvoie un code d'erreur ou null.
function foodFormError(cids, ings) {
  if (!cids.length) return "invalid_classes";
  if (!cids.some((id) => (classes.find((c) => c.id === id) || {}).type === "composante")) return "class_component_required";
  if (isRecipe(cids) && !ings.length) return "ingredients_required";
  return null;
}

// Filtre d'utilisation (Tous | Utilisés | Non utilisés) des listes Admin ; il se combine avec la recherche.
function usageFilter(onChange) {
  const seg = el("div", "segment mini");
  for (const [key, label] of [["all", "Tous"], ["used", "Utilisés"], ["unused", "Non utilisés"]]) {
    const b = button("seg" + (adminUsage === key ? " on" : ""), label, () => {
      adminUsage = key;
      for (const x of seg.children) x.classList.toggle("on", x === b);
      onChange();
    });
    seg.append(b);
  }
  return seg;
}

const matchesUsage = (uses) => adminUsage === "all" || (adminUsage === "used") === (Number(uses) > 0);

function renderAdmin() {
  const root = $("tab-admin");
  if (role !== "admin") { root.replaceChildren(); return; }
  root.replaceChildren();
  const seg = el("div", "segment");
  for (const [key, label] of [["foods", "Aliments"], ["ingredients", "Ingrédients"], ["constraints", "Contraintes"]]) {
    seg.append(button("seg" + (adminSection === key ? " on" : ""), label, () => {
      adminSection = key;
      adminSearch = "";
      adminUsage = "all";
      renderAdmin();
    }));
  }
  root.append(seg);
  if (adminSection === "constraints") renderConstraintsAdmin(root);
  else if (adminSection === "ingredients") renderIngredientsAdmin(root);
  else renderFoodsAdmin(root);
}

function renderFoodsAdmin(root) {

  const chips = el("div", "chips");
  for (const c of classes) {
    chips.append(button("chip" + (c.id === adminClassId ? " on" : ""), c.name, () => {
      adminClassId = c.id;
      adminSearch = "";
      renderAdmin();
    }));
  }
  root.append(chips);

  // Nouvel aliment : un nom et une ou plusieurs classes (la classe affichée est cochée d'office).
  const addForm = el("form", "add-form");
  const addRow = el("div", "add-row");
  const addInput = el("input");
  addInput.type = "text";
  addInput.maxLength = 60;
  addInput.placeholder = "Nouvel aliment";
  addInput.autocomplete = "off";
  const addBtn = el("button", "btn-primary", "Ajouter");
  addBtn.type = "submit";
  addRow.append(addInput, addBtn);
  const addChecks = classChecks(new Set([adminClassId]));
  // Ingrédients avec leur quantité pour 1 portion : un aliment simple a une seule ligne (sa quantité) ;
  // à partir de 2 ingrédients la case Recettes se coche toute seule.
  const startsAsRecipe = isRecipe([adminClassId]);
  const addIngredients = ingredientEditor({
    initial: startsAsRecipe ? [] : [{ auto: true }],
    recipe: startsAsRecipe,
    foodName: () => addInput.value,
    onChange: () => syncRecipeBox(addChecks, addIngredients),
  });
  addChecks.addEventListener("change", (e) => {
    if (e.target === recipeCheckbox(addChecks)) addIngredients.setRecipe(e.target.checked);
  });
  addInput.addEventListener("input", () => addIngredients.refreshAuto());
  const addIngBox = el("div", "ing-box");
  addIngBox.append(el("span", "ing-label", "Ingrédients"), addIngredients);
  addForm.append(addRow, addChecks, addIngBox);
  addForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    const name = addInput.value.trim().toLowerCase();
    if (!name) return;
    addIngredients.flushPending();
    const cids = addChecks.values();
    const ings = addIngredients.payload();
    const problem = addIngredients.error() || foodFormError(cids, ings);
    if (problem) { statusEl.textContent = errorText({ code: problem }); return; }
    addBtn.disabled = true;
    try {
      await rpc("add_food", { ...auth(), n: name, cids, ings });
      statusEl.textContent = "";
      await loadFoodsAndIngredients();
      renderAdmin();
      $("tab-admin").querySelector(".add-row input").focus();
      return;
    } catch (err) {
      fail(err);
    }
    addBtn.disabled = false;
  });
  root.append(addForm);

  const search = el("input", "search");
  search.type = "search";
  search.placeholder = "Rechercher";
  search.value = adminSearch;
  root.append(search);

  const list = el("ul", "food-list");
  const filter = usageFilter(() => fill());
  root.append(filter, list);
  const fill = () => {
    const q = adminSearch.trim().toLowerCase();
    const rows = foods
      .filter((f) => f.class_ids.includes(adminClassId) && f.name.includes(q) && matchesUsage(f.uses))
      .sort((a, b) => a.name.localeCompare(b.name, "fr"));
    list.replaceChildren();
    if (!rows.length) {
      const li = el("li", "empty", q || adminUsage !== "all" ? "Aucun résultat" : "Aucun aliment dans cette classe");
      list.append(li);
      return;
    }
    for (const f of rows) {
      const li = el("li", "food-row");
      const name = el("span", "fname", f.name);
      const others = f.class_ids.filter((id) => id !== adminClassId)
        .map((id) => (classes.find((c) => c.id === id) || {}).name).filter(Boolean);
      // Les autres classes de l'aliment : des pastilles à droite du nom.
      for (const cname of others) name.append(el("span", "cls-pill", cname));
      const uses = Number(f.uses) || 0;
      name.append(el("small", "fmeta", uses ? `utilisé dans ${uses} repas` : "non utilisé"));
      // Pour retrouver ce qu'il reste à remplir : au moins une quantité d'ingrédient n'est pas définie.
      if ((f.ingredients || []).some((i) => i.quantity === null)) name.append(el("small", "fmeta qty-missing", "quantité à définir"));
      li.append(name);
      li.append(button("btn-sm", "Modifier", () => openFoodEdit(f)));
      li.append(button("btn-sm danger", "Supprimer", () => deleteFood(f)));
      list.append(li);
    }
  };
  search.addEventListener("input", () => { adminSearch = search.value; fill(); });
  fill();
}

// ------------------------------------------- Suppression refusée : qu'est-ce qui l'utilise ?
// Fenêtre d'information (un seul bouton) qui liste les repas, aliments ou jours qui utilisent
// l'élément qu'on voulait supprimer.
const usageDialog = $("usage-dialog");
closeOnBackdrop(usageDialog);
$("usage-close").addEventListener("click", () => usageDialog.close());

function showUsage(title, name, hint, lines) {
  $("usage-title").textContent = title;
  $("usage-name").textContent = name;
  $("usage-hint").textContent = hint;
  $("usage-list").replaceChildren(...lines.map((t) => el("li", "", t)));
  usageDialog.showModal();
}

// Un élément utilisé ne peut pas être supprimé : inutile de demander une confirmation, on
// tente la suppression (la base refuse et renvoie la liste) et on montre ce qui l'utilise.
async function deleteFood(f) {
  if (!(Number(f.uses) > 0)) {
    const ok = await confirmAction("Êtes-vous sûr de vouloir supprimer cet aliment ?", f.name);
    if (!ok) return;
  }
  try {
    await rpc("delete_food", { ...auth(), fid: f.id });
    statusEl.textContent = "";
    await loadFoodsAndIngredients();
    renderAdmin();
  } catch (e) {
    if (e.code === "food_in_use") {
      const { n, items } = usageOf(e);
      showUsage("Suppression impossible", f.name,
        `Cet aliment est utilisé dans ${n || items.length || "plusieurs"} repas. Retirez-le de ces repas avant de le supprimer.`,
        items.map((it) => { const [d, slot] = it.split("|"); return `${fmtDay(d)} · ${slot}`; }));
    } else {
      fail(e);
    }
  }
}

// ------------------------------------------------- Admin : gestion des ingrédients
// Liste déroulante des unités (select.value : identifiant) ; `selected` : unité présélectionnée (la 1re par défaut).
function unitSelect(selected) {
  const sel = el("select", "unit-select");
  for (const u of units) sel.append(new Option(u.name, u.id, false, u.id === selected));
  return sel;
}

// Paramètre « unité » des appels (omis tant que la base n'a pas les unités).
const unitArg = (uid) => (units.length ? { uid } : {});

function renderIngredientsAdmin(root) {
  const addForm = el("form", "add-form");
  const addRow = el("div", "add-row");
  const addInput = el("input");
  addInput.type = "text";
  addInput.maxLength = 60;
  addInput.placeholder = "Nouvel ingrédient";
  addInput.autocomplete = "off";
  const addBtn = el("button", "btn-primary", "Ajouter");
  addBtn.type = "submit";
  addRow.append(addInput, addBtn);
  // Unité de l'ingrédient (g par défaut) : toutes ses quantités sont exprimées dans cette unité.
  const addUnit = unitSelect(undefined);
  const unitRow = el("label", "unit-row");
  unitRow.append(el("span", "ing-label", "Unité"), addUnit);
  addForm.append(addRow, unitRow);
  addForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    const name = addInput.value.trim().toLowerCase();
    if (!name) return;
    addBtn.disabled = true;
    try {
      await rpc("add_ingredient", { ...auth(), n: name, ...unitArg(Number(addUnit.value)) });
      statusEl.textContent = "";
      await loadIngredients();
      renderAdmin();
      $("tab-admin").querySelector(".add-row input").focus();
      return;
    } catch (err) {
      fail(err);
    }
    addBtn.disabled = false;
  });
  root.append(addForm);

  const search = el("input", "search");
  search.type = "search";
  search.placeholder = "Rechercher";
  search.value = adminSearch;
  root.append(search);

  const list = el("ul", "food-list");
  const filter = usageFilter(() => fill());
  root.append(filter, list);
  const fill = () => {
    const q = adminSearch.trim().toLowerCase();
    const rows = ingredients.filter((i) => i.name.includes(q) && matchesUsage(i.uses))
      .sort((a, b) => a.name.localeCompare(b.name, "fr"));
    list.replaceChildren();
    if (!rows.length) {
      list.append(el("li", "empty", q || adminUsage !== "all" ? "Aucun résultat" : "Aucun ingrédient pour le moment"));
      return;
    }
    for (const i of rows) {
      const li = el("li", "food-row");
      const name = el("span", "fname", i.name);
      if (i.unit_id !== undefined) name.append(el("span", "cls-pill", unitOf(i.unit_id).name)); // son unité
      const uses = Number(i.uses) || 0;
      name.append(el("small", "fmeta", uses ? `utilisé par ${uses} aliment${uses > 1 ? "s" : ""}` : "non utilisé"));
      li.append(name);
      li.append(button("btn-sm", "Modifier", () => openIngredientEdit(i)));
      li.append(button("btn-sm danger", "Supprimer", () => deleteIngredient(i)));
      list.append(li);
    }
  };
  search.addEventListener("input", () => { adminSearch = search.value; fill(); });
  fill();
}

async function deleteIngredient(i) {
  if (!(Number(i.uses) > 0)) {
    const ok = await confirmAction("Êtes-vous sûr de vouloir supprimer cet ingrédient ?", i.name);
    if (!ok) return;
  }
  try {
    await rpc("delete_ingredient", { ...auth(), iid: i.id });
    statusEl.textContent = "";
    await loadIngredients();
    renderAdmin();
  } catch (e) {
    if (e.code === "ingredient_in_use") {
      const { n, items } = usageOf(e);
      showUsage("Suppression impossible", i.name,
        `Cet ingrédient est utilisé par ${n || items.length || "plusieurs"} aliment(s). Retirez-le de ces aliments avant de le supprimer.`,
        items);
    } else {
      fail(e);
    }
  }
}

const ingredientDialog = $("ingredient-dialog");
const ingredientError = $("ingredient-error");
const ingredientName = $("ingredient-name");
let editingIngredient = null;

function openIngredientEdit(i) {
  editingIngredient = i;
  ingredientName.value = i.name;
  $("ingredient-unit").replaceChildren(unitSelect(i.unit_id));
  ingredientError.textContent = "";
  ingredientDialog.showModal();
  ingredientName.focus();
  ingredientName.select();
}

$("ingredient-cancel").addEventListener("click", () => ingredientDialog.close());
closeOnBackdrop(ingredientDialog);
ingredientName.addEventListener("keydown", (e) => {
  if (e.key === "Enter") { e.preventDefault(); $("ingredient-save").click(); }
});
$("ingredient-save").addEventListener("click", async () => {
  const name = ingredientName.value.trim().toLowerCase();
  if (!name) { ingredientError.textContent = errorText({ code: "invalid_name" }); return; }
  const uid = Number($("ingredient-unit").querySelector("select").value);
  const unitChanged = units.length > 0 && uid !== editingIngredient.unit_id;
  if (name === editingIngredient.name && !unitChanged) { ingredientDialog.close(); return; }
  // Changer l'unité ne convertit pas les quantités déjà saisies : on demande confirmation si elles existent.
  if (unitChanged && Number(editingIngredient.uses) > 0) {
    const ok = await confirmAction("Changer l'unité de cet ingrédient ?",
      "Les quantités déjà saisies gardent leur valeur (aucune conversion) : pensez à les vérifier.");
    if (!ok) return;
  }
  const btn = $("ingredient-save");
  btn.disabled = true;
  try {
    await rpc("update_ingredient", { ...auth(), iid: editingIngredient.id, n: name, ...unitArg(uid) });
    ingredientDialog.close();
    statusEl.textContent = "";
    await loadFoodsAndIngredients(); // les recettes qui l'utilisent suivent
    renderAdmin();
  } catch (e) {
    fail(e, ingredientError);
  }
  btn.disabled = false;
});

// ---------------------------------------------------- Admin : gestion des contraintes
// Choix de l'effet d'une contrainte : « Aucun effet » et un choix par effet existant, exclusifs. La
// description de chaque effet est écrite sous son nom (lisible sans survol, smartphone compris).
// choice.value() renvoie l'identifiant de l'effet choisi, ou null.
let effectChoiceCount = 0;
function effectChoice(selectedId) {
  const box = el("div", "effect-choice");
  box.value = () => null;
  if (!effects.length) { box.hidden = true; return box; } // base pas encore à jour : pas d'effets
  const group = `effect-${effectChoiceCount++}`;
  const options = [{ id: null, name: "Aucun effet", description: "La contrainte est purement informative." }, ...effects];
  for (const o of options) {
    const label = el("label", "effect-opt");
    const radio = el("input");
    radio.type = "radio";
    radio.name = group;
    radio.value = o.id === null ? "" : String(o.id);
    radio.checked = o.id === (selectedId === undefined ? null : selectedId);
    const text = el("span", "effect-text");
    text.append(el("span", "effect-name", o.name), el("small", "check-meta", o.description));
    label.append(radio, text);
    box.append(label);
  }
  box.value = () => {
    const c = box.querySelector("input:checked");
    return c && c.value !== "" ? Number(c.value) : null;
  };
  return box;
}

// Paramètre « effet » des appels : omis tant que la base n'a pas les effets (ancienne signature).
const effectArg = (eid) => (effects.length ? { eid } : {});

function renderConstraintsAdmin(root) {
  const addForm = el("form", "add-form");
  const addRow = el("div", "add-row");
  const addInput = el("input");
  addInput.type = "text";
  addInput.maxLength = 60;
  addInput.placeholder = "Nouvelle contrainte";
  addInput.autocomplete = "off";
  const addBtn = el("button", "btn-primary", "Ajouter");
  addBtn.type = "submit";
  addRow.append(addInput, addBtn);
  const addEffect = effectChoice(null);
  addForm.append(addRow, addEffect);
  addForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    const name = addInput.value.trim();
    if (!name) return;
    addBtn.disabled = true;
    try {
      await rpc("add_constraint", { ...auth(), n: name, ...effectArg(addEffect.value()) });
      statusEl.textContent = "";
      await loadConstraints();
      render();
      $("tab-admin").querySelector(".add-row input").focus();
      return;
    } catch (err) {
      fail(err);
    }
    addBtn.disabled = false;
  });
  root.append(addForm);

  const search = el("input", "search");
  search.type = "search";
  search.placeholder = "Rechercher";
  search.value = adminSearch;
  root.append(search);

  const list = el("ul", "food-list");
  const filter = usageFilter(() => fill());
  root.append(filter, list);
  const fill = () => {
    const q = adminSearch.trim().toLowerCase();
    const rows = constraints.filter((k) => k.name.toLowerCase().includes(q) && matchesUsage(k.uses));
    list.replaceChildren();
    if (!rows.length) {
      list.append(el("li", "empty", q || adminUsage !== "all" ? "Aucun résultat" : "Aucune contrainte pour le moment"));
      return;
    }
    for (const k of rows) {
      const li = el("li", "food-row");
      const name = el("span", "fname", k.name);
      const uses = Number(k.uses) || 0;
      // L'effet de la contrainte : une pastille à droite du nom. Survol (ordinateur) : infobulle ; clic ou
      // appui (smartphone compris) : la description s'affiche sous le nom, un second appui la masque.
      const eff = effectOf(k);
      let desc = null;
      if (eff) {
        const pill = button("cls-pill effect-pill", eff.name, () => desc.classList.toggle("open"));
        pill.title = eff.description;
        name.append(pill);
        desc = el("small", "fmeta effect-desc", eff.description);
      }
      name.append(el("small", "fmeta", uses ? `attribuée à ${uses} jour${uses > 1 ? "s" : ""}` : "non attribuée"));
      if (desc) name.append(desc);
      li.append(name);
      li.append(button("btn-sm", "Modifier", () => openConstraintEdit(k)));
      li.append(button("btn-sm danger", "Supprimer", () => deleteConstraint(k)));
      list.append(li);
    }
  };
  search.addEventListener("input", () => { adminSearch = search.value; fill(); });
  fill();
}

async function deleteConstraint(k) {
  if (!(Number(k.uses) > 0)) {
    const ok = await confirmAction("Êtes-vous sûr de vouloir supprimer cette contrainte ?", k.name);
    if (!ok) return;
  }
  try {
    await rpc("delete_constraint", { ...auth(), cid: k.id });
    statusEl.textContent = "";
    await loadConstraints();
    render();
  } catch (e) {
    if (e.code === "constraint_in_use") {
      const { n, items } = usageOf(e);
      showUsage("Suppression impossible", k.name,
        `Cette contrainte est attribuée à ${n || items.length || "plusieurs"} jour(s). Retirez-la de ces jours avant de la supprimer.`,
        items.map((d) => fmtDay(d)));
    } else {
      fail(e);
    }
  }
}

const constraintDialog = $("constraint-dialog");
const constraintError = $("constraint-error");
const constraintName = $("constraint-name");
let editingConstraint = null;
let editEffect = null;

function openConstraintEdit(k) {
  editingConstraint = k;
  constraintName.value = k.name;
  editEffect = effectChoice(k.effect_id === undefined ? null : k.effect_id);
  $("constraint-effects").replaceChildren(editEffect);
  constraintError.textContent = "";
  constraintDialog.showModal();
  constraintName.focus();
  constraintName.select();
}

$("constraint-cancel").addEventListener("click", () => constraintDialog.close());
closeOnBackdrop(constraintDialog);
constraintName.addEventListener("keydown", (e) => {
  if (e.key === "Enter") { e.preventDefault(); $("constraint-save").click(); }
});
$("constraint-save").addEventListener("click", async () => {
  const name = constraintName.value.trim();
  if (!name) { constraintError.textContent = errorText({ code: "invalid_name" }); return; }
  const eid = editEffect.value();
  const oldEid = editingConstraint.effect_id === undefined ? null : editingConstraint.effect_id;
  if (name === editingConstraint.name && eid === oldEid) { constraintDialog.close(); return; }
  const btn = $("constraint-save");
  btn.disabled = true;
  try {
    await rpc("update_constraint", { ...auth(), cid: editingConstraint.id, n: name, ...effectArg(eid) });
    constraintDialog.close();
    statusEl.textContent = "";
    await loadConstraints();
    render();
  } catch (e) {
    if (e.code === "effect_conflict") {
      // L'effet bloquerait des repas déjà remplis : on montre les jours concernés.
      const { n, slot, items } = usageOf(e);
      constraintDialog.close();
      showUsage("Modification impossible", name,
        `Cette contrainte est attribuée à ${n || items.length} jour(s) dont le repas du ${slot} est déjà rempli. Videz ces repas avant de lui donner cet effet.`,
        items.map((d) => fmtDay(d)));
    } else {
      fail(e, constraintError);
    }
  }
  btn.disabled = false;
});

const foodDialog = $("food-dialog");
const foodEditError = $("food-edit-error");
let editingFood = null;
let editChecks = null;
let editIngredients = null;

function openFoodEdit(f) {
  editingFood = f;
  $("food-edit-name").value = f.name;
  editChecks = classChecks(new Set(f.class_ids));
  $("food-edit-classes").replaceChildren(editChecks);
  // Ingrédients avec leur quantité pour 1 portion : un aliment simple a une seule ligne (sa quantité) ;
  // à partir de 2 ingrédients la case Recettes se coche toute seule.
  const recipe = isRecipe(f.class_ids);
  const own = f.ingredients || [];
  editIngredients = ingredientEditor({
    initial: recipe ? own : [{ auto: true, quantity: own[0] ? own[0].quantity : null, unit_id: own[0] ? own[0].unit_id : undefined }],
    recipe,
    foodName: () => $("food-edit-name").value,
    onChange: () => syncRecipeBox(editChecks, editIngredients),
  });
  $("food-edit-ingredients").replaceChildren(editIngredients);
  editChecks.addEventListener("change", (e) => {
    if (e.target === recipeCheckbox(editChecks)) editIngredients.setRecipe(e.target.checked);
  });
  syncRecipeBox(editChecks, editIngredients);
  foodEditError.textContent = "";
  foodDialog.showModal();
}

// La ligne « automatique » d'un aliment simple porte le nom de l'aliment, tel qu'on le saisit.
$("food-edit-name").addEventListener("input", () => editIngredients && editIngredients.refreshAuto());
$("food-edit-cancel").addEventListener("click", () => foodDialog.close());
closeOnBackdrop(foodDialog);
$("food-edit-save").addEventListener("click", async () => {
  const name = $("food-edit-name").value.trim().toLowerCase();
  if (!name) { foodEditError.textContent = errorText({ code: "invalid_name" }); return; }
  editIngredients.flushPending();
  const cids = editChecks.values();
  const ings = editIngredients.payload();
  const problem = editIngredients.error() || foodFormError(cids, ings);
  if (problem) { foodEditError.textContent = errorText({ code: problem }); return; }
  const btn = $("food-edit-save");
  btn.disabled = true;
  try {
    await rpc("update_food", { ...auth(), fid: editingFood.id, n: name, cids, ings });
    foodDialog.close();
    statusEl.textContent = "";
    await loadAll();
  } catch (e) {
    fail(e, foodEditError);
  }
  btn.disabled = false;
});

// ------------------------------------------------------------------ Session
function storeSession(r) {
  const value = JSON.stringify({ u: userId, p: password });
  try {
    if (r === "admin") sessionStorage.setItem(STORAGE_KEY, value);
    else localStorage.setItem(STORAGE_KEY, value);
  } catch {}
}

function storedSession() {
  try {
    const raw = sessionStorage.getItem(STORAGE_KEY) || localStorage.getItem(STORAGE_KEY);
    const s = raw && JSON.parse(raw);
    return s && s.u && s.p ? s : null;
  } catch {
    return null;
  }
}

function clearSession() {
  try { sessionStorage.removeItem(STORAGE_KEY); } catch {}
  try { localStorage.removeItem(STORAGE_KEY); } catch {}
}

function unlock(r) {
  role = r;
  gate.hidden = true;
  app.hidden = false;
  $("role-badge").textContent = { read: "Lecture", write: "Écriture", admin: "Admin" }[r];
  $("tab-admin-btn").hidden = r !== "admin";
  statusEl.textContent = "";
  switchTab("home");
  loadAll();
}

function lock() {
  clearSession();
  userId = "";
  password = "";
  role = "";
  mealDialog.open && mealDialog.close();
  foodDialog.open && foodDialog.close();
  ingredientDialog.open && ingredientDialog.close();
  usageDialog.open && usageDialog.close();
  app.hidden = true;
  todayBtn.hidden = true;
  gate.hidden = false;
  (userInput.value ? passwordInput : userInput).focus();
}

$("quit").addEventListener("click", lock);

gateForm.addEventListener("submit", async (e) => {
  e.preventDefault();
  const button = gateForm.querySelector("button");
  button.disabled = true;
  gateError.textContent = "";
  try {
    const u = userInput.value.trim().toLowerCase();
    const r = await rpc("login", { u, p: passwordInput.value });
    if (r) {
      userId = u;
      password = passwordInput.value;
      storeSession(r);
      userInput.value = "";
      passwordInput.value = "";
      unlock(r);
    } else {
      gateError.textContent = "Identifiant ou mot de passe incorrect.";
      passwordInput.value = "";
      passwordInput.focus();
    }
  } catch {
    gateError.textContent = "Connexion impossible. Réessayez plus tard.";
  }
  button.disabled = false;
});

// Si le site reste ouvert d'un jour à l'autre, on recalcule « aujourd'hui » au retour.
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && role && zurichToday() !== today) loadAll();
});

// Reprise de session : on revérifie l'identifiant et le mot de passe (et le rôle) auprès de la base.
(async () => {
  try { localStorage.removeItem("food_pw"); } catch {} // ancienne session (mot de passe seul)
  const stored = storedSession();
  if (!stored) return;
  try {
    const r = await rpc("login", stored);
    if (r) { userId = stored.u; password = stored.p; unlock(r); } else clearSession();
  } catch {
    // Réseau indisponible : on garde la session et on affiche la page de connexion.
  }
})();
