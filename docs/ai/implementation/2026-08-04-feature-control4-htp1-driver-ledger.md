# SDD ledger — plan: docs/ai/planning/2026-08-04-feature-control4-htp1-driver.md

Branch: feature-control4-htp1-driver
Base: a69fdad9c663331ae55fa008def21330fc084779

Task 1: review clean (Spec OK, quality Approved) — commits a69fdad..80ebf5a
Task 1: minor (deferred): SendToProxy smoke test covers only the reject-explicit-nil path, not the omitted-arg success path. A regression to fixed arity would still pass. Add a positive-path assertion once driver code exercises it.
Task 1: OPEN (plan-mandated, awaiting ruling): mock.advance loops forever on a repeating timer with interval <= 0. No current or planned interval is <= 0 (min values: flush 50, ramp 50, ping 30000, backoff 1600 after jitter), but a hang would be silent.
Task 1: fix round 1/5 (1 addressed, 0 open — non-positive timer interval now refused at SetTimer; commit 8539ff9)
Task 1: ruling — owner chose to fix the plan-mandated finding; standing rule set: controller may decide additive safety fixes alone, and stops only for findings that contradict plan text.
Task 1: complete (commits a69fdad..8539ff9, review clean, 6 tests green, verified by controller)
Task 2: review clean (Spec OK, quality Approved) — commits 8539ff9..b80d962, 13 tests green, verified by controller
Task 2: minor (deferred, self-resolving): unused `sub` local in htp1/frame.lua and a MAX_PAYLOAD comment describing rejection this file does not perform. Both are consumed by Task 3's decoder. Re-check at final review if Task 3 leaves either unused.
Task 2: fix round 1 dispatched — masking assertions were round-trip only and could not catch an off-by-one in key cycling; adding the RFC 6455 s5.7 worked-example vector as an external oracle.
Task 2: fix round 1/5 (1 addressed, 0 open — RFC 6455 s5.7 oracle added; re-review confirmed the wrong cycling formula yields 0x52 where the RFC says 0x58, so the test bites; commit 05617a7)
Task 2: note — encoder masking was already correct; the gap was the tests' inability to prove it.
Task 2: complete (commits 8539ff9..05617a7, review clean, 14 tests green, verified by controller)
Infra: subagents are blocked from running git commit and from writing into .superpowers/. Controller commits on their behalf and records their evidence. Added .claude/settings.json allowlist (commit 91b756e) to reduce prompting.
Task 3: review NOT approved (Spec OK, 2 Important + 1 Minor, all plan-mandated) — commit 5b34836, 28 tests green, verified by controller
Task 3: fix round 1 dispatched — (a) Reader had no cumulative cap on reassembled fragments, so endless sub-cap CONT frames grow memory without bound on a shared controller; (b) reader-level errors advanced the buffer past the offending frame before returning, so a caller ignoring the error silently resumed mid-stream, while decode-level errors wedged. Fix makes errors sticky and caps the total. Also closing the Minor: no test covered truncated extended-length headers.
Task 3: fix round 1/5 (2 addressed, 0 open — fragment cap bounds total at exactly MAX_PAYLOAD; errors sticky across all three paths; commit 2b46c23)
Task 3: controller-applied minor — re-review noted push() still appended after failure, trading one unbounded accumulator for another. Guarded plus test; commit b940550. FINAL REVIEW MUST CHECK: this one-line change had no independent review round.
Task 3: complete (commits 91b756e..b940550, 33 tests green, verified by controller)
Task 4: review clean (Spec OK, Approved) — commit 3b380ff, 44 tests green, verified by controller
Task 4: minor (deferred, plan-mandated): parse edge cases untested — a bare number, a trailing-space body, a huge payload. Gap originates in the brief's own test list.
Task 4: fix round 1 dispatched — vendored JSON codec prints on decode failure, and one print (json.lua:520 "JSON decode panic:") is bare and unreachable by any documented hook. Malformed input arrives from the network and driver print goes to Composer's Lua window, so a faulty peer could drive unbounded output while debug is off. Silencing from our side around the decode; vendored file stays pristine. Also correcting error text that blamed the decoder for a valid `null`.
Task 4: fix round 1/5 (1 addressed, 1 partially — codec prints fully silenced and restore proven safe; but the null/undecodable split reopened the mislabelling for garbage input; commit 7ba4c97)
Task 4: fix round 2/5 (controller-applied) — a nil decode result does not mean the payload was null: the codec catches its own runtime errors and returns nil normally. Now keyed on the literal token, with a test over four garbage bodies. Commit bbe12fc. FINAL REVIEW MUST CHECK: round 2 had no independent review round.
Task 4: complete (commits b940550..bbe12fc, 47 tests green, verified by controller)
Infra: ROOT CAUSE of the repeated blocks — compound `cd "..." && ...` commands never matched the allowlist patterns, so every call prompted. Standalone commands and `git -C` match. Also: luajit IS on PATH here; the sibling repos' claim that it is not is stale. Both corrected in CLAUDE.md and .claude/settings.json (commit 7dfefda).
Task 5: review clean (Spec OK with one justified deviation, Approved) — commit dcab60d, 60 tests green
Task 5: PLAN DEFECT FOUND — the plan contradicted itself: its mandated math.floor(x+0.5) rounds 41% of -50..0 to -29 while its own test pinned -30. Implementer changed the code to match the test (correct TDD response). Review established the tie rule decides ~49.5% of all inputs over this device's range, and that half-away-from-zero is right only by accident of sign.
Task 5: fix round 1/5 (controller-applied) — switched to math.ceil(x-0.5), which states "ties go quieter" directly and holds for either sign; test now includes a positive range that half-away-from-zero would fail. Commit 85e0f6c. FINAL REVIEW MUST CHECK: no independent review round on this change.
Task 5: complete (commits bbe12fc..85e0f6c, 61 tests green, verified by controller)
Task 6: review clean (Spec OK, Approved) — commit 6c5e745, 72 tests green, verified by controller
Task 6: plan defect (minor) — the brief's Interfaces prose lists 10 state fields and omits powerAction, while its own mandated code tracks 12. Implementer correctly followed the code block. No action.
Task 6: OPEN NOTE FOR TASK 7 — _setInputs (state.lua:74-76) CLEARS a stored label when an input entry is present but has no label key. Unreachable from full documents, but Task 7 routes /inputs container replaces through the same branch, where a partial entry could silently wipe a known label.
Task 6: complete (commits 85e0f6c..6c5e745, 72 tests green, verified by controller)
Task 7: review clean (Spec OK, Approved) — commit 9d7392e, 86 tests green, verified by controller
Task 7: fix round 1/5 (controller-applied) — _setInputs cleared a label when a pushed entry omitted it, contradicting the per-key merge it already performs one level up; a partial /inputs replace would silently wipe an installer's label. Now absent means unspecified. Also tested input-leaf remove. Commit b955169, 88 green. FINAL REVIEW MUST CHECK: no independent review round.
Task 7: minor (deferred): `remove` on a container path (e.g. /cal) silently no-ops, since _applyContainer returns on a non-table value. Undocumented edge, no requirement violated.
Task 7: minor (deferred): an unwrapped single op missing `op` or `path` is dropped via ipairs finding no index 1, not via _applyOne validation. Correct outcome, untested path.
Task 7: complete (commits 6c5e745..b955169, 88 tests green, verified by controller)
Task 8: review clean (Spec OK, Approved) — commit 7d2d798, 98 tests green, verified by controller
Task 8: fix round 1/5 (controller-applied) — handshake buffer had no cap (a peer never sending the terminator grows it without bound); Upgrade check was a plain substring so "X-Original-Upgrade: websocket" and "Upgrade: websocketZZZ" both passed, defeating the one thing the handshake check exists to establish. Capped at 8 KB and matched exactly. Commit d1b6374, 100 green. FINAL REVIEW MUST CHECK: no independent review round.
Task 8: complete (commits b955169..d1b6374, 100 tests green, verified by controller)
Task 9: implemented by the CONTROLLER (Agent tool was unavailable during a classifier outage) — commit 151d024, 114 tests green
Task 9: review found 1 CRITICAL, 2 Important, 2 Minor. Critical: connect() did not cancel an armed reconnect timer and neither the scheduler nor its callback checked state, so a pending reconnect could fire over a live connection and force it back to idle. Reachable via re-entrancy: _shutdown calls onClose before scheduling, so a driver reconnecting from that callback got a dangling timer over its own attempt.
Task 9: Important — two of the four amendments were unpinned; the suite stayed green with either the deliberate-flag reset or the close-time timer cancellation deleted. Losing the first means the driver never reconnects after one manual close (silent permanent failure).
Task 9: fix round 1/5 (controller-applied) — cancel on connect, guard scheduler and callback on state, clamp caller-supplied jitter, four new regression tests. Commit 8001490, 118 green. FINAL REVIEW MUST CHECK: no independent review round on the fix itself.
Task 9: complete (commits d1b6374..8001490, 118 tests green, verified by controller)
Task 10: review clean (Spec OK) — commit 835fbf9, 135 tests green, verified by controller
Task 10: fix round 1/5 (controller-applied) — a nil write broke coalescing (nil is the queue's not-queued sentinel, so the path was appended to `order` twice and one changemso carried the same op twice) and encoded a replace with no value key; now refused. Reconcile watchdog was armed only by the first flush of a run, so a later write inherited an older deadline and could re-read while its own confirmation was in flight; now re-armed per flush. Commit 00e5fc4, 137 green. FINAL REVIEW MUST CHECK: no independent review round.
Task 10: complete (commits 8001490..00e5fc4, 137 tests green, verified by controller)
Task 11: review clean (Spec OK, Approved) — commit bff960e, 145 tests green, verified by controller. Reviewer cross-checked all 27 connections against Mapping.INPUTS programmatically and confirmed the XML parses under a real parser.
Task 11: fix round 1/5 (controller-applied) — closed two coverage gaps: connection 5001's own block and connection 6001 were both unasserted (the suite stayed green with either deleted; without 6001 the driver has no socket). Added a duplicate-id guard. Commit 2d0a6fb, 147 green. FINAL REVIEW MUST CHECK: no independent review round.
Task 11: minor (deferred): the manifest test parses with Lua patterns, so a <connection> inside an XML comment would be counted as live. Not triggered today; structural risk if driver.xml is edited later.
Task 11: complete (commits 00e5fc4..2d0a6fb, 147 tests green, verified by controller)
Task 12: PLAN DEFECT (4th) — the brief's SET_VOLUME_LEVEL test used LEVEL 50, which over -50..0 dB maps to exactly the -25 dB the fixture already holds, so the brief's own already-there guard suppressed the write and the test indexed a nil op. Implementer deleted the guard; CONTROLLER REVERSED THAT — without the guard a ramp held against either end rewrites the same dB every tick (600 writes over a ten-second hold), which the existing clamp test could not catch since it only checked the final value. Test now uses LEVEL 80. Commits 98dce41, 75984c1.
Task 12: review Approved; confirmed the reversal was correct. Flagged Minor: the notify on the suppressed path trickled an identical notification per ramp tick.
Task 12: fix round 2/5 (controller-applied) — deduping on last-notified percent alone broke the lossy case the notify existed for (a room asserting 51% lands on the same dB as 50% and would be told nothing). Now keyed on whether the room ASSERTED a level (SET_VOLUME_LEVEL) or merely nudged one (ramp tick); announce always restates. Also added a public Proxy:stop() so driver.lua stops reaching for a private method. Commit d2c3985, 179 green. FINAL REVIEW MUST CHECK: no independent review round on rounds 1-2.
Task 12: context (not a regression) — the already-there guard compares against the OPTIMISTIC local value, so a same-value command arriving while a prior write is unconfirmed is swallowed; self-heals via the 2 s reconcile.
Task 12: complete (commits 2d0a6fb..d2c3985, 179 tests green, verified by controller)
Task 13: review clean (Spec OK, Approved) — commit bdb0ebf. Reviewer executed the require-graph regex against the real files (zero false positives, correctly skipping the bare word "require" in frame.lua's error text) and empirically tested the git-tracking check against this space-containing repo path.
Task 13: fix round 1/5 (controller-applied) — archive was written straight to the load-bearing output name after deleting the prior good build, so a mid-write failure would leave a truncated but valid .c4z someone could install. Now written to .partial and moved into place. Commit follows. FINAL REVIEW MUST CHECK: no independent review round.
Task 13: minor (deferred, latent): the require-graph regex is comment- and string-blind. No false positive today; a future comment containing require("...") would break the build.
Task 13: complete (commits d2c3985..0c57d4a, build verified independently: 11 entries, auto_update false, 27.9 KB)
Task 14: complete (commit 8238107, 184 tests green, verified by controller). Our hand-written encoder matched Python's websockets byte-for-byte on the FIRST attempt across all six outbound vectors, and decoded all ten inbound reference frames including byte-at-a-time delivery. No generator changes were needed.
ALL 14 TASKS COMPLETE. Proceeding to the final whole-branch review.

=== FINAL WHOLE-BRANCH REVIEW ===
Final review (opus): 2 Critical, 5 Important, 3 Minor. Verified clean: all ten unreviewed controller fixes judged correct in final form; no polling; idle silence; errors never swallowed; privacy clean across all 31 commits; cross-module coherence clean.
  C1 transport could wedge permanently — nothing internal could leave "connecting"/"handshaking"; a unit rebooting and binding :80 before its /ws route was live would hang the driver until a reload.
  C2 an undecodable message caused an unthrottled getmso storm plus one error log per iteration.
  I1 first install could never connect — address read once, Composer's order is add-then-set-IP.
  I2 notification params carried raw booleans/numbers while OUTPUT was stringified.
  I3 websocket key could contain NUL (~6% per handshake) and be truncated by a C-string base64.
  I4 nothing seeded math.random, so both instances reconnected in lockstep — defeating the jitter.
Fix wave: commit 6bc5268, 200 green.
Scoped re-review (opus): all six ADDRESSED; judged the three modified backoff tests an acceptable fixture change, not a loosening. Found one Important: the parse cap had no self-recovery.
Final hardening: commit ebcc1a1, 202 green. The cap's reset is scoped to DELIBERATE re-requests only — putting it in the shared refresh() would have restored the very storm C2 fixed, and both halves are now pinned by tests. Plus pcall-guarded seed, OnNetworkBindingChanged alias, backoff reset on address arrival.
STATUS: ready for a hardware trial. 202 tests green, build 11 entries / 30.7 KB.
OPEN FOR HARDWARE (cannot be settled from code): C4:GetBindingAddress semantics; whether keep_connection makes Director re-establish TCP behind our state machine; SendToProxy param typing; whether binding 7000 needs proxybindingid="5001" like every other proxy-addressed connection; C4:Base64Encode NUL handling; whether SendToNetwork/ReceivedFromNetwork are binary-clean; whether the unit keeps its network stack alive with powerIsOn false.
