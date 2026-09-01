# Mitarbeit

## Commits

Conventional Commits, ausnahmslos. Erlaubte Typen: `feat`, `fix`, `docs`,
`style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.
Breaking Change über `!` hinter dem Typ und `BREAKING CHANGE:` im Body.

Der **PR-Titel** ist die kritische Stelle: bei Squash-Merge wird er zur
Betreffzeile auf `main` und bestimmt die nächste Version.

Kein KI-Attributions-Trailer in Commits, PR-Bodys oder Autorenfeldern.

## Hooks

`lefthook` mit den Skripten unter `scripts/hooks/`:

```bash
brew install lefthook && lefthook install
```

## Vor jeder Änderung an der Veröffentlichung

Dieses Repository erzeugt signierte Paketarchive. Zwei Regeln gelten ohne
Ausnahme.

Keine Fehlerunterdrückung auf einem Pfad, der veröffentlicht. Kein `|| true`,
kein `continue-on-error`, keine Warnung statt eines Abbruchs.

Nach jeder Veröffentlichung wird gegen die **öffentliche** URL verifiziert,
dass das abrufbare Artefakt byteweise dem entspricht, was gebaut wurde.

## Actions

Ausschließlich per Commit-SHA gepinnt, mit Versionskommentar dahinter. Niemals
`@v4` oder `@main`. Achtung: manche Tags sind annotierte Tag-Objekte; deren SHA
ist ebenfalls unveränderlich, aber `gh api repos/X/git/commits/<sha>` findet ihn
nicht. Das ist kein Fehler.
