# Accounts

An account is optional. Without one, everything stays on the phone, as it did before accounts existed. Signing in is needed only for the community catalog and for the account-backed features that come later.

## Signing in

- Sign in with Apple, or an email address and a six-digit code. The code is emailed to the address; there is no password.
- The session is kept in the Keychain on this phone. It is readable only after the first unlock and is never copied to another device or a backup.
- The first sign-in on a phone shows a sharing disclosure once. It says what is shared before the sharing switch is left on.

The Account section appears only in a build that carries the project settings (see [the community client](community-client.md) and the [iOS app README](../ios/HealthNutrition/README.md)). A local, unsigned or CI build has no account section and makes no account call.

## What is shared

- The sharing switch in Settings, Account, is on by default. It controls whether the labels you scan are shared with the community catalog. Turning it off stops new labels from being shared.
- A shared label has its product name, brand, barcode, serving text and nutrient amounts. Photos, what you eat and when are never shared.
- A label is shown to others once at least two people agree on it, and gets a verified badge once more people agree.
- The name you enter is shown with the labels you share. It is at most 60 characters. Leave it empty to share without a name.

The catalog integration that sends labels arrives in a later change. Until then the switch only records your choice.

## What stays on this device

Signing in does not upload your journal, goals, recipes, favorites, reminders or exports. They stay on the phone. A backup of the journal through your own iCloud is planned and is not part of this change, so the Account footer's mention of iCloud describes a feature that is not built yet.

## Sign out and delete

- **Sign out** asks the server to end the session and forgets it on this phone. Local data stays on the phone.
- **Delete account** removes the account and every label it shared from the server. Data on this phone is kept.
- **Erase all data** in Settings removes the journal and the settings on this phone. It does not sign out and does not delete the account. Sign out first if you also want the session removed from this phone.
