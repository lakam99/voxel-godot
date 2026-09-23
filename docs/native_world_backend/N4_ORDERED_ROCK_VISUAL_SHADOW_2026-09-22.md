# N4 ordered rock visual shadow checkpoint

Status: verified shadow slice, not N4 or N3 production cutover.

The ordered rock composer consumes the 28-entry source-ordered stream and
placement bridge without reconstructing the old unfiltered attempt stream.
It recomputes the visual biome at the transformed float32 world anchor using
Godot's rounded-position query, distinct from the attempt's spawn biome. The
catalog-bound visual plan applies resolved environment profiles and effective
visual-manifest rock rows, then binds the selected asset receipt and six
geometry draws into its definition digest. A selected GLB remains an intent:
Godot still owns instantiation and the primitive fallback if loading fails.

The direct Godot service oracle
`artifacts/native-world-backend/n4-rock-visual-biome-oracle.json` passed 18
visual-biome rows and five registry-selection rows, including half-cell and
negative-coordinate boundaries, an edited cell whose visual/spawn biomes
diverge, Unicode hashing, and selection of a disabled asset that cannot be
instantiated. These are direct service/registry contracts, not headed gameplay
or screenshot acceptance. The native component tests cover catalog selection,
ordered visual composition, receipt binding and fallback intent. Independent
read-only review found no actionable critical defect in the plan; its caveat
was to keep the internal primitive marker out of the externally selected
asset identity, which the implementation does.

Integrated command: `node tools/run-native-world-backend-tests.mjs --run-name
n4-rock-visual-plan-01`. The report at
`artifacts/native-world-backend/n4-rock-visual-plan-01/report.json` passed
407/407 debug and 407/407 release standalone tests, editor and isolated
release-adapter smokes, and strict pure-core coverage of 9,019/9,019 lines,
1,219/1,219 functions and 5,308/5,308 branches. The report's source
inventory and binary hashes bind this evidence to the checkpoint inputs.

Caller/deletion audit: these new classes are still pure-core shadow producers;
no normal-gameplay caller consumes the plan. `MainPlaytestTools.gd`, the
generated visual manifest, registry, Godot GLB instantiation and fallback,
surface prop publication, `MainSaveState.gd`, and `removedProps` production
logic remain unchanged. No production code is eligible for deletion on this
evidence. N4 still needs source-bound feature footprints across all changed
families, actual adapter admission and publication, direct headed visual and
collision parity, save/reload and no-resurrection proof, and a later caller
cutover/deletion audit. N3 full checkpoint admission likewise remains open.
