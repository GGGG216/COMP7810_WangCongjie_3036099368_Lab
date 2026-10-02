# STUDENT-QUESTIONS.md — Discussion questions (submit with your repo)

Answer directly under each question. 150–300 words each — **reasoning over length**.

---

## A. Permission design

**A1.** The vault holds `MINTER_ROLE`, so it can `burn` any user's balance. Explain why that is a risk, then write out how you would change `Vault` and `SimpleStablecoin` to remove it.

> Your answer:

`SimpleStablecoin.burn(from, amount)` checks only `MINTER_ROLE`; it does not require the owner's consent. A minter can therefore destroy another holder's tokens without paying them collateral. This combines issuance and confiscation powers, and makes a compromised privileged account particularly damaging. There is an important boundary: the current `Vault.redeem` passes `msg.sender` as `from`, and the vault has no public function that chooses an arbitrary victim. Impersonating the vault in a test demonstrates the token-level authority, not an existing public arbitrary-burn exploit in `Vault`.

I would keep `mint` restricted to authorized vaults but remove privileged `burn(address,uint256)`. The token would instead provide `burn(uint256)` for the caller's own balance and `burnFrom(address,uint256)` that spends the owner's ERC-20 allowance before burning. The vault's `redeem(amount)` would call `stable.burnFrom(msg.sender, amount)`, then transfer exactly that amount of collateral to the same caller. Users would approve the vault for the redemption amount first; `MINTER_ROLE` would never bypass that allowance.

The transaction must remain atomic: if either the burn or collateral transfer fails, all changes revert. Tests should cover missing and insufficient allowances, allowance consumption, a minter attempting an unauthorized burn, and successful redemption. Exact approvals limit exposure, although an allowance still intentionally delegates authority until spent or revoked. This redesign is proposed here; the lab retains its original burn behavior so Ex4 can demonstrate it.

**A2.** In this contract `DEFAULT_ADMIN_ROLE`, `MINTER_ROLE` and `PAUSER_ROLE` all go to the same address. How would you split them in production, and who holds each?

> Your answer:

The constructor gives all three roles to `admin`. `Deploy.s.sol` then also grants `MINTER_ROLE` to the vault, without revoking the admin's minting authority. Thus the deployed system has two minters, not just the vault. A stolen admin key can already mint without collateral and can grant additional roles.

In production I would place `DEFAULT_ADMIN_ROLE` behind a governance multisignature with independent signers and a timelock for role grants and sensitive configuration changes. Its job is administering policy, not routine minting. Because the default admin can appoint other admins and minters, separating addresses alone is insufficient: threshold signing, delayed changes, monitoring, and a carefully limited emergency revocation mechanism matter.

`MINTER_ROLE` should belong only to reviewed issuance contracts that enforce collateral receipt and supply limits. An operator's everyday wallet should not be a minter. Deployment should grant the vault its role, verify the final role configuration, and revoke the deployer's minting and administrative privileges after transferring administration safely.

`PAUSER_ROLE` should belong to a separate incident-response multisignature able to react quickly. I would split pausing from unpausing in a revised contract: responders can stop affected operations, while recovery requires governance review. Separate controls for minting, transfers, and redemption would avoid unnecessarily disabling exits. These are changes to the role model; the current contract allows every pauser to both pause and unpause. Events and alerts should make each role change and emergency action observable.

---

## B. Pausing and redemption

**B1.** `_update` is the single entry point for every balance change, so `pause()` freezes transfers, minting and redemption together. If you wanted "pause transfers but **allow redemption**", how would you change it? Give the approach — full code not required.

> Your answer:

OpenZeppelin's `_update` distinguishes ordinary transfers by two nonzero addresses, minting by `from == address(0)`, and burning by `to == address(0)`. I would replace the unconditional `whenNotPaused` modifier with operation-specific checks. A transfer pause would reject only updates where both addresses are nonzero. A separate mint pause would block issuance if the incident concerns new liabilities. Burning for redemption would remain available unless an independently controlled redemption emergency stop is explicitly activated.

For the existing vault, redemption calls `stable.burn(msg.sender, amount)` and then transfers collateral. Allowing that burn through `_update` preserves the exit even while sUSD transfers are frozen. With the allowance-based redesign in A1, the vault should call `burnFrom` directly on the user's approved balance. A design that first transfers sUSD into the vault would accidentally depend on the very transfer path being paused. Approvals themselves are not balance updates, so they can remain available under a transfer-only pause.

Allowing burns must not bypass authorization, balance checks, or the requirement to deliver collateral. It also cannot overcome a pause or blacklist in the collateral token itself. I would test that transfers fail, a funded approved redemption succeeds, a failed collateral transfer restores the original supply and user balance, and minting follows its own configured policy. A separate redemption stop is justified only for an incident affecting that path, with explicit recovery rules.

