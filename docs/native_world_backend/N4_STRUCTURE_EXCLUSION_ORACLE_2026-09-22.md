# N4 direct structure-exclusion oracle

Run `node tools/run-surface-structure-exclusion-oracle.mjs --report-path artifacts/native-world-backend/n4-surface-structure-exclusion-oracle-03/report.json`.

This is a direct Godot `StructureSystem.blocks_natural_prop_at_cell` contract with 28 ordered, synthetic XZ decisions. It exercises natural-exclusion and terrain-footprint inclusive maxima, Citadel reservation half-open maxima, negative/2048-cell seams, ready/prepared equivalence, pending/unrequested behavior, record content replacement, insertion-order-independent *oracle* content digest, and clearing record stores. The test uses synthetic `source_state` results because the query is intentionally non-enqueuing. It reports both the decision vector and per-check outcomes.

The digest here is a reference over sorted semantic fixture records, **not** a production structure snapshot digest. Record-store clearing is not a full `StructureSystem.reset()` integration test. The coordinates are an explicit decision fixture, not the 28 PCG-generated coordinates from a live chunk; the test does not cover the `request_bounds` pre-RNG gate, full generated Citadel admission, live prop RNG, geometry/collision publication, or gameplay. Those remain N4 cutover obligations.
