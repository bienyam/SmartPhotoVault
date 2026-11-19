# Smart Photo Vault Inventory redesign

## Decision for this review

Choose a visual direction for the next TestFlight build. The three directions are Clarity, Photo Library, and Storage Control. Clarity is the recommended default, with the denser storage details from Storage Control available on demand.

| Direction | App icon and visual style | Home screen |
| --- | --- | --- |
| Clarity | Overlapping photo frames, porcelain and cobalt | One prominent scan button and clear next actions |
| Photo Library | An arched photo frame with a horizon and sun, warm ivory and denim blue | A warmer home built around real photography |
| Storage Control | Overlapping vault plates, midnight navy and glacier blue | A storage overview with a prominent review button |

## Product decisions

- **Check my photos** launches an inventory or shows the next useful action after a scan. **Find duplicates**, **Connect storage**, and **Free up space** are direct routes. Surface one primary action and keep guidance in contextual help.
- **Free up space on this iPhone** explains Apple’s Optimize iPhone Storage setting. Apple manages local storage and synchronizes deletions across iCloud Photos.
- **Keep originals in another location** starts with a copy to the selected destination, verifies every required resource, and offers a restore test. Previews for independent cloud originals live inside this app. Show Apple Photos previews only through Apple’s own optimization.
- **Lower my storage bill** compares the user's current spend with candidate plans, including monthly storage, file retrieval fees, time to restore, and estimated migration costs.
- The optional **one full-resolution copy** plan makes the retained location explicit and identifies the risk of a single copy. Show the effects on each connected location before any action that could remove a copy.

## Build sequence

### Storage savings questionnaire

Ask users what they pay today, how much storage they use, how quickly they need originals back, and whether they want to keep browsing in Apple Photos. Make unknown inputs skippable and show which estimates depend on assumptions.

Compare keeping the current setup, downgrading a plan, and moving suitable originals to an archive. Show estimated monthly cost and savings alongside one-time migration charges, retrieval cost and time, and the conditions for actually lowering the current bill. Include any overlap while both subscriptions are active.

Users compare the options and choose whether to proceed. A questionnaire answer or recommendation does not authorize a transfer, deletion, or billing change. Any chosen action goes through its own review and confirmation.

1. **Redesign the existing TestFlight experience.** Build the chosen SwiftUI theme, icon, action-centered home, and duplicate review around the current read-only scan. Add progress, clear limited-access states, and expandable help. Verify Dynamic Type, VoiceOver, contrast, and touch targets of at least 44 points.
2. **Prove independent storage with one connector.** Start with Backblaze B2 as a prototype, with S3-compatible object storage behind a provider interface. Use only selected test assets first. Store resource-level hashes, byte counts, destination IDs and verification state. Resume interrupted uploads without creating extra copies. Test downloadable originals, videos, paired Live Photo resources, edited versions and metadata. Verify the selected restore path on a real iPhone.
3. **Add decisions backed by evidence.** Show where each original was verified, where only a preview exists, and when verification is incomplete. Present a simple before-and-after plan per provider. Failure, offline access, a revoked account, or a missing resource should stop the affected action. Keep the first archive beta copy-and-restore only. Revisit removal after verified restores, sync effects, favorites and album preservation are tested.
4. **Expand connectors and test pricing.** Assess user-authorized file storage connectors individually for read, write, checksum, restore and deletion capabilities. Evaluate Google Photos as a selected-item flow after policy review. Test whether users will pay for ongoing monitoring and verified restore, or prefer a one-time archive migration. Keep the first iPhone scan useful on its own.

## Archive candidates

| Option | Use | Trade-off |
| --- | --- | --- |
| iCloud Photos | Keep originals inside the Apple Photos experience | Synchronized deletion and system-managed phone storage |
| Backblaze B2 | First independent archive prototype with on-demand retrieval, starting at $6.95/TB per month | Egress allowance and excess retrieval costs need to be reflected in estimates |
| Amazon S3 Glacier Deep Archive | Later option for rarely retrieved collections | Slow restores, retrieval charges and a 180-day minimum |

Apple Photos already groups duplicates on-device. The opportunity is to help people who pay for overlapping storage understand where each original lives and verify that it can be restored. A 2026 Popsa-commissioned survey found that 49% of respondents reported stress from a disorganized photo library. This is a directional signal about the problem. Validate the proposed solution and willingness to pay directly with users.

## Validation before widening the beta

Watch people with different comfort levels use the app without coaching. Ask them to review a duplicate group, explain which original will remain, and restore one photo. Track completion, errors, time to a successful restore and whether they understand the storage charges. Interview people who regularly run out of iPhone space or pay for overlapping subscriptions. Those are customer problems to validate before committing to pricing.

## Sources

- [Apple Photos synchronization and optimization](https://support.apple.com/en-us/108782)
- [Apple Photos duplicate detection](https://support.apple.com/en-ca/guide/iphone/iph1978d9c23/27/ios/27)
- [Apple PhotoKit resource manager](https://developer.apple.com/documentation/photos/phassetresourcemanager)
- [Google Photos API access changes](https://developers.google.com/photos/support/updates) and [developer policy](https://developers.google.com/photos/support/api-policy)
- [Backblaze B2 pricing](https://www.backblaze.com/cloud-storage/pricing)
- [AWS S3 pricing](https://aws.amazon.com/s3/pricing/) and [Glacier storage class restore options](https://docs.aws.amazon.com/AmazonS3/latest/userguide/glacier-storage-classes.html)
- [Popsa’s 2026 photo trends survey](https://popsa.com/en-gb/perspectives/memory-economy-2026-photo-trends-report/)
