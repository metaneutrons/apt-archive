# Renderer

`render_archive.py` erzeugt aus einem Domain-Manifest und einem Verzeichnis
voller `.deb`-Dateien den vollstaendigen, signierfertigen Archivbaum **eines
Projekts**. Er kennt kein Netz, keinen Schluessel und keine Cloudflare-API.

```
scripts/render-archive.sh \
  --manifest domains/metaneutrons.cc/manifest.toml \
  --project aros-tools \
  --pool-dir /pfad/zu/allen/debs \
  --output-dir /pfad/zum/neuen/archiv \
  --metadata-epoch 1700000000
```

Ergebnis unter `--output-dir`, dem Archivwurzelverzeichnis eines Projektpraefix,
also zum Beispiel `https://deb.metaneutrons.cc/aros-tools`:

```
pool/main/a/aros-tools/aros-tools_1.0.0-1_amd64.deb
dists/rolling/main/binary-amd64/Packages
dists/rolling/main/binary-amd64/Packages.gz
dists/rolling/main/binary-amd64/by-hash/SHA256/<summe>
dists/rolling/main/binary-amd64/by-hash/SHA512/<summe>
dists/rolling/Release
```

## Ein Archiv je Projekt

Jedes Projekt bekommt ein eigenes Praefix und damit eine eigene `Release`-Datei
mit eigener `Valid-Until`-Uhr. Ein Projekt ohne Release in einem halben Jahr
laeuft ab, ohne die uebrigen mitzureissen.

## Der Pool ist die Eingabe, nicht eine Version

`--pool-dir` enthaelt **jede** Version, die veroeffentlicht werden soll. Der
Renderer indiziert, was er vorfindet. Damit sind ein Projekt mit einer Version
und eines mit einundvierzig derselbe Codepfad.

## Warum by-hash unter jedem Hash

`Release` nennt SHA256 und SHA512, und apt fragt den **staerksten** an, also
`by-hash/SHA512/<summe>`. Fehlt dieser Baum, faellt apt ohne Fehlermeldung auf
den veraenderlichen Pfad `Packages.gz` zurueck, und by-hash ist wirkungslos.
Gemessen am 1. September 2026 gegen `debian:bookworm`, apt 2.6.1, mit einem
mitloggenden Server. Deshalb wird unter jedem in `Release` genannten Hash
gespiegelt; die Indexe sind wenige Kilobyte gross.

`Packages.xz` fehlt bewusst. Seine Bytes haengen an der liblzma-Version, und die
Ersparnis auf einem Index dieser Groesse rechtfertigt den Determinismusverlust
nicht.

## Was der Renderer ablehnt

Alles, was ein Archiv still beschaedigen wuerde:

- ein Paketname, den das Projekt im Manifest nicht auffuehrt
- eine Architektur, die die Domain nicht bedient
- zwei Dateien mit derselben Identitaet aus Name, Version und Architektur
- ein Manifest mit abgeschaltetem `acquire_by_hash`
- ein bereits vorhandenes Ausgabeverzeichnis

## Determinismus

Zwei Laeufe mit gleicher Eingabe und gleichem `--metadata-epoch` sind
byteidentisch; die Testsuite prueft das. `render-archive.sh` fuehrt den Renderer
in einem digest-gepinnten Container ohne Netz aus, weil die Bytes von
`Packages.gz` sonst an der zlib-Version des Hosts haengen. `AR_RENDER_LOCAL=1`
umgeht den Container.

## Signatur

`sign-archive.sh` erzeugt neben dem gerenderten `Release` die Dateien
`InRelease` und `Release.gpg` sowie den Domain-Keyring in beiden Fassungen, und
prueft sein Ergebnis mit `gpgv` gegen genau den Keyring, den ein Client
bekommt. `verify-signing-bundle.sh` prueft vorher das importierte Material.

