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
| Sepolia deployment and Etherscan verification | 20% | `evidence/sepolia.json`; three verified source links in README and generated Moodle text | Complete |
| A-D answers, 150-300 words per answer; E table and scenario | 25% | `STUDENT-QUESTIONS.md` | Complete |
| Naming, explanatory comments, architecture in README | 15% | `README.md`, contracts and tests | Complete |

Ex1 is an ungraded warm-up. Ex7 is complete but **unmarked**; it does not replace
the graded Sepolia deployment. No grade is guaranteed by this checklist.

## Files and packaging

Run from the project root:

```powershell
python scripts\package-submission.py --final
```

This creates `output/submission/COMP7810_WangCongjie_3036099368_Lab.zip`,
`MOODLE_TEXT.txt`, and `PACKAGE_REPORT.json`. Use the final ZIP without a
`_DRAFT` suffix. The final option requires confirmed deployments, the vault's
minting role, and successful source verification for all three contracts.

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

1. Review the answers and code so you can explain your submission. Follow the
   course's rules for acknowledging assistance and complete any declaration yourself.
2. Log in to the course Moodle assignment and upload the **final ZIP** from
   `output/submission/` (the file without `_DRAFT` in its name).
3. Paste the contents of `output/submission/MOODLE_TEXT.txt` into Moodle's text
   box. It contains the three Sepolia contract addresses and verified source links.
4. Confirm the final submission and keep its receipt before **16 October 2026,
   23:55**, using the timezone displayed by Moodle.

Deployment and Etherscan verification are complete. No additional ETH or wallet
transactions are needed. No Moodle submission has been made.

Tier 2 status: COMPLETE
