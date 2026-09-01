# apt-archive

Erzeugt und signiert die APT-Archive unter `deb.metaneutrons.cc` und
`deb.snapdog.cc`. Ein Repository für alle Archiv-Domains, ein Verzeichnis je
Domain unter `domains/`.

## Warum zentral

Ein R2-API-Token lässt sich auf Buckets beschränken, nicht auf Präfixe.
Bekäme jedes Projekt einen Schreibzugang, hätte jedes Projekt Schreibzugang auf
das gesamte Archiv. Deshalb laden Projekt-Repositories gar nicht hoch: sie
hängen ihre `.deb` mit Attestation an ihr GitHub-Release, und dieses Repository
holt sie, prüft die Attestation, rendert die Metadaten und veröffentlicht.

## Was hier nicht liegt

Kein Schlüsselmaterial. Der Certify-only-Primärschlüssel ist offline, die
Signing-Subkeys liegen auf einem Hardware-Token. Die Pipeline rendert die
Metadaten und lädt sie als Artefakt hoch; signiert wird lokal, danach
verifiziert und veröffentlicht die Pipeline.

## Aufbau

```
domains/
  metaneutrons.cc/manifest.toml   Projekte, Bucket, Subkey, Basis-URL
  snapdog.cc/manifest.toml
```

Der Renderer und die Workflows sind gemeinsam und lesen das Manifest. Tritt
einer der Abspaltungs-Trigger ein, wandert ein Verzeichnis in ein neues
Repository, ohne dass Code mitwandert.

## Festlegungen

Layout ist ein Archiv je Projekt unter einem eigenen Präfix, nicht ein
gemeinsames `dists/` mit Komponenten. Ein gemeinsames Archiv hätte eine
gemeinsame `Valid-Until`-Uhr, und ein vernachlässigtes Projekt risse alle
übrigen mit.

`Suite` und `Codename` lauten `rolling`. `stable` ist in der Debian-Welt ein
Fachbegriff für das aktuelle Debian-Release und für ein fortlaufendes
Eigenarchiv irreführend. Ab der ersten veröffentlichten Stanza ist das
eingefroren.

`Acquire-By-Hash` ist verpflichtend. Damit holt `apt` die Indexdateien unter
ihrer Prüfsumme, und ein zwischengespeicherter alter Index kann nicht mehr
gegen ein neues `InRelease` laufen.

`Valid-Until` steht auf 180 Tagen und wird bei jedem Release neu gesetzt. Kein
Cron: GitHub deaktiviert geplante Workflows in öffentlichen Repositories nach
60 Tagen ohne Commit, und nur Commits zählen als Aktivität.

## Einbinden

```
# /etc/apt/sources.list.d/metaneutrons.sources
Types: deb
URIs: https://deb.metaneutrons.cc/<projekt>
Suites: rolling
Components: main
Signed-By: /usr/share/keyrings/metaneutrons-archive-keyring.pgp
```

Ein Keyring-Paket je Domain. Beide Subkey-Fingerprints sind zusammen mit dem
Primärfingerprint veröffentlicht, weil `gpgv` und `sqv` im Fehlerfall den
signierenden Subkey melden und nicht den Primärschlüssel.

## Stand

Im Aufbau. Nichts ist veröffentlicht, die Schlüssel sind noch nicht erzeugt.
