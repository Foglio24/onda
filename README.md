# Onda

Client musicale per iPhone ispirato a [LastWave](https://github.com/Clash-Projects/LastWave-Native) per Android.
È scritto da zero in Swift/SwiftUI e non contiene codice del progetto originale.
Funziona da iOS 26 in su, quindi anche su iPhone 17 Pro con iOS 27, e usa il design Liquid Glass.

## Cosa fa

| LastWave (Android) | Onda (iOS) |
|---|---|
| Streaming dal catalogo YouTube Music, in background e senza pubblicità | ✅ Audio AAC (m4a). AVPlayer non decodifica Opus/WebM, quindi niente Opus |
| Radio e mix intelligenti | ✅ Radio da ogni brano, radio automatica a fine coda, mood (Relax, Festa, …), *Taste Mix* e *Riscopri* da Last.fm |
| Scrobbler Last.fm | ✅ Now playing, scrobble dopo metà brano o 4 minuti, coda offline, "Mi piace" sincronizzato |
| Testi sincronizzati da LRCLIB | ✅ Scorrimento automatico, riga attiva evidenziata, tocca una riga per saltarci |
| Download offline | ✅ Audio e copertina salvati nell'app |
| Controlli su schermata di blocco, Centro di Controllo e AirPlay | ✅ |
| Colori dinamici dalla copertina | ✅ Sfondo del player tinto con il colore dell'album |
| Libreria | ✅ Preferiti, download, cronologia, coda modificabile (trascina, elimina, mescola) |

Funzioni di LastWave **non** incluse:
- **Scrobbler universale delle altre app**: iOS non permette a un'app di leggere cosa riproducono Spotify o Apple Music. Onda registra solo ciò che ascolti in Onda.
- **Import di playlist Spotify/Apple Music** e **feed social**: possono arrivare in futuro.
- **Android Auto / CarPlay**: CarPlay richiede un entitlement che Apple non dà agli account gratuiti.
- **Driver USB DAC / bit-perfect**: non è possibile su iOS.

## 1. Compilare l'IPA (non serve un Mac)

L'IPA viene compilata da GitHub Actions su un Mac nel cloud.

1. Crea un repository su GitHub (anche privato) e caricaci il contenuto di questa cartella: `.github`, `Onda`, `Support`, `project.yml`, `README.md`, `.gitignore`.
   Senza git puoi usare **Add file → Upload files** e trascinare le cartelle nella pagina.
   Se la cartella `.github` non viene caricata, crea il file a mano con **Add file → Create new file**: come nome scrivi `.github/workflows/build.yml` e incolla il contenuto del file.
2. Apri la scheda **Actions** del repository. La build **Build IPA** parte da sola a ogni push su `main`, oppure puoi avviarla a mano con **Run workflow**.
3. Dopo circa 5-10 minuti apri la build completata e scarica l'artifact **Onda-ipa**: è uno zip che contiene `Onda.ipa`.

Se crei un tag `v1.0.0`, l'IPA viene anche allegata a una Release, comoda da scaricare direttamente dall'iPhone.

> Repository privato: GitHub conta i minuti macOS 10 volte, quindi i 2000 minuti gratuiti diventano circa 20 build al mese. Con un repository pubblico i minuti sono illimitati.

## 2. Installare sull'iPhone (sideloading da Windows)

Con **Sideloadly**:

1. Installa iTunes e iCloud per Windows scaricati **dal sito Apple** e non dal Microsoft Store (la pagina di Sideloadly ha i link diretti), poi installa [Sideloadly](https://sideloadly.io).
2. Collega l'iPhone con il cavo USB e, se te lo chiede, scegli "Autorizza questo computer".
3. Trascina `Onda.ipa` in Sideloadly, inserisci il tuo Apple ID e premi **Start**. Va bene un Apple ID gratuito.
4. Sull'iPhone vai in **Impostazioni → Privacy e sicurezza → Modalità sviluppatore**, attivala e riavvia.
5. Vai in **Impostazioni → Generali → VPN e gestione dispositivi**, tocca il tuo Apple ID e scegli **Autorizza**.

Con un Apple ID gratuito l'app scade dopo **7 giorni**: per rinnovarla ripeti il punto 3, senza perdere i dati.
Se vuoi rinnovarla direttamente dall'iPhone senza PC, usa [SideStore](https://sidestore.io).
Con un account sviluppatore a pagamento la firma dura un anno.

## 3. Collegare Last.fm (facoltativo)

1. Vai su <https://www.last.fm/api/account/create> e crea un'applicazione API. Nome e descrizione sono a piacere, il callback puoi lasciarlo vuoto.
2. In Onda apri **Impostazioni → Last.fm**, incolla **API key** e **Shared secret** e tocca **Salva chiavi**.
3. Tocca **Connetti account Last.fm**, accedi, scegli **Yes, allow access** e chiudi la pagina.

Da quel momento in Home compaiono *Taste Mix*, *Riscopri* e i tuoi brani più ascoltati del mese.

## Problemi comuni

- **La build su GitHub fallisce**: apri il log del passaggio *Build (unsigned)* e copia le righe che contengono `error:`.
- **"Brano non disponibile" su tutti i brani**: YouTube cambia spesso il suo player. Aggiorna la versione di YouTubeKit in `project.yml` (`from: "0.4.9"`) e ricompila.
- **L'app non si apre più**: è passata la scadenza dei 7 giorni, quindi rifirmala con Sideloadly.

## Come è fatto

```
Onda/
  App/        avvio dell'app e tab bar (Home, Libreria, Impostazioni, Cerca, mini player)
  Player/     AVPlayer, coda, radio automatica, schermata di blocco, scrobbling
  Services/   YouTube Music (InnerTube), stream (YouTubeKit), LRCLIB, Last.fm, download, libreria
  Views/      schermate SwiftUI
project.yml   progetto XcodeGen (il .xcodeproj viene generato in CI)
```

- Ricerca e radio usano l'API web di YouTube Music (client `WEB_REMIX`).
- Gli URL audio arrivano da [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit). L'estrazione avviene sul telefono e, solo se fallisce, sul server dell'autore della libreria, che riceve l'ID del video.
- I testi arrivano da [LRCLIB](https://lrclib.net). Lo scrobbling usa l'[API di Last.fm](https://www.last.fm/api).

## Note

Progetto personale e non commerciale, non affiliato a Google, YouTube o Last.fm.
I client non ufficiali e il download dei brani possono violare i Termini di servizio di YouTube: usalo solo per te.
