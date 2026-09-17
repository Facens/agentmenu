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
runImportTests(runner)
runStatuslineBridgeTests(runner)
runBundleVersionTests(runner)
runPublishScriptTests(runner)
runVerifySigningTests(runner)
runCheckSourceTests(runner)

exit(runner.report())
