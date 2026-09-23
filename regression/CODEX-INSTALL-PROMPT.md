# Codex install prompt — IFTC WMS Automated Regression V1 seed

Use the GitHub repository `jemagno1030/IFTC-WMS-TEST-REGRESSION` only.

Safety requirements:
1. Do not modify `main` directly.
2. Create branch `automation/regression-v1` from current `main`.
3. Add the `regression/` directory from the supplied seed package exactly as provided.
4. Do not modify `app.js`, `index.html`, `styles.css`, `config.js`, database SQL installers, or any production repository.
5. Commit with message: `chore: add WMS automated regression v1 seed`
6. Open a pull request targeting `main` titled: `Automated Regression V1 seed`.
7. Do not merge the PR.
8. Report branch name, commit SHA, PR number, and changed file list.

This seed is read-only regression infrastructure. It must not contain destructive LIVE SQL or any LIVE mutation path.
