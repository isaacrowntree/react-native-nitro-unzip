# Security Policy

## Supported versions

Fixes land on the latest minor release. Older minors are not backported.

| Version | Supported |
| ------- | --------- |
| 0.5.x   | ✅        |
| < 0.5   | ❌        |

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

Report it privately through GitHub's
[private vulnerability reporting](https://github.com/isaacrowntree/react-native-nitro-unzip/security/advisories/new)
form. Expect an acknowledgement within 5 working days and, for a confirmed
issue, a fix or mitigation plan within 30 days.

Please include the archive (or a minimal reproduction of it), the platform and
OS version, and the library version.

## Threat model

This library extracts untrusted archives, so the following are treated as
security bugs rather than ordinary defects:

- **Zip Slip / path traversal** — any entry that writes outside the caller's
  destination directory, whether via `../` segments, absolute paths, symlink
  ancestors, or Unicode/normalisation tricks. Every entry path is validated
  *before* any byte is written (`ExtractionScope` on iOS, the path checks in
  `HybridUnzipTask` on Android).
- **Symlink escapes** — a symlink entry resolving outside the destination, or a
  later entry writing *through* an earlier symlinked directory.
- **Partial-extraction leakage** — a cancelled or failed extraction leaving
  attacker-controlled files behind (`PartialExtractionRollback`).
- **Zip bombs** — uncontrolled decompression leading to disk or memory
  exhaustion.

Out of scope: archives the *application itself* trusts and constructs, and
vulnerabilities in a consuming app's handling of the extracted files.
