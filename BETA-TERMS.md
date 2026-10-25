# Preflight beta terms

*Draft, 2026-10-24. To be read by Logan before the first key is issued, and
by a lawyer before any paid plan.*

Plain words, because these are short on purpose.

1. **It is free.** The beta costs nothing and asks for no payment details.

2. **Each key lasts 90 days.** Keys may be renewed at Preflight's discretion.
   When a key ends, Preflight becomes read-only: your history, polling and
   the report button keep working; new replays, recordings and deploys stop
   until a current key is entered. Rollback also keeps working, and it still
   writes to your n8n: it restores a version that was live there before.

3. **It runs on your machine.** Preflight stores your recordings, workflow
   versions and the n8n API keys you register in its own database on your
   computer. It sends nothing to anyone unless you press **Send** on a report,
   after a preview of exactly what the report contains. A sent report goes to
   preflightgate.com with your beta key, and from there to Preflight's
   private issue tracker and its founder's inbox.

4. **No warranty.** The beta is provided as is, without any promise that it
   is fit for a particular purpose or free of faults. It is a testing tool:
   a green result is evidence about the runs it replayed, not a guarantee
   about every run. You decide what to deploy.

5. **No support guarantee.** Reports are read and answered as time allows.

6. **Your key is yours.** Please do not share it. A key that is shared or
   misused may be revoked; revocation stops it sending reports.

7. **You can stop at any time** by stopping and removing the stack
   (`docker compose down -v` removes its data too). Nothing on your n8n
   depends on Preflight, except the optional run-count workflow if you
   imported it; deactivate that in n8n when you stop.

8. **These terms may change** with a new release; the release notes will say
   so. They are governed by the laws of Alberta, Canada.
