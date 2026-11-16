Answers and pages for the integration tests, `Tests/integrations.py` and `Tests/integration_previews.py`.

Broadway takes no API key or token. It reads GitHub from signed-in pages and Linear from the web app's session, so these are what a signed-in space would get. All written by hand, not recorded: the tests may never call either service with a real session. Names, repositories and issues are made up.

- `linear-assigned.json`, `linear-assigned-later.json`, `linear-inbox.json`, `linear-cycle.json`: answers of Linear's GraphQL (`assignedIssues`, `notifications`, `teams.activeCycle`) as the session endpoint gives them. `linear-assigned.json` carries comments and history for unseen activity (one by the viewer, one by an integration with no user); the `-later` file is the same list after someone else commented.
- `linear-unauthenticated.json`: what a call with no session gets.
- `linear-preview.json`: one issue for a link preview.
- `github-preview.html`: a pull request's page as a signed-in space sees it, for a link preview.
- `github-sso-banner.html`: the list page's "Single sign-on to see results in the … organization" banner, copied in shape from github.com with an invented organisation.
- `ecb-daily-2026-11-03.xml`: the ECB's daily reference rates, for `Tests/field_extras.py`.