Signiert wird immer mit dem Subkey aus dem Manifest, gepinnt per abschliessendem
Ausrufezeichen. Ohne das waehlt gpg bei mehreren Signing-Subkeys selbst einen
aus, und der Export liefert alle statt des einen, der zu dieser Domain gehoert.

Die Metadaten-Epoche darf nicht vor der Erzeugung des Subkeys liegen. gpg
signiert sonst nicht und meldet nur "unbrauchbarer geheimer Schluessel"; das
Skript lehnt es benannt ab. Folge: ein alter Baum laesst sich nach einer
Rotation nicht mit seinem urspruenglichen `SOURCE_DATE_EPOCH` nachsignieren.

## Veroeffentlichung

```
scripts/publish-archive.sh --manifest domains/metaneutrons.cc/manifest.toml \
  --project aros-tools --archive-dir <signierte wurzel> [--preflight]
```

Zugangsdaten kommen aus `R2_ACCESS_KEY_ID` und `R2_SECRET_ACCESS_KEY`, nie aus
Argumenten. `--preflight` prueft Zugang, Bucket und Plan und schreibt nichts.

**Objekte zuerst, Metadaten zuletzt.** Vier Phasen in dieser Reihenfolge:
Keyring, Pool, Indexe, dann `Release`, `Release.gpg` und `InRelease`. Umgekehrt
entstuende ein Fenster, in dem signierte Metadaten auf noch nicht vorhandene
Pakete zeigen. Innerhalb einer Phase laeuft der Upload parallel, zwischen den
Phasen streng sequenziell, und die Release-Phase ganz sequenziell.

**Der Keyring liegt in der Bucket-Wurzel**, nicht unter dem Projektpraefix: er
gilt fuer die Domain, nicht fuer ein Projekt.

**Es wird nie geloescht und nie synchronisiert.** Alte by-hash-Dateien muessen
mindestens eine Release-Generation liegen bleiben, damit ein laufendes
`apt update` nicht ins Leere greift; ein `sync --delete` entfernte genau die.

**Keine Cache-Header auf den Objekten.** Die kommen aus den Cache Rules der
Zone; eine zweite Quelle der Wahrheit waere eine zu viel.

`publication_plan.py` berechnet den Plan und ist davon getrennt, weil die
Reihenfolge und die Zuordnung von Pfad zu Objektschluessel reine Rechnung ist
und ohne Zugangsdaten pruefbar bleibt.

## Nachkontrolle

```
scripts/verify-publication.sh --manifest <manifest> --project <name> \
  --archive-dir <lokale wurzel> [--base-url <uebersteuerung>]
```

Geprueft wird, was ein Client bekommt, nicht was hochgeladen wurde: Keyring
laden, `InRelease` damit gegen `gpgv` halten, byteweise gegen die lokale Fassung
vergleichen, je Architektur `Packages.gz` gegen die Summe aus `InRelease`
pruefen, denselben Index unter seinem `by-hash/SHA512`-Pfad laden und
vergleichen, und schliesslich den ersten `Filename`-Eintrag aufloesen und das
Paket byteweise vergleichen.

## Tests

```
bash tests/test_render_archive.sh
```

```
bash tests/test_signing.sh
bash tests/test_publication.sh
```

Dreiundsiebzig Zusicherungen, kein Netz nach draussen, kein echtes
Schluesselmaterial, kein `dpkg`. `tests/make_deb.py` baut echte `.deb`-Dateien
mit den Bordmitteln von Python, so dass die Tests gegen Paketbytes laufen statt
gegen eine Attrappe. Die Signaturtests erzeugen einen Wegwerfschluessel in der
vorgeschriebenen Form, und die Nachkontrolle laeuft gegen einen lokalen Server,
der den Baum so ausliefert wie der Bucket.

**Was nicht getestet ist:** `publish-archive.sh` selbst. Der Upload braucht
R2-Zugangsdaten, die es nur als GitHub-Secret gibt. Geprueft sind seine Syntax,
shellcheck und der Plan, den er ausfuehrt; die Ausfuehrung ist es nicht.
