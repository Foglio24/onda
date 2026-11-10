"use strict";

// Seaglass's account page: sign-in for the browser and for the app, and everything about the
// account (profile, password, Patreon, data, sign-out, deletion). The app only shows it.

const strings = {
  it: {
    signOut: "Esci", loginTitle: "Accedi a Seaglass", email: "Email", password: "Password", loginButton: "Accedi",
    loginAppHint: "Accedi per sincronizzare libreria, playlist e preferenze con l'app.",
    forgot: "Password dimenticata?", noAccount: "Non hai un account?", registerLink: "Registrati a Seaglass",
    registerTitle: "Crea il tuo account", passwordConfirm: "Ripeti la password", passwordRule: "Almeno 8 caratteri, con almeno un carattere speciale (come ! ? @ #).",
    registerButton: "Registrati", haveAccount: "Hai già un account?", loginLink: "Accedi",
    forgotTitle: "Reimposta la password",
    forgotLead: "Inserisci l'email del tuo account: ti mandiamo un codice di 6 cifre per scegliere una nuova password.",
    sendCode: "Invia il codice", haveCode: "Hai già un codice?", code: "Codice di 6 cifre",
    resetLead: "Inserisci il codice che ti abbiamo mandato per email e scegli una nuova password.",
    support: "Assistenza:", supportHelp: "Per qualsiasi problema scrivi all'assistenza:",
    send: "Invia", back: "Indietro", resetTitle: "Scegli una nuova password", newPassword: "Nuova password", save: "Salva",
    verifyTitle: "Conferma la tua email", verifyLead: "Ti abbiamo mandato un link: aprilo per attivare l'account, poi accedi.",
    verifyResend: "Invia di nuovo", yourPlan: "Il tuo piano", sectionAccount: "Account", editProfile: "Modifica profilo",
    changePassword: "Cambia password", membership: "Seaglass Premium", sectionLibrary: "La tua libreria",
    playlists: "Playlist", liked: "Brani che ti piacciono", history: "Ascoltati di recente",
    downloadData: "Scarica i tuoi dati", sectionSecurity: "Sicurezza e privacy", signOutEverywhere: "Esci ovunque",
    deleteAccount: "Elimina account",
    signOutEverywhereHint: "«Esci ovunque» chiude la sessione nell'app su tutti i dispositivi e in tutti i browser.",
    firstName: "Nome", lastName: "Cognome", displayName: "Nome visualizzato", saveProfile: "Salva profilo",
    currentPassword: "Password attuale",
    passwordChangeHint: "Almeno 8 caratteri, con un carattere speciale. Gli altri dispositivi dovranno accedere di nuovo.",
    setPassword: "Imposta nuova password",
    membershipLead: "Premium sblocca AutoMix, l'import delle playlist da link, il riconoscimento dei brani, la traduzione dei testi, il karaoke AI e il Tempo. Si attiva con l'abbonamento a Seaglass su Patreon, collegato a questo account.",
    deleteLead: "Eliminiamo subito l'account e tutto ciò che è sincronizzato: playlist, brani che ti piacciono, cronologia, preferenze e il collegamento a Patreon. Sui dispositivi la libreria resta, ma non si sincronizza più. Non si può annullare.",
    deletePatreon: "L'eventuale abbonamento su Patreon si annulla su Patreon.",
    deleteConfirm: "Per confermare scrivi la tua email", deleteButton: "Elimina definitivamente",
    loading: "Caricamento…", footer: "Seaglass non è affiliato a YouTube né a Patreon.",
    planFree: "Seaglass Free", planFreeDetail: "Ascolto, libreria, dissolvenze e download.", planSupporter: "Seaglass Premium",
    planSupporterDetail: "AutoMix, import da link, riconoscimento dei brani, traduzioni, karaoke e Tempo.", planDeclined: "Pagamento non riuscito su Patreon",
    planDeclinedDetail: "Aggiorna il metodo di pagamento su Patreon per mantenere Premium.",
    becomeSupporter: "Passa a Premium", managePatreon: "Gestisci abbonamento", linkPatreon: "Collega Patreon",
    unlinkPatreon: "Scollega Patreon", patreonSoon: "Premium arriverà presto.",
    patreonNotLinked: "Patreon non collegato", patreonNotLinkedDetail: "Abbonati a Seaglass su Patreon, poi collega qui il tuo account Patreon: Premium si attiva da solo.",
    patreonActive: "Premium attivo", patreonLinkedNone: "Collegato, senza abbonamento",
    patreonLinkedNoneDetail: "Il tuo account Patreon è collegato ma non ha un abbonamento attivo a Seaglass. Quando ti abboni, Premium si attiva da solo.",
    patreonFormer: "Abbonamento terminato", patreonDeclined: "Pagamento non riuscito",
    patreonUpdated: "Aggiornato il %s.",
    memberSince: "Su Seaglass dal %s", syncedAt: "Ultima sincronizzazione: %s", neverSynced: "La libreria non è ancora stata sincronizzata: accedi dall'app.",
    emailUnverified: "Email non confermata",
    noticeLinked: "Patreon collegato.", noticeLinkFailed: "Non è stato possibile collegare Patreon. Riprova.",
    noticeVerified: "Email confermata: ora puoi accedere.", noticeVerifyInvalid: "Il link di conferma non è valido o è scaduto.",
    noticeProfile: "Profilo salvato.", noticePassword: "Password aggiornata.", noticeSignedOutAll: "Sei uscito da tutti i dispositivi.",
    noticeUnlinked: "Patreon scollegato.", noticeResetSent: "Se l'email corrisponde a un account, riceverai un codice a breve. Controlla anche lo spam.",
    noticeResetDone: "Password reimpostata: ora puoi accedere.", noticeVerifySent: "Link inviato di nuovo.",
    deletedTitle: "Account eliminato", deletedText: "Il tuo account e i dati sincronizzati sono stati eliminati.",
    appReturnTitle: "Torna a Seaglass", appReturnText: "Accesso completato: puoi tornare all'app.",
    confirmSignOutAll: "Uscire da Seaglass su tutti i dispositivi?", confirmUnlink: "Scollegare l'account Patreon?",
    errPasswordsDiffer: "Le password non coincidono.", errInvalidCredentials: "Email o password non corretti.",
    errNotVerified: "Conferma prima la tua email.", errExpired: "La pagina è scaduta: riprova.",
    errExpiredApp: "L'accesso è scaduto: torna all'app e premi di nuovo Accedi.",
    errRateLimited: "Troppi tentativi: riprova tra qualche minuto.", errWeakPassword: "La password deve avere almeno 8 caratteri e un carattere speciale.",
    strength: "Sicurezza", strengthWeak: "debole", strengthFair: "media", strengthStrong: "forte",
    missing: "manca", needLength: "almeno 8 caratteri", needSpecial: "un carattere speciale",
    tipStronger: "più lunga o con maiuscole e numeri è più sicura", passwordsMatch: "Le password coincidono.",
    errInvalidEmail: "Inserisci un indirizzo email valido.", errInvalidReset: "Il codice non è valido o è scaduto.", errTooManyAttempts: "Troppi tentativi: chiedi un nuovo codice.",
    errEmailUnavailable: "L'invio delle email non è ancora disponibile.", errConflict: "Il profilo è cambiato altrove: è stato ricaricato, riprova.",
    errConfirmEmail: "L'email non corrisponde a quella dell'account.", errNetwork: "Connessione non riuscita. Riprova.",
    errGeneric: "Qualcosa è andato storto. Riprova.", errPatreonUnavailable: "Patreon non è ancora configurato.",
    forgotUnavailable: "Il recupero della password via email non è ancora disponibile: scrivi all'assistenza.",
    benefitAutoMix: "AutoMix: passaggi tra i brani a tempo, come un DJ, e il Mix delle playlist",
    benefitLinks: "Importa playlist da Spotify, Apple Music e YouTube con un link",
    benefitRecognition: "Riconosci il brano che stai ascoltando",
    benefitTranslation: "Traduci i testi mentre ascolti",
    benefitKaraoke: "Karaoke AI: togli la voce o ascolta solo quella",
    benefitTempo: "Tempo: brani più veloci o più lenti, con il key lock",
    premiumHow: "Abbonati su Patreon e collega qui il tuo account Patreon: Premium si attiva nell'app su iPhone, iPad e Mac.",
  },
  en: {
    signOut: "Log out", loginTitle: "Log in to Seaglass", email: "Email", password: "Password", loginButton: "Log in",
    loginAppHint: "Log in to sync your library, playlists and preferences with the app.",
    forgot: "Forgot your password?", noAccount: "Don't have an account?", registerLink: "Sign up for Seaglass",
    registerTitle: "Create your account", passwordConfirm: "Repeat the password", passwordRule: "At least 8 characters, with at least one special character (like ! ? @ #).",
    registerButton: "Sign up", haveAccount: "Already have an account?", loginLink: "Log in",
    forgotTitle: "Reset your password",
    forgotLead: "Enter your account's email: we'll send you a 6-digit code to choose a new password.",
    sendCode: "Send the code", haveCode: "Already have a code?", code: "6-digit code",
    resetLead: "Enter the code we emailed you and choose a new password.",
    support: "Support:", supportHelp: "For any problem, write to support:",
    send: "Send", back: "Back", resetTitle: "Choose a new password", newPassword: "New password", save: "Save",
    verifyTitle: "Confirm your email", verifyLead: "We sent you a link: open it to activate your account, then log in.",
    verifyResend: "Send again", yourPlan: "Your plan", sectionAccount: "Account", editProfile: "Edit profile",
    changePassword: "Change password", membership: "Seaglass Premium", sectionLibrary: "Your library",
    playlists: "Playlists", liked: "Liked songs", history: "Recently played",
    downloadData: "Download your data", sectionSecurity: "Security and privacy", signOutEverywhere: "Sign out everywhere",
    deleteAccount: "Delete account",
    signOutEverywhereHint: "“Sign out everywhere” logs you out of the app on every device and of every browser.",
    firstName: "First name", lastName: "Last name", displayName: "Display name", saveProfile: "Save profile",
    currentPassword: "Current password",
    passwordChangeHint: "At least 8 characters, with a special character. Your other devices will need to log in again.",
    setPassword: "Set new password",
    membershipLead: "Premium unlocks AutoMix, importing playlists from links, song recognition, lyrics translation, AI karaoke and Tempo. It comes with a Seaglass membership on Patreon, linked to this account.",
    deleteLead: "We delete your account and everything synced right away: playlists, liked songs, history, preferences and the Patreon link. Your devices keep their library, but it no longer syncs. This can't be undone.",
    deletePatreon: "A Patreon membership is cancelled on Patreon.",
    deleteConfirm: "To confirm, type your email", deleteButton: "Delete permanently",
    loading: "Loading…", footer: "Seaglass isn't affiliated with YouTube or Patreon.",
    planFree: "Seaglass Free", planFreeDetail: "Listening, your library, crossfades and downloads.", planSupporter: "Seaglass Premium",
    planSupporterDetail: "AutoMix, link imports, song recognition, translations, karaoke and Tempo.", planDeclined: "Payment declined on Patreon",
    planDeclinedDetail: "Update your payment method on Patreon to keep Premium.",
    becomeSupporter: "Get Premium", managePatreon: "Manage membership", linkPatreon: "Link Patreon",
    unlinkPatreon: "Unlink Patreon", patreonSoon: "Premium is coming soon.",
    patreonNotLinked: "Patreon not linked", patreonNotLinkedDetail: "Join Seaglass on Patreon, then link your Patreon account here: Premium turns on by itself.",
    patreonActive: "Premium active", patreonLinkedNone: "Linked, no membership",
    patreonLinkedNoneDetail: "Your Patreon account is linked but has no active Seaglass membership. When you join, Premium turns on by itself.",
    patreonFormer: "Membership ended", patreonDeclined: "Payment declined",
    patreonUpdated: "Updated on %s.",
    memberSince: "On Seaglass since %s", syncedAt: "Last synced: %s", neverSynced: "Your library hasn't synced yet: log in from the app.",
    emailUnverified: "Email not confirmed",
    noticeLinked: "Patreon linked.", noticeLinkFailed: "Patreon couldn't be linked. Try again.",
    noticeVerified: "Email confirmed: you can log in now.", noticeVerifyInvalid: "The confirmation link is invalid or has expired.",
    noticeProfile: "Profile saved.", noticePassword: "Password updated.", noticeSignedOutAll: "You've been signed out everywhere.",
    noticeUnlinked: "Patreon unlinked.", noticeResetSent: "If the email matches an account, you'll get a code shortly. Check your spam folder too.",
    noticeResetDone: "Password reset: you can log in now.", noticeVerifySent: "Link sent again.",
    deletedTitle: "Account deleted", deletedText: "Your account and its synced data have been deleted.",
    appReturnTitle: "Back to Seaglass", appReturnText: "You're logged in: you can go back to the app.",
    confirmSignOutAll: "Sign out of Seaglass on every device?", confirmUnlink: "Unlink your Patreon account?",
    errPasswordsDiffer: "The passwords don't match.", errInvalidCredentials: "Incorrect email or password.",
    errNotVerified: "Confirm your email first.", errExpired: "This page has expired: try again.",
    errExpiredApp: "The login has expired: go back to the app and tap Log in again.",
    errRateLimited: "Too many attempts: try again in a few minutes.", errWeakPassword: "The password needs at least 8 characters and a special character.",
    strength: "Strength", strengthWeak: "weak", strengthFair: "fair", strengthStrong: "strong",
    missing: "missing", needLength: "at least 8 characters", needSpecial: "a special character",
    tipStronger: "longer, or with capitals and digits, is safer", passwordsMatch: "The passwords match.",
    errInvalidEmail: "Enter a valid email address.", errInvalidReset: "The code is invalid or has expired.", errTooManyAttempts: "Too many attempts: ask for a new code.",
    errEmailUnavailable: "Sending emails isn't available yet.", errConflict: "Your profile changed elsewhere: it has been reloaded, try again.",
    errConfirmEmail: "The email doesn't match the account's.", errNetwork: "Couldn't connect. Try again.",
    errGeneric: "Something went wrong. Try again.", errPatreonUnavailable: "Patreon isn't set up yet.",
    forgotUnavailable: "Password recovery by email isn't available yet: write to support.",
    benefitAutoMix: "AutoMix: beat-matched transitions like a DJ, and playlist Mixes",
    benefitLinks: "Import playlists from Spotify, Apple Music and YouTube with a link",
    benefitRecognition: "Recognize the song you're hearing",
    benefitTranslation: "Translate lyrics as you listen",
    benefitKaraoke: "AI karaoke: remove the vocals or hear only them",
    benefitTempo: "Tempo: songs faster or slower, with key lock",
    premiumHow: "Join on Patreon and link your Patreon account here: Premium turns on in the app on iPhone, iPad and Mac.",
  },
};
const language = (navigator.languages ?? [navigator.language]).map((tag) => String(tag).slice(0, 2).toLowerCase())
  .find((tag) => tag in strings) ?? "en";
