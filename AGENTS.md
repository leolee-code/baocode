# AGENT

- Reply to the user using their current natural language
- After changing code, run only the tests related to the change. The full test suite is slow and bogs down the machine, so don't run it casually.

# Egress policy (hard rules)

This is a company fork with everything that reaches the publisher's services, or relays content through a third party, removed. Read `docs/egress-policy.md` before merging from upstream or adding anything that touches the network.

- Never add code that contacts `baocode.dev` or any of its subdomains: no telemetry, no self-update, no diagnostics upload, no channel build, no featured or one-click upstreams, no downloads from the publisher.
- Never bring back the phone link, push notifications, bots, or `packages/bao_link` / `packages/bao_iroh`. When an upstream merge conflicts on those paths, keep them deleted and remove the new call sites.
- GitHub and GitLab are the only code hosts an account can be added for; do not bring back Gitee or GitCode.
- Commit attribution defaults to none; do not add a BaoCode trailer.
- A new network call, hard-coded host, native networking API or dependency (direct or transitive) must be explained in `docs/egress-policy.md` and reviewed by a person before it is added to the lists in `test/policy/egress_policy_test.dart`. Do not widen those lists just to make the test pass.
- After any change that touches the network, settings pages, `pubspec.yaml` or an upstream merge, run `flutter test test/policy`.
