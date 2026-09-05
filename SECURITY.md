# Security

Please report vulnerabilities through Private Vulnerability Reporting, not as an
issue. A response follows within seven days.

This repository produces and signs package archives. Findings that allow a
publication under a false identity, a bypass of the signature check or a
rollback to an older archive state are of particular interest.

No secret key material lives in this repository. The certify-only primary key
stays offline in the vault. Per domain, the protected GitHub environments hold
nothing but a passphrase-protected secret subkey bundle; the workflow rejects a
secret primary key contained in it as well as missing or additional signing
subkeys.
