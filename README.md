# Account Switcher

Save Windows sign-in profiles and switch from a vertical list. Antigravity automatically closes and reopens after you confirm the switch.

By [Nikolos89](https://github.com/nikolos89). Independent community project; not affiliated with or endorsed by Google.

## What it does

- Shows the currently signed-in account with an **Active** badge. Other saved profiles have a **Switch account** button.
- Saves the current sign-in under an optional Personal, Work or custom label.
- Lists the saved profiles together, with their names and account emails.
- Asks before restarting Antigravity and checks that the desktop window and selected sign-in have returned.
- Encrypts saved sign-in material with Windows DPAPI for the current Windows user.
- Opens the add-account instructions directly when launched from the companion menu.

## Better together

Install [Profile Sidebar](https://github.com/nikolos89/profile-sidebar) to see your active account and subscription plan below Settings. Its menu opens Account Switcher for **Switch account** or **Add account** when this module is enabled and its panel is ready.

Account Switcher also works independently. Profile Sidebar's footer integration is experimental and has additional compatibility requirements; installing that companion does not enable switching without Account Switcher.

## Compatibility and beta status

This is **1.1.0-beta.2**, for Windows 10/11 and the **main Antigravity App**. Native integration was developed on App **2.34.0**. Node.js 22+ and PowerShell 7+ must be available. The sidecar loads the SDK provided by Antigravity.

Checks cover panel authentication, input validation, protected storage with synthetic credentials, and rejection of a restart that exits without opening a window. A complete switch between two real accounts remains unverified in this public build.

## Install

Download and extract the [Account Switcher release ZIP](https://github.com/nikolos89/account-switcher/releases/tag/v1.1.0-beta.2). From the extracted plugin folder, use the official Antigravity CLI:

~~~powershell
agy plugin validate --strict .
agy plugin install .
~~~

Enable Account Switcher and its sidecar in Antigravity Customizations if prompted. Open the Account Switcher auxiliary panel. Do not install two copies of the same plugin ID.

For an existing installation, uninstall the old package in Customizations before installing this build. Retain its separate sidecar data directory to keep saved profiles and settings.

Prerequisites: [Antigravity CLI](https://antigravity.google/docs/getting-started?tab=cli), [PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows), and [Node.js](https://nodejs.org/en/download).

Standard Antigravity App and PowerShell locations are discovered automatically, including PowerShell installed as a .NET global tool. For a nonstandard location, create **settings.json in this sidecar's data directory**:

~~~json
{
  "appExe": "D:\\Apps\\Antigravity\\Antigravity.exe",
  "pwsh": "D:\\Tools\\PowerShell\\pwsh.exe"
}
~~~

Use absolute paths to trusted executables. Do not put settings or saved profiles inside the plugin folder: plugin updates replace that folder.

## Save, add and switch

1. Sign in normally through Google in Antigravity, open the panel, and click **Save current account**.
2. To add another account, first save the current one, then use Antigravity's native sign-out and Google sign-in. Return to the panel and save that account too.
3. Find the profile in the list, click **Switch account**, save your work, then confirm the restart.
4. After reopening, check the current email in Antigravity settings. Expired, revoked or otherwise unusable sessions can require normal Google sign-in again.

Adding an account uses the normal Google sign-in flow. Antigravity continues to enforce the signed-in account's subscription and quota.

## Storage and privacy

Persistent data lives under **~/.gemini/antigravity/sidecar_data/account-switcher/accounts/data**. Encrypted credential snapshots are tied to the Windows user and machine; they are not portable login backups. Email addresses, display names and labels are local plaintext metadata protected by the directory's access controls. Treat the entire data directory as private.

The panel receives account metadata, not access or refresh tokens. Its local API uses the host's sidecar token, binds through the host SDK on loopback, and does not expose credential files as static assets. There is no analytics, external credential upload, scheduled task or permanent restart watchdog in this plugin.

The enabled plugin has one host-managed sidecar process. An explicitly confirmed restart starts a bounded one-shot worker so it can finish after the app closes. It requests a normal window close, tracks the app PID and start time, never force-kills the app, and attempts to restore the previous sign-in if relaunch fails. A verified encrypted rollback snapshot is retained locally.

## Disable or remove

Disable or uninstall Account Switcher through Antigravity Customizations. This leaves the current native sign-in and saved private data in place. To forget saved profiles, first disable the plugin, then remove its **data directory** using your file manager. Removing the public plugin package alone does not revoke Google sessions; use the Google account security page for revocation.

## Support and development

Report reproducible problems through [GitHub Issues](https://github.com/nikolos89/account-switcher/issues). Include Windows, Antigravity, Node.js and PowerShell versions. Never attach credentials, profiles.json, encrypted snapshots or unredacted logs.

Run the official validator before a release: **agy plugin validate --strict .** See [CHANGELOG](CHANGELOG.md) and [SECURITY](SECURITY.md). Licensed under [MIT](LICENSE).