const text = strings[language];
const t = (key, value) => (text[key] ?? strings.it[key] ?? key).replace("%s", value ?? "");
const errorMessages = {
  invalid_credentials: "errInvalidCredentials", email_not_verified: "errNotVerified", login_expired: "errExpired",
  login_rate_limited: "errRateLimited", weak_password: "errWeakPassword", invalid_email: "errInvalidEmail",
  invalid_reset: "errInvalidReset", too_many_attempts: "errTooManyAttempts", email_failed: "errGeneric",
  email_unconfigured: "errEmailUnavailable", revision_conflict: "errConflict",
  patreon_unconfigured: "errPatreonUnavailable", network: "errNetwork",
};

const $ = (selector) => document.querySelector(selector);
const params = new URLSearchParams(location.search);
// Where the sign-in was started: "app" ends back in the app, anything else stays on the page.
const loginMode = params.get("login");
// The app's "Get Premium" opens the page here: the Premium section once signed in.
let pendingView = params.get("view") === "premium" ? "membership" : null;
const deletionPhrase = "ELIMINA IL MIO ACCOUNT";
let status = { emailEnabled: false, patreonEnabled: false };
let account = null;

document.documentElement.lang = language;
document.title = language === "it" ? "Account Seaglass" : "Seaglass account";
for (const element of document.querySelectorAll("[data-t]")) element.textContent = t(element.dataset.t);

