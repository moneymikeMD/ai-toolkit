# Changelog

## [1.6.0](https://github.com/moneymikeMD/ai-toolkit/compare/v1.5.0...v1.6.0) (2026-09-21)


### Features

* add skill-routing, a zero-token SKILL.md description routing check ([fadf40c](https://github.com/moneymikeMD/ai-toolkit/commit/fadf40c540786e9306365ef79579241b31c98a4f))
* bar-check, a diff-scoped CI check for a quality bar being lowered ([14b73e6](https://github.com/moneymikeMD/ai-toolkit/commit/14b73e65644c36273b1b7ffcbc77082c0727bf74))


### Bug Fixes

* bar-check's declared exceptions no longer widen silently ([270fed3](https://github.com/moneymikeMD/ai-toolkit/commit/270fed3eebd8a60f61a72e54130b0ad20981f868))
* skill-routing masked usage errors and miscounted the rank-1 rate ([4183ced](https://github.com/moneymikeMD/ai-toolkit/commit/4183ced54c68edc39f3ea9fbce042f3fa191759e))

## [1.5.0](https://github.com/moneymikeMD/ai-toolkit/compare/v1.4.1...v1.5.0) (2026-09-20)


### Features

* add workspace.sh, a manifest runner for a multi-repo workspace ([#29](https://github.com/moneymikeMD/ai-toolkit/issues/29)) ([3fa071a](https://github.com/moneymikeMD/ai-toolkit/commit/3fa071a2d733c48151dfcd7acc58bac6815d1902))


### Bug Fixes

* no personal home directory in a public repo, plus a reusable gate for it ([#30](https://github.com/moneymikeMD/ai-toolkit/issues/30)) ([a4cd9d8](https://github.com/moneymikeMD/ai-toolkit/commit/a4cd9d8af9a9345a521d1a0b5397a5b52ee7d928))

## [1.4.1](https://github.com/moneymikeMD/ai-toolkit/compare/v1.4.0...v1.4.1) (2026-09-20)


### Bug Fixes

* **landing:** degrade unreadable branch rules and close the head-race in land-queue (WO-047) ([#26](https://github.com/moneymikeMD/ai-toolkit/issues/26)) ([974556a](https://github.com/moneymikeMD/ai-toolkit/commit/974556a55c5f9365ba19998848256dc1c95d4ece))

## [1.4.0](https://github.com/moneymikeMD/ai-toolkit/compare/v1.3.0...v1.4.0) (2026-09-20)


### Features

* **landing:** widen the derived admin bypass and close three freshness gaps (WO-045) ([#24](https://github.com/moneymikeMD/ai-toolkit/issues/24)) ([1f0fa5c](https://github.com/moneymikeMD/ai-toolkit/commit/1f0fa5caf029e1ca3a66325ad58f4a791c4ba54a))
* **mcp:** register the release MCP server for this repo (WO-029) ([#23](https://github.com/moneymikeMD/ai-toolkit/issues/23)) ([bf40c11](https://github.com/moneymikeMD/ai-toolkit/commit/bf40c11142d40d57b6cdd469db6ba0cb1ddc156e))

## [1.3.0](https://github.com/moneymikeMD/ai-toolkit/compare/v1.2.0...v1.3.0) (2026-09-20)


### Features

* **land-queue:** add scripts/land-queue.sh for wave landing ([#20](https://github.com/moneymikeMD/ai-toolkit/issues/20)) ([9f9f7ff](https://github.com/moneymikeMD/ai-toolkit/commit/9f9f7ff28fef01197db6f924034279aa588a3c24))
* **verify-run:** add a verify-block runner with the four rules built in ([#19](https://github.com/moneymikeMD/ai-toolkit/issues/19)) ([c8f35b3](https://github.com/moneymikeMD/ai-toolkit/commit/c8f35b34d4794d6283570610f22706e47abad46e))

## [1.2.0](https://github.com/moneymikeMD/ai-toolkit/compare/v1.1.0...v1.2.0) (2026-09-20)


### Features

* **pr-land:** merge a PR behind a required-check gate ([#17](https://github.com/moneymikeMD/ai-toolkit/issues/17)) ([f717cae](https://github.com/moneymikeMD/ai-toolkit/commit/f717cae25dc31472eab326c4025b9be676c9f219))

## [1.1.0](https://github.com/moneymikeMD/ai-toolkit/compare/v1.0.1...v1.1.0) (2026-09-19)


### Features

* **git-retry:** retry only transient git network failures ([#14](https://github.com/moneymikeMD/ai-toolkit/issues/14)) ([47934c9](https://github.com/moneymikeMD/ai-toolkit/commit/47934c993a7adff58aacbe75ec09ab6e9bfacc7d))

## [1.0.1](https://github.com/moneymikeMD/ai-toolkit/compare/v1.0.0...v1.0.1) (2026-09-19)


### Bug Fixes

* **comment-lint:** make report-only actually suppress the build failure ([#12](https://github.com/moneymikeMD/ai-toolkit/issues/12)) ([f6efde8](https://github.com/moneymikeMD/ai-toolkit/commit/f6efde867ccf25b2950b66beca13a1d5ce1210b8))

## [1.0.0](https://github.com/moneymikeMD/ai-toolkit/compare/v0.1.0...v1.0.0) (2026-09-18)


### Features

* comment-lint as a composite action and reusable workflow ([5b07920](https://github.com/moneymikeMD/ai-toolkit/commit/5b07920a94b8c2b8c708e46b35e918361b62a018))