**B2.** In 2008, when a money-market fund "broke the buck", redemptions were frozen for days. In 2023 USDC depegged to $0.87 after a reserve bank failed, but redemptions were **not** shut. Compare the two responses — what does closing the redemption channel, or leaving it open, do to a stablecoin?

> Your answer:

The historical contrast needs qualification. The Reserve Primary Fund reported a $0.97 net asset value in September 2008 and initially delayed redemption payments. The SEC's September 22 order permitted suspension beyond that initial period to avoid liquidation at prices that further impaired investors; it was not simply a brief routine outage. [SEC explanation](https://www.sec.gov/divisions/investment/guidance/reservefundmmffaq.htm).

USDC's March 2023 redemption channel was not continuously available either. Federal Reserve researchers report that primary-market operations largely ceased over the weekend because of banking-hour constraints. Circle maintained its commitment to dollar redemption, and subsequently reported clearing substantially all pending requests by March 15, with $3.8 billion redeemed since Monday. The federal depositor backstop and restored processing both mattered for recovery. [Federal Reserve analysis](https://www.federalreserve.gov/econres/notes/feds-notes/in-the-shadow-of-bank-run-lessons-from-the-silicon-valley-bank-failure-and-its-impact-on-stablecoins-20251217.html), [Circle operations update](https://www.circle.com/blog/march-15-update-on-usdc-operations).

My interpretation is that closing redemption conserves immediate cash and can prevent forced sales, but removes the arbitrage route that normally supports a stablecoin's price. Holders may still sell on secondary markets, where uncertainty and waiting costs produce discounts. Keeping an accessible, credible redemption channel lets arbitrageurs buy discounted coins and redeem near par, reducing circulating supply and supporting price. However, an insolvent issuer paying early redeemers in full transfers losses to remaining holders. Neither an open channel nor a freeze creates missing assets. The design needs both adequate reserves and an operational plan for liquidity, settlement delays, and equitable loss handling.

---

## C. Depeg analysis

**C1.** Under what conditions does this coin depeg? Distinguish at least two classes of cause, and say how each one shows up in the invariant `totalCollateral() >= totalSupply()`.

> Your answer:

One class is a shortage of collateral units. An authorized minter can create sUSD directly without depositing mUSDC, or a faulty collateral integration could credit deposits larger than the amount actually received. Then `totalCollateral() < totalSupply()`: the on-chain accounting invariant detects that not every token can be redeemed for one collateral token. A direct collateral donation has the opposite effect, so backing should generally use `>=`; strict equality is appropriate only for the restricted mint/redeem model without donations or external issuance.

A second class is blocked or costly conversion. Pausing freezes burns in this implementation, so users cannot redeem even when collateral exactly equals supply. Congestion, transaction fees, revoked vault permissions, or collateral transfer restrictions can similarly obstruct arbitrage. The invariant can remain true throughout a market discount because it measures balances, not access or execution costs. Restricted minting can also permit an upward deviation when new supply cannot meet demand.

A third class is collateral losing dollar value. If one collateral token becomes worth less than one dollar, one-for-one token backing still passes the raw-balance invariant while sUSD's dollar backing deteriorates. `MockUSDC` has an unrestricted faucet and no real dollar claim, so this lab demonstrates accounting rather than a traded dollar peg. The repository has no market-price measurement: unbacked minting proves a solvency failure, not an observed exchange price. Full peg analysis therefore needs asset valuation, liquidity, redemption access, and market evidence alongside the invariant.

**C2.** Suppose an attacker bribes their way to `MINTER_ROLE`, mints 1,000,000 sUSD out of nothing and redeems it all. Describe the flow of funds, and name the step that could have stopped them.

> Your answer:

Suppose honest users have deposited 1,000,000 mUSDC and hold the corresponding 1,000,000 sUSD. After gaining `MINTER_ROLE`, the attacker calls `stable.mint(attacker, 1_000_000e6)`. Supply becomes 2,000,000 sUSD while the vault still holds only 1,000,000 mUSDC. The token's permission check succeeds because the attacker now has the very authority it checks; it never verifies that collateral arrived.

The attacker then calls `vault.redeem(1_000_000e6)`. The vault checks that enough collateral is currently present, burns the attacker's tokens using its own minter role, and transfers 1,000,000 mUSDC to the attacker. The vault is empty, but honest holders still own 1,000,000 outstanding sUSD. Their backing funded the withdrawal. Burning the forged tokens reduces supply, but reduces collateral by the same amount and does not repair the existing deficit.

The premise requires enough reserves to redeem the whole amount. If the vault holds less, that single redemption reverts with `InsufficientCollateral`; the attacker can instead redeem up to the available reserve, subject to their token balance. Failed transactions are atomic.

The decisive prevention point is the unauthorized role grant or compromised minter key before issuance. Governance controls should prevent arbitrary minters, and token issuance should be restricted to contracts that enforce backing. Once tokens exist, this vault cannot distinguish their provenance. Monitoring and emergency controls may limit damage, but they are not substitutes for preventing unbacked issuance.

