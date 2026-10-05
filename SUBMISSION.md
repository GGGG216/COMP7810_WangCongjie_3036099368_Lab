# Assignment Two submission checklist

Latest brief: `Y26-7810(SH)-assign2.pdf`, supplied on 5 October 2026.
Deadline: **16 October 2026, 23:55** (check the timezone displayed by Moodle).

The deliverable is **one ZIP uploaded to Moodle**, with the project files at the
archive root and the `lib/` directory inside. A GitHub link does not replace it.
Paste the three Sepolia contract addresses and their Etherscan source links into
the Moodle text box as well.

| Requirement | Weight | Current evidence | Status |
|---|---:|---|---|
| Ex0, Ex2, Ex4, Ex5, Ex6 and passing exercise tests | 40% | `src/`, `test/`, `evidence/forge-test.txt`, `evidence/doctor.txt` | Complete locally |
| Ex3 screenshot: supply far above collateral | Required | `evidence/ex3.png`, matching transcript and receipts | Complete locally |
| Sepolia deployment and Etherscan verification | 20% | Three public addresses and source links still needed | Pending |
| A-D answers, 150-300 words per answer; E table and scenario | 25% | `STUDENT-QUESTIONS.md` | Complete |
| Naming, explanatory comments, architecture in README | 15% | `README.md`, contracts and tests | Complete |

Ex1 is an ungraded warm-up. Ex7 is complete but **unmarked**; it does not replace
the graded Sepolia deployment. No grade is guaranteed by this checklist.

## Files and packaging

Run from the project root:

```powershell
python scripts\package-submission.py
```

This creates `output/submission/COMP7810_WangCongjie_3036099368_Lab_DRAFT.zip`, a
Moodle text draft, and a package report. The draft is deliberately marked
incomplete while Tier 2 is pending.

Use this generated archive, not GitHub's source ZIP or a ZIP of the whole working
folder: those alternatives can include dependency key fixtures or local secrets.

The packager includes source, tests, deployment scripts, answers, diagrams,
screenshots, and all dependency runtime sources and licenses under `lib/`.
Dependency self-tests/examples are omitted because some contain hard-coded
sample keys; neither dependency's runtime source is modified. The archive is
validated by extracting it and compiling/running the lab against those bundled
sources. `.env`, `.git`, `.tools`, `broadcast`, caches, temporary files, logs,
and old output archives are excluded. `.env.example` contains empty key fields.
Runtime-generated local demo keys are not saved in the archive.

The key scan checks literal key assignments, seed phrases, and configured key
values without printing them. It is a packaging safeguard, not a proof against
every possible encoded secret; do not add screenshots containing wallet keys.

## What is still needed from you

1. Prepare a throwaway wallet funded with **Sepolia test ETH** and an Etherscan
   API key. Configure `PRIVATE_KEY`, `SEPOLIA_RPC_URL`, and `ETHERSCAN_API_KEY`
   only in the ignored local `.env` file. Do not paste keys into chat or Moodle.
2. Tell Codex the configuration is ready. The deployment helper can deploy all
   three contracts, verify their source, and save public `evidence/sepolia.json`.
   A failed source verification can be retried with
   `scripts/deploy-sepolia.ps1 -Mode VerifyOnly` without redeployment.
3. After successful verification, update the pending status in the README and
   this checklist, then build the final archive with:

   ```powershell
   python scripts\package-submission.py --final
   ```

   The final option refuses missing/unverified Sepolia evidence. It generates
   `MOODLE_TEXT.txt` with the three addresses and source links.
4. Log in to the course Moodle assignment, upload the **final ZIP**, paste the
   generated text, complete any required declaration yourself, and confirm the
   submission receipt before the deadline. No Moodle submission has been made.

Tier 2 status: PENDING
