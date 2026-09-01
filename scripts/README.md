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

## Tests

```
bash tests/test_render_archive.sh
```

Sechsundzwanzig Zusicherungen, kein Netz, kein Schluessel, kein `dpkg`.
`tests/make_deb.py` baut echte `.deb`-Dateien mit den Bordmitteln von Python, so
dass die Tests gegen Paketbytes laufen statt gegen eine Attrappe.
