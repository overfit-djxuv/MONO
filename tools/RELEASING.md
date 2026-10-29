# Releasing MONO

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, then `tools/generate.sh`.
2. Add the release at the top of `VersionHistory.releases` (`MONO/Services/VersionHistory.swift`): features in `notes`, then `improvements`, `fixes`, `security`. Only list what was built and verified.
3. Add the same release to the top of `CHANGELOG.md`, using the heading `## <version> · <date> · <title>`. A unit test fails if the two lists differ or the top version isn't the app version.
4. Run unit and UI tests. If the data model changed, rehearse the migration on a pulled copy of the real store.
5. `FORCE=1 tools/backup-data.sh`, then `tools/refresh-install.sh`, then pull the data and check it.
6. Commit with the version in the message.

Rollback: not supported in-app (iOS can't downgrade an installed app, and older builds may not read newer data). Restore data from a backup instead.
