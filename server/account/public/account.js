"use strict";

// Seaglass's account page: sign-in for the browser and for the app, and everything about the
// account (profile, password, Patreon, data, sign-out, deletion). The app only shows it.

const strings = {
  it: {
    signOut: "Esci", loginTitle: "Accedi a Seaglass", email: "Email", password: "Password", loginButton: "Accedi",
    loginAppHint: "Accedi per sincronizzare libreria, playlist e preferenze con l'app.",
    forgot: "Password dimenticata?", noAccount: "Non hai un account?", registerLink: "Registrati a Seaglass",
    registerTitle: "Crea il tuo account", passwordConfirm: "Ripeti la password", passwordRule: "Almeno 12 caratteri.",
    registerButton: "Registrati", haveAccount: "Hai già un account?", loginLink: "Accedi",
    forgotTitle: "Reimposta la password",
    forgotLead: "Inserisci l'email del tuo account: ti mandiamo un link per scegliere una nuova password.",
    send: "Invia", back: "Indietro", resetTitle: "Scegli una nuova password", newPassword: "Nuova password", save: "Salva",
    verifyTitle: "Conferma la tua email", verifyLead: "Ti abbiamo mandato un link: aprilo per attivare l'account, poi accedi.",
    verifyResend: "Invia di nuovo", yourPlan: "Il tuo piano", sectionAccount: "Account", editProfile: "Modifica profilo",
    changePassword: "Cambia password", membership: "Sostieni Seaglass", sectionLibrary: "La tua libreria",
    playlists: "Playlist", liked: "Brani che ti piacciono", history: "Ascoltati di recente",
    downloadData: "Scarica i tuoi dati", sectionSecurity: "Sicurezza e privacy", signOutEverywhere: "Esci ovunque",
    deleteAccount: "Elimina account",
    signOutEverywhereHint: "«Esci ovunque» chiude la sessione nell'app su tutti i dispositivi e in tutti i browser.",
    firstName: "Nome", lastName: "Cognome", displayName: "Nome visualizzato", saveProfile: "Salva profilo",
    currentPassword: "Password attuale",
    passwordChangeHint: "Almeno 12 caratteri. Gli altri dispositivi dovranno accedere di nuovo.",
    setPassword: "Imposta nuova password",
    membershipLead: "Seaglass è gratuito e lo resta: il sostegno su Patreon aiuta a svilupparlo. In cambio hai il badge di sostenitore nell'app.",
    deleteLead: "Eliminiamo subito l'account e tutto ciò che è sincronizzato: playlist, brani che ti piacciono, cronologia, preferenze e il collegamento a Patreon. Sui dispositivi la libreria resta, ma non si sincronizza più. Non si può annullare.",
    deletePatreon: "L'eventuale abbonamento su Patreon si annulla su Patreon.",
    deleteConfirm: "Per confermare scrivi la tua email", deleteButton: "Elimina definitivamente",
    loading: "Caricamento…", footer: "Seaglass non è affiliato a YouTube né a Patreon.",
    planFree: "Seaglass", planFreeDetail: "Tutte le funzioni, gratis.", planSupporter: "Sostenitore",
    planSupporterDetail: "Grazie: sostieni Seaglass su Patreon.", planDeclined: "Pagamento non riuscito su Patreon",
    planDeclinedDetail: "Aggiorna il metodo di pagamento su Patreon per restare sostenitore.",
    becomeSupporter: "Diventa sostenitore", managePatreon: "Gestisci su Patreon", linkPatreon: "Collega Patreon",
    unlinkPatreon: "Scollega Patreon", patreonSoon: "Il sostegno su Patreon arriverà presto.",
    patreonNotLinked: "Non collegato", patreonNotLinkedDetail: "Collega il tuo account Patreon: se sostieni Seaglass, il tuo piano si aggiorna da solo.",
    patreonActive: "Sostenitore attivo", patreonLinkedNone: "Collegato, nessun abbonamento",
    patreonLinkedNoneDetail: "Il tuo account Patreon è collegato ma non sostiene Seaglass. Se ti iscrivi, il piano si aggiorna da solo.",
    patreonFormer: "Ex sostenitore", patreonDeclined: "Pagamento non riuscito",
    patreonUpdated: "Aggiornato il %s.",
    memberSince: "Su Seaglass dal %s", syncedAt: "Ultima sincronizzazione: %s", neverSynced: "La libreria non è ancora stata sincronizzata: accedi dall'app.",
    emailUnverified: "Email non confermata",
    noticeLinked: "Patreon collegato.", noticeLinkFailed: "Non è stato possibile collegare Patreon. Riprova.",
    noticeVerified: "Email confermata: ora puoi accedere.", noticeVerifyInvalid: "Il link di conferma non è valido o è scaduto.",
    noticeProfile: "Profilo salvato.", noticePassword: "Password aggiornata.", noticeSignedOutAll: "Sei uscito da tutti i dispositivi.",
    noticeUnlinked: "Patreon scollegato.", noticeResetSent: "Se l'email corrisponde a un account, riceverai un link a breve.",
    noticeResetDone: "Password reimpostata: ora puoi accedere.", noticeVerifySent: "Link inviato di nuovo.",
    deletedTitle: "Account eliminato", deletedText: "Il tuo account e i dati sincronizzati sono stati eliminati.",
    appReturnTitle: "Torna a Seaglass", appReturnText: "Accesso completato: puoi tornare all'app.",
    confirmSignOutAll: "Uscire da Seaglass su tutti i dispositivi?", confirmUnlink: "Scollegare l'account Patreon?",
    errPasswordsDiffer: "Le password non coincidono.", errInvalidCredentials: "Email o password non corretti.",
    errNotVerified: "Conferma prima la tua email.", errExpired: "La pagina è scaduta: riprova.",
    errExpiredApp: "L'accesso è scaduto: torna all'app e premi di nuovo Accedi.",
    errRateLimited: "Troppi tentativi: riprova tra qualche minuto.", errWeakPassword: "La password deve avere almeno 12 caratteri.",
    errInvalidEmail: "Inserisci un indirizzo email valido.", errInvalidReset: "Il link non è valido o è scaduto.",
    errEmailUnavailable: "L'invio delle email non è ancora disponibile.", errConflict: "Il profilo è cambiato altrove: è stato ricaricato, riprova.",
    errConfirmEmail: "L'email non corrisponde a quella dell'account.", errNetwork: "Connessione non riuscita. Riprova.",
    errGeneric: "Qualcosa è andato storto. Riprova.", errPatreonUnavailable: "Patreon non è ancora configurato.",
    forgotUnavailable: "Il recupero della password via email non è ancora disponibile.",
  },
  en: {
    signOut: "Log out", loginTitle: "Log in to Seaglass", email: "Email", password: "Password", loginButton: "Log in",
    loginAppHint: "Log in to sync your library, playlists and preferences with the app.",
    forgot: "Forgot your password?", noAccount: "Don't have an account?", registerLink: "Sign up for Seaglass",
    registerTitle: "Create your account", passwordConfirm: "Repeat the password", passwordRule: "At least 12 characters.",
    registerButton: "Sign up", haveAccount: "Already have an account?", loginLink: "Log in",
    forgotTitle: "Reset your password",
    forgotLead: "Enter your account's email: we'll send you a link to choose a new password.",
    send: "Send", back: "Back", resetTitle: "Choose a new password", newPassword: "New password", save: "Save",
    verifyTitle: "Confirm your email", verifyLead: "We sent you a link: open it to activate your account, then log in.",
    verifyResend: "Send again", yourPlan: "Your plan", sectionAccount: "Account", editProfile: "Edit profile",
    changePassword: "Change password", membership: "Support Seaglass", sectionLibrary: "Your library",
    playlists: "Playlists", liked: "Liked songs", history: "Recently played",
    downloadData: "Download your data", sectionSecurity: "Security and privacy", signOutEverywhere: "Sign out everywhere",
    deleteAccount: "Delete account",
    signOutEverywhereHint: "“Sign out everywhere” logs you out of the app on every device and of every browser.",
    firstName: "First name", lastName: "Last name", displayName: "Display name", saveProfile: "Save profile",
    currentPassword: "Current password",
    passwordChangeHint: "At least 12 characters. Your other devices will need to log in again.",
    setPassword: "Set new password",
    membershipLead: "Seaglass is free and stays free: support on Patreon helps develop it. In return you get the supporter badge in the app.",
    deleteLead: "We delete your account and everything synced right away: playlists, liked songs, history, preferences and the Patreon link. Your devices keep their library, but it no longer syncs. This can't be undone.",
    deletePatreon: "A Patreon membership is cancelled on Patreon.",
    deleteConfirm: "To confirm, type your email", deleteButton: "Delete permanently",
    loading: "Loading…", footer: "Seaglass isn't affiliated with YouTube or Patreon.",
    planFree: "Seaglass", planFreeDetail: "Every feature, free.", planSupporter: "Supporter",
    planSupporterDetail: "Thank you for supporting Seaglass on Patreon.", planDeclined: "Payment declined on Patreon",
    planDeclinedDetail: "Update your payment method on Patreon to stay a supporter.",
    becomeSupporter: "Become a supporter", managePatreon: "Manage on Patreon", linkPatreon: "Link Patreon",
    unlinkPatreon: "Unlink Patreon", patreonSoon: "Support on Patreon is coming soon.",
    patreonNotLinked: "Not linked", patreonNotLinkedDetail: "Link your Patreon account: if you support Seaglass, your plan updates by itself.",
    patreonActive: "Active supporter", patreonLinkedNone: "Linked, no membership",
    patreonLinkedNoneDetail: "Your Patreon account is linked but doesn't support Seaglass. If you join, your plan updates by itself.",
    patreonFormer: "Former supporter", patreonDeclined: "Payment declined",
    patreonUpdated: "Updated on %s.",
    memberSince: "On Seaglass since %s", syncedAt: "Last synced: %s", neverSynced: "Your library hasn't synced yet: log in from the app.",
    emailUnverified: "Email not confirmed",
    noticeLinked: "Patreon linked.", noticeLinkFailed: "Patreon couldn't be linked. Try again.",
    noticeVerified: "Email confirmed: you can log in now.", noticeVerifyInvalid: "The confirmation link is invalid or has expired.",
    noticeProfile: "Profile saved.", noticePassword: "Password updated.", noticeSignedOutAll: "You've been signed out everywhere.",
    noticeUnlinked: "Patreon unlinked.", noticeResetSent: "If the email matches an account, you'll get a link shortly.",
    noticeResetDone: "Password reset: you can log in now.", noticeVerifySent: "Link sent again.",
    deletedTitle: "Account deleted", deletedText: "Your account and its synced data have been deleted.",
    appReturnTitle: "Back to Seaglass", appReturnText: "You're logged in: you can go back to the app.",
    confirmSignOutAll: "Sign out of Seaglass on every device?", confirmUnlink: "Unlink your Patreon account?",
    errPasswordsDiffer: "The passwords don't match.", errInvalidCredentials: "Incorrect email or password.",
    errNotVerified: "Confirm your email first.", errExpired: "This page has expired: try again.",
    errExpiredApp: "The login has expired: go back to the app and tap Log in again.",
    errRateLimited: "Too many attempts: try again in a few minutes.", errWeakPassword: "The password needs at least 12 characters.",
    errInvalidEmail: "Enter a valid email address.", errInvalidReset: "The link is invalid or has expired.",
    errEmailUnavailable: "Sending emails isn't available yet.", errConflict: "Your profile changed elsewhere: it has been reloaded, try again.",
    errConfirmEmail: "The email doesn't match the account's.", errNetwork: "Couldn't connect. Try again.",
    errGeneric: "Something went wrong. Try again.", errPatreonUnavailable: "Patreon isn't set up yet.",
    forgotUnavailable: "Password recovery by email isn't available yet.",
  },
};
const language = (navigator.languages ?? [navigator.language]).map((tag) => String(tag).slice(0, 2).toLowerCase())
  .find((tag) => tag in strings) ?? "en";
