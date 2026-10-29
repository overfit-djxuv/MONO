# MONO

A minimalist, fully offline personal-finance app for iPhone. Native Swift / SwiftUI / SwiftData / Swift Charts.
No account, no backend, no bank connection, no analytics, no network code.

## Build and run

Requirements: Xcode 26+ (built and tested with Xcode 27.1), iOS 17+ device or simulator.

```sh
tools/generate.sh             # creates MONO.xcodeproj (needs XcodeGen: brew install xcodegen)
open MONO.xcodeproj
```

Regenerate the project after editing `project.yml`: `tools/generate.sh`.

Simulator: pick an iPhone in the toolbar and press **Run** (⌘R).
Tests: **Product ▸ Test** (⌘U), or

```sh
xcodebuild -project MONO.xcodeproj -scheme MONO -destination 'platform=iOS Simulator,name=iPhone 17' test
```

If `xcodebuild` says it needs Xcode, point it at the app once: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

## Install on your iPhone

1. **Apple ID in Xcode.** Xcode ▸ Settings ▸ Accounts ▸ **+** ▸ Apple ID. A free Apple ID works.
2. **Signing.** Select the project ▸ target **MONO** ▸ *Signing & Capabilities*. Tick *Automatically manage signing* and choose your **Team**.
   Your team and bundle id come from `tools/local.env` (copy `tools/local.env.example`), then run `tools/generate.sh`. The bundle id (`<BUNDLE_ID_PREFIX>.monoapp`) must be unique to you; free accounts reject IDs already used by anyone else.
3. **Connect the phone** with a cable, unlock it, tap **Trust This Computer**. It should appear in Xcode's device menu (first time Xcode indexes it can take a minute).
4. **Developer Mode** (iOS 16 and later, required once). On the iPhone: Settings ▸ Privacy & Security ▸ **Developer Mode** ▸ On, then restart and confirm. The switch only appears after Xcode has tried to install something on the device.
5. **Run.** Choose your iPhone as the destination and press ⌘R.
6. **Trust the developer profile.** The first launch is blocked with "Untrusted Developer". On the iPhone open Settings ▸ General ▸ **VPN & Device Management** (the menu name can vary slightly between iOS versions) ▸ your Apple ID ▸ **Trust**. Then open MONO.

Command-line alternative once signing works:

```sh
xcodebuild -project MONO.xcodeproj -scheme MONO -configuration Release \
  -destination 'id=<YOUR-DEVICE-UDID>' -allowProvisioningUpdates DEVELOPMENT_TEAM=<TEAM-ID> build
xcrun devicectl device install app --device <YOUR-DEVICE-UDID> \
  "$(xcodebuild -project MONO.xcodeproj -scheme MONO -configuration Release -destination 'id=<YOUR-DEVICE-UDID>' -showBuildSettings | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/MONO.app"
```

### Free account vs paid, and what "installed" means here

| | Free Apple ID | Apple Developer Program (paid) |
|---|---|---|
| Install on your own iPhone from Xcode | Yes | Yes |
| Profile lifetime | **7 days**, then the app stops opening until you re-run from Xcode | 1 year |
| Apps you can have installed this way | Small limit (3 at a time) | Higher |
| Your data when the profile expires | Kept as long as you don't delete the app. Re-running from Xcode re-signs it | Same |
| TestFlight / App Store distribution | **No** | Yes |

This is *local development installation*. It is not App Store distribution: nobody else can install it, and it needs the re-signing step above (weekly on a free account). App Store release needs the paid program, an App Store Connect record, a 1024px icon without transparency, and a privacy-policy URL.

**Back up before you delete the app or reinstall after expiry**: Settings ▸ Create JSON backup. Deleting the app deletes its data.

## Project structure

```
project.yml                    XcodeGen spec (targets, deployment target, Info.plist keys)
MONO/
  App/        MONOApp (entry, store-failure screen), RootView (5 tabs, privacy cover)
  Domain/     Pure logic, no UI/persistence: Money, MonthKey, FinanceEngine, SavingsPlanner
  Models/     SwiftData models + default categories
  Services/   Persistence, Ledger (multi-record rules), BackupService (JSON/CSV), DemoData (DEBUG only)
  Design/     Theme (palette, motion), Components, Charts
  Features/   Overview · Transactions · Budget · Shopping · Goals · Analytics · Settings
  Assets.xcassets
MONOTests/    67 unit tests: money, engine, planner, ledger rules, backup validation
MONOUITests/  3 UI tests: add/persist/restart, delete confirmation, goal money ≠ expense
tools/make_icon.swift          generates the app icon
```

## How the numbers work

- Amounts are **integer cents** (RM default; the symbol can be changed in Settings).
- **Available cash** = opening balance + income − expenses − money moved into goals (+ money withdrawn back).
- Goal movements are separate records, never transactions, so allocating to a goal cannot be counted as income or expense, and cash + saved is conserved.
- "Already saved" money you enter when creating a goal is flagged *not from cash*: it counts toward the goal without reducing cash.
- Budget: spent, remaining, % used, over-by, and a daily allowance = remaining ÷ days left in the month (today included). Warning at 80%, over when spent exceeds the limit.
- Goal plans: contributions are scheduled on a chosen day each month, **strictly after today** up to the deadline. Required monthly = ceil(remaining ÷ contributions left). Status: funded / on track / behind / overdue / no deadline.
- Shopping: each item can be recorded as an expense **once** (guarded by a link on the item and a source id on the transaction). Deleting that expense unlinks it so it can be recorded again deliberately.
- Analytics only uses recorded data and starts at the first record; nothing earlier is estimated.

## Privacy

Data lives in an on-device SwiftData store with iOS file protection (`completeUntilFirstUserAuthentication`). The app has no network code and requests no permissions. The app-switcher snapshot is covered so balances aren't visible. Note: like all app data, it is included in your iPhone's own iCloud/computer backups if you have those switched on.

## Debug-only launch arguments (compiled out of Release)

`-MONODemo` sample data · `-MONOReset <token>` wipe once per token · `-MONOTab 0…4` · `-MONOScreen analytics|settings`.
