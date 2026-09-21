// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// Every suite is wired here once, so no implementation unit has to edit this
// file to add its own tests. Each suite lives in its own file.
let runner = TestRunner()

runTOMLTests(runner)
runConfigStoreTests(runner)
runManifestRegistryTests(runner)
runPresetResolverTests(runner)
runCommandBuilderTests(runner)
runUsageReaderTests(runner)
runUsageProjectionTests(runner)
runUsageAlertTests(runner)
runResolveCommandTests(runner)
runStatuslineBridgeTests(runner)
runBundleTranslocationTests(runner)
runBundleVersionTests(runner)
runReleaseChannelTests(runner)
runUpdatePolicyTests(runner)
runPublishScriptTests(runner)
runVerifySigningTests(runner)
runCheckSourceTests(runner)
runHarnessScriptTests(runner)
runImageRecipeTests(runner)
runHarnessGuestTests(runner)
runHarnessScenarioTests(runner)
runAccessibilityIDTests(runner)
runJournalTests(runner)
runOverridesTests(runner)
runHarnessFixtureTests(runner)
runHarnessReportTests(runner)
runHarnessGateTests(runner)

exit(runner.report())
