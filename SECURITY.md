# Security and privacy

This is a community beta. Report security concerns without including credentials, sign-in snapshots, account identifiers or unredacted logs. Public issues are suitable for a redacted description only; arrange a private disclosure channel before sharing sensitive material.

No telemetry or external identity upload is implemented. Follow the compatibility and storage restrictions in README.md. Review executable paths before installing. A manifest validation result does not establish the security or support status of the host's private APIs.

Saved tokens use Windows DPAPI CurrentUser; email and labels remain plaintext local metadata. Malware running as the same Windows user can access that user’s credential material. Keep the entire sidecar data directory private. Real cross-account switching remains unverified in this release.