const text = strings[language];
const t = (key, value) => (text[key] ?? strings.it[key] ?? key).replace("%s", value ?? "");
const errorMessages = {
  invalid_credentials: "errInvalidCredentials", email_not_verified: "errNotVerified", login_expired: "errExpired",
  login_rate_limited: "errRateLimited", weak_password: "errWeakPassword", invalid_email: "errInvalidEmail",
  invalid_reset: "errInvalidReset", email_unconfigured: "errEmailUnavailable", revision_conflict: "errConflict",
  patreon_unconfigured: "errPatreonUnavailable", network: "errNetwork",
};

const $ = (selector) => document.querySelector(selector);
const params = new URLSearchParams(location.search);
// Where the sign-in was started: "app" ends back in the app, anything else stays on the page.
const loginMode = params.get("login");
const resetToken = params.get("reset");
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
    formError($("#forgot-form"), t("forgotUnavailable"));
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
  if (String(data.get("password")).length < 12) throw new Error(t("errWeakPassword"));
}

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
  const result = await api("POST", "/v1/auth/register", { email, password });
  if (result?.verify) {
    $("#verify-form").email.value = email;
    show("verify");
    return;
  }
  await signIn(email, password);
});

handle($("#forgot-form"), async (data) => {
  if (!status.emailEnabled) throw new Error(t("forgotUnavailable"));
  await api("POST", "/v1/auth/reset/request", { email: String(data.get("email")).trim() });
  show("login");
  notice("noticeResetSent");
});

