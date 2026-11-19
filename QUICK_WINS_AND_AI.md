# Storage quick wins and assisted decisions

## What people should get in the first minute

- **Phone nearly full.** Show a read-only scan without cloud downloads, then offer the largest verified videos and exact duplicate groups when available. Flag unreadable originals separately. Explain Apple’s Optimize Storage path when the user wants to keep browsing in Photos.
- **Cloud bill feels too high.** Show the annual cost from one monthly number. Ask for usage and a smaller-plan quote only if the user wants to compare. Add independent archive costs, remaining subscriptions, migration and expected retrieval only in advanced analysis.
- **Too many copies.** Let the user choose whether to keep browsing in Apple Photos, merge duplicates in Apple Photos, or retain an independent original. Each choice should explain where the original remains and any effect on other devices.
- **Documents take up space.** Guide users to remove locally downloaded copies of confirmed synced files in iCloud Drive or OneDrive. Avoid suggesting Delete as a way to evict a local download.
- **I have files in several places.** Analyze the names and sizes reported for a user-selected set from the iPhone Files picker. Start with the largest known files. Files exposes the locations configured on that device. Provider-wide usage, an account’s bill, and whether a second original exists require separate evidence.

## Where people keep their files

| Situation | First action | What the app must verify before promising savings or preservation |
| --- | --- | --- |
| Photos on an iPhone with iCloud Photos | Review Optimize Storage and Apple Photos duplicate groups | Apple manages device copies. Deletions sync. Device storage saved varies. |
| Photos in both Apple Photos and Google Photos | Compare the accounts and a small user-selected sample | Google’s API has selected-item access for existing libraries. Storage Saver copies may differ from full originals. |
| Documents in iCloud Drive, Google Drive, or OneDrive | Distinguish online files from offline downloads and review total account usage | A file provider returning a file does not prove that a separate online original has finished syncing. Drive, Gmail and Google Photos can share one Google quota. |
| Files under On My iPhone, on a USB drive, or on a home NAS | Choose which folder or drive is the destination and test reopening a copy | Identify which device holds the original and whether another recoverable copy exists. A single external drive can fail. |
| Long-term photo and document archive | Compare a quote with the current bill and try a restore | Include fees, time to retrieve, subscriptions that must stay, shared storage and minimum retention. |

## Build and validation order

1. **Guide the actions available now.** Show quick wins up front and keep an advanced questionnaire available on demand. Keep system-controlled actions, such as Apple Photos Merge, in the system that performs them.
2. **Prove a copy and a restore.** Start with small local JPEG, HEIC and PDF samples and a user-selected Files destination. Stream bytes, re-read and verify size and hash, and test reopening. Separate byte verification from cloud sync confirmation. Preserve associated resources and metadata before supporting Live Photos, RAW pairs and edited photos.
3. **Show the real decision.** Put the selected source, exact destination, latest verification, remaining full-resolution copies, and any on-device preview on a before-and-after screen. Apply storage-provider capabilities. Recheck evidence at action time and require separate authorization before uploads or removal. Label a single copy as having no independent backup.
4. **Test on real devices.** Include a nearly full phone, limited Photos access, offline documents, a disconnected drive, an interrupted transfer and a full restore. Watch whether users can explain the result after the first tap. Measure time to first useful action and completion before testing conversion.

## Useful AI in order

- **On-device similarity review.** Use Apple Vision feature prints on bounded batches of available thumbnails. Present “Looks similar” separately from verified exact matches. Similarity is a review aid and provides no evidence that full-resolution resources match.
- **Optional bill and document OCR.** Let users select one bill or scanned document. Extract amounts or searchable text with Apple Vision, ask users to confirm the extracted values, and keep temporary text local. The cost calculation uses the confirmed inputs.
- **Optional explanations.** On devices that support Apple Foundation Models, explain already-calculated findings using structured facts. Show a deterministic explanation when the model is unavailable. The model does not determine copy integrity, invent quotes or approve destructive actions. Defer external AI uploads while on-device options meet the need.

## Sources

- [Apple Photos optimization and synchronization](https://support.apple.com/en-us/108782)
- [iPhone Photos merging](https://support.apple.com/en-mide/guide/iphone/iph1978d9c23/27/ios/27)
- [Apple Files downloads and deletion](https://support.apple.com/en-ie/104953) and [selected directory access](https://developer.apple.com/documentation/uikit/providing-access-to-directories)
- [Microsoft OneDrive offline files](https://support.microsoft.com/en-us/onedrive/read-files-or-folders-offline-in-onedrive-for-ios)
- [Google Photos API access](https://developers.google.com/photos/support/updates), [storage quality](https://support.google.com/photos/answer/6220791), and [shared Google quota](https://support.google.com/googleone/answer/9312312)
- [Apple Vision similarity](https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest), [Vision text recognition](https://developer.apple.com/documentation/vision/recognizing-text-in-images), and [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
