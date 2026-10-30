<p align="center">
  <img src="docs/images/seaglass-banner.jpg" alt="Seaglass — your music, in motion" width="100%">
</p>

<h1 align="center">Seaglass <sub>ex Onda</sub></h1>

<p align="center"><strong>La tua musica, il tuo ritmo.</strong><br>
Un lettore musicale indipendente per iPhone, con AutoMix, playlist e testi sincronizzati.</p>

<p align="center">
  <a href="https://github.com/Foglio24/onda/releases/latest/download/Seaglass.ipa"><img src="https://img.shields.io/badge/SCARICA-Seaglass.ipa-EC3F8E?style=for-the-badge&amp;logo=apple&amp;logoColor=white" alt="Scarica Seaglass.ipa"></a>
  <a href="https://github.com/Foglio24/onda/releases/latest"><img src="https://img.shields.io/github/v/release/Foglio24/onda?style=for-the-badge&amp;label=VERSIONE" alt="Ultima versione"></a>
  <a href="https://github.com/Foglio24/onda/releases"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2FFoglio24%2Fonda%2Fdownload-stats%2Fdownload-count.json&amp;style=for-the-badge" alt="Download totali delle app IPA"></a>
</p>

<p align="center">
  <a href="#scopri-seaglass">Scopri l'app</a> · <a href="#anteprima">Anteprima</a> ·
  <a href="#installazione">Installazione</a> · <a href="#domande-frequenti">Domande frequenti</a> ·
  <a href="CHANGELOG.md">Novità</a>
</p>

## Scopri Seaglass

**Seaglass**, prima conosciuta come Onda, è un'app musicale per iPhone che utilizza il catalogo YouTube Music. Riunisce riproduzione in background, libreria personale e strumenti per passare da una canzone all'altra: un'alternativa indipendente per chi cerca un'esperienza musicale personalizzabile.

### La tua musica, senza interruzioni

- **AutoMix** analizza le canzoni e sceglie una transizione adatta. Quando il ritmo lo permette, prova ad allineare i beat modificando gradualmente la velocità senza cambiare l'intonazione; per brani meno compatibili può scegliere un altro tipo di passaggio.
- **Playlist Mix** applica automaticamente le transizioni a una playlist. Tra brani scaricati puoi anche personalizzare il mix con forme d'onda, volume, equalizzazione ed effetti.
- **Qualità audio regolabile** separatamente per Wi-Fi, rete mobile e download. La qualità massima può usare Opus; Dolby Digital Plus o AAC possono essere utilizzati quando disponibili. Il formato effettivo dipende dal brano e dalle condizioni del dispositivo.
- **Equalizzatore e volume uniforme** per adattare l'ascolto alle tue preferenze.

### Una libreria tutta tua

- Cerca brani, artisti e album; salva preferiti, crea playlist e organizza la coda.
- Scarica brani, album e playlist per ascoltarli offline e controlla lo spazio occupato nelle impostazioni.
- Importa playlist da link Spotify, Apple Music e YouTube. Se una canzone non viene trovata, puoi consultare il rapporto e scegliere un'alternativa proposta.
- I link Spotify pubblici possono mostrare solo i primi 100 brani: per playlist più lunghe puoi importare un file Spotify JSON o CSV da **Libreria → Importa playlist da file**.
- Scopri radio e mix personalizzati; collega Last.fm per lo scrobbling e altre funzioni legate ai tuoi ascolti.

### Segui e canta

- **Testi sincronizzati** da LRCLIB, con scorrimento e possibilità di toccare un verso per spostarsi nel brano.
- **Traduzione dei testi** con gli strumenti di Apple, quando la lingua è disponibile sul dispositivo.
- **Karaoke con IA** per regolare voce e accompagnamento: l'elaborazione avviene su iPhone e può richiedere tempo.
- Controlli da schermata di blocco, Centro di Controllo e AirPlay; interfaccia in italiano e inglese.

