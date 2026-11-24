# Age rating answers (App Store Connect → App Information → Age Rating)

Owner decisions E20-D1 (13+ everywhere, social media answered Yes) and E20-D7 (Entertainment as the secondary category),
wiki [E20 §3.1](https://github.com/Al-Ummah-Now/AlUmmahNowWiki/blob/main/epics/E20-system-parental-controls.md). The answers
are in [`age-rating.json`](age-rating.json); App Store Connect's team API key can't enter them, so they are typed once per
record and re-checked at every release. `scripts/check-store-metadata.py` (CI) checks that no question is missing and that
the cited files exist.

| Record | Result | Category | Secondary |
|---|---|---|---|
| Al Ummah Now (iOS), for Mac | 13+ | Photo & Video | Entertainment |
| Al Ummah Now TV | 13+ | Photo & Video | Entertainment |
| Al Ummah Now Studio (iOS) | 13+, by **Override to Higher Age Rating** | Photo & Video | none |

Admin and the QA records are TestFlight internal only and have no rating. Studio for Mac is outside the store.

- **Social media: Yes** on iOS and Mac from the first release. Apple counts a feed people view, like and share, and
  answering Yes now means the rating and the Social Media time allowance don't change when those features ship. TV only
  plays videos: No. **Disabled under 13: No**, because a Yes also promises a feed made for children.
- **User-generated content: Yes**, the videos come from creators.
- **Messaging and chat: No** until comments or chat ship in an app; Apple counts public posting. Change it in the same PR.
- **Age assurance: No.** A date of birth people type themselves is not assurance. **Parental controls: No.** Parents use
  the device's own.
- **Infrequent** where creators' talks and news can touch a theme (realistic violence, weapons, alcohol and drug
  references, medical, wellness and mature themes). Videos above that are age-restricted and need a signed-in 18+ account.
- **Dating and relationships, Shared location: No** (required since 16 November 2026; every app answers by 12 January 2027).
- **Age Suitability URL:** the parents' guide, once it is published (E20-S1).
- Names, subtitles, keywords, promotional texts and descriptions never say "for kids" or "for children", in either
  language: Apple reserves them for the Kids category (guideline 2.3.8). The same check enforces it.
