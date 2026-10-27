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
let currentTab = "home";
let today = "";
let adminClassId = null;
let adminSearch = "";

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

function errorText(e) {
  switch (e.code) {
    case "food_exists": return "Cet aliment existe déjà.";
    case "food_in_use":
      return `Cet aliment est utilisé dans ${e.details || "plusieurs"} repas. Retirez-le de ces repas avant de le supprimer.`;
    case "food_in_use_class":
      return "Cet aliment est utilisé dans des repas : vous pouvez lui ajouter des classes, mais pas en retirer.";
    case "invalid_classes": return "Choisissez au moins une classe.";
    case "unknown_class": return "Une classe sélectionnée n'existe plus. Rechargez la page.";
    case "invalid_name": return "Le nom est invalide (1 à 60 caractères).";
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
  foods = cat.foods;
  if (!classes.some((c) => c.id === adminClassId)) adminClassId = classes[0] ? classes[0].id : null;
}

async function loadMeals() {
  today = zurichToday();
  const rows = await rpc("get_meals", {
    ...auth(),
    d_from: addDays(today, -DAYS_BEFORE),
    d_to: addDays(today, DAYS_AFTER),
  });
  meals = new Map();
  for (const r of rows) {
    const key = `${r.meal_date}|${r.slot}`;
    if (!meals.has(key)) meals.set(key, []);
    meals.get(key).push({ id: r.food_id, name: r.food_name, class_ids: r.class_ids || [] });
  }
}

async function loadAll() {
  try {
    await Promise.all([loadCatalog(), loadMeals()]);
    statusEl.textContent = "";
    render();
  } catch (e) {
    if (!fail(e)) statusEl.textContent = "Impossible de charger les données. Réessayez plus tard.";
  }
}

async function reloadMeals() {
  await loadMeals();
  const y = window.scrollY;
  renderHome();
  renderMeals();
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
  const box = el("div", "meal");
  const head = el("div", "meal-head");
  head.append(el("span", "meal-name", slot));

  if (editable) {
    const btns = el("div", "meal-btns");
    if (items.length) {
      btns.append(button("btn-sm", "Modifier", () => openMeal(date, slot)));
      btns.append(button("btn-sm danger", "Vider", () => clearMeal(date, slot)));
    } else {
      btns.append(button("btn-sm", "Générer repas manuel", () => openMeal(date, slot)));
    }
    head.append(btns);
  }
  box.append(head);

  if (!items.length) {
    box.append(el("p", "meal-empty", "vide"));
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
    groups.get(key).names.push(f.name);
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
  return box;
}

function dayCard(date, editable) {
  const card = el("article", "day" + (date === today ? " today" : ""));
  card.dataset.date = date;
  const title = el("h3", "day-title", fmtDay(date));
  if (date === today) title.append(el("small", "", "aujourd'hui"));
  else if (date === addDays(today, 1)) title.append(el("small", "", "demain"));
  card.append(title);
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
  const editable = role === "write";
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
function createPicker(options, chosen, onChange) {
  const root = el("div", "picker");
  const field = el("div", "picker-field");
  const input = el("input");
  input.type = "text";
  input.autocomplete = "off";
  input.placeholder = "Choisir…";
  const list = el("ul", "picker-list");
  list.hidden = true;
  let active = -1;
  let shown = [];

  function renderTags() {
    field.querySelectorAll(".tag").forEach((t) => t.remove());
    const mine = options.filter((f) => chosen.has(f.id));
    for (const f of mine) {
      const tag = el("span", "tag", f.name);
      const x = button("", "×", () => { chosen.delete(f.id); onChange(); });
      x.setAttribute("aria-label", `Retirer ${f.name}`);
      tag.append(x);
      field.insertBefore(tag, input);
    }
    input.placeholder = mine.length ? "" : "Choisir…";
  }

  function renderList() {
    const q = input.value.trim().toLowerCase();
    shown = options.filter((o) => !chosen.has(o.id) && o.name.includes(q));
    active = shown.length && q ? 0 : -1;
    list.replaceChildren();
    if (!shown.length) {
      list.append(el("li", "none", options.length ? "Aucun aliment" : "Aucun aliment dans cette classe"));
      return;
    }
    shown.forEach((o, i) => {
      const li = el("li", i === active ? "act" : "", o.name);
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
    else if (e.key === "Backspace" && !input.value) {
      const mine = options.filter((f) => chosen.has(f.id));
      if (mine.length) { chosen.delete(mine[mine.length - 1].id); onChange(); }
    }
  });

  field.append(input);
  root.append(field, list);
  renderTags();
  return { el: root, refresh() { renderTags(); renderList(); } };
}

// ------------------------------------------------------------ Édition repas
const mealDialog = $("meal-dialog");
const mealError = $("meal-error");
const mealSave = $("meal-save");
let mealTarget = null; // { date, slot, chosen, existing }

function openMeal(date, slot) {
  const existing = meals.get(`${date}|${slot}`) || [];
  const chosen = new Map(existing.map((f) => [f.id, f]));
  const rows = $("meal-rows");
  rows.replaceChildren();
  const pickers = [];
  const refreshAll = () => pickers.forEach((p) => p.refresh());
  for (const c of classes) {
    const options = foods.filter((f) => f.class_ids.includes(c.id));
    const picker = createPicker(options, chosen, refreshAll);
    pickers.push(picker);
    const label = el("div", "part-label", c.part_name);
    rows.append(label, picker.el);
  }
  mealTarget = { date, slot, chosen, existing };
  $("meal-title").textContent = `${fmtDay(date)} · ${slot}`;
  mealError.textContent = "";
  mealSave.disabled = false;
  mealDialog.showModal();
  // Sans ça, le navigateur met le focus dans le 1er champ et ouvre sa liste déroulante d'office.
  $("meal-title").tabIndex = -1;
  $("meal-title").focus();
}

$("meal-cancel").addEventListener("click", () => mealDialog.close());
closeOnBackdrop(mealDialog);

mealSave.addEventListener("click", async () => {
  const { date, slot, chosen, existing } = mealTarget;
  const ids = [...chosen.keys()];
  const before = existing.map((f) => f.id).sort((a, b) => a - b).join();
  if (ids.slice().sort((a, b) => a - b).join() === before) { mealDialog.close(); return; }

  if (existing.length) {
    const ok = await confirmAction(
      ids.length ? "Êtes-vous sûr de vouloir modifier ce repas ?" : "Êtes-vous sûr de vouloir vider ce repas ?",
      `${fmtDay(date)} · ${slot}`
    );
    if (!ok) return;
  }
  await saveMeal(date, slot, ids, mealError, mealSave);
});

async function saveMeal(date, slot, ids, errorTarget, btn) {
  if (btn) btn.disabled = true;
  try {
    await rpc("set_meal", { ...auth(), d: date, s: slot, food_ids: ids });
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
  if (ok) await saveMeal(date, slot, [], statusEl, null);
}

// ------------------------------------------------------------------- Admin
// Cases à cocher des classes d'un aliment ; box.values() renvoie les identifiants cochés.
function classChecks(selected) {
  const box = el("div", "class-checks");
  for (const c of classes) {
    const label = el("label", "class-check");
    const cb = el("input");
    cb.type = "checkbox";
    cb.value = c.id;
    cb.checked = selected.has(c.id);
    label.append(cb, document.createTextNode(c.name));
    box.append(label);
  }
  box.values = () => [...box.querySelectorAll("input:checked")].map((i) => Number(i.value));
  return box;
}

function renderAdmin() {
  const root = $("tab-admin");
  if (role !== "admin") { root.replaceChildren(); return; }
  root.replaceChildren(el("h2", "section-title", "Aliments"));

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
  addForm.append(addRow, addChecks);
  addForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    const name = addInput.value.trim().toLowerCase();
    if (!name) return;
    const cids = addChecks.values();
    if (!cids.length) { statusEl.textContent = errorText({ code: "invalid_classes" }); return; }
    addBtn.disabled = true;
    try {
      await rpc("add_food", { ...auth(), n: name, cids });
      statusEl.textContent = "";
      await loadCatalog();
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
  root.append(list);
  const fill = () => {
    const q = adminSearch.trim().toLowerCase();
    const rows = foods
      .filter((f) => f.class_ids.includes(adminClassId) && f.name.includes(q))
      .sort((a, b) => a.name.localeCompare(b.name, "fr"));
    list.replaceChildren();
    if (!rows.length) {
      const li = el("li", "empty", q ? "Aucun résultat" : "Aucun aliment dans cette classe");
      list.append(li);
      return;
    }
    for (const f of rows) {
      const li = el("li", "food-row");
      const name = el("span", "fname", f.name);
      const others = f.class_ids.filter((id) => id !== adminClassId)
        .map((id) => (classes.find((c) => c.id === id) || {}).name).filter(Boolean);
      if (others.length) name.append(el("small", "fmeta", `aussi : ${others.join(", ")}`));
      li.append(name);
      li.append(button("btn-sm", "Modifier", () => openFoodEdit(f)));
      li.append(button("btn-sm danger", "Supprimer", () => deleteFood(f)));
      list.append(li);
    }
  };
  search.addEventListener("input", () => { adminSearch = search.value; fill(); });
  fill();
}

async function deleteFood(f) {
  const ok = await confirmAction("Êtes-vous sûr de vouloir supprimer cet aliment ?", f.name);
  if (!ok) return;
  try {
    await rpc("delete_food", { ...auth(), fid: f.id });
    statusEl.textContent = "";
    await loadCatalog();
    renderAdmin();
  } catch (e) {
    fail(e);
  }
}

const foodDialog = $("food-dialog");
const foodEditError = $("food-edit-error");
let editingFood = null;
let editChecks = null;

function openFoodEdit(f) {
  editingFood = f;
  $("food-edit-name").value = f.name;
  editChecks = classChecks(new Set(f.class_ids));
  $("food-edit-classes").replaceChildren(editChecks);
  foodEditError.textContent = "";
  foodDialog.showModal();
}

$("food-edit-cancel").addEventListener("click", () => foodDialog.close());
closeOnBackdrop(foodDialog);
$("food-edit-save").addEventListener("click", async () => {
  const name = $("food-edit-name").value.trim().toLowerCase();
  if (!name) { foodEditError.textContent = errorText({ code: "invalid_name" }); return; }
  const cids = editChecks.values();
  if (!cids.length) { foodEditError.textContent = errorText({ code: "invalid_classes" }); return; }
  const btn = $("food-edit-save");
  btn.disabled = true;
  try {
    await rpc("update_food", { ...auth(), fid: editingFood.id, n: name, cids });
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
