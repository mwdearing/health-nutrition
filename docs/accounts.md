# Accounts

An account is optional. It is used for the community catalog and its account features. Signing in does not move or partition the journal on this device.

## Signing in

- Sign in with Apple, or request a one-time code by email. The code is emailed to the address; there is no password.
- The session is kept in the Keychain on this phone. It is readable only after the first unlock and is not copied by this app to another device.
- The first sign-in of each account on a phone shows a sharing disclosure before the sharing switch can authorize submissions. Acknowledgment is stored separately for each account on this device.
- The Account section appears only in a build that carries the project settings (see [the community client](community-client.md) and the [iOS app README](../ios/HealthNutrition/README.md)). A local, unsigned or CI build with no account service makes no account calls.

Requesting an email sign-in code may first show an hCaptcha human check. Its embedded browser challenge can process browser/device signals and sends a verification result with the sign-in request. The app does not send the journal or label facts to hCaptcha. Sign in with Apple does not show this email-code check.

## What the account sends

Signing in sends the account email address and identifier to the project server. The optional display name is saved to the account profile. These account details are separate from the local journal.

## Barcode lookup

Open Food Facts is asked first when you submit the barcode field, tap Look up, or accept a barcode from the camera scanner. The camera scan sends nothing while the camera is open; after a code is accepted, it starts the lookup. If Open Food Facts has no product and you are signed in, the app also asks the authenticated community catalog. Turning Share labels off does not disable this read lookup. A signed-out person does not get the community fallback.

## Sharing a saved label

The switch in Settings > Account controls new community submissions. Turning it off stops new labels from being submitted; it does not erase older submissions. The app submits a qualifying label only when the person is signed in, has acknowledged the disclosure for that account, and sharing is on at save time.

What is sent: product name, brand, barcode, serving text and nutrient amounts. The amount eaten, time, meal, notes, entry identifier, account identifier and photo are not part of the label submission. A product label can be derived from a community aggregate. Community agreement does not verify a label, regardless of how many accounts agree. Only a label with an explicit owner-reviewed source is attributed exactly as **“Reviewed by the catalog owner.”** That is a statement about review source, not nutrition or medical accuracy.

An owner-reviewed label is a separate product-catalog snapshot, not a contributor-owned journal record. Withdrawing submissions or deleting the contributor's account removes that account's submissions and profile, but an approved catalog snapshot can remain without contributor identity. The community account and submission data are not removed by **Erase all data**; use account controls to delete the server account.

## What stays on this device

Entries, product snapshots, goals, recipes, favorites, reminders, HealthKit and relay settings, and export files stay on this device. Signing into another account does not partition, merge or replace them. They remain available after sign-out or account deletion. Your device backup may also include its local app data, depending on your backup settings.

## Sign out, delete and erase

- **Sign out** asks the server to end the session and clears the session stored on this phone. Local journal data stays on the phone.
- **Delete account** removes the server account, its profile and its submissions. An independently approved owner-reviewed catalog snapshot may remain without contributor identity. Local journal data and other device settings are kept.
- **Erase all data** removes local journal rows, favorites, recipes, goals, display preferences, reminders, the session in this phone's Keychain and export files the app can still reach. It does not call server sign-out, delete the account or retract shared submissions. Copies already shared outside the app remain with those destinations. Row deletion is not a promise of forensic erasure.
