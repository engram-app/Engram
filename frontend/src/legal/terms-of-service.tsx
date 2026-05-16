export const TERMS_VERSION = '2026-05-15'

export function TermsContent() {
  return (
    <>
      <h2>Terms of Service</h2>
      <p>
        <strong>Last updated:</strong> {TERMS_VERSION}
      </p>
      <p>
        Engram (&quot;we&quot;, &quot;our&quot;) operates a knowledge-base service that stores and
        indexes notes you choose to sync to your account. By creating an account you agree to these
        Terms.
      </p>
      <h3>1. Account</h3>
      <p>
        You are responsible for the security of your credentials and for any activity on your
        account.
      </p>
      <h3>2. Content</h3>
      <p>
        You retain ownership of your notes. We process them only to provide the service
        (storage, indexing, search) and never sell or share them.
      </p>
      <h3>3. Subscriptions and billing</h3>
      <p>
        Paid plans renew automatically until cancelled. Billing is handled by Paddle as our
        Merchant of Record; their terms apply to the payment itself.
      </p>
      <h3>4. Termination</h3>
      <p>
        You may cancel at any time from your account settings. We may suspend accounts that
        violate these Terms or applicable law.
      </p>
      <h3>5. Changes</h3>
      <p>
        We may update these Terms; the version date at the top reflects the current revision.
        Continued use after a revision constitutes acceptance.
      </p>
      <p>
        <em>
          Placeholder content. Replace with reviewed legal text before launch — coordination item
          tracked in the spec at docs/superpowers/specs/2026-05-15-signup-wizard-design.md.
        </em>
      </p>
    </>
  )
}
