# Context Doc: Paddle wallet payments closed mid-sheet by our own cooldown

_Last verified: 2026-10-24 (against origin/main 735cdeb31)_

## Status
Root cause proven. Fix owned by the "alerts n fixes" PR (part B): arm the cooldown on
`CHECKOUT_COMPLETED` only, and re-enable wallets in `frontend/src/billing/paddle-checkout.ts`
(`WITHOUT_WALLETS`, which PR #2202 used to hide Apple Pay and Google Pay as a stopgap).
Tracking issue: engram-app/Engram#2203.

## What This Is
Apple Pay and Google Pay checkouts on the billing page parked at Paddle `action_required`
with no error. The transaction stayed `ready`, no subscription was created, and the buyer
saw nothing useful. Roughly half of Apple Pay attempts failed; every observed slow Google
Pay attempt failed.

## Symptom
- Paddle transaction `status: ready`, `payments[].status: action_required`, no error code.
- No `transaction.completed` / `subscription.created` webhook.
- Frontend shows our "slow activation" recovery banner instead of a success.
- Card payments (no sheet) are unaffected, so it looks wallet-specific.

## Root cause
`frontend/src/billing/billing-page.tsx` (origin/main):

- `:43` `const COOLDOWN_MS = 15_000;`
- `:480-496` the `CHECKOUT_PAYMENT_INITIATED` handler calls
  `setCompletedAt((prev) => prev ?? Date.now())`, arming the activation cooldown.
- `:352-362` the cooldown effect: after `COOLDOWN_MS` it calls
  `paddleRef.current?.Checkout.close()` and shows the recovery banner.

Paddle.js fires `checkout.payment.initiated` when the buyer TAPS the wallet button, before
the Apple Pay / Google Pay sheet is even shown. The buyer then has 15 s to authenticate
(Face ID, PIN, picking a card). Anyone slower than 15 s has the checkout iframe torn down
underneath the open sheet, and Paddle is left waiting on an action that can no longer
complete. "About half of Apple Pay fails" just means "about half of buyers take longer
than 15 s".

The comment at `:349` says the cooldown "starts on CHECKOUT_COMPLETED", which is no longer
true; the PAYMENT_INITIATED arming was added as a belt-and-suspenders for dropped
COMPLETED events on trial redirects.

## Evidence: Paddle payment start to our `Checkout.close()` (PostHog)

| Date  | Method     | Delta to close | Outcome |
|-------|------------|----------------|---------|
| 10-24 | Google Pay | 13.4 s | failed |
| 10-24 | Google Pay | 14.7 s | failed |
| 10-24 | Google Pay | 15.0 s | failed |
| 10-21 | Apple Pay  | 15.4 s | failed |
| 10-21 | Apple Pay  | 15.1 s | failed |
| (success) | Apple Pay | 12.3 s | succeeded (sheet finished before close) |
| 10-19 | Apple Pay (`txn_01m5b3w4hqtx5qd5zcrwyknnah`) | 14.9 s | closed by us even though Paddle recorded the payment authorized |
| 10-24 23:35 | (`txn_01m5r49vsytzdm6fwgk0qm6xzs`) | 5.25 s | outlier; cause not verified, most likely the buyer closed it |

Deltas below 15.0 s are because Paddle's payment start lands slightly after the tap that
fired PAYMENT_INITIATED; the close is always ~15 s after PAYMENT_INITIATED.

## Failed Approaches / Dead Ends
- **$0 trials.** Suspected because trials authorize $0. Ruled out: a paid, non-trial Apple
  Pay checkout failed the same way.
- **Our Permissions-Policy header.** `frontend/public/_headers:99` sends
  `payment=(self "https://*.paddle.com")`. Ruled out for both browsers:
  - Chromium checks each frame only against its DIRECT parent's policy. Our page allows
    `buy.paddle.com`; Paddle's frame in turn allows its `js.stripe.com` Google Pay
    grandchild. Payment Request is permitted at every hop.
  - Safari ignores the `Permissions-Policy` header entirely (caniuse), so it cannot block
    Apple Pay there.
- **Hiding wallets (PR #2202).** Stops the failures but loses the conversion; a stopgap,
  not a fix.

## How to diagnose next time
1. In PostHog, for the session, take the Paddle payment-start event and our checkout-close
   event; compute the delta. A cluster at ~15 s (= `COOLDOWN_MS`) means our timer closed it.
2. In Paddle, fetch the transaction and read `payments[].status`. `action_required` with no
   error code plus `status: ready` means the payment was abandoned mid-flow, not declined.
3. Check whether the method opens an out-of-frame step (wallet sheet, 3DS challenge, bank
   redirect). Those are the flows a timer kills.

## Gotchas
- **General rule: never arm a timer, redirect, or `Checkout.close()` on
  `PAYMENT_INITIATED`.** That event means "the buyer started paying", not "payment is
  done". Wallet sheets and 3DS challenges run AFTER it for an unbounded, human-paced time.
  Only `CHECKOUT_COMPLETED` (or the server webhook / activation push) is safe to act on.
- The failure is silent on Paddle's side: no decline, no error, so error-rate alerts stay
  green. Watch for transactions stuck at `ready` with `action_required` payments instead.
- Card payments mask the bug because they usually complete well inside 15 s.

## References
- `frontend/src/billing/billing-page.tsx` (cooldown + event handlers)
- `frontend/src/billing/paddle-checkout.ts` (`WITHOUT_WALLETS`)
- `frontend/public/_headers` (Permissions-Policy)
- `docs/context/paddle-integration.md`
- engram-app/Engram#2203, PR #2202
