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

Ein Bucket je Archiv-Domain, benannt nach ihr, und die Custom Domain hängt
genau daran. Zwei Hostnamen auf denselben Objekten wären für `apt` zwei
Repositories mit gleichem Inhalt, und ein Token für einen gemeinsamen Bucket
wäre ein Token für beide Domains.

Damit die Beschränkung auf einen Bucket wirkt, muss das Tokenpaar in einer
Environment auch genau auf diesen einen Bucket ausgestellt sein. Ein
kontoweites Paar erfüllt die Signatur der Prüfung und nicht ihren Zweck.

## Was hier nicht liegt

Der Certify-only-Primärschlüssel. Er wird offline erzeugt und bleibt es; sein
geheimer Teil verlässt den Tresor nie. In CI liegt ausschließlich ein Export
der Signing-Subkeys, je Domain in einer eigenen Environment als
`APT_GPG_PRIVATE_KEY`.

Dass es wirklich nur die Subkeys sind, prüft `verify-signing-bundle.sh` am
importierten Material und nicht am Armor: im `sec`-Datensatz von
`--with-colons` muss Feld 15 ein `#` tragen, das Kennzeichen für einen
Primärschlüssel ohne geheimen Teil. Fehlt das `#`, bricht die Signatur ab,
bevor sie beginnt. Von außen ist einem Schlüsselblock nicht anzusehen, was er
enthält, deshalb ist diese Prüfung kein Zusatz, sondern die Bedingung.

Signiert wird mit dem Domain-Subkey, gepinnt per abschließendem
Ausrufezeichen; ohne das Pinning wählt gpg selbst, und die Wahl steht dann
nicht im Manifest.

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

`Date` und `Valid-Until` werden bei jeder Veröffentlichung einschließlich einer
Neusignatur aus einer unmittelbar zuvor intern erzeugten Publikationszeit neu
gesetzt; `Valid-Until` liegt exakt 180 Tage danach. Kein Cron: GitHub deaktiviert
geplante Workflows in öffentlichen Repositories nach 60 Tagen ohne Commit, und
nur Commits zählen als Aktivität.

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

Die binäre OpenPGP-Keyring-Datei wird im Archiv und durch das Keyring-Paket
unter demselben `.pgp`-Namen geführt. `Signed-By` verweist damit ohne
Umbenennung genau auf die vom Paket installierte Datei.

Die `packages`-Liste eines Projekts ist vollständig: Jeder genannte Paketname
muss in den betrachteten stabilen Releases mindestens einmal als passendes
`.deb` vorkommen. Optionale Pakete werden nicht stillschweigend angenommen;
falls sie später gebraucht werden, erhalten sie ein eigenes Manifestfeld.

## Stand

Nichts ist veröffentlicht. Die Kette steht vollständig, ist mit Buckets,
Schlüsselmaterial und getrennten Domain-Credentials ausgestattet und durch die
Vertragssuiten abgedeckt. `deb.metaneutrons.cc` liegt auf
`deb-metaneutrons-cc`, `deb.snapdog.cc` auf `deb-snapdog-cc`; beide Manifeste
tragen die geprüften öffentlichen Fingerprints. Die geschützten Environments
`release-metaneutrons.cc` und `release-snapdog.cc` enthalten jeweils die vier
vom Workflow benötigten Secrets. Der geheime Primärschlüssel bleibt im Tresor
und ist in keinem CI-Bundle enthalten.

Für die erste Veröffentlichung fehlen noch Voraussetzungen in den
Quellprojekten. Stand 2. September 2026:

| Projekt | Releases | `.deb` im Release | Attestierung |
| --- | --- | --- | --- |
| `aros-tools` | keine | — | `release.yml` attestiert |
| `devserial-mcp` | 4 | keine | nein |
| `ugos-cli` | 14 | keine | nein |
| `snapdog` | 30 | vier, passend | nein |

`devserial-mcp` und `ugos-cli` liefern nur Tarballs und Zips; für sie gibt es
nichts zu holen, bis ihre Release-Workflows Debian-Pakete bauen. `snapdog`
liefert genau die erwarteten vier Pakete, aber ohne Provenance: die
Attestierungs-API antwortet für den SHA256 von `snapdog_0.27.1-1_amd64.deb`
mit 404. `fetch-packages.sh` bricht darauf ab und warnt nicht, und das ist
Absicht: ein Asset beweist nur, dass ein Konto es hochladen durfte, eine
Attestierung bindet es an eine Workflow-Identität.

## Lizenz

Copyright © 2026 Fabian Schmieder.

Dieses Repository steht unter der GNU General Public License Version 3; siehe
[`LICENSE`](LICENSE).
