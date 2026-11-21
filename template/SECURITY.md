# Security

## Reporting a vulnerability

Report it privately through this repository's
[private vulnerability reporting](https://github.com/shuwariafrica/<project>/security/advisories/new).
Please do not open a public issue for it.

## Verifying a release

Every release of <project> is built, signed and published by this repository's release workflow,
from a tag the owner signed, and recorded with its signed checksums and attestations in its
[releases](https://github.com/shuwariafrica/<project>/releases). Its signing key is
<project>'s own, whose fingerprint is

```
<SIGNING KEY FINGERPRINT>
```

Fetch the crate, with `<version>` here and below the version you are verifying:

```
curl -fsSLo <crate>-<version>.crate https://static.crates.io/crates/<crate>/<crate>-<version>.crate
```

With a GitHub login, this prints the attested repository, tag and commit, and prints nothing
unless the attestation is of this tag:

```
gh attestation verify <crate>-<version>.crate \
  --repo shuwariafrica/<project> \
  --signer-workflow shuwariafrica/<project>/.github/workflows/release.yml \
  --source-ref refs/tags/v<version> \
  --predicate-type https://shuwari.africa/attestations/crate-release/v1 \
  --format json \
  --jq '.[].verificationResult.statement.predicate | select(.tag == "v<version>") | "\(.repository) \(.tag) \(.commit)"'
```

Without one, check the release's signed checksums against the signing key's certificate as
keys.openpgp.org publishes it, so a published revocation makes `sqv` refuse:

```
base=https://github.com/shuwariafrica/<project>/releases/download/v<version>
curl -fsSLO "$base/SHA256SUMS" -fsSLO "$base/SHA256SUMS.asc" \
  -fsSLo signing.asc https://keys.openpgp.org/vks/v1/by-fingerprint/<SIGNING KEY FINGERPRINT>
gpg --show-keys --with-fingerprint signing.asc   # compare with the fingerprint above
sqv --keyring signing.asc SHA256SUMS.asc SHA256SUMS && sha256sum -c --ignore-missing SHA256SUMS
```

The `.crate` crates.io serves has the index's checksum, which `SHA256SUMS` lists.