## Anteprima

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/home.jpg" width="200" alt="Home"><br><sub>Home</sub></td>
    <td align="center"><img src="docs/screenshots/search.jpg" width="200" alt="Ricerca"><br><sub>Ricerca</sub></td>
    <td align="center"><img src="docs/screenshots/player.jpg" width="200" alt="Player"><br><sub>Player</sub></td>
    <td align="center"><img src="docs/screenshots/artist.jpg" width="200" alt="Artista"><br><sub>Artista</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/album.jpg" width="200" alt="Album"><br><sub>Album</sub></td>
    <td align="center"><img src="docs/screenshots/mix.jpg" width="200" alt="Editor Playlist Mix"><br><sub>Playlist Mix</sub></td>
    <td align="center"><img src="docs/screenshots/equalizer.jpg" width="200" alt="Equalizzatore"><br><sub>Equalizzatore</sub></td>
    <td align="center"><img src="docs/screenshots/settings.jpg" width="200" alt="Impostazioni audio"><br><sub>Impostazioni</sub></td>
  </tr>
</table>

<sub>Schermate create nel simulatore iOS. Copertine, nomi e musica appartengono ai rispettivi titolari.</sub>

## Installazione

**Requisiti:** iPhone con iOS 26 o successivo. L'IPA è **non firmata**: occorre firmarla e installarla con uno strumento di sideload, come Sideloadly, AltStore Classic o SideStore.

1. [Scarica l'ultima versione di Seaglass.ipa](https://github.com/Foglio24/onda/releases/latest/download/Seaglass.ipa).
2. Apri il file con lo strumento di sideload scelto e segui le sue istruzioni per firmarlo e installarlo.
3. Se richiesto, abilita **Modalità sviluppatore** in Impostazioni → Privacy e sicurezza e autorizza il profilo in Impostazioni → Generali → VPN e gestione dispositivo.

Con un Apple ID gratuito la firma può scadere dopo 7 giorni: in quel caso va rinnovata. Le modalità di rinnovo dipendono dallo strumento scelto. Seaglass non è pubblicata su App Store o AltStore PAL.

### Aggiornamenti

L'app può cercare nuove release su GitHub e avvisarti oppure scaricare l'IPA nell'app File. L'installazione dell'aggiornamento resta manuale tramite il tuo strumento di sideload. Trovi l'elenco completo delle modifiche nel [changelog](CHANGELOG.md).

## Domande frequenti

**Perché il formato audio non è sempre Opus?**  
La disponibilità cambia da brano a brano. L'app può usare un formato alternativo, per esempio se è disponibile Dolby o se la decodifica Opus non può essere utilizzata; controlla il formato indicato nel player e la diagnostica nelle impostazioni.

**AutoMix usa sempre il beat matching?**  
No. Prova a privilegiare transizioni a tempo quando sono adatte, ma può scegliere un altro passaggio se ritmo o voci rendono il mix poco naturale.

**Perché mancano canzoni dopo un'importazione?**  
Alcune versioni potrebbero non essere trovate o non corrispondere con sufficiente sicurezza. Apri il rapporto dell'importazione per vedere i brani mancanti e scegliere eventuali alternative. Per playlist Spotify lunghe usa l'importazione da file descritta sopra.

**Cosa indica il contatore?**  
Somma i download dei file `Onda.ipa` e `Seaglass.ipa` nelle release pubblicate su GitHub. Si aggiorna periodicamente: non rappresenta il numero di utenti o installazioni.

**Come segnalo un problema?**  
Apri una [segnalazione su GitHub](https://github.com/Foglio24/onda/issues), indicando la versione dell'app, il modello di iPhone e i passaggi per riprodurre il problema. Se utile, puoi condividere il rapporto da **Impostazioni → Diagnostica**.

## Dettagli del progetto

Seaglass è scritta in Swift e SwiftUI. Usa YouTube Music per ricerca e catalogo, YouTubeKit per i collegamenti audio, LRCLIB per i testi e Last.fm per lo scrobbling. Le dipendenze e i relativi riconoscimenti sono elencati in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

GitHub Actions compila un'IPA non firmata: il workflow **Build IPA** produce un artefatto scaricabile. Le release pubblicate e le relative note sono disponibili nella [pagina Releases](https://github.com/Foglio24/onda/releases).

## Licenza e note

Il codice è pubblico e consultabile. L'app può essere scaricata e installata sui propri dispositivi per uso personale e non commerciale; modifica e ridistribuzione richiedono autorizzazione. Consulta la [licenza completa](LICENSE).

Seaglass è un progetto personale indipendente, non affiliato né approvato da Google, YouTube, Spotify, Apple, Last.fm o LRCLIB. Musica, copertine, testi e marchi appartengono ai rispettivi titolari. L'uso di client non ufficiali e il download dei brani possono essere soggetti ai termini dei servizi utilizzati.
