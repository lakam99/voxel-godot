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

Follow-up adapter/caller audit: `MainCore.gd` constructs one environment
catalog and passes it into `VisualAssetRegistry.setup`; registry setup may
replace the object and clears/rebuilds asset maps and scene cache. A future
native admission must capture the active registry's effective ID values and
independent family member lists, plus resolved profiles during that setup, bind an active registry
generation/readiness receipt, and invalidate it on replacement or reload.
The registry's family lists retain duplicate-ID rows while its ID map
overwrites the value, so reconstructing candidate lists from `assets_by_id`
alone would mistranslate live selection. Native selection must not mask an
import failure by picking a different asset; Godot's documented primitive
fallback remains presentation policy. Production surface cutover must replace
the shared 28-attempt stream atomically across rock, ore, tree, forage and
wildlife; replacing only `make_rock` would shift later RNG decisions. The
underground `make_rock` caller is a separate source path. These are current
cutover requirements, not claims that the adapter or gameplay now pass.

Effective-registry core checkpoint: `NativeSurfaceRockAssetCatalog::create_effective`
now accepts the active last-write-wins ID values and ordered family lists as
separate inputs. It preserves cross-family membership and duplicate IDs, uses
the final ID value for tag/path/size, and binds both value and membership
payloads into its digest. The earlier manifest-row constructor remains only
for existing shadow tests until the adapter cutover. A focused standalone
debug link of `test_main`, the rock-catalog tests, and the current core library
passed 10/10 tests; the wider direct debug binary passed 458/458, but its
wildcard object link is not a source-inventoried integrated gate. No adapter
retains this effective catalog and no production caller consumes it yet.

The first source-inventoried gate for this checkpoint,
`artifacts/native-world-backend/n4-effective-registry-owner-01/report.json`,
passed 445/445 standalone tests in both debug and release and all line and
function coverage. It is blocked at 5,930/5,940 pure-core branches. All ten
missing branches are the new effective-catalog bounds/numeric rejection
conditions, not gameplay or adapter failures. A focused 11/11 test run now
exercises those exact rejection lanes; the full coverage gate still needs a
rerun. The same gate built the adapter, and the direct Godot
`N4BiomeCatalogAdapterContract.gd` passed after typed biome catalog retention
was added. The retained catalog is invalidated on any rejected replacement.
This remains a shadow receipt, not a live N4 publication.
