// Help is resolved before the runner callback: no artifacts, hashing or launch.
const details = {
  'building-contract': '-Contract <Name.gd|res://artifacts/citadel-runtime-integration/...gd> -OutputDirectory <fresh path> -ReportEnvironment <UPPER_CASE_NAME> [-OutputIsDirectory] [-TimeoutSeconds <1..240; default 30>]',
  'building-scene-publication-contract': '[-Phase <facade|actual; default actual>]',
  'building-validation-cancellation-contract': '-AuthorizeLaunch [-StageMap <JSON object: entry,resolve,grid,support_resolution,validation,frame,final>] [-TimeoutSeconds <1..60; default 60>]',
  'citadel-completion-cancellation-contract': '-Phase <cancellation|parity> -AuthorizeLaunch [-Archive <opening-head snapshot>] [-LaterStage <default bracket_first_started>] [-TimeoutSeconds <1..60; default 60>]',
  'citadel-compound-cancellation-contract': '-Phase <baseline|success|cancellation|failure|reuse-reference|reuse|planner> [-BaselineDirectory <completed baseline>] [-ReuseReferenceDirectory <completed reuse-reference>] [-CancelStage <exact stage>] [-CancelOccurrence <1..1000000>] [-Target <builder|source>] [-Mode <omitted|empty|true>] [-ExpectedBuilderSha256 <hash>] [-PrepareOnly] [-AuthorizeCurrent] [-TimeoutSeconds <1..90>]',
  'citadel-landscape-cancellation-contract': '-Phase <baseline|parity|cancellation> [-BaselineDirectory <completed baseline>] [-Target <houses|sites|records>] [-Mode <omitted|empty|true>] [-CancelStage <stage>] [-CancelOccurrence <positive integer>] [-AuthorizeCurrent] [-ExpectedComposerSha256 <hash>] [-TimeoutSeconds <1..90>]',
  'citadel-retained-paving-cancellation-contract': '-Phase <baseline|success|cancellation|synthetic> [-BaselineDirectory <completed baseline>] [-Target <adapter|helper>] [-Mode <omitted|empty|true>] [-CancelStage <stage>] [-ArmStage <stage>] [-CancelOccurrence <1..1000000>] [-AuthorizeCurrent] [-ExpectedHelperSha256 <hash>] [-ExpectedComposerSha256 <hash>] [-TimeoutSeconds <1..90>]',
  'citadel-main-menu-diagnostic': 'Ordinary headed menu; 600-second owned watchdog, isolated user data and cleared VOXEL_/CITADEL_/BUILDING_/TREE_ variables. No gameplay acceptance inferred.',
  'citadel-recipe-preparation-contract': '-Phase <reference|fixture|worker> [-ReferenceDirectory <completed reference phase; required for consumers>]',
  'citadel-sign-completion-contract': '-Phase <final_old|final_new|initial|blocked> [-FinalSnapshot <path>] [-ReferenceSnapshot <path>]',
  'citadel-structural-composer-contract': '[-Seed <integer; default 208159>]',
  'citadel-structural-composer-two-phase-contract': '-Mode <Codec|PhaseA|PhaseB> [-PhaseADirectory <completed Phase A; required for PhaseB>] [-Seed <integer; default 208159>]',
  'citadel-visual-preservation': '[-Mode <Import|Contract|Capture; default Contract>] [-Variant <urban|compound; default urban>] [-Seed <positive integer; default 208159>]',
  'household-sign-placement-contract': '[-InputSnapshot <path>] [-ReferenceSnapshot <path>]',
  'npc-biped-poc': '[-Seed <integer; default 209154>] [-Capture] [-ArtifactDir <fresh path; default artifacts/npcs/npc-biped-poc>] [-TimeoutSeconds <1..86400; default 600>]',
  'npc-biped-recipe-contract': '[-ArtifactDir <fresh path; default artifacts/npcs/npc-biped-recipe-contract>] [-TimeoutSeconds <1..86400; default 120>]',
};
export function runnerHelp(name) {
  const frozen = ['citadel-compound-cancellation-contract', 'citadel-landscape-cancellation-contract', 'citadel-retained-paving-cancellation-contract'].includes(name);
  const common = name === 'building-contract' ? '' : '-OutputDirectory <fresh path>' + (frozen ? '' : ' [-GodotExe <console executable>] [-ProjectPath <project root>]');
  return 'Usage: node tools/run-' + name + '.mjs ' + common + '\n' + (details[name] ?? 'Runs the focused fixture with its dedicated report, source, log and cleanup checks.') + '\n\nSingle-dash PowerShell-style parameter names and double-dash kebab-case names are supported.\n--help / -Help / -h prints this text without launching or creating artifacts.\nOutputs must be fresh; constrained contracts require their named prefix directly under artifacts/citadel-runtime-integration.\nEvidence remains source/service/diagnostic only unless separately verified in live gameplay.\n';
}
