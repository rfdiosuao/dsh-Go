# Pets

Pick a pet to keep you company in chats. When a turn finishes, fails, or waits for your approval or answer, it pops up a bubble.

## Choose a pet

<!-- nav: commonSettings,botsPets -->
`Settings › Pets` · [Open](dshgo://open/pets)

Tap **Pets** in the Appearance group of Settings, or touch and hold the pet in a chat and choose **Pet settings**. Choose a pet first; the other settings appear below it.

- Choose **Deepy**, **Whale girl** or **None**.
- **Size**: **Small**, **Standard** or **Large**. Standard by default.
- **Quiet mode**: animations only, no bubbles.

On HarmonyOS the pet stays in the app: it can't show outside the app, and there's no floating pet to ask or to answer in.

## In chats

- The pet sits above the composer; drag it left or right to move it.
- Tap a bubble to jump to its chat; swipe up to dismiss it.
- Touch and hold the pet for **Change pet**, **Hide for 1 hour** and **Pet settings**. While it's hidden, **Show now** appears on the pet page.

## Companion room

The companion room is a separate full page with an animated Live2D character. It isn't the status pet above: the pet watches the agent for you, and the room is a place to spend a little time.

Open the **Switch host** panel and tap **Companion room**. The first time, import an asset pack (zip). Character assets aren't part of the app and stay on this phone; you can remove them from the menu at the top right of the room.

On HarmonyOS she stays on this page: she can't live in a floating window, and there's no home-screen widget.

What you can do:

- Touch her: stroke her head to pat it, and tap her face, body or tail for different reactions. Three quick pokes make her dizzy. None of this calls a model or spends tokens.
- Move the phone: tilt it to one side and she drifts that way with the water, tips over a little, then finds her balance. Shake it hard a few times and she gets dizzy and lets out a stream of bubbles. None of this happens when the phone has reduced motion turned on, and shaking does nothing on phones without a motion sensor.
- Talk to her: type or use voice in the bar at the bottom. Choose how in **How she talks** in the menu at the top right:
  - **Light**: chat only. The phone uses the DeepSeek API key you saved in Settings to talk to the model directly, with no engine and no host. The chat stays on this phone, and **Start over** deletes it. Not available when you signed in with a DeepSeek account and saved no key.
  - **Full**: uses DSH on the current host, in its own conversation that stays out of the chat list. **View chat history** in the menu opens it, and **Start over** begins a new conversation while the old record stays on the host. She can use the host's tools; anything that acts asks you first.
  - Until you choose, she uses Full while a host is connected and Light otherwise.
- Zoom: pinch to zoom and move.
- Her corner: there's a snack in the shell at the bottom left, a bubble floating on the right, and a seaweed cushion behind her. Tap the shell to give her a snack, the bubble to play, and the cushion to let her rest for a while. What she's doing shows under her name.
- Feed her, hold her: drag a snack out of the shell dish and let go at her mouth, and she eats it. Rest a finger on her to give her a hug. Tilt the phone and the reef shifts a little.
- Her voice: HarmonyOS can't give her a voice yet. **Her voice** in the menu has no effect on this phone, for the phone's own voice and for external speech services alike.
- About her: under **About her** in the menu, change her name, what she calls you, and her persona: who she is, her personality, how she talks, all of it, with **Reset** to start over. The default persona includes a few boundaries you can delete; only the format of her expression marks is added by the app.
- Getting closer: visit and pat her often and she slowly gets more familiar with you; **You two** in the menu shows how far you've come. Once you're close she hums more and has fonder words for a pat.
- Your other chats: while the room is open, she tells you when another chat finishes, fails or waits for your approval; tap Take a look to go there.
- Her invitations: when you sit quietly with her for a while, she may now and then ask, above the input bar, whether you'd like to rest on the cushion together. Tap **Sure** and she leans back on it; tap **Not now** or just leave it, and she waits a while before asking again. She asks silently. Choose how often in **How often she speaks up** in the menu at the top right: **Now and then** by default (at most twice a day, at least 6 hours apart), **Often** or **Chatty** for more, **Quiet** for none. Mentions of your other chats count toward the same allowance.

She notices that you visit and pat her, and slowly gets more familiar with you; staying away for a few days doesn't upset her. Write down things you want her to remember in **What she remembers** in the menu. You can edit or delete them anytime. In Full mode they stay on the current host; in Light mode, on this phone. She doesn't bring these up by herself yet, can't speak aloud and only shows text, and can't touch your files or phone.

If this host's engine is older, she runs on the default preset and may ask to use tools. When "Something needs your confirmation" appears, tap it and handle the request in the regular chat.

## Workshop

The Workshop holds pixel pets and companions other people made. Pick the ones you like and install them on this phone, or send in your own. There are two ways in: the **Workshop** row on the pet settings page, and **Workshop** in the menu at the top right of the companion room. If the row isn't there, this version isn't connected to a workshop yet.

The page has three tabs:

- **Browse**: look around, search, and filter by **Pixel pets** or **Companions**. Tap an item for its description, author, license and size, and tap **Get** to download and install it. A pet is added to the pets you can choose, and a companion becomes the character in the room; you're asked first when something already on this phone would be overwritten. Browsing and installing need no sign-in.
- **Installed**: what came from the Workshop onto this phone. A new version, or an item withdrawn by its author or a reviewer, is marked here; open an item to update or uninstall it. This tab works offline.
- **My uploads**: what you sent in and where each one stands in review. Sign in to your forum account first.

To submit: tap **Submit** under **My uploads**, pick a pet you imported or your current companion, fill in the name, author, license and source link, check the packed result, tick **I confirm I have the right to share this** and send it. A pet comes with a preview picture by default, the first frame of its idle animation, and you can turn it off; for a companion you can pick a PNG as its cover (at most 512 pixels a side and 2 MB), or leave it and the first letter of its name is shown. A reviewer looks at it first, and it shows up under **Browse** once approved; a rejection says why, and you can fix it and send it again. To take one back, open it and tap **Withdraw**.

If the phone's record of an unfinished submission can't be read, or keeps failing to clear, that step offers **Let go of this record**. It only deletes the record on this phone (if the phone's submission records can't be read as a whole, it clears the unfinished records of every account on this phone, and the confirmation says so) and doesn't ask the Workshop to cancel anything: if the Workshop already received the submission, it stays under **My uploads**; if not, you'll need to submit again.

The first time you submit, view your uploads or report something, the app asks you to confirm one thing: the Workshop tells who you are by your forum account, by sending your forum sign-in credential to the Workshop service, which asks the forum whose it is. The page shows both addresses, and nothing is sent until you tap **Agree and continue**. You can browse and install without agreeing.

If something is wrong with an item (infringement, unsuitable content), tap **Report** in its details and say why. A reviewer handles the report; an item isn't taken down automatically because it was reported.
