# Coremeleon

SwiftUI app that imports any Core ML model (.mlmodel / .mlpackage / .mlmodelc), builds an input form from the
model's own description (image, text, number inputs), runs it, and shows outputs. You can switch compute units
(Neural Engine / GPU / CPU) and see load + inference time.

## Build from Ubuntu (no Mac needed)
1. Create a GitHub repo and push this folder:
   `git init && git add -A && git commit -m init && git branch -M main`
   `git remote add origin <your-repo-url> && git push -u origin main`
2. GitHub > Actions > "Build IPA" runs on a free macOS runner. When it's green, download the
   `Coremeleon-ipa` artifact and unzip it to get `Coremeleon.ipa`.
   (If the build fails, open the log and send me the error.)

## Install on the iPhone 16 Pro from Ubuntu
- iPhone: Settings > Privacy & Security > Developer Mode > On (restarts the phone).
- Use a Linux sideloader such as Dadoum's Sideloader or iloader (both support Linux). Plug in via USB, sign in
  with an Apple ID (a spare one is recommended), and install the .ipa.
- Free Apple ID: the app expires after 7 days (re-install to refresh), max 3 sideloaded apps.
  A paid $99/yr Apple Developer account removes that and enables TestFlight.
- First launch: Settings > General > VPN & Device Management > trust your Apple ID.

## Getting models onto the phone
Copy a .mlpackage to iCloud Drive/Files (or AirDrop it), then tap + in the app. Models are compiled on-device.