class ApiError extends Error {
  constructor(code, status) { super(code); this.code = code; this.status = status; }
}

async function api(method, path, body) {
  let response;
  try {
    response = await fetch(path, {
      method,
      credentials: "same-origin",
      headers: body === undefined ? {} : { "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    throw new ApiError("network", 0);
  }
  let data = null;
  if (response.status !== 204) {
    try { data = await response.json(); } catch { data = null; }
  }
  if (!response.ok) throw new ApiError(data?.error ?? "error", response.status);
  return data;
}

function message(error) {
  if (error?.code === "login_expired" && loginMode === "app") return t("errExpiredApp");
  return t(errorMessages[error?.code] ?? "errGeneric");
}

function notice(key, tone = "ok") {
  const element = $("#notice");
  element.textContent = t(key);
  element.className = "notice " + tone;
  element.hidden = false;
}
function clearNotice() { $("#notice").hidden = true; }

const views = ["login", "register", "forgot", "reset", "verify", "overview", "profile", "password", "membership", "delete", "done"];
function show(name) {
  for (const view of views) $("#view-" + view).hidden = view !== name;
  $("#loading").hidden = true;
  $("#sign-out").hidden = !account;
  for (const form of document.querySelectorAll("form")) {
    const error = form.querySelector(".error");
    if (error) error.hidden = true;
  }
  window.scrollTo(0, 0);
  if (name === "profile") fillProfile();
  if (name === "membership") renderMembership();
  if (name === "password") $("#password-form").username.value = account?.email ?? "";
  if (name === "forgot" && !status.emailEnabled) {
    formError($("#forgot-form"), t("forgotUnavailable") + (status.supportEmail ? " " + status.supportEmail : ""));
  }
}

function formError(form, value) {
  const element = form.querySelector(".error");
  element.textContent = value;
  element.hidden = false;
}

/** Runs a form's action with its button disabled, showing the error under it. */
function handle(form, action) {
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = form.querySelector("button[type=submit]");
    form.querySelector(".error").hidden = true;
    button.disabled = true;
    try {
      await action(new FormData(form));
    } catch (error) {
      formError(form, error instanceof ApiError ? message(error) : String(error.message || t("errGeneric")));
    } finally {
      button.disabled = false;
    }
  });
}

function samePasswords(data) {
  if (data.get("password") !== data.get("confirm")) throw new Error(t("errPasswordsDiffer"));
  if (!passwordCheck(String(data.get("password"))).valid) throw new Error(t("errWeakPassword"));
}

// MARK: Choosing a password

/** The service's rule (8 characters, one special) and how strong the password is beyond it. */
function passwordCheck(value) {
  const missing = [];
  if (value.length < 8) missing.push(t("needLength"));
  if (!/[^\p{L}\p{N}\s]/u.test(value)) missing.push(t("needSpecial"));
  const extras = [value.length >= 12, /\p{Lu}/u.test(value) && /\p{Ll}/u.test(value), /\p{N}/u.test(value), value.length >= 16]
    .filter(Boolean).length;
  const level = missing.length ? 0 : extras >= 2 ? 2 : 1;
  return { valid: missing.length === 0, missing, level };
}

/**
 * Under each new password: how strong it is while it's typed, and what it still needs; under
 * its repetition, whether the two match.
 */
function watchPassword(form) {
  const input = form.querySelector('input[name="password"]');
  const confirm = form.querySelector('input[name="confirm"]');
  const meter = document.createElement("div");
  meter.className = "meter";
  meter.hidden = true;
  meter.setAttribute("aria-live", "polite");
  const bar = document.createElement("div");
  bar.className = "bar";
  for (let index = 0; index < 3; index += 1) bar.append(document.createElement("span"));
  const label = document.createElement("p");
  meter.append(bar, label);
  input.closest("label").after(meter);
  const match = document.createElement("p");
  match.className = "match";
  match.hidden = true;
  match.setAttribute("aria-live", "polite");
  confirm.closest("label").after(match);

  const update = () => {
    const value = input.value;
    meter.hidden = value.length === 0;
    const check = passwordCheck(value);
    meter.dataset.level = String(check.level);
    const name = [t("strengthWeak"), t("strengthFair"), t("strengthStrong")][check.level];
    label.textContent = `${t("strength")}: ${name}` +
      (check.missing.length ? ` · ${t("missing")} ${check.missing.join(", ")}` : check.level === 1 ? ` · ${t("tipStronger")}` : "");
    match.hidden = confirm.value.length === 0;
    const same = confirm.value === value;
    match.textContent = same ? t("passwordsMatch") : t("errPasswordsDiffer");
    match.classList.toggle("bad", !same);
    confirm.setCustomValidity(same ? "" : t("errPasswordsDiffer"));
  };
  input.addEventListener("input", update);
  confirm.addEventListener("input", update);
  form.addEventListener("reset", () => setTimeout(update));
}
for (const id of ["#register-form", "#reset-form", "#password-form"]) watchPassword($(id));

function formatDate(seconds) {
  return new Intl.DateTimeFormat(language, { day: "numeric", month: "long", year: "numeric" }).format(new Date(seconds * 1000));
}
function formatDateTime(seconds) {
  return new Intl.DateTimeFormat(language, { dateStyle: "medium", timeStyle: "short" }).format(new Date(seconds * 1000));
}

// MARK: Signing in

async function signIn(email, password) {
  // The browser's own sign-in starts here; the app's was started by the app (its cookie is set).
  if (loginMode !== "app") {
    try { await fetch("/v1/auth/start?client=web", { credentials: "same-origin" }); }
    catch { throw new ApiError("network", 0); }
  }
  const result = await api("POST", "/v1/auth/login", { email, password });
  const target = String(result?.redirect ?? "");
  if (target.startsWith("com.onda.player.auth:")) {
    $("#done-title").textContent = t("appReturnTitle");
    $("#done-text").textContent = t("appReturnText");
    $("#view-done .links").hidden = true;
    show("done");
    location.href = target;
    return;
  }
  history.replaceState(null, "", "/account");
  await loadAccount();
}

handle($("#login-form"), async (data) => {
  const email = String(data.get("email")).trim();
  try {
    await signIn(email, String(data.get("password")));
  } catch (error) {
    if (error instanceof ApiError && error.code === "email_not_verified") {
      $("#verify-form").email.value = email;
      show("verify");
      return;
    }
    throw error;
  }
});

handle($("#register-form"), async (data) => {
  samePasswords(data);
  const email = String(data.get("email")).trim();
  const password = String(data.get("password"));
  const result = await api("POST", "/v1/auth/register", { email, password, language });
  if (result?.verify) {
    $("#verify-form").email.value = email;
    show("verify");
    return;
  }
  await signIn(email, password);
});

handle($("#forgot-form"), async (data) => {
  if (!status.emailEnabled) throw new Error(t("forgotUnavailable") + (status.supportEmail ? " " + status.supportEmail : ""));
  const email = String(data.get("email")).trim();
  await api("POST", "/v1/auth/reset/request", { email, language });
  // Straight to entering the code.
  show("reset");
  $("#reset-form").email.value = email;
  $("#reset-form").code.focus();
  notice("noticeResetSent");
});

handle($("#reset-form"), async (data) => {
  samePasswords(data);
  const email = String(data.get("email")).trim();
  const code = String(data.get("code")).replace(/\s/g, "");
  await api("POST", "/v1/auth/reset", { email, code, password: String(data.get("password")) });
  $("#reset-form").reset();
  show("login");
  $("#login-form").email.value = email;
  notice("noticeResetDone");
});

handle($("#verify-form"), async (data) => {
  await api("POST", "/v1/auth/verify/resend", { email: String(data.get("email")), language });
  notice("noticeVerifySent");
});

// MARK: The account

async function loadAccount() {
  try {
    account = await api("GET", "/v1/account");
  } catch (error) {
    account = null;
    if (error.status === 401) { show("login"); return; }
    show("login");
    notice(errorMessages[error.code] ?? "errGeneric", "bad");
    return;
  }
  renderOverview();
  show(pendingView ?? "overview");
  pendingView = null;
}

function displayName() {
  const profile = account.profile ?? {};
  const full = [profile.firstName, profile.lastName].filter(Boolean).join(" ");
  return profile.displayName || full || account.email.split("@")[0];
}

function renderOverview() {
  const name = displayName();
  $("#who-name").textContent = name;
  $("#who-email").textContent = account.email + (account.emailVerified ? "" : " · " + t("emailUnverified"));
  $("#who-since").textContent = t("memberSince", formatDate(account.createdAt));
  $("#avatar").textContent = Array.from(name.trim())[0]?.toUpperCase() ?? "S";

  const membership = account.membership ?? {};
  const plan = $("#plan");
  const actions = $("#plan-actions");
  actions.replaceChildren();
  plan.classList.toggle("premium", Boolean(membership.premium));
  if (membership.premium) {
    $("#plan-name").textContent = t("planSupporter");
    $("#plan-detail").textContent = t("planSupporterDetail");
    actions.append(button(t("managePatreon"), () => show("membership"), "secondary"));
  } else if (membership.status === "declined_patron") {
    $("#plan-name").textContent = t("planDeclined");
    $("#plan-detail").textContent = t("planDeclinedDetail");
    actions.append(button(t("managePatreon"), () => show("membership"), "secondary"));
  } else {
    $("#plan-name").textContent = t("planFree");
    $("#plan-detail").textContent = t("planFreeDetail");
    if (membership.available) actions.append(button(t("becomeSupporter"), () => show("membership"), "primary"));
  }

  const records = account.records ?? {};
  $("#count-playlists").textContent = String(records.playlist ?? 0);
  $("#count-liked").textContent = String(records.favorites ?? 0);
  $("#count-history").textContent = String(records.history ?? 0);
  $("#synced-at").textContent = account.syncedAt ? t("syncedAt", formatDateTime(account.syncedAt)) : t("neverSynced");
}

function button(label, action, style) {
  const element = document.createElement("button");
  element.type = "button";
  element.className = style;
  element.textContent = label;
  element.addEventListener("click", action);
  return element;
}

function link(label, href, style) {
  const element = document.createElement("a");
  element.className = style === "primary" ? "primary" : "button";
  element.href = href;
  element.target = "_blank";
  element.rel = "noopener noreferrer";
  element.textContent = label;
  return element;
}

function fillProfile() {
  const form = $("#profile-form");
  const profile = account?.profile ?? {};
  form.firstName.value = profile.firstName ?? "";
  form.lastName.value = profile.lastName ?? "";
  form.displayName.value = profile.displayName ?? "";
  form.email.value = account?.email ?? "";
}

handle($("#profile-form"), async (data) => {
  const values = Object.fromEntries(["firstName", "lastName", "displayName"]
    .map((key) => [key, String(data.get(key) ?? "").trim()]).filter(([, value]) => value));
  try {
    await api("PUT", "/v1/sync/profile/profile", {
      revision: account.profileRevision ?? 0,
      operationId: crypto.randomUUID(),
      data: Object.keys(values).length ? values : null,
    });
  } catch (error) {
    if (error instanceof ApiError && error.code === "revision_conflict") {
      account = await api("GET", "/v1/account");
      fillProfile();
    }
    throw error;
  }
  account = await api("GET", "/v1/account");
  renderOverview();
  show("overview");
  notice("noticeProfile");
});

handle($("#password-form"), async (data) => {
  samePasswords(data);
  await api("POST", "/v1/account/password", { current: String(data.get("current")), password: String(data.get("password")) });
  $("#password-form").reset();
  show("overview");
  notice("noticePassword");
});

function renderMembership() {
  const membership = account?.membership ?? {};
  const actions = $("#membership-actions");
  actions.replaceChildren();
  $("#membership-error").hidden = true;
  const updated = membership.updatedAt ? " " + t("patreonUpdated", formatDate(membership.updatedAt)) : "";
  if (!membership.available) {
    $("#membership-state").textContent = t("patreonSoon");
    $("#membership-detail").textContent = "";
    return;
  }
  if (!membership.linked) {
    $("#membership-state").textContent = t("patreonNotLinked");
    $("#membership-detail").textContent = t("patreonNotLinkedDetail");
    if (membership.joinURL) actions.append(link(t("becomeSupporter"), membership.joinURL, "primary"));
    actions.append(button(t("linkPatreon"), connectPatreon, membership.joinURL ? "secondary" : "primary"));
    return;
  }
  const states = {
    active_patron: ["patreonActive", "planSupporterDetail"],
    declined_patron: ["patreonDeclined", "planDeclinedDetail"],
    former_patron: ["patreonFormer", "patreonLinkedNoneDetail"],
  };
  const [state, detail] = states[membership.status] ?? ["patreonLinkedNone", "patreonLinkedNoneDetail"];
  $("#membership-state").textContent = t(state);
  $("#membership-detail").textContent = t(detail) + updated;
  if (membership.premium || membership.status === "declined_patron") {
    // Patreon's own page of the memberships: cancelling, changing tier, the payment method.
    actions.append(link(t("managePatreon"), "https://www.patreon.com/settings/memberships", "secondary"));
  } else if (membership.joinURL) {
    actions.append(link(t("becomeSupporter"), membership.joinURL, "primary"));
  }
  actions.append(button(t("unlinkPatreon"), disconnectPatreon, "secondary"));
}

async function connectPatreon(event) {
  const target = event.currentTarget;
  target.disabled = true;
  try {
    const result = await api("POST", "/v1/patreon/connect", {});
    const patreon = new URL(result.redirect);
    if (patreon.protocol !== "https:" || patreon.hostname !== "www.patreon.com") throw new ApiError("error", 0);
    location.href = patreon.href;
  } catch (error) {
    target.disabled = false;
    const element = $("#membership-error");
    element.textContent = message(error);
    element.hidden = false;
  }
}

async function disconnectPatreon() {
  if (!confirm(t("confirmUnlink"))) return;
  try {
    await api("POST", "/v1/patreon/disconnect", {});
    account = await api("GET", "/v1/account");
    renderOverview();
    show("membership");
    notice("noticeUnlinked");
  } catch (error) {
    const element = $("#membership-error");
    element.textContent = message(error);
    element.hidden = false;
  }
}

handle($("#delete-form"), async (data) => {
  if (String(data.get("email")).trim().toLowerCase() !== account.email.toLowerCase()) throw new Error(t("errConfirmEmail"));
  await api("DELETE", "/v1/account", { confirm: deletionPhrase });
  account = null;
  $("#done-title").textContent = t("deletedTitle");
  $("#done-text").textContent = t("deletedText");
  $("#view-done .links").hidden = false;
  show("done");
});

$("#download-data").addEventListener("click", async (event) => {
  const target = event.currentTarget;
  target.disabled = true;
  try {
    const [overview, library] = await Promise.all([api("GET", "/v1/account"), api("GET", "/v1/sync/library")]);
    const data = {
      exportedAt: new Date().toISOString(),
      account: { email: overview.email, createdAt: new Date(overview.createdAt * 1000).toISOString(), profile: overview.profile },
      membership: overview.membership,
      library: library?.record?.data ?? null,
    };
    const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
    const anchor = document.createElement("a");
    anchor.href = URL.createObjectURL(blob);
    anchor.download = "seaglass-data.json";
    document.body.append(anchor);
    anchor.click();
    anchor.remove();
    setTimeout(() => URL.revokeObjectURL(anchor.href), 10_000);
  } catch (error) {
    notice(errorMessages[error.code] ?? "errGeneric", "bad");
  } finally {
    target.disabled = false;
  }
});

$("#sign-out-everywhere").addEventListener("click", async () => {
  if (!confirm(t("confirmSignOutAll"))) return;
  try {
    await api("DELETE", "/v1/sessions");
    account = null;
    show("login");
    notice("noticeSignedOutAll");
  } catch (error) {
    notice(errorMessages[error.code] ?? "errGeneric", "bad");
  }
});

$("#sign-out").addEventListener("click", async () => {
  try { await api("DELETE", "/v1/session"); } catch { /* signed out either way */ }
  account = null;
  show("login");
});

for (const element of document.querySelectorAll("[data-go]")) {
  element.addEventListener("click", () => {
    clearNotice();
    show(element.dataset.go);
  });
}

// MARK: Start

(async () => {
  try { status = await api("GET", "/v1/status"); } catch { /* the defaults: no email, no Patreon */ }
  if (status.supportEmail) {
    const anchor = $("#support-link");
    anchor.textContent = status.supportEmail;
    anchor.href = "mailto:" + status.supportEmail;
    $("#support").hidden = false;
  }
  const outcome = { linked: ["noticeLinked", "ok"], failed: ["noticeLinkFailed", "bad"] }[params.get("patreon")];
  const verified = { success: ["noticeVerified", "ok"], invalid: ["noticeVerifyInvalid", "bad"] }[params.get("verify")];
  if (loginMode === "app") {
    // The app's sign-in: always a fresh login, ending back in the app.
    $("#login-app-hint").hidden = false;
    show("login");
    return;
  }
  if (params.has("patreon") || params.has("verify") || params.has("view") || loginMode) history.replaceState(null, "", "/account");
  await loadAccount();
  if (outcome) {
    if (account) show("membership");
    notice(...outcome);
  }
  if (verified) notice(...verified);
})();
