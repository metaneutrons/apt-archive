# Sicherheit

Schwachstellen bitte über Private Vulnerability Reporting melden, nicht als
Issue. Reaktion innerhalb von sieben Tagen.

Dieses Repository erzeugt und signiert Paketarchive. Besonders relevant sind
Befunde, die eine Veröffentlichung unter falscher Identität, eine Umgehung der
Signaturprüfung oder ein Zurückrollen auf einen älteren Archivzustand
ermöglichen.

Geheimes Schlüsselmaterial liegt nicht in diesem Repository. Der
Certify-only-Primärschlüssel bleibt offline im Tresor. Die geschützten
GitHub-Environments enthalten je Domain nur ein passphrasengeschütztes
Secret-Subkey-Bundle; der Workflow lehnt einen enthaltenen geheimen
Primärschlüssel sowie fehlende oder zusätzliche Signing-Subkeys ab.
