# Context Doc: Web-app translation spot-check guide

_Last verified: 2026-10-06_

How a human checks the ten LLM-generated web-app catalogs in a real browser, and the per-locale list of entries the translators and reviewers were unsure about. Mechanism, key model and automated validation live in `docs/context/webapp-i18n.md` (read its "Validation (browser level)" section first). Nothing here has been checked by a native speaker yet.

## 1. How to spot-check

### Switch language (picker)

Settings > Account > Language (a `<select>` card after Appearance). Switches without a reload; the pick is stored in `localStorage["engram:locale"]`.

### Test auto-detection instead

The stored pick beats the browser language, so clear it first:

1. DevTools console: `localStorage.removeItem("engram:locale")`, then change the browser language and reload.
2. Chrome: `chrome://settings/languages`, move the language to the top. Or launch a throwaway profile: `google-chrome --user-data-dir=$(mktemp -d) --lang=de`.
3. Firefox: `about:preferences` > Language > Choose your preferred language.
4. Safari follows the OS language; there is no per-browser setting.

Fallbacks to expect: `en-GB` -> `en`, `zh-HK/MO/Hant` -> `zh-TW`, other `zh` -> `zh-CN`, `pt-PT` -> `pt-BR`, anything unsupported -> `en`.

### Confirm what the app resolved

```js
document.documentElement.lang        // catalog actually on screen
localStorage["engram:locale"]        // stored pick (null = auto-detect)
navigator.languages                  // what the browser offers
```

### Which dev shape

| Shape | Start | Differs |
|---|---|---|
| Self-host (local auth, billing off) | `make dev-selfhost` (default) | No Clerk, no Paddle, no agreement or billing onboarding steps. Registration may be invite-gated on a shared DB. |
| SaaS | `make saas-dev` | Clerk sign-in/sign-up, agreement + billing onboarding steps, Billing settings, Paddle checkout (sandbox). |

App is at http://127.0.0.1:5173 through the SSH tunnel (see `local-browser-cdp-tunnel.md`). Both shapes use `:4000`/`:5173`.

### Checklist (walk in this order, once per locale)