---

## D. Toward RWA

**D1.** Right now the collateral is `MockUSDC` and `totalCollateral()` just reads an on-chain balance — simple and reliable. If the collateral were **US Treasuries**, could this invariant still be written that way? What new problems appear?

> Your answer:

A raw token balance would no longer express dollar backing. The vault could hold a token representing Treasury claims or fund shares, but a balance of those units is not automatically the cash obtainable by redeeming them. I would define a conservative reserve valuation in the same six-decimal dollar units as sUSD: verified eligible holdings multiplied by current realizable prices, plus cash, less other or senior liabilities, encumbrances, fees, and appropriate risk haircuts. The sUSD liability being compared is excluded from these deductions to avoid counting it twice. The solvency condition becomes `conservativeReserveValue >= outstandingStableLiabilities`.

That calculation introduces trusted inputs. Custodians must establish that the securities exist, belong to the relevant reserve arrangement, and are not pledged elsewhere. Independent reconciliation and attestations should match legal holdings, tokenized claims, cash, and supply. An oracle publishes valuations with explicit units, timestamps, and update rules; code should reject stale or invalid data rather than treating an old price as fresh backing. These controls reduce uncertainty but do not make off-chain facts cryptographically certain.

Treasury market prices can change before maturity, and selling now may realize a different amount from face value. Settlement schedules and service outages also separate solvency from liquidity: sufficient assets on paper do not guarantee cash for every immediate redemption. I would track available redemption liquidity and obligations separately, maintain a cash buffer, and specify queues or settlement windows. Tokenization changes how claims move; it does not remove custody, valuation, operational, or legal-enforcement risk.

**D2.** If the collateral were **a building**, how would you put it inside this vault? Which off-chain roles or legal structures would you have to introduce?

> Your answer:

A building cannot be transferred to a Solidity address. One possible design is a special-purpose entity that legally owns the property and issues a defined tokenized claim, such as an ownership interest or secured financing claim. The vault would hold that claim, while binding documents specify how token holders obtain cash flows or enforce against the asset. A token transfer alone must not be assumed to transfer registered land title; the connection depends on the jurisdiction and the claim's legal structure.

The arrangement needs a title and legal administrator, an asset or property manager, an independent appraiser, an accountant or auditor, and a trustee or security agent where required to represent claim holders and enforce security. Banking and payment providers collect rent and deliver proceeds. Insurance, maintenance, taxes, existing mortgages, and other senior obligations affect what is actually available to the vault. Legal design must address insolvency, segregation of assets, transfer eligibility, dispute resolution, and who may authorize a sale.

On-chain accounting would therefore use a conservative estimate of the claim's recoverable net value, with clear timestamps and valuation authority, rather than the building's headline appraisal. Appraisals are infrequent and liquidation can be slow and costly. A liquid dollar stablecoin backed mainly by property would need substantial liquidity reserves, conservative borrowing limits, and redemption terms that reflect those delays. Smart contracts can enforce token rules and record claims; off-chain institutions must service and enforce the underlying rights.

---

## E. Tests (Tier 1 required — this is Ex4)

Turn the red tests green in `test/exercises/01_LoopTasks.t.sol` to cover the scenarios below, and write your test function names here:

| Scenario | Your test function name |
|---|---|
| Minting by a non-minter reverts | `test_Ex4_Mint_RevertsForNonMinter` |
| Transfers revert while paused | `test_Ex4_Pause_BlocksTransfers` |
| **Redemption** reverts while paused | `test_Ex4_Pause_BlocksRedeem` |
| An attacker cannot burn someone else's balance | `test_Ex4_AttackerCannotBurnOthersBalance` |
| ...but the vault holding `MINTER_ROLE` can | `test_Ex4_VaultHoldsTheKey_CanBurnAnyonesBalance` |

That last pair is meant to be read together: the guard is written correctly, but the key was handed to the vault. Keep it in mind when you answer A1.

Now write one more scenario you consider **most likely to be attacked**, and say why you picked it:

> Your answer:

Proposed additional scenario (not implemented): compromise of an account that can grant `MINTER_ROLE`, followed by unbacked minting and redemption of honest users' collateral. I choose it because the attack uses intended public functions with no complicated numerical exploit, and the deployment deliberately leaves the administrator able to mint and grant roles. This is a threat-model priority, not a measured claim about attack frequency.

The test should seed the vault with Alice's legitimate deposit, show that an unprivileged attacker cannot grant themselves the role, then model an authorized but malicious administrator granting it. The attacker mints and redeems the full reserve. Assertions should prove that the attacker received the collateral, Alice still owns her sUSD, and `totalCollateral() < totalSupply()`. Alice's subsequent redemption should revert without changing her balance or total supply. This demonstrates why a correct access-control check is insufficient when its trusted role is compromised.