handle($("#reset-form"), async (data) => {
  samePasswords(data);
  await api("POST", "/v1/auth/reset", { token: resetToken, password: String(data.get("password")) });
  history.replaceState(null, "", "/account");
  show("login");
  notice("noticeResetDone");
});

handle($("#verify-form"), async (data) => {
  await api("POST", "/v1/auth/verify/resend", { email: String(data.get("email")) });
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
  show("overview");
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
  plan.classList.toggle("supporter", Boolean(membership.supporter));
  if (membership.supporter) {
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
    actions.append(button(t("linkPatreon"), connectPatreon, "primary"));
    if (membership.joinURL) actions.append(link(t("becomeSupporter"), membership.joinURL));
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
  if (membership.joinURL) {
    actions.append(link(t(membership.supporter ? "managePatreon" : "becomeSupporter"), membership.joinURL,
      membership.supporter ? "secondary" : "primary"));
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
  const outcome = { linked: ["noticeLinked", "ok"], failed: ["noticeLinkFailed", "bad"] }[params.get("patreon")];
  const verified = { success: ["noticeVerified", "ok"], invalid: ["noticeVerifyInvalid", "bad"] }[params.get("verify")];
  if (resetToken && /^[A-Za-z0-9_-]{43}$/.test(resetToken)) {
    show("reset");
    return;
  }
  if (loginMode === "app") {
    // The app's sign-in: always a fresh login, ending back in the app.
    $("#login-app-hint").hidden = false;
    show("login");
    return;
  }
  if (params.has("patreon") || params.has("verify") || loginMode) history.replaceState(null, "", "/account");
  await loadAccount();
  if (outcome) {
    if (account) show("membership");
    notice(...outcome);
  }
  if (verified) notice(...verified);
})();