- [ ] **Sign-in / first run:** heading, field labels, placeholders, validation errors, reset-password page, invite-required and invalid-invite states.
- [ ] **Onboarding, self-host:** tools -> vault (Obsidian panel, "starting fresh" panel; the vault name field starts as the translated default; untouched, it is stored as English `My Vault`) -> dashboard.
- [ ] **Onboarding, SaaS:** Clerk sign-up -> agreement (intro, privacy link and checkbox translated; the Terms body stays English) -> billing (Continue with Free; Pro/Starter/Free names) -> tools -> vault -> dashboard.
- [ ] **Settings > Account:** profile, Appearance (theme label reads `Theme: light|dark|system` as whole sentences), Language, session/sign-out, account deletion wording.
- [ ] **Settings > Vaults:** list, create, rename, delete, deleted-vaults (trash, "Purges" column, 30-day recovery sentence).
- [ ] **Settings > Connections:** device vs external connection wording ("1 active {kind}" sentences), revoke/disconnect dialogs, free-tier limit text with the `{upgrade}` link.
- [ ] **Settings > API keys:** create, copy, revoke, scopes label.
- [ ] **Settings > Billing (SaaS):** current plan, plan cards, change/cancel panels, proration summary (Charge/Credit/Change/Effective), billing history, alerts. Dates and money follow the app language (not the browser's).
- [ ] **Settings > Administration:** Members, Invites, Registration, Telemetry tabs (admin account only).
- [ ] **Vault / notes viewer:** tree, right-click and "..." context menus, rename/move/delete/duplicate dialogs, upload dialog, attachment embeds, backlinks/outline panels, search panel and filters (Type, Modified, From/To), "{count} ago" times, empty states.
- [ ] **Editor:** toolbar (Heading 1-6, Quote, Code, Wiki link, Outdent/Indent), fold chevron tooltips, widgets (properties panel, mermaid error, callouts), placeholders, Edit/Raw/Reading toggle, "Not syncing - reconnecting..." status.
- [ ] **Markdown reference panel:** prose, row labels and sample text are translated; syntax tokens, `[!tip]`-style callout type names, frontmatter keys, fence languages, math, URLs and `![[diagram.png]]` stay English **by design**. Click Insert on a row and check the inserted template is valid markdown (tag words `idea`/`topic` must be single words). Search by an English keyword and a translated word.
- [ ] **Error page and 404:** trigger a 404 (`/nope`), and the root error fallback (a chunk-load failure via DevTools offline then navigation).
- [ ] **Toasts and error messages:** failed save (stop the backend, edit a note, wait), revoke a key or connection, offline (DevTools > Network > Offline) then retry, failed upload, failed checkout (SaaS). Server-written error text stays English (see section 4).
- [ ] **Billing formatting:** dates (`6. Okt. 2026`, `2026年10月6日`), currency symbol and separators, "per month/year" fragments.
- [ ] **Clerk and Paddle screens (SaaS only):** Clerk sign-in/up/user-profile in the locale; Paddle checkout overlay opens in the locale (`zh-CN` -> `zh-Hans`). Use the Paddle sandbox (`paddle-ops.md`, test cards in the Paddle docs).

### What to look for

- **Leftover English**, including `placeholder`, `aria-label`, `title` (hover) and tooltips.
- **Mixed-language or broken sentences** built from `{placeholders}`: `{upgrade}`, `{kind}`, `{setup}`, `{type}`, `{reads}`, `{synced}`, `{recoverable}`, `{what}`/`{expectsLabel}`. Read the whole rendered sentence, not the fragment. Check the link renders mid-sentence and capitalization matches (the fragment is lowercase).
- **Register and terminology** versus the Obsidian plugin and the marketing site (vault, note, plan, device, revoke).
- **Truncation and overflow:** buttons, tabs, table headers, badges. German and Russian run long; CJK is dense (check line-height and wrapping). Test at a narrow window too.
- **Plurals:** Russian counts 1, 2, 5, 21 (one/few/many/other); French/Spanish/Italian/Portuguese 0, 1, 2, 1000000; ko/ja/zh have a single form.
- **Tag words** (`idea`, `topic`, `draft`) are one word, no spaces.
- **Dates and numbers** in the locale format; `<html lang>` equals the chosen locale.

### Record and fix a finding

1. Find the key: `cd frontend && rg -n "<English text>" src/i18n/locale/<code>.ts`. If it is absent in the catalog, the string is unwrapped in source: `rg -n "<English text>" src --glob '!*.test.*'`, and report it as a code bug instead.
2. Edit the **value only** in `src/i18n/locale/<code>.ts`. Never change the key (the English text), never add, drop or rename a `{placeholder}`, and keep plural objects' categories (`one`/`few`/`many`/`other`).
3. `bun run i18n:missing -- --count` (all zeros) and `bunx vitest run src/i18n` (placeholder, parity and orphan guards).
4. One finding per line in your notes: locale, surface, English text, current, proposed. Fix all ten locales when the problem is a shared decision (see section 3).

### Automated checks and where they stop

See "Validation (browser level)" in `docs/context/webapp-i18n.md`:

- `e2e/i18n-detection.spec.ts`: each browser locale lands on the right `<html lang>` and catalog heading; fallbacks; stored pick wins; picker switch.
- `e2e/i18n-onboarding.spec.ts` (self-host) and `e2e/i18n-onboarding-clerk.spec.ts` (SaaS): per-step leak detector (`e2e/support/i18n-leaks.ts`).
- `src/i18n/keys.test.ts`: parity, orphans, placeholders, hidden translator calls.

None of them judge translation quality: a string passes if it differs from the English key. They only cover onboarding and a few unauthenticated pages, not the viewer, editor, settings sub-pages, toasts or billing.

## 2. Cross-locale decisions

| Decision | Detail |
|---|---|
| "Engram docs" | Translated in de (Engram-Doku), fr, it, ja, ko, ru, zh-CN, zh-TW (their marketing references translate "Docs"); left English in es and pt-BR (their references do not). Decide whether it should be uniform. |
| Callout and markdown keywords | Callout type ids (`[!tip]`), fold markers, frontmatter keys, fence languages, mermaid ids and LaTeX stay English; callout titles in the gallery stay English; the renderer's omitted-title fallback is English too. |
| Binding consent text | Only the Terms body (server-provided, English) stays English. The agreement-step intro, privacy link and checkbox are translated. |
| Plan names | "Free" is translated (de Kostenlos, es/it/pt-BR Gratuito, fr Gratuit, ja 無料, zh-CN 免费版, zh-TW 免費); ru keeps Pro/Starter/Free as tier names; zh-CN translates Starter/Pro (入门版/专业版); zh-TW keeps Starter/Pro. Check plan cards and "your {plan} plan" sentences. |
| "Upgrade" as a `{upgrade}` link fragment | A lowercase verb link spliced into sentences ("Free tier: 1 connection. {upgrade}"). Each locale restructured around it; es/fr/it/pt-BR/ru/ja/ko/zh-* must be read rendered. German uses the noun "Upgrade" ("Mit einem Upgrade ..."). |
| `{kind}` (device / external connection) | Genders differ per language, so de/es/fr/it/pt-BR reworded to avoid agreement ("1 conexión activa del tipo {kind}"); ru picked neuter forms; ko/ja/zh use particles/neutral nouns. |
| `Purges` (Vaults > deleted table column) | Context unknown to translators; each locale guessed "date of permanent deletion". |
| `soft-deletes your user` | Rendered as logical/soft deletion in every locale; de was re-edited to "als gelöscht markiert". |
| Plural categories | `many` forms for es/fr/it/pt-BR read "{count} de ..." (correct CLDR for millions, looks odd for small counts); ru has one/few/many/other; ko/ja/zh only `other`. |
| `YYYY-MM-DD` hint | Localized letters in es (AAAA-MM-DD), fr (AAAA-MM-JJ), ru (ГГГГ-ММ-ДД); literal in it, ko, pt-BR. Verify it is a prose hint and not a format the user must type. |
| `Settings -> Community plugins -> Browse` | Obsidian UI path written from memory in several locales; must match the real Obsidian UI language (plugin ref not available). |
| "Callouts", "frontmatter", "wikilink" | Left English or loanword in several locales (see tables); check against Obsidian's own localized UI. |
| Em dashes | Replaced by comma/period/colon in de; elsewhere unchanged from source. |

## 3. Per-locale review list

Each table: English key, current choice, why doubtful. Ordered by consequence (billing and destructive wording, `{placeholder}` fragments, terminology, then style). Cross-locale items from section 2 are repeated only where the locale choice is specific.

### de

| English key | Current | Doubt |
|---|---|---|
| Revoke (key/connection/invite) | widerrufen | Fine for access, "widerrufen" also reads as legal withdrawal |
| Free tier: 1 connection. {upgrade} / "Mit einem {upgrade} ..." | Noun "Upgrade" sentences | Link text is a noun; check the sentence reads |
| Free plan allows 1 active {kind} | "1 aktive Verbindung der Art {kind}" | Clunky; gender of {kind} unknown |
| This soft-deletes your user... | "als gelöscht markiert" | Destructive wording, edited once by QA |
| Purges (column) | Endgültige Löschung | Context guessed |
| Charge / Credit / Prorated | Belastung / Gutschrift / Anteilig | Billing terms |
| Change (summary table) | Änderung | Billing summary column |
| Wire transfer / Korea local card | Überweisung / Koreanische lokale Karte | Payment method names |
| Scopes: | Berechtigungen: | Terminology |
| We index each note's {type}... | "den {type}", "Er ist ..." | Assumes {type} = masculine "Typ" |
| the device syncing your ... fragments | "das Gerät, das ..." | Accusative fragments |
| {setup}, then click Link in Obsidian again | assumes {setup} = "Einrichtung abschließen" | Fragment |
| It is also the one field required by the {okf} | "das vom {okf} verlangt wird ..." | Rewritten by QA |
| Math | Mathe | Colloquial |
| broke this page | beschädigt | Tone |
| Clear | Leeren | Filter reset wording |
| Open files / Open tools | Dateien öffnen / Werkzeuge öffnen | Could be a toggle label |
| Edit / Raw / Reading | Bearbeiten / Roh / Lesen | Mode toggle |
| Callouts / Wiki link / Section Divider | Callouts / Wikilink / Trennlinie | Obsidian German term |
| Vault root | Vault-Stammverzeichnis | Terminology |
| Reference / Sync | Referenz / Synchronisieren | Button vs noun |
| idea / topic | idee / thema | Lowercase tag words |
| Deployment Runbook / the runbook | Deployment-Handbuch / das Handbuch | No standard word |
| For a generous value of on time. | Bei großzügiger Auslegung von pünktlich. | Joke register |
| Engram docs | Engram-Doku | Uniformity (section 2) |

### es

| English key | Current | Doubt |
|---|---|---|
| Downgrade | Reducción de plan | Billing wording |
| Effective / Updated / Modified | Entra en vigor / Actualizada / Modificada | Gender guessed (nota) |
| Purges | Purga | Column header, context guessed |
| This soft-deletes your user... | elimina tu usuario de forma lógica | Destructive wording |
| Free tier: 1 connection. {upgrade} | "... conexión. {upgrade}" | {upgrade} renders capitalized "Mejorar plan" as a link |
| {upgrade} anytime ... | "Mejorar plan cuando quieras para..." | Terse |
| Heads up ... 1 active {kind} | "permite solo 1 {kind} a la vez" | Avoids agreement with device/connection |
| Daily/Weekly/monthly/annual | diaria/semanal/mensual/anual | Gender guessed feminine (plan/cycle) |
| the device syncing your '{vault}' vault | noun phrases with «» | Fragment inside larger sentence |
| {what} Wants {expectsLabel}. | {what} Espera {expectsLabel}. | Fragment |
| Offline (payment) / Korea local card | Fuera de línea / Tarjeta local de Corea | Payment method |
| Charge / Credit / Change / Tax | Cargo / Crédito / Cambio / Impuestos | Billing columns |
| a date (YYYY-MM-DD) | AAAA-MM-DD | Format hint |
| Raw | Sin procesar | Mode toggle |
| Settings -> Community plugins -> Browse | Ajustes -> Plugins de la comunidad -> Explorar | From memory |
| text / list / checkbox / datetime | texto / lista / casilla de verificación / fecha y hora | Property types |
| That is why your notes are plain {md} files... | "El texto fuente sigue siendo legible" | QA edit |
| Callouts / frontmatter | left English | By choice |
| My Vault | Mi bóveda | Name default |
| Engram docs | left English | Uniformity |

### fr

| English key | Current | Doubt |
|---|---|---|
| This soft-deletes your user... | "effectue une suppression logique de ton utilisateur" | Destructive wording, QA rewrite |
| upgrade (link) | passer à une offre payante | Restructured "Pour ..., il suffit de {upgrade}"; check mid-sentence |
| Your Free plan allows 1 active {kind} | "1 seule connexion active ({kind})" | Gender mismatch workaround |
| revoke cancellation | révoquer l'annulation | "retirer" may be more natural |
| Purges | Purge | Column header |
| {what} Wants {expectsLabel}. | "Attend texte." | Needs "du texte" |
| Setup checklist, {remaining} remaining | {remaining} restantes | Assumes feminine "étapes" |
| Which vaults can {client} access? | "... {client} peut-il ..." | Masculine client |
| {count} days ago (many) | "il y a {count} de jours" | Correct CLDR, unusual |
| Charge / Credit / Change / Effective | Prélèvement / Crédit / Changement / Date d'effet | Billing columns |
| Applies to | S'applique à | No context |
| Offline (payment) | Hors ligne | Payment method |
| Modified / Updated | Modifiée / Mise à jour | Feminine (note) |
| a date (YYYY-MM-DD) | AAAA-MM-JJ | Format hint |
| Reference (markdown) | Aide-mémoire | Terminology |
| Callouts | Encadrés | Obsidian French term |
| Settings -> Community plugins -> Browse | Paramètres -> Plugins communautaires -> Parcourir | From memory |
| Raw / Math / Tag | Brut / Maths / Tag | Terminology |
| the runbook / Deployment Runbook | le guide / Guide de déploiement | No standard word |
| Engram docs | Documentation Engram | Uniformity |

### it

| English key | Current | Doubt |
|---|---|---|
| Email o password errata | agreement | Agreement of "errata" |
| past due | scaduto | Billing status |
| annulli quando vuoi (cancel anytime) | wording | Billing promise, QA doubt |
| Free tier: 1 connection. {upgrade} | "Piano Gratuito: 1 connessione, {upgrade}." | Lowercase link |
| Free tier, pick 1 to start. {upgrade} anytime... | "Quando vuoi, {upgrade} per" | QA rewrite, sentence-initial link |
| Your Free plan allows 1 active {kind} | "un solo elemento attivo ({kind})" | Gender workaround |
| Purges | Eliminazione definitiva | Column header |
| Scopes: | Ambiti: | Terminology |
| {prorated} of {total} days | {prorated} giorni su {total} | Billing |
| Copy wikilink / Wikilink copied (one form) | drop {count} | Check plural one forms |
| Account setup ... click Link in Obsidian again | "Collega" assumed | Obsidian button name |
| Settings -> Community plugins -> Browse | Plugin della community, Sfoglia | Assumed |
| Downgrade | kept as loanword | Billing |
| Raw | Sorgente | Mode toggle |
| Open / Closed (registration) | Aperta / Chiusa | Gender |
| Callouts / Backlinks / tag | Callout / Backlink / Tag | Loanwords |
| Claim. / Struck through | Affermazione. / Barrato | Sample text |
| Deployment Runbook / the runbook | Runbook di distribuzione / il runbook | Loanword |
| Engram docs | Documentazione di Engram | Uniformity |

### ja

| English key | Current | Doubt |
|---|---|---|
| synced to your devices / recoverable for 30 days | "デバイスに同期済みの" / "30 日間は復元できます" | Fragments spliced into sentences, visual check |
| upgrade | アップグレード, composed "{upgrade}すると…" | Fragment |
| Finish setting up | "{setup}してから…" | Fragment |
| Free tier: 1 connection. {upgrade} | Free プラン: 接続は 1 つまで。{upgrade} | Mixed Latin/Japanese |
| Purges | 完全削除予定 | Column header |
| per {interval} | {interval}ごと | "月ごと" reads oddly |
| Revoke | 取り消す | Destructive wording |
| Scopes: | スコープ: | Terminology |
| Raw | left English | Mode toggle |
| Settings -> Community plugins -> Browse | 閲覧 | Obsidian's Browse label |
| Free / Open / Closed (registration) | 無料 / オープン / クローズ | Terminology |
| Wire transfer / Offline | 銀行振込 / オフライン | Payment methods |
| Engram also {reads} | 読み取る | Sentence flow |
| Type (note type) | 種類 | Terminology |
| e.g. Mom | 例: 母 | Sample |
| {count} months | {count} か月 | Counter |
| Obsidian's flavour | Obsidian 独自の仕様 | Wording |
| My note | 私のノート | "マイノート"? |
| For a generous value of on time. | 「期限どおり」を広い意味で捉えれば。 | Joke paraphrase |
| Engram docs / runbook | Engram ドキュメント / 運用手順書 | Terminology |
| Folder | フォルダ | Round 1 used フォルダー, round 2 フォルダ: check consistency |

### ko

| English key | Current | Doubt |
|---|---|---|
| Revoke | 해제 | No plugin precedent; 취소/철회 alternatives; also used for "Revoke {name}?" |
| Can't remove the last admin | 삭제 | Could be demote/delete |
| {amount} (price) fragments | "{amount}이" | Particle depends on the currency string |
| Purges | 영구 삭제일 | Meaning inferred |
| note limit vs other limits | 상한 vs 한도 | Inconsistent |
| This vault holds {notes} and {attachments}. | 와(과)/이(가) particles | Dynamic text |
| {recoverable} / {synced} fragments | particles | Fragments |
| {upgrade} | "{upgrade}하면 ..." | Link text works as verb stem |
| {setup} | "{setup}한 다음 ..." | Assumes {setup} text |
| {what} Wants {expectsLabel}. | {what} 입력 형식: {expectsLabel}. | Fragment |
| Engram {reads} | 추가로 읽는 | Fragment |
| {kind} | "활성 {kind}을(를) 1개" | Particle fallback |
| per {interval} | /{interval} ("/월") | Terse |
| Select more | 더 선택 | Terse |
| Open / Closed (registration) | 공개 / 닫힘 | Terminology |
| Wire transfer / Korea local card | 계좌 이체 / 한국 로컬 카드 | Payment |
| Demote to member / Promote to admin | 구성원으로 변경 / 관리자로 지정 | Role wording |
| A to Z / Z to A | 가나다순 / 가나다 역순 | Latin filenames still sort A-Z |
| Raw | 원문 | Mode toggle |
| Sign up / Registration | 가입 | Short |
| Engram docs / runbook | Engram 문서 / 런북 | Terminology |

### pt-BR

| English key | Current | Doubt |
|---|---|---|
| This soft-deletes your user... | exclusão lógica | Destructive wording |
| Purges | Exclusão definitiva | Column header |
| upgrade | "melhore seu plano" (lowercase imperative) | Sentences rewritten "Para ..., {upgrade}." (329-331, 340, 492, 494, 549) |
| Finish setting up | Conclua a configuração, used as {setup} at sentence start | Fragment |
| Your Free plan allows 1 active {kind} | "1 conexão ativa do tipo {kind}" | Gender workaround |
| Downgrade / Effective / Change type | Redução de plano / Vigência / Tipo de alteração | Billing |
| Billing | Cobrança | vs Faturamento |
| Self-hosted | Auto-hospedado | Terminology |
| just now | agora há pouco | vs "agora mesmo" |
| Join (Discord) | Entrar | vs "Participar" |
| Onboarding | Primeiros passos | Terminology |
| Offline / Card | Offline / Cartão | Payment |
| Raw / Reading view | Bruto / Modo de leitura | Mode toggle |
| Updated (filter) | Atualizada | Gender |
| Copied {count} wikilinks (one) | Wikilink copiado | Drops digit |
| Resize document left/right edge | borda esquerda/direita | Wording |
| Unchecked / Checked item | Item pendente / Item concluído | Sample |
| Engram docs | left English | Uniformity |
| the runbook | o manual / Manual de Implantação | No standard word |
| Mixed "..." vs "…" | several entries | Typography |

### ru

| English key | Current | Doubt |
|---|---|---|
| Disconnected '{name}' but authorizing the new connection failed | "Подключение «{name}» отключено" | QA fix (was Устройство) |
| Your Free plan syncs files between 1 device | "с одним устройством" | QA fix (grammar) |
| Credit applied / Credit to balance | зачёт | Billing wording |
| Purges | Удаляется навсегда | Column header, assumed date |
| Scopes: / Identity: | Разрешения: / Идентичность: | Terminology |
| upgrade ({upgrade}) | Перейти на платный план | Imperative used mid-sentence ("можно {upgrade}") relies on lowercase key |
| Free tier: 1 connection. {upgrade} | relies on {upgrade} text | Fragment |
| Heads up ... will stop having access | "и доступ будет закрыт" | Gender-neutral |
| {kind} | neuter forms | "1 активное {kind}" agreement |
| {indexed} самых старых | assumes large {indexed} | Plural |
| {count} days remaining (other) | "дня" | Fractional form |
| Settings -> Community plugins -> Browse | "Сторонние плагины" | Obsidian ru may say "Плагины сообщества" |
| Link (Obsidian button) | quoted English "Link" | Must match the real label |
| Open files | Открыть файлы | Could be a tab label |
| Raw / Edit / Reading | Исходник / Правка / Чтение | Mode toggle |
| Open / Closed (registration) | Открытая / Закрытая | Terminology |
| Wire transfer / Offline | Банковский перевод / Офлайн | Payment |
| Frontmatter (raw YAML) | (сырой YAML) | Wording |
| Mermaid error: {error} | literal newlines | Keep |
| Left / Center / Right | Слева / По центру / Справа | Column names |
| Docs / runbook | Документация / руководство | Terminology |

### zh-CN

| English key | Current | Doubt |
|---|---|---|
| This soft-deletes your user... | 软删除你的用户 | Destructive wording |
| Purges | 清除时间 | Column header |
| Charge / Credit / Prorated | 扣款 / 抵扣 / 按比例计费 | Billing terms |
| per {interval} / {trialPeriod} free trial | 每{interval} / {trialPeriod}免费试用 | Assumes localized interval units |
| You recently swapped devices ... {hours}h | {hours} 小时后 | Fragment |
| This vault holds {notes} and {attachments}. | "{notes}和 {attachments}" | Fragment spacing |
| Files already {synced} | 已{synced}文件 | Assumes {synced} text |
| Engram also {reads} (850) | 读取 | Sentence flow |
| Use {action} right below Current Plan | assumed button label | Fragment |
| {what} Wants {expectsLabel}. | {what}需要{expectsLabel}。 | Assumes noun phrase |
| Duplicate / Failed to duplicate | 创建副本 / 复制失败 | Inconsistent word |
| Obsidian's flavour | Obsidian 的风格 | Wording |
| Settings -> Community plugins -> Browse | 第三方插件 | Obsidian zh name |
| Wiki link (toolbar) / Wikilink | Wiki 链接 / Wikilink | Distinction |
| Free / Starter / Pro | 免费版 / 入门版 / 专业版 | Plan names |
| vault | 知识库 (round 3: 库) | Consistency |
| Raw | 源码 | Mode toggle |
| e.g. Mom | 例如 妈妈 | Sample |
| Callout | 标注 | Terminology |
| For a generous value of on time. | “按时”的标准相当宽松。 | Joke |
| Claim. / Struck through | 论点。 / 删除线文字 | Sample |
| Engram docs / runbook | Engram 文档 / 运维手册 | Terminology |

### zh-TW

| English key | Current | Doubt |
|---|---|---|
| This soft-deletes your user... | 軟刪除 | Destructive wording |
| Purges | 清除時間 | Column header |
| Delivered to: | 傳送至 | Terminology |
| Scopes: | 權限範圍 | Terminology |
| Failed to duplicate | 複製失敗 | Shares the word with Copy |
| Credit / Charge / Prorated | 抵免 / 收費 / 按比例計算 | Billing terms |
| upgrade ({upgrade}) | 升級, spaces dropped ("{upgrade}即可…") | Fragment |
| It is also the one field required by the {okf} / We index each note's {type} | reworded | Placeholder counts match, wording differs from English |
| KaTeX "dollar signs" | 錢字號 | vs 美元符號 |
| Annual / Annually | 按年 / 每年 | Billing cadence |
| Card / Korea local card | 卡片 / 韓國本地卡 | Payment |
| Settings -> Community plugins -> Browse | 設定 -> 第三方外掛 -> 瀏覽 | Not in plugin reference |
| Obsidian's flavour | Obsidian 的特有語法 | Wording |
| Raw / Reading view | 原始碼 / 閱讀檢視 | Mode toggle |
| checkbox | 核取方塊 | Terminology |
| instance | 執行個體 | Terminology |
| Callouts / Wiki link | 標註區塊 / Wikilink | QA changed Wiki 連結 |
| Community plugins | 第三方外掛 | Obsidian zh-TW name |
| Connect / Disconnect | 連接 / 中斷連接 | vs 連線 |
| For a generous value of on time. | 以寬鬆的標準來說啦。 | Joke register |
| Engram docs / runbook | Engram 文件 / 操作手冊 | Terminology |
| Cell | 儲存格 | Terminology |

## 4. Known gaps

**Intentionally English**

- Binding consent text: Terms/agreement body (server-provided `LegalDoc`) and the agreement-step lines in `onboarding/agreement-page.tsx` (bare JSX text, an `aria-label` and a checkbox label). Expect them as suspects in ja/ko/ru/zh-* scans.
- Server-written error text and API messages.
- `index.html` `<title>` and the pre-React splash (before `LocaleProvider` mounts).
- Markdown syntax keywords, callout type names, frontmatter keys, fence languages, math (section 2).
- Dev-only strings.
- The default vault name `My Vault` is persisted in English; every vault display (switcher, vault settings, onboarding field) shows it translated via `displayVaultName`. Names elsewhere (connections list, device-link, API, plugin, MCP) stay English.
- Plan prices in `billing/plan-change-panel.tsx` (`formatCents`, `formatPlanPrice`) are hardcoded USD `$` strings, not locale-formatted.

**Formatting follows the app language, not the browser:** dates and money use `renderedLocale` through `intlLocale()`, so a German UI shows `6. Okt. 2026` even in an `en-US` browser.

**Clerk and Paddle**

- `@clerk/localizations` is pinned to 4.17.0 (the repo's `@clerk/shared` override holds 4.33); strings Clerk added later show in English. Clerk marks localization experimental.
- Not covered: the hosted Clerk Account Portal, and everything Paddle hosts (customer portal, receipts, invoices, emails).
- The Paddle locale is set per `Checkout.open(...)`; verify in the sandbox, not by unit test.

**Unrun checks**

- The SaaS onboarding spec (`i18n-onboarding-clerk.spec.ts`) has never run (no Clerk credentials); its Clerk title assertion and the billing-step selectors are unverified against the live DOM.
- The self-host onboarding spec and the picker test registered no user (the shared FastRaid DB is unsafe and invite-gated); run them against a disposable DB. The walker's role locators and step order are unexecuted.
- Dynamic leak scan found 0 leaks on the unauthenticated pages in all ten locales; authenticated surfaces were never scanned.
- A static scan found the unwrapped agreement-step strings above (SaaS only).
